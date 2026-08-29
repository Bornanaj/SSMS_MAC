# Architecture notes

## Why a hand-written TDS driver

macOS has no first-party SQL Server driver. The alternatives all add an install step the
user has to perform before the app works: Microsoft's ODBC driver needs Homebrew and a EULA
acceptance, FreeTDS needs Homebrew, JDBC needs a JVM. Implementing TDS 7.4 directly means
the `.app` is self-contained.

## The TLS handshake is wrapped in TDS packets

SQL Server negotiates encryption inside the protocol rather than before it. The client
sends PRELOGIN, the server answers with an encryption byte, and then the TLS handshake runs
**with each handshake flight encapsulated in a TDS packet of type 0x12**. Once the handshake
completes, the relationship inverts: TDS packets travel inside TLS records.

The pipeline is arranged so this works with stock NIOSSL:

```
socket → TDSTLSHandshakeWrapper → NIOSSLClientHandler → TDSTLSCompletionNotifier
       → ByteToMessageHandler(TDSPacketDecoder) → TDSPacketWriter → TDSConnectionHandler
```

Two details are easy to get wrong and both cost real debugging time:

1. **The wrapper must be installed before the TLS handler.** `NIOSSLClientHandler` writes
   its ClientHello the moment it joins an active channel. Adding TLS first means that first
   flight escapes unencapsulated and the server never answers.
2. **User events travel away from the network**, so the wrapper cannot observe
   `TLSUserEvent.handshakeCompleted` itself. `TDSTLSCompletionNotifier` sits directly above
   the TLS handler and flips the wrapper into pass-through mode.

The wrapped handshake is capped at TLS 1.2. SQL Server only negotiates 1.3 in strict
(TDS 8.0) mode, where TLS is established before any TDS traffic and no wrapping is needed.

## One TDS packet per TLS record

A multi-packet request written as a single buffer is a valid TDS byte stream, and it works
without encryption. Under TLS the server drops the connection. SQL Server keeps the
one-packet-per-record relationship it established during the encapsulated handshake, so
`TDSPacketWriter` writes **and flushes** each packet individually. Every other TDS driver
does the same thing; the failure mode without it is an abrupt disconnect with no error
token, which is thoroughly unhelpful.

## Streaming the token stream

`TDSTokenStreamParser` is incremental. It parses as many complete tokens as the buffer
holds and rewinds the reader index when a token is only partially present, so a result set
of any size streams packet by packet with memory bounded by the largest single row. A
dedicated `TDSNeedMoreData` error distinguishes "wait for more bytes" from a genuine
protocol violation.

## Actor reentrancy and the request lock

`SQLServerSession` is an actor, which serialises *entry* into its methods but not their
`await` points. Two catalog queries could therefore interleave on one connection, and TDS
has no multiplexing. `AsyncLock` in `TDSKit` serialises requests properly, in FIFO order.
The promise handed to the channel handler is also created inside the same event-loop hop
that hands it over, so a rejected request can never strand an unfulfilled promise — NIO
traps on those in debug builds.

## Values are decoded, not converted

`TDSValue` keeps SQL Server's own representation:

- `TDSDecimal` stores a digit string plus a scale, so `decimal(38,10)` survives intact.
  Routing it through `Double` would silently lose digits.
- `TDSTemporal` stores calendar components and a scale rather than a `Date`, so
  `datetime2(7)` keeps all seven fractional digits and `datetimeoffset` renders in its own
  offset instead of the machine's time zone.
- `real` is a separate case from `float` so it renders with 7 significant digits.
- Non-Unicode text is decoded through the code page implied by the column's collation.
  `CFStringConvertWindowsCodepageToEncoding` covers every code page SQL Server can store,
  including 1256 for Persian and Arabic collations.

## CRLF is one Character in Swift

Swift's `Character` is a grapheme cluster, and `\r\n` is a single cluster. A CSV parser that
scans `Array(text)` and compares against `"\n"` silently fails to split rows in any file
written on Windows — which is most exported CSVs. `CSVParser` walks unicode scalars instead.

## Testing without Xcode

XCTest ships with Xcode, not with the Command Line Tools, so `swift test` is unavailable in
a CLT-only environment. The regression suite is a plain executable (`swift run ssms-tests`)
with a small assertion harness, and it exits non-zero on failure so CI can use it directly.

`ssms-mac --selftest` runs the app's own models — `AppState`, `ObjectExplorerModel`,
`QueryTab`, `ResultSetModel` — against a live server without a window, covering the exact
code path the SwiftUI views bind to.

## Admin work gets its own connection

The Object Explorer shares one metadata connection per session, because a tree expansion is
a short read and a fresh login per folder would be visible. Administration is the opposite:
`DBCC CHECKDB`, `BACKUP`, `DBCC SHRINKFILE` and `sp_configure` all run long, and TDS has no
multiplexing, so any of them on the shared connection would freeze the tree.

`AdminRunner` draws the line. Its `read` goes through the shared connection; its `run` and
`runCollectingMessages` open a connection, use it and close it. `runCollectingMessages`
exists because DBCC and the detach/shrink procedures report their results as info tokens
rather than as result sets, so the caller needs the message stream rather than rows.

## Some SQL cannot be parameterised, so it is validated instead

TDS has no way to parameterise an identifier, a permission name or a collation. Those
values reach a statement as text, so each one is checked against what SQL Server actually
accepts rather than escaped and hoped for:

- Identifiers go through `SQLIdentifier.quote`, which doubles closing brackets.
- String literals go through `SQLIdentifier.literal`, which doubles quotes.
- A permission name has to be letters and single spaces (`VIEW DEFINITION`,
  `ALTER ANY SCHEMA`); anything else is rejected, so `SELECT; DROP TABLE x` can never
  become a `GRANT`.
- A collation name has to be letters, digits and underscores.
- A `sp_configure` option name is matched against `sys.configurations` before it is used,
  and its value against that row's minimum and maximum.
- An Agent job id is parsed as a `UUID` before it goes anywhere near `sp_start_job`.

The regression suite pins each of these, including the rejections.

## Generate Scripts orders by tier, then topologically inside the tier

A script that creates a view before the view it selects from does not run. Ordering the
whole database topologically is overkill, though: kinds already imply most of the order —
schemas and types first, then tables, then functions, views and procedures, then triggers.

`ScriptProject.ordered` ranks by kind and only runs a topological sort *inside* a rank,
using `sys.sql_expression_dependencies` for the edges. Cross-rank edges are already
satisfied by the ranking, so they are dropped. Two procedures that call each other — which
SQL Server allows — form a cycle; the sort emits the whole cycle in alphabetical order
rather than dropping either one, because a missing object is a worse outcome than a
statement that has to be re-run.

Foreign keys need no ordering at all: `ScriptGenerator` emits them as `ALTER TABLE` after
every table exists.

## Agent stores times and durations as decimal-packed integers

`msdb.dbo.sysschedules.active_start_time` is the integer `HHMMSS`, so 2 AM is `20000`, and
`sysjobhistory.run_duration` is `HHMMSS` too — `13045` is an hour and a half, not thirteen
thousand seconds. Reading either as a count of seconds is wrong by a factor that looks
plausible, which is exactly the kind of bug that survives review, so
`AgentScheduleFormatter` owns the conversions and the suite pins them.

The frequency columns are a small bitfield language on top of that: a weekly schedule packs
its days into a mask starting at Sunday = 1, and a "monthly relative" schedule carries both
an ordinal (`freq_relative_interval`) and a weekday (`freq_interval`). All of it is decoded
in one pure function so it can be tested without an Agent.
