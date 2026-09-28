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

## The editor palette must not mix colour systems

`Theme.SyntaxPalette` originally took its background from `NSColor.textBackgroundColor`
— a dynamic system colour — while every foreground entry was a fixed sRGB value. A
dynamic colour resolves against whatever appearance is current when it is drawn, so the
light palette's near-black text could land on a dark background and vanish entirely.
Contrast 1.0, no error, no crash, just an editor that swallows everything typed into it.

Two changes keep that from recurring:

- Every palette entry is an explicit sRGB colour, so a palette is internally consistent
  no matter what appearance resolves around it.
- The appearance is read from the text view itself, not its enclosing scroll view.
  Before the view joins a window the scroll view still reports the process default, which
  is how the wrong palette got latched in and then cached behind a change guard.

`ssms-mac --editor-check` renders the editor headlessly in both appearances and asserts
WCAG contrast between every attribute run and the background, plus the container
geometry and glyph counts. Invisible text is not something a compiler or a unit test on
the model layer can catch, so the check runs in CI.

## A custom NSRulerView stops the editor compositing

The line-number gutter began life as an `NSRulerView`, and the editor drew nothing at
all: no text, and not even its own background colour. Everything that can be measured
said the view was fine — 51 glyphs laid out, a used rect of the right size, correct
foreground and background colours, `isHidden` false, `alphaValue` 1, a non-empty
`visibleRect`, a layer with contents — and `cacheDisplay(in:to:)` rendered the text
correctly into an offscreen bitmap.

The give-away was in the scroll view's geometry:

```
clipView.frame   {{0, 0}, {692, 340}}     <- full width, not inset for the ruler
clipView.bounds  {{-46, 0}, {692, 340}}   <- shifted by the rule thickness instead
scroll.visibleRect {{-308, 0}, {1000, 340}}   <- wider than the view's own bounds
```

`NSScrollView.tile()` is supposed to inset the clip view's *frame* to make room for a
ruler. With a custom ruler inside SwiftUI's `AppKitPlatformViewHost` it shifted the
*bounds* instead, and the document view stopped compositing even though every property
still reported a healthy view.

The gutter is now an ordinary sibling view laid out next to the scroll view by
`EditorContainerView`, and the scroll view keeps `rulersVisible = false`. Owning the
layout is a few dozen extra lines and removes an entire class of failure.

`--editor-check` asserts the clip view's frame and bounds both start at the origin,
which is the signature this bug leaves behind.

## The keychain must never be read from a view update

The connect dialog filled in a saved password from `onAppear`, which runs on the main
thread inside a SwiftUI update. `SecItemCopyMatching` blocks on the security daemon, and
after every ad-hoc re-sign macOS wants to prompt before handing the item over. The prompt
cannot be drawn while the main thread is inside a layout pass, so launch simply stopped:

```
ConnectSheet.body.getter
  -> ConnectSheet.prefill()
    -> ConnectionStore.password(for:)
      -> Keychain.password(for:)
        -> mach_msg                     [blocked]
```

Nothing crashed and nothing logged; the window never appeared. `Keychain.password(for:)`
now has an async form that hops to a background queue, and every UI path uses it. The
synchronous form is marked as safe only away from the main thread.

`Scripts/test.sh` bounds the self test at 180 seconds, because a hang is a real failure
here and an unbounded run would just stall.

## Testing without Xcode

XCTest ships with Xcode, not with the Command Line Tools, so `swift test` is unavailable in
a CLT-only environment. The regression suite is a plain executable (`swift run ssms-tests`)
with a small assertion harness, and it exits non-zero on failure so CI can use it directly.

`ssms-mac --selftest` runs the app's own models — `AppState`, `ObjectExplorerModel`,
`QueryTab`, `ResultSetModel` — against a live server without a window, covering the exact
code path the SwiftUI views bind to.

## The blocking tree is built on the client

SQL Server can be asked for the blocking chain with a recursive CTE, and that was the first
attempt. It produced a tree that disagreed with the process list next to it: the two
queries run milliseconds apart, sessions come and go in between, and the operator ends up
looking at a chain whose members are not in the grid above.

`BlockingChain` builds the tree from the same `[ActivitySession]` the Processes tab is
already showing, so the two can never diverge. That moves the fiddly parts to the client,
which is where the tests can reach them:

- A blocker that is not in the list — it disconnected, or it was filtered out as a system
  session — becomes a placeholder root rather than swallowing its waiters.
- A session that reports itself as its own blocker is a parallel query waiting on its own
  sibling tasks. That is not a chain, so it is dropped rather than drawn as a self-loop.
- A cycle is possible in a snapshot even though a real deadlock would have been resolved,
  because the rows are not read atomically. Every member of a cycle is emitted as its own
  root, so a loop can never make a blocked session invisible.

## Query Store is the only place a finished query's plan still exists

The plan cache evicts under memory pressure and on recompilation, so by the time anyone
investigates a slow query it usually has no plan left. Query Store keeps both the plan and
the runtime statistics per interval, which is why the reports are worth having even though
the DMV-based ones in `ServerReports` cover similar ground.

Two details shape `QueryStoreService`:

- Durations are microseconds in `sys.query_store_runtime_stats`, and page counts are
  counts. `QueryStoreMetric.isMicroseconds` decides the divisor rather than a magic 1000
  scattered through the SQL.
- The averages are weighted. `avg_duration` is per interval, so averaging the averages
  would weight a quiet interval the same as a busy one. Every aggregate multiplies by
  `count_executions` first and divides by the summed count at the end.

Execution count has no meaningful regression form — it is a total, not an average — so the
regressed-queries report falls back to duration for it instead of dividing a count by
itself and reporting 1.

## Some SQL cannot be parameterised, so it is validated instead

TDS has no way to parameterise an identifier or a keyword. Those values reach a statement
as text, so each one is checked against what SQL Server actually accepts rather than
escaped and hoped for. `QueryStoreService.setStateScript` takes the operation mode as a
string and refuses anything that is not `OFF`, `READ_ONLY` or `READ_WRITE`; the database
name goes through `SQLIdentifier.quote`. The regression suite pins the rejections, not just
the happy path.

Azure SQL Database needs `ALTER DATABASE CURRENT` because it has no cross-database `ALTER`
and no reachable `master`, so the script builder takes a flag for it and the caller decides
from `ServerInfo`.

## Schema Compare works on snapshots, whatever the source

Every data source — a live database, a `.ssnap` file, a scripts folder — is turned into the
same `SchemaSnapshot` before anything is compared, so the comparer, the deployment planner
and the reports never know where a side came from. `LiveSchemaReader` reads a database in
about 25 bulk catalog queries (one per object family, never one per object), which keeps a
database with thousands of objects to a few seconds; a family that fails to read (a missing
permission, an older server) becomes a warning on the snapshot rather than a failed
comparison. `SchemaScriptParser` builds the same model from DDL: a table's indexes,
constraints, triggers and permissions may be spread over any files in any order, so they
are collected as pending operations and attached once every file has been read.

Objects are compared twice over. `SchemaNormalizer.prepared` keeps everything deployment
needs (filegroups included, because a partitioned table cannot be re-keyed without its
scheme), while `fingerprint` renders a canonical JSON form with the ignored properties
blanked and collections sorted; two objects are identical exactly when their fingerprints
match. Module bodies are compared through `ModuleText.comparable`, which rewrites the
header to a canonical `CREATE <kind> [schema].[name]` first, so `create proc dbo.x` and
`CREATE PROCEDURE [dbo].[x]` agree, and stored expressions go through
`ModuleText.expression`, because SQL Server hands `DEFAULT 0` back as `((0))`.

## Deployment is planned in phases, then ordered by dependencies

The planner never emits statements in the order differences were found. Each action is
placed in a phase — drop foreign keys, drop, rename, create/alter, late drop, add foreign
keys, post — and objects inside a phase are ordered topologically (Kahn's algorithm) over
the dependency graph read from `sys.sql_expression_dependencies` or, for scripts, from the
names a module body references. Foreign keys are dropped and re-added in one global pass
so a table rebuild never trips over a key on another table. Objects an altered object still
uses (a function a computed column calls, say) move to the late-drop phase.

A table change SQL Server cannot express with `ALTER TABLE` — the identity property of an
existing column, a column order that must match (with *Force column order*), FILESTREAM or
column-set changes, a move to another filegroup, switching memory-optimized on or off — is
deployed as a rebuild: create
`SSMS_Rebuild_<name>`, copy the rows with `IDENTITY_INSERT`, drop the original, rename the
copy, and re-create its indexes, triggers and permissions. The script uses the same
transaction pattern Redgate's tools produce (`IF @@ERROR <> 0 SET NOEXEC ON` after every
batch and an `@Success` check at the end), so a failure anywhere stops the rest of the
script without depending on `XACT_ABORT` reaching batches that fail to compile.

## Data Compare streams one side through the other

Rows are matched through a dictionary keyed by the comparison key's canonical text
(`DataValueComparer.keyComponent`), built from the target while the source streams past
it. Two key values SQL Server considers equal — `'abc'` and `'ABC  '` under a
case-insensitive collation — produce the same text, which is why rows are not ordered on
the server and merged: a server-side `ORDER BY` sorts by the column's collation, and
reproducing every collation's sort order on the client is far harder than reproducing its
equality. Kept rows (differences, and identical rows when they are shown) are capped per
table and outcome by `maximumRowsKept`, so memory stays bounded however large the tables.

The synchronization script turns off only the foreign keys and triggers that are enabled
in the target, and turns the keys back on `WITH CHECK` when they were trusted before, so a
deployment never leaves a key untrusted (which would silently stop the optimizer using it).
Dates are written in the forms SQL Server documents as language-neutral (`'20240304'`,
`'2024-03-04T10:00:00.123'`), because the script may run under a login whose language
reads `2024-03-04` as the 3rd of April.
