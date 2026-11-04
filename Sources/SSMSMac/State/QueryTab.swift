import Foundation
import AppKit
import TDSKit
import SQLServerKit

enum ResultsPaneTab: String, CaseIterable, Identifiable {
    case results
    case messages
    case executionPlan
    case liveStatistics
    case clientStatistics

    var id: String { rawValue }

    var title: String {
        switch self {
        case .results: return "Results"
        case .messages: return "Messages"
        case .executionPlan: return "Execution plan"
        case .liveStatistics: return "Live statistics"
        case .clientStatistics: return "Client statistics"
        }
    }

    var symbol: String {
        switch self {
        case .results: return "tablecells"
        case .messages: return "text.alignleft"
        case .executionPlan: return "point.topleft.down.curvedto.point.bottomright.up"
        case .liveStatistics: return "waveform.path.ecg"
        case .clientStatistics: return "chart.bar"
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
    /// SSMS's Live Query Statistics: poll sys.dm_exec_query_profiles while the query
    /// runs. It needs profiling on, so it turns the actual plan on with it.
    @Published var includeLiveStatistics = false

    @Published private(set) var liveSnapshot = LiveQuerySnapshot()
    /// Why live statistics are not arriving, when they are not: a permission error, an
    /// engine that predates the DMV, or simply a query that finished too quickly.
    @Published private(set) var liveStatisticsMessage: String?
    /// The SPID of this window's own connection, which is what the DMV is keyed by.
    @Published private(set) var spid = 0
    private var liveStatsTask: Task<Void, Never>?

    @Published private(set) var completionItems: [CompletionItem] = []
    /// True when the last request was for "alias." or "schema.": the editor shows
    /// nothing rather than a keyword list there.
    @Published private(set) var completionIsMemberContext = false
    @Published private(set) var isLoadingCatalog = false
    /// What the completion catalog is doing, shown in the status bar: a load in
    /// progress, what it found, or why it did not.
    @Published private(set) var intelliSenseStatus = ""
    /// The last catalog failure, for the status bar's tooltip.
    @Published private(set) var intelliSenseError: String?
    /// Raised on the main actor once a completion request has landed, so the popup can
    /// open with the real list instead of whatever was cached a keystroke ago.
    var onCompletionsUpdated: (() -> Void)?
    private var intelliSense: IntelliSenseProvider?
    private var completionTask: Task<Void, Never>?
    private var catalogTask: Task<Void, Never>?

    private var session: SQLServerSession?
    private var connection: TDSConnection?
    private var executor: QueryExecutor?
    private var executionTask: Task<Void, Never>?
    private var elapsedTimer: Timer?
    private var resultsByID: [UUID: ResultSetModel] = [:]

    /// Set by AppState so a finished run lands in the history browser. The tab itself
    /// owns no store: it reports what it ran and who it ran it against.
    var onExecutionRecorded: ((QueryHistoryEntry) -> Void)?
    private var executedScript = ""
    private var executionStartedAt = Date()

    var maxRows: Int = 0
    var timeoutSeconds: Int = 0
    var setOptions = QuerySetOptions()

    /// How Results to Text renders rows, applied app-wide from Query Options.
    var textResultPreferences = QueryResultsPreferences.load() {
        didSet { cachedTextOutput = nil }
    }
    private var cachedTextOutput: String?
    /// Lines to add to the server's line numbers when the run was a selection, so the
    /// gutter and "go to line" point at the document line rather than the selection's.
    private var executionLineOffset = 0

    // MARK: - Editor state

    /// Undo history is per window in SSMS, so each tab has its own manager: Cmd+Z in
    /// one window never rewrites another.
    let undoManager = UndoManager()
    /// 1-based bookmarked lines.
    var bookmarks: Set<Int> = []
    /// The AppKit editor built for this tab. SwiftUI rebuilds its wrapper whenever the
    /// window re-arranges itself (switching tabs, hiding the results pane); keeping the
    /// view here is what preserves the undo history, the caret and the scroll position.
    var editorTextView: SQLTextView?
    var editorScrollOrigin: NSPoint = .zero

    init(title: String = "SQLQuery1.sql", text: String = "") {
        self.title = title
        self.text = text
    }

    var isConnected: Bool { connection != nil && !(connection?.isClosed ?? true) }

    var lineCount: Int {
        TextLines.count(in: text as NSString)
    }

    /// 1-based line holding the caret.
    var currentLine: Int {
        TextLines.line(at: selectedRange.location, in: text as NSString)
    }

    var displayTitle: String {
        let base = fileURL?.lastPathComponent ?? title
        return isDirty ? base + " •" : base
    }

    /// The text that F5 should run: the selection when there is one, otherwise everything.
    var textToExecute: String { scriptToExecute().script }

    /// The script to run and the 1-based document line it starts on.
    private func scriptToExecute() -> (script: String, startLine: Int) {
        let ns = text as NSString
        guard selectedRange.length > 0, NSMaxRange(selectedRange) <= ns.length else {
            return (text, 1)
        }
        return (ns.substring(with: selectedRange), TextLines.line(at: selectedRange.location, in: ns))
    }

    // MARK: - Connection

    func attach(session: SQLServerSession, database: String?) async {
        isConnecting = true
        statusText = "Connecting…"
        defer { isConnecting = false }

        let info = await session.serverInfo
        self.session = session
        self.sessionID = session.id
        self.sessionName = info.serverName.isEmpty
            ? session.profile.displayName
            : info.serverName
        self.serverLabel = info.serverName
        self.accentColorHex = session.profile.colorHex
        let target = database ?? info.currentDatabase
        // The connect dialog's own execution timeout wins over the global preference.
        if session.profile.executionTimeoutSeconds > 0 {
            timeoutSeconds = session.profile.executionTimeoutSeconds
        }

        do {
            let connection = try await session.openConnection(database: target)
            self.connection = connection
            self.executor = QueryExecutor(connection: connection)
            self.database = connection.database
            statusText = "Connected."
            // The DMV that backs live statistics is keyed by SPID, and this window has
            // its own connection, so its SPID is read once here.
            if let spidResult = try? await connection.query("SELECT @@SPID AS spid;"),
               let row = spidResult.resultSets.first?.dictionaries().first {
                self.spid = row.int("spid")
            }
            self.intelliSense = IntelliSenseProvider(session: session)
            await refreshDatabaseList()
            refreshIntelliSenseCatalog()
        } catch {
            statusText = "Connection failed: \(error)"
            appendLocalError("\(error)")
        }
    }

    /// Lets a dialog report what it did in this window's status line.
    func statusMessage(_ text: String) {
        statusText = text
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
        isLoadingCatalog = true
        intelliSenseStatus = "IntelliSense: reading \(target)…"
        catalogTask = Task { [weak self] in
            do {
                let catalog = try await intelliSense.refresh(database: target) { count in
                    Task { @MainActor [weak self] in
                        guard self?.isLoadingCatalog == true else { return }
                        self?.intelliSenseStatus = "IntelliSense: \(count) objects, "
                            + "reading columns…"
                    }
                }
                guard !Task.isCancelled else { return }
                self?.intelliSenseStatus = "IntelliSense: \(catalog.tables.count) tables, "
                    + "\(catalog.routines.count) routines"
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                // A login without VIEW DEFINITION sees nothing in sys.columns, and
                // the editor then offers keywords only. That belongs in the status
                // line, not as an error interrupting the results pane.
                self?.intelliSenseStatus = "IntelliSense: \(target) could not be read"
                self?.intelliSenseError = String(describing: error)
            }
            self?.isLoadingCatalog = false
        }
    }

    /// Start a catalog load only when none is running: typing must not cancel the
    /// fetch it is waiting for, which would leave completion stuck on keywords.
    private func ensureCatalogLoaded() {
        guard !isLoadingCatalog else { return }
        refreshIntelliSenseCatalog()
    }

    /// Recompute the completion list for the caret position. The popup reads
    /// `completionItems` synchronously, so when the answer lands after the popup has
    /// already opened, `onCompletionsUpdated` tells the editor to re-rank.
    ///
    /// `script` comes from the text view rather than from `text`, which is only
    /// updated once AppKit has finished the edit and so lags the caret by a character.
    func requestCompletions(script: String? = nil, at offset: Int) {
        guard let intelliSense else { return }
        let source = script ?? text
        let target = database
        completionTask?.cancel()
        completionTask = Task { [weak self] in
            let result = await intelliSense.completionResult(script: source, offset: offset,
                                                             database: target)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                self.completionItems = result.items
                self.completionIsMemberContext = result.isMemberContext
                self.onCompletionsUpdated?()
                // Nothing to complete against usually means the catalog never
                // loaded; fetch it so the next keystroke has something to offer.
                if !result.hasCatalog { self.ensureCatalogLoaded() }
            }
        }
    }

    /// Expand `SELECT *` into the real column list, using the IntelliSense catalog.
    func expandWildcards(at offset: Int) async -> SQLAssist.Expansion? {
        guard let intelliSense, let catalog = await intelliSense.catalog(for: database) else {
            statusText = "IntelliSense is still loading the catalog for \(database)."
            return nil
        }
        guard let expansion = SQLAssist.expandWildcards(script: text, offset: offset,
                                                        catalog: catalog) else {
            statusText = "No wildcard to expand at the cursor."
            return nil
        }
        text = expansion.text
        statusText = expansion.expandedCount == 1
            ? "Expanded 1 wildcard."
            : "Expanded \(expansion.expandedCount) wildcards."
        return expansion
    }

    func signatureHelp(at offset: Int) async -> String? {
        guard let intelliSense else { return nil }
        return await intelliSense.signatureHelp(script: text, offset: offset, database: database)
    }

    func disconnect() async {
        executionTask?.cancel()
        completionTask?.cancel()
        catalogTask?.cancel()
        liveStatsTask?.cancel()
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
        let (script, startLine) = scriptToExecute()
        guard !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        clearResults()
        executionLineOffset = startLine - 1
        executedScript = script
        executionStartedAt = Date()
        isExecuting = true
        showResultsPane = true
        selectedPaneTab = .results
        statusText = "Executing query…"
        startTimer()

        var options = QueryExecutionOptions()
        options.maxRows = maxRows
        options.timeoutSeconds = timeoutSeconds
        // Live statistics read a DMV that only fills while the request is profiled, and
        // the actual plan is what turns profiling on.
        options.includeActualExecutionPlan = includeActualPlan || includeLiveStatistics
        options.includeEstimatedExecutionPlan = includeEstimatedPlan
        options.setOptions = setOptions
        options.database = database.isEmpty ? nil : database

        if includeLiveStatistics { startLiveStatistics() }

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
            var message = message
            // Server line numbers are relative to what was sent, which may have been a
            // selection part way down the document.
            if message.scriptLine > 0 { message.scriptLine += executionLineOffset }
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
        cachedTextOutput = nil
        stopTimer()
        stopLiveStatistics()
        recordHistory()
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
    }

    // MARK: - Live query statistics

    /// Polls the profiles DMV on the session's metadata connection — a second
    /// connection, because the one running the query is busy running it.
    private func startLiveStatistics() {
        guard let session, spid > 0 else {
            liveStatisticsMessage = "This window has no connection of its own to watch."
            return
        }
        let service = LiveQueryStatsService(session: session)
        let target = spid
        liveStatsTask?.cancel()
        liveStatsTask = Task { [weak self] in
            let info = await session.serverInfo
            guard LiveQueryStatsService.isSupported(info) else {
                await MainActor.run {
                    self?.liveStatisticsMessage = service.requirementText(info)
                }
                return
            }
            while !Task.isCancelled {
                do {
                    let snapshot = try await service.snapshot(sessionID: target)
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        guard let self else { return }
                        // An empty poll mid-run means the request has not started
                        // producing rows yet; it is not a reason to drop what is shown.
                        if !snapshot.isEmpty {
                            self.liveSnapshot = snapshot
                            self.liveStatisticsMessage = nil
                        }
                    }
                } catch {
                    await MainActor.run {
                        self?.liveStatisticsMessage = String(describing: error)
                    }
                    return
                }
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
        }
    }

    private func stopLiveStatistics() {
        liveStatsTask?.cancel()
        liveStatsTask = nil
        if includeLiveStatistics, liveSnapshot.isEmpty, liveStatisticsMessage == nil {
            liveStatisticsMessage = "The query finished before any operator reported "
                + "progress. Live statistics only show something for a query that runs "
                + "long enough to be sampled."
        }
    }

    /// One entry per execution, with what it returned and how long it took. A run that
    /// never reached the server (no connection, empty script) is not recorded.
    private func recordHistory() {
        guard let onExecutionRecorded, !executedScript.isEmpty else { return }
        let firstError = messages.first { $0.kind == .error }
        let entry = QueryHistoryEntry(
            sql: executedScript,
            server: sessionName,
            database: database,
            startedAt: executionStartedAt,
            elapsed: summary?.elapsed ?? Date().timeIntervalSince(executionStartedAt),
            rowsReturned: summary?.totalRows ?? resultSets.reduce(0) { $0 + $1.rowCount },
            succeeded: summary?.succeeded ?? (firstError == nil),
            errorText: firstError?.text,
            rowsAffected: summary?.rowsAffected,
            cancelled: summary?.cancelled,
            batchCount: summary?.batchCount,
            tabTitle: title)
        executedScript = ""
        onExecutionRecorded(entry)
    }

    private func clearResults() {
        liveSnapshot = LiveQuerySnapshot()
        liveStatisticsMessage = nil
        resultSets.removeAll()
        resultsByID.removeAll()
        messages.removeAll()
        executionPlanXML = nil
        summary = nil
        elapsed = 0
        cachedTextOutput = nil
    }

    private func appendLocalError(_ text: String) {
        messages.append(SQLMessage(kind: .error, text: text))
        cachedTextOutput = nil
        selectedPaneTab = .messages
        showResultsPane = true
    }

    // MARK: - Results to Text

    /// SSMS's "Results to Text": every result set as fixed-width columns followed by
    /// the messages, the way sqlcmd prints them. Formatted once per run and cached, so
    /// a keystroke in the editor does not re-render every row.
    var textOutput: String {
        if let cachedTextOutput { return cachedTextOutput }
        let formatter = TextResultFormatter(style: textResultPreferences.textStyle)
        var blocks: [String] = []
        for model in resultSets {
            blocks.append(formatter.format(columns: model.columns, rows: model.rows))
            blocks.append(formatter.rowsAffected(Int64(model.rowCount)))
        }
        for message in messages where message.kind == .info {
            blocks.append(message.text)
        }
        for message in messages where message.kind == .error {
            blocks.append(message.displayText)
        }
        let output = blocks.joined(separator: "\n")
        cachedTextOutput = output
        return output
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
}
