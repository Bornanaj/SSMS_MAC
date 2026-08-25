# App layer contract (read before touching Sources/SSMSMac)

Read `docs/INTERNAL_API.md` first for `TDSKit` and `SQLServerKit`. This file covers
the SwiftUI app.

## What already exists

```
Sources/SSMSMac/
  App/            SSMSMacApp (@main, menus), MainWindowView, QueryWindowView,
                  SelfTest, EditorCheck
  State/          AppState, QueryTab, ResultSetModel, ObjectExplorerModel,
                  ConnectionStore, QueryHistoryStore, AppSettings
  ObjectExplorer/ ObjectExplorerView, ObjectExplorerMenu, ObjectExplorerActions
  Editor/         SQLEditorView (NSViewRepresentable), SQLTextView, SQLHighlighter,
                  LineNumberGutter, EditorDump
  Results/        ResultsPaneView, ResultGridView, MessagesView,
                  ExecutionPlanView, ShowplanParser
  Dialogs/        ConnectSheet, ActivityMonitorView, PropertiesViews,
                  BackupRestoreSheets, DataEditorSheet, ImportFlatFileSheet,
                  SettingsView
  Support/        Theme, Keychain
```

## Types you will need

```swift
@MainActor final class AppState: ObservableObject {
    @Published private(set) var servers: [ConnectedServer]
    @Published var tabs: [QueryTab]
    @Published var selectedTabID: UUID?
    @Published var activeSheet: AppSheet?
    @Published var statusMessage: String
    let explorer: ObjectExplorerModel
    let connections: ConnectionStore
    let settings: AppSettings
    let history: QueryHistoryStore
    var selectedTab: QueryTab? { get }
    func server(id: UUID) -> ConnectedServer?
    func server(for node: ObjectExplorerNode) -> ConnectedServer?
    @discardableResult
    func newQueryTab(server: ConnectedServer?, database: String?, text: String = "") async -> QueryTab
    func openScript(_ sql: String, server: ConnectedServer?, database: String?, title: String)
}

@MainActor final class ConnectedServer: ObservableObject, Identifiable {
    let id: UUID
    let session: SQLServerSession      // the SQLServerKit actor
    let profile: ConnectionProfile
    @Published var serverInfo: ServerInfo
    var displayName: String { get }
}

@MainActor final class QueryTab: ObservableObject, Identifiable {
    var text: String                    // the script
    var database: String
    var selectedRange: NSRange
    private(set) var resultSets: [ResultSetModel]
    private(set) var messages: [SQLMessage]
    func execute()
}

enum Theme {
    struct SyntaxPalette { /* plain, keyword, dataType, function, string, comment,
                              number, variable, quotedIdentifier, op, background,
                              currentLine, lineNumber, lineNumberBackground */ }
    static let light: SyntaxPalette
    static let dark: SyntaxPalette
    static func color(hex: String?) -> Color?
}
```

Sheets are presented from `MainWindowView.sheetContent(_:)` off `AppState.AppSheet`.
**Do not edit `AppState` or `MainWindowView`** — the orchestrator wires new sheets in.
Write each dialog as a self-contained `View` whose initialiser takes plain values
(`ConnectedServer`, database name, schema, table…) and which calls `dismiss()` via
`@Environment(\.dismiss)`.

## House rules

- Swift 6 toolchain, language mode 5. macOS 14 APIs only.
- Create ONLY the files your task lists. Never edit a file owned by another task.
- Do NOT run `swift build`; several agents share this checkout. The orchestrator
  compiles and integrates.
- Views must work in both light and dark appearance. Use SwiftUI semantic colours
  (`.primary`, `.secondary`, `Color(nsColor: .textBackgroundColor)`) — do not hardcode
  black or white.
- Long-running work goes through `Task` and reports progress; never block the main
  actor on a query.
- Every generated T-SQL string quotes identifiers via `SQLIdentifier.quote` / `.literal`.
- Destructive operations show the generated script and require an explicit confirm.
- Keep expressions simple enough for the type checker: bind intermediate values to
  explicitly typed locals rather than chaining long generic expressions. A too-complex
  expression fails the build on CI even when it compiles locally.
- Comments explain why, not what. No emoji. 4-space indent, ~110 column wrap.
