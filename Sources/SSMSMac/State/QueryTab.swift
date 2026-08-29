import Foundation
import AppKit
import TDSKit
import SQLServerKit

enum ResultsPaneTab: String, CaseIterable, Identifiable {
    case results
    case textResults
    case messages
    case executionPlan
    case clientStatistics

    var id: String { rawValue }

    var title: String {
        switch self {
        case .results: return "Results"
        case .textResults: return "Text"
        case .messages: return "Messages"
        case .executionPlan: return "Execution plan"
        case .clientStatistics: return "Client statistics"
        }
    }

    var symbol: String {
        switch self {
        case .results: return "tablecells"
        case .textResults: return "text.justify.left"
        case .messages: return "text.alignleft"
        case .executionPlan: return "point.topleft.down.curvedto.point.bottomright.up"
        case .clientStatistics: return "chart.bar"
        }
    }
}

/// SSMS's Results To choice: a grid, fixed-width text, or straight to a file.
enum ResultsDestination: String, CaseIterable, Identifiable {
    case grid
    case text
    case file

    var id: String { rawValue }

    var title: String {
        switch self {
        case .grid: return "Results to Grid"
        case .text: return "Results to Text"
        case .file: return "Results to File"
        }
    }

    var symbol: String {
        switch self {
        case .grid: return "tablecells"
        case .text: return "text.justify.left"
        case .file: return "doc.badge.arrow.up"
        }
    }
}

/// One query window: its text, its own connection, and everything it produced.
@MainActor
final class QueryTab: ObservableObject, Identifiable {
    let id = UUID()

    @Published var title: String
    @Published var text: String {
        didSet { if text != oldValue { isDirty = true } }
    }
    @Published var isDirty = false
    @Published var fileURL: URL?
    @Published var selectedRange = NSRange(location: 0, length: 0)
    /// Lines the user bookmarked with ⌘K ⌘K, one-based like the ruler.
    @Published var bookmarkedLines: Set<Int> = []

    @Published private(set) var sessionID: UUID?
    @Published private(set) var sessionName: String = "Not connected"
    @Published private(set) var serverLabel: String = ""
    @Published var database: String = ""
    @Published private(set) var availableDatabases: [String] = []
    @Published var accentColorHex: String?

    @Published private(set) var isExecuting = false
    @Published private(set) var isConnecting = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var resultSets: [ResultSetModel] = []
    @Published private(set) var messages: [SQLMessage] = []
    @Published private(set) var summary: QueryExecutionSummary?
    @Published private(set) var executionPlanXML: String?
    @Published private(set) var statusText: String = "Ready"
    @Published var selectedPaneTab: ResultsPaneTab = .results
    @Published var showResultsPane = true

    @Published var includeActualPlan = false
    @Published var includeEstimatedPlan = false
    @Published var includeClientStatistics = false

    /// Where finished results go. `.text` and `.file` both render through
    /// `TextResultFormatter`; `.file` additionally writes what it rendered.
    @Published var resultsDestination: ResultsDestination = .grid
    @Published private(set) var textResults: String = ""
    @Published var textResultOptions = TextResultOptions()

    @Published private(set) var completionItems: [CompletionItem] = []
    private var intelliSense: IntelliSenseProvider?
    private var completionTask: Task<Void, Never>?
    private var catalogTask: Task<Void, Never>?

    private var session: SQLServerSession?
    private var connection: TDSConnection?
    private var executor: QueryExecutor?
    private var executionTask: Task<Void, Never>?
    private var elapsedTimer: Timer?
    private var resultsByID: [UUID: ResultSetModel] = [:]
    private var lastExecutedScript = ""

    /// Execution limits and SET options. Published because the Query Options sheet binds
    /// straight into them.
    @Published var maxRows: Int = 0
    @Published var timeoutSeconds: Int = 0
    @Published var setOptions = QuerySetOptions()

    /// Called on the main actor once an execution finishes, so `AppState` can record the
    /// statement in the query history without this type knowing about it.
    var onExecutionFinished: ((QueryTab) -> Void)?
    /// Asks the host for a file to write text results into. Returns nil when cancelled.
    var requestResultsFile: ((QueryTab, String) -> Void)?

    init(title: String = "SQLQuery1.sql", text: String = "") {
        self.title = title
        self.text = text
    }

    var isConnected: Bool { connection != nil && !(connection?.isClosed ?? true) }

    var displayTitle: String {
        let base = fileURL?.lastPathComponent ?? title
        return isDirty ? base + " •" : base
    }

    /// The text that F5 should run: the selection when there is one, otherwise everything.
    var textToExecute: String {
        guard selectedRange.length > 0 else { return text }
        let ns = text as NSString
        guard selectedRange.location + selectedRange.length <= ns.length else { return text }
        return ns.substring(with: selectedRange)
    }

    /// The script the last execution ran, for the history entry.
    var executedScript: String { lastExecutedScript }

    // MARK: - Connection

    func attach(session: SQLServerSession, database: String?) async {
        isConnecting = true
        statusText = "Connecting…"
        defer { isConnecting = false }

        let info = await session.serverInfo
        self.session = session
        self.sessionID = session.id
        self.sessionName = session.profile.displayName
        self.serverLabel = info.serverName
        self.accentColorHex = session.profile.colorHex
        let target = database ?? info.currentDatabase

        do {
            let connection = try await session.openConnection(database: target)
            self.connection = connection
            self.executor = QueryExecutor(connection: connection)
            self.database = connection.database
            statusText = "Connected."
            self.intelliSense = IntelliSenseProvider(session: session)
            await refreshDatabaseList()
            refreshIntelliSenseCatalog()
        } catch {
            statusText = "Connection failed: \(error)"
            appendLocalError("\(error)")
        }
    }

    func refreshDatabaseList() async {
        guard let session else { return }
        do {
            let sql = """
            SELECT name FROM sys.databases
            WHERE HAS_DBACCESS(name) = 1 AND state_desc = 'ONLINE'
            ORDER BY CASE WHEN database_id <= 4 THEN 0 ELSE 1 END, name
            """
            let result = try await session.metadataQuery(sql)
            availableDatabases = result.resultSets.first?.dictionaries().map { $0.string("name") } ?? []
        } catch {
            availableDatabases = []
        }
    }

    func changeDatabase(to name: String) async {
        guard let connection, !name.isEmpty else { return }
        do {
            _ = try await connection.query("USE \(SQLIdentifier.quote(name));")
            database = connection.database
            statusText = "Database changed to \(database)."
            refreshIntelliSenseCatalog()
        } catch {
            appendLocalError("\(error)")
        }
    }

    /// Warm the IntelliSense catalog in the background; completions fall back to
    /// keywords until it lands.
    func refreshIntelliSenseCatalog() {
        guard let intelliSense, !database.isEmpty else { return }
        let target = database
        catalogTask?.cancel()
        catalogTask = Task { _ = try? await intelliSense.refresh(database: target) }
    }

    /// Recompute the completion list for the caret position. The popup itself reads
    /// `completionItems` synchronously, so this has to run ahead of it.
    func requestCompletions(at offset: Int) {
        guard let intelliSense else { return }
        let script = text
        let target = database
        completionTask?.cancel()
        completionTask = Task { [weak self] in
            let items = await intelliSense.completions(script: script, offset: offset, database: target)
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.completionItems = items }
        }
    }

    func signatureHelp(at offset: Int) async -> String? {
        guard let intelliSense else { return nil }
        return await intelliSense.signatureHelp(script: text, offset: offset, database: database)
    }

    func disconnect() async {
        executionTask?.cancel()
        completionTask?.cancel()
        catalogTask?.cancel()
        if let connection { try? await connection.close() }
        connection = nil
        executor = nil
        session = nil
        sessionID = nil
        sessionName = "Not connected"
        statusText = "Disconnected."
    }

    // MARK: - Execution

    func execute() {
        guard !isExecuting else { return }
        guard let executor else {
            appendLocalError("This query window is not connected to a server.")
            return
        }
        let script = textToExecute
        guard !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        clearResults()
        lastExecutedScript = script
        isExecuting = true
        showResultsPane = true
        selectedPaneTab = resultsDestination == .grid ? .results : .textResults
        statusText = "Executing query…"
        startTimer()

        var options = QueryExecutionOptions()
        options.maxRows = maxRows
        options.timeoutSeconds = timeoutSeconds
        options.includeActualExecutionPlan = includeActualPlan
        options.includeEstimatedExecutionPlan = includeEstimatedPlan
        options.includeClientStatistics = includeClientStatistics
        options.setOptions = setOptions
        options.database = database.isEmpty ? nil : database

        executionTask = Task { [weak self] in
            guard let self else { return }
            let sink: @Sendable (QueryEvent) -> Void = { event in
                Task { @MainActor [weak self] in self?.handle(event) }
            }
            do {
                _ = try await executor.execute(script: script, options: options, onEvent: sink)
            } catch {
                await MainActor.run {
                    self.appendLocalError("\(error)")
                    self.finishExecution()
                }
            }
        }
    }

    func cancel() {
        guard isExecuting else { return }
        statusText = "Cancelling…"
        executor?.cancel()
    }

    private func handle(_ event: QueryEvent) {
        switch event {
        case .started:
            break

        case .batchStarted:
            break

        case .resultSetStarted(let handle):
            let model = ResultSetModel(handle: handle)
            resultsByID[handle.id] = model
            resultSets.append(model)

        case .rows(let id, let rows, _):
            resultsByID[id]?.append(rows)

        case .resultSetFinished(let id, let rowCount, let truncated, let elapsed):
            resultsByID[id]?.finish(rowCount: rowCount, truncated: truncated, elapsed: elapsed)

        case .message(let message):
            messages.append(message)
            if message.kind == .error && selectedPaneTab == .results && resultSets.isEmpty {
                selectedPaneTab = .messages
            }

        case .rowsAffected(let rows, _):
            var message = SQLMessage(kind: .info, text: "(\(rows) row\(rows == 1 ? "" : "s") affected)")
            message.batchIndex = 0
            messages.append(message)

        case .executionPlan(let xml, _, _):
            executionPlanXML = xml
            selectedPaneTab = .executionPlan

        case .databaseChanged(let name):
            database = name

        case .batchFinished:
            break

        case .finished(let summary):
            self.summary = summary
            finishExecution()
        }
    }

    private func finishExecution() {
        isExecuting = false
        stopTimer()
        if let summary {
            elapsed = summary.elapsed
            if summary.cancelled {
                statusText = "Query cancelled."
            } else if summary.errorCount > 0 {
                statusText = "Query completed with errors."
            } else {
                let rows = summary.totalRows
                statusText = "Query executed successfully. \(rows) row\(rows == 1 ? "" : "s")."
            }
        } else {
            statusText = "Query finished."
        }

        if resultsDestination != .grid {
            renderTextResults()
            if resultsDestination == .file, !textResults.isEmpty {
                requestResultsFile?(self, textResults)
            }
        }
        onExecutionFinished?(self)
    }

    /// Builds the Results-to-Text output for every result set that came back.
    func renderTextResults() {
        let formatter = TextResultFormatter(options: textResultOptions)
        var out = ""
        for model in resultSets {
            if resultSets.count > 1 {
                out += "-- Result set \(model.ordinal)\n"
            }
            out += formatter.format(columns: model.columns, rows: model.rows)
            out += "\n"
        }
        for message in messages {
            out += message.displayText + "\n"
        }
        textResults = out
    }

    private func clearResults() {
        resultSets.removeAll()
        resultsByID.removeAll()
        messages.removeAll()
        executionPlanXML = nil
        textResults = ""
        summary = nil
        elapsed = 0
    }

    private func appendLocalError(_ text: String) {
        messages.append(SQLMessage(kind: .error, text: text))
        selectedPaneTab = .messages
        showResultsPane = true
    }

    private func startTimer() {
        let start = Date()
        elapsedTimer?.invalidate()
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.elapsed = Date().timeIntervalSince(start) }
        }
    }

    private func stopTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
    }

    /// "00:00:03" like the SSMS status bar.
    var elapsedText: String {
        let total = Int(elapsed)
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    // MARK: - Caret and bookmarks

    /// One-based line number of the caret.
    var caretLine: Int {
        QueryTab.line(at: selectedRange.location, in: text)
    }

    /// One-based column of the caret.
    var caretColumn: Int {
        let ns = text as NSString
        let location = min(selectedRange.location, ns.length)
        let lineRange = ns.lineRange(for: NSRange(location: location, length: 0))
        return location - lineRange.location + 1
    }

    static func line(at offset: Int, in text: String) -> Int {
        let ns = text as NSString
        let location = min(max(0, offset), ns.length)
        var line = 1
        ns.enumerateSubstrings(in: NSRange(location: 0, length: location),
                               options: [.byLines, .substringNotRequired]) { _, _, _, _ in
            line += 1
        }
        return line
    }

    /// The character offset the given one-based line starts at.
    static func offset(ofLine line: Int, in text: String) -> Int {
        let ns = text as NSString
        var current = 1
        var offset = 0
        while current < line && offset < ns.length {
            let lineRange = ns.lineRange(for: NSRange(location: offset, length: 0))
            offset = NSMaxRange(lineRange)
            current += 1
        }
        return min(offset, ns.length)
    }

    func moveCaret(toLine line: Int) {
        let clamped = max(1, line)
        selectedRange = NSRange(location: QueryTab.offset(ofLine: clamped, in: text), length: 0)
    }

    func toggleBookmark() {
        let line = caretLine
        if bookmarkedLines.contains(line) {
            bookmarkedLines.remove(line)
        } else {
            bookmarkedLines.insert(line)
        }
    }

    func clearBookmarks() { bookmarkedLines.removeAll() }

    /// Wraps to the first bookmark when the caret is past the last one, like SSMS does.
    func goToNextBookmark() {
        guard !bookmarkedLines.isEmpty else { return }
        let current = caretLine
        let sorted = bookmarkedLines.sorted()
        moveCaret(toLine: sorted.first { $0 > current } ?? sorted[0])
    }

    func goToPreviousBookmark() {
        guard !bookmarkedLines.isEmpty else { return }
        let current = caretLine
        let sorted = bookmarkedLines.sorted()
        moveCaret(toLine: sorted.last { $0 < current } ?? sorted[sorted.count - 1])
    }
}
