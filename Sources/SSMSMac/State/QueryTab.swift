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

    init(title: String = "SQLQuery1.sql", text: String = "") {
        self.title = title
        self.text = text
    }

    var isConnected: Bool { connection != nil && !(connection?.isClosed ?? true) }

    var lineCount: Int {
        let ns = text as NSString
        var count = 0
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length),
                               options: [.byLines, .substringNotRequired]) { _, _, _, _ in
            count += 1
        }
        return max(1, count)
    }

    var currentLine: Int {
        let ns = text as NSString
        let caret = min(selectedRange.location, ns.length)
        var line = 1
        ns.enumerateSubstrings(in: NSRange(location: 0, length: caret),
                               options: [.byLines, .substringNotRequired]) { _, _, _, _ in
            line += 1
        }
        return line
    }

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
        catalogTask = Task { [weak self] in
            _ = try? await intelliSense.refresh(database: target)
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
        let script = textToExecute
        guard !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        clearResults()
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
}
