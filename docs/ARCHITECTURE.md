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
