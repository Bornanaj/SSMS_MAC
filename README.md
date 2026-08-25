# SSMS for Mac

[![CI](https://github.com/Bornanaj/SSMS_MAC/actions/workflows/ci.yml/badge.svg)](https://github.com/Bornanaj/SSMS_MAC/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black?logo=apple)](https://www.apple.com/macos/)
[![Swift 6](https://img.shields.io/badge/Swift-6-orange?logo=swift)](https://swift.org)

A native macOS SQL Server client in the shape of SQL Server Management Studio:
Object Explorer, a T-SQL editor with IntelliSense, a results grid, execution plans,
scripting, an editable data grid, activity monitoring, backup/restore and flat-file
import.

It talks to SQL Server directly. There is **no ODBC driver, FreeTDS, Docker container
or JVM to install** — the TDS 7.4 protocol is implemented in Swift inside this repo.

```
┌─────────────────────────────────────────────────────────────┐
│ SSMSMac        SwiftUI + AppKit app                          │
│                Object Explorer · editor · grid · dialogs     │
├─────────────────────────────────────────────────────────────┤
│ SQLServerKit   sessions · catalog queries · scripting ·      │
│                admin · IntelliSense · import/export          │
├─────────────────────────────────────────────────────────────┤
│ TDSKit         TDS 7.4 over SwiftNIO + NIOSSL                │
│                PRELOGIN · TLS · LOGIN7 · token stream        │
└─────────────────────────────────────────────────────────────┘
```

## Install

### Build from source — recommended

One command. The app is compiled on your machine, so macOS never quarantines it and
opens it with **no Gatekeeper prompt**:

```bash
git clone https://github.com/Bornanaj/SSMS_MAC.git
cd SSMS_MAC && ./Scripts/install.sh
```

Needs macOS 14+ and the Xcode Command Line Tools (`xcode-select --install`). Full Xcode
is not required — the build uses SwiftPM and assembles the `.app` bundle by hand.

### Homebrew

```bash
brew tap bornanaj/ssms https://github.com/Bornanaj/SSMS_MAC.git
brew install --HEAD bornanaj/ssms/ssms-mac
```

### Disk image

Grab the `.dmg` from [Releases](https://github.com/Bornanaj/SSMS_MAC/releases) and drag
the app to Applications.

Unless the release notes say the build is notarized, macOS will ask once:

> Apple could not verify "SSMS for Mac" is free of malware…

That is the quarantine flag macOS attaches to *anything* downloaded, not a problem with
the app. Open it once with **right-click → Open → Open** and macOS remembers the choice.
Clearing the flag outright also works:

```bash
xattr -dr com.apple.quarantine "/Applications/SSMS for Mac.app"
```

Removing that prompt for downloads requires an Apple Developer ID certificate and Apple
notarization ($99/year); the release pipeline already implements it and switches on as
soon as the signing secrets exist. [docs/CODE_SIGNING.md](docs/CODE_SIGNING.md) explains
the whole mechanism.

## Requirements

- macOS 14 or later, Apple silicon or Intel
- Swift 6 toolchain — the **Command Line Tools are enough**, Xcode is not required
- A reachable SQL Server 2016–2022, Azure SQL Database, or Azure SQL Managed Instance

## Building by hand

```bash
swift build -c release          # libraries and executables
./Scripts/build-app.sh release  # -> build/SSMS for Mac.app
./Scripts/make-dmg.sh release   # -> build/SSMS-for-Mac-1.0.0.dmg
```

## Features

**Connecting**
- SQL Server authentication, Windows authentication (NTLMv2), Microsoft Entra ID access tokens
- Encryption: mandatory (default), strict (TDS 8.0), or off; optional certificate trust
- Named instances resolved through the SQL Browser (UDP 1434)
- Saved connections with passwords in the login keychain, per‑connection tab colours
- Azure SQL redirection (ENVCHANGE routing) is followed automatically

**Object Explorer**
- The SSMS tree: Databases → Tables/Views/Programmability/Storage/Security, plus
  server‑level Security, Server Objects and Management
- Lazy expansion, one round trip per folder, name filter, system‑object toggle
- Context menus: Select Top 1000 Rows, Edit Top 200 Rows, Script as
  CREATE/ALTER/DROP/SELECT/INSERT/UPDATE/DELETE, Properties, Refresh

**Query editor**
- T‑SQL syntax colouring, line numbers, current‑line highlight
- IntelliSense that understands aliases: `c.` after `FROM dbo.Customers AS c` lists that
  table's columns; `EXEC sales.` lists only procedures
- Signature help, snippets, block indent, comment toggle, SQL formatter
- `GO` batch splitting including `GO 5`, comment‑ and string‑aware
- F5 executes, ⇧F5 executes the selection, ⌘. cancels (a real TDS attention)

**Results**
- Virtualised grid backed by `NSTableView`; 100k rows stay responsive
- Multiple result sets, Messages with clickable error lines, client statistics
- Actual and estimated execution plans with per‑operator cost and missing‑index hints
- Export to CSV, TSV, JSON, XML, Markdown, HTML, SQL INSERT and XLSX

**Administration**
- Activity Monitor: processes, blocking, resource waits, expensive queries, file I/O, KILL
- Database and table properties, index fragmentation with rebuild/reorganize
- Backup and restore script generation, `RESTORE HEADERONLY` / `FILELISTONLY` inspection
- Import Flat File with delimiter sniffing, encoding detection and type inference

## Data fidelity

Values are decoded from the wire, not through an intermediate driver, so they render the
way SSMS renders them:

| Type | Rendered as |
|---|---|
| `decimal(38,10)` | `12345678901234567890123456.7890000000` (never via `Double`) |
| `datetime` | `1999-12-31 23:59:59.997` (1/300 s ticks) |
| `datetime2(7)` | `2024-06-15 08:30:15.1234567` |
| `datetimeoffset(7)` | `2024-06-15 08:30:15.1234567 +03:30` |
| `real` | `3.14159`, not `3.141590118408203` |
| `money` | `1234.5678` |
| `varchar` in a Persian/Arabic collation | decoded through Windows‑1256 |

Non‑Unicode columns are decoded using the code page implied by the column's collation, so
`varchar` data in `Arabic_CI_AS` or `Persian_100_CI_AS` reads correctly instead of turning
into mojibake.

## Testing

```bash
swift run ssms-tests          # 120 offline regression checks, no server needed
swift run tdscli all          # service smoke tests against a live server
./.build/debug/ssms-mac --selftest   # drives the real UI models end to end
```

The live tests read `SQL_HOST`, `SQL_PORT`, `SQL_USER`, `SQL_PASSWORD` and `SQL_DB`.
To bring up a server to test against:

```bash
docker run -d --platform linux/amd64 --name ssms-mac-test \
  -e ACCEPT_EULA=Y -e 'MSSQL_SA_PASSWORD=Str0ngP@ssw0rd!' -e MSSQL_PID=Developer \
  -p 11433:1433 mcr.microsoft.com/mssql/server:2022-latest
```

## Known limitations

- Login‑only encryption (`ENCRYPT_OFF`) is not implemented; connections are either fully
  encrypted or fully plaintext. Every SQL Server since 2005 supports full encryption.
- Windows authentication uses NTLMv2. Kerberos and channel binding are not implemented,
  so a server configured to require them will reject the login.
- MARS is not negotiated. Each query window owns its own connection, which is how SSMS
  behaves anyway.
- The execution plan is a cost‑annotated operator tree, not the SSMS graphical canvas.
- Always On, Replication, Service Broker and SQL Agent job editing are not implemented;
  SQL Agent jobs are listed but not editable.

## Contributing

Issues and pull requests are welcome. `./Scripts/test.sh` runs the offline suite, plus
the live suites when a SQL Server is reachable on `SQL_HOST:SQL_PORT`. CI runs the
offline suite and builds the bundle on every push.

## Licence

MIT — see [LICENSE](LICENSE).

## Layout

```
Sources/
  TDSKit/          protocol: packets, PRELOGIN, LOGIN7, tokens, type decoding, NTLM
  SQLServerKit/    session, catalog queries, scripting, admin, IO, IntelliSense
  SSMSMac/         SwiftUI app
  SSMSTests/       offline regression suite
  TDSCLI/          live service smoke tests
Scripts/
  install.sh           build from source and install into /Applications
  build-app.sh         SwiftPM build plus .app assembly
  make-icon.swift      generates the icon, so no binary art is checked in
  make-dmg.sh          packages the disk image
  sign-and-notarize.sh Developer ID signing and Apple notarization
  test.sh              offline suite, then the live suites when a server answers
docs/
  ARCHITECTURE.md      protocol and design notes
  CODE_SIGNING.md      Gatekeeper, signing and notarization
```
