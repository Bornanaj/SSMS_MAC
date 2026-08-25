import Foundation
import TDSKit

public struct QuerySetOptions: Codable, Hashable, Sendable {
    public var ansiNulls = true
    public var ansiPadding = true
    public var ansiWarnings = true
    public var arithAbort = true
    public var concatNullYieldsNull = true
    public var quotedIdentifier = true
    public var numericRoundAbort = false
    public var xactAbort = false
    public var nocount = false
    public var transactionIsolationLevel = "READ COMMITTED"
    public var lockTimeoutMilliseconds = -1
    public var deadlockPriority = "NORMAL"
    public var rowCountLimit = 0

    public init() {}

    /// The SET block SSMS emits before running a script.
    public var script: String {
        var lines: [String] = []
        func flag(_ name: String, _ value: Bool) { lines.append("SET \(name) \(value ? "ON" : "OFF");") }
        flag("ANSI_NULLS", ansiNulls)
        flag("ANSI_PADDING", ansiPadding)
        flag("ANSI_WARNINGS", ansiWarnings)
        flag("ARITHABORT", arithAbort)
        flag("CONCAT_NULL_YIELDS_NULL", concatNullYieldsNull)
        flag("QUOTED_IDENTIFIER", quotedIdentifier)
        flag("NUMERIC_ROUNDABORT", numericRoundAbort)
        flag("XACT_ABORT", xactAbort)
        flag("NOCOUNT", nocount)
        lines.append("SET TRANSACTION ISOLATION LEVEL \(transactionIsolationLevel);")
        if lockTimeoutMilliseconds >= 0 { lines.append("SET LOCK_TIMEOUT \(lockTimeoutMilliseconds);") }
        lines.append("SET DEADLOCK_PRIORITY \(deadlockPriority);")
        if rowCountLimit > 0 { lines.append("SET ROWCOUNT \(rowCountLimit);") }
        return lines.joined(separator: "\n")
    }
}

public struct QueryExecutionOptions: Sendable {
    /// 0 means no limit.
    public var maxRows: Int = 0
    public var includeActualExecutionPlan = false
    public var includeEstimatedExecutionPlan = false
    public var includeClientStatistics = false
    public var includeIOStatistics = false
    public var includeTimeStatistics = false
    /// 0 means wait forever, like SSMS's default execution timeout.
    public var timeoutSeconds: Int = 0
    public var database: String?
    public var setOptions: QuerySetOptions?
    /// How many rows to batch before publishing them to the UI.
    public var rowChunkSize = 500

    public init() {}
}

public struct SQLMessage: Sendable, Identifiable, Hashable {
    public enum Kind: Sendable, Hashable { case info, error }

    public var id = UUID()
    public var kind: Kind
    public var text: String
    public var number: Int32 = 0
    public var severity: UInt8 = 0
    public var state: UInt8 = 0
    public var lineNumber: Int32 = 0
    public var procedureName: String = ""
    public var batchIndex: Int = 0
    /// Line in the whole script, not just the batch.
    public var scriptLine: Int = 0

    public init(kind: Kind, text: String) {
        self.kind = kind
        self.text = text
    }

    public init(server message: TDSServerMessage, batchIndex: Int, batchStartLine: Int) {
        self.kind = message.severity >= 11 ? .error : .info
        self.text = message.text
        self.number = message.number
        self.severity = message.severity
        self.state = message.state
        self.lineNumber = message.lineNumber
        self.procedureName = message.procedureName
        self.batchIndex = batchIndex
        self.scriptLine = batchStartLine + max(0, Int(message.lineNumber) - 1)
    }

    /// SSMS renders errors with a header line then the text.
    public var displayText: String {
        guard kind == .error else { return text }
        var head = "Msg \(number), Level \(severity), State \(state)"
        if !procedureName.isEmpty { head += ", Procedure \(procedureName)" }
        head += ", Line \(lineNumber)"
        return head + "\n" + text
    }
}

public struct ResultSetHandle: Sendable, Hashable {
    public var id: UUID
    public var batchIndex: Int
    public var ordinal: Int
    public var columns: [TDSColumn]
    /// True when this "result set" is actually a showplan payload.
    public var isExecutionPlan: Bool
}

public struct ClientStatistics: Sendable, Hashable {
    public var clientExecutionTime: TimeInterval = 0
    public var selectStatements = 0
    public var rowsReturned = 0
    public var rowsAffected: Int64 = 0
    public var serverRoundtrips = 0
    public var resultSets = 0

    public init() {}
}

public struct QueryExecutionSummary: Sendable {
    public var batchCount = 0
    public var elapsed: TimeInterval = 0
    public var totalRows = 0
    public var rowsAffected: Int64 = 0
    public var errorCount = 0
    public var cancelled = false
    public var succeeded: Bool { errorCount == 0 && !cancelled }
    public var statistics = ClientStatistics()
    public var startedAt = Date()
    public var finishedAt = Date()
}

public enum QueryEvent: Sendable {
    case started(batchCount: Int)
    case batchStarted(index: Int, startLine: Int, repetition: Int, repeatCount: Int)
    case resultSetStarted(ResultSetHandle)
    case rows(resultSetID: UUID, rows: [[TDSValue]], startIndex: Int)
    case resultSetFinished(resultSetID: UUID, rowCount: Int, truncated: Bool, elapsed: TimeInterval)
    case message(SQLMessage)
    case rowsAffected(rows: Int64, batchIndex: Int)
    case executionPlan(xml: String, isActual: Bool, batchIndex: Int)
    case databaseChanged(String)
    case batchFinished(index: Int, elapsed: TimeInterval, failed: Bool)
    case finished(QueryExecutionSummary)
}

/// Runs a script batch by batch on one connection and streams everything back.
public final class QueryExecutor: @unchecked Sendable {

    public let connection: TDSConnection
    private var cancelled = false
    private let lock = NSLock()

    public init(connection: TDSConnection) {
        self.connection = connection
    }

    public var isCancelled: Bool { lock.withLock { cancelled } }

    public func cancel() {
        lock.withLock { cancelled = true }
        connection.cancel()
    }

    private static let showplanColumnNames: Set<String> = [
        "Microsoft SQL Server 2005 XML Showplan",
        "Microsoft SQL Server 2005 XML Plan"
    ]

    @discardableResult
    public func execute(script: String,
                        options: QueryExecutionOptions = QueryExecutionOptions(),
                        onEvent: @escaping @Sendable (QueryEvent) -> Void) async throws -> QueryExecutionSummary {
        lock.withLock { cancelled = false }

        var summary = QueryExecutionSummary()
        summary.startedAt = Date()
        let overallStart = Date()

        let batches = BatchSplitter.split(script).filter { !$0.isEmpty }
        summary.batchCount = batches.count
        onEvent(.started(batchCount: batches.count))

        if batches.isEmpty {
            summary.finishedAt = Date()
            summary.elapsed = Date().timeIntervalSince(overallStart)
            onEvent(.finished(summary))
            return summary
        }

        // Preamble: database context, SET options and plan/statistics switches.
        var preamble: [String] = []
        if let database = options.database, !database.isEmpty,
           connection.database.caseInsensitiveCompare(database) != .orderedSame {
            preamble.append("USE \(SQLIdentifier.quote(database));")
        }
        if let setOptions = options.setOptions { preamble.append(setOptions.script) }
        if options.includeActualExecutionPlan { preamble.append("SET STATISTICS XML ON;") }
        if options.includeEstimatedExecutionPlan { preamble.append("SET SHOWPLAN_XML ON;") }
        if options.includeIOStatistics { preamble.append("SET STATISTICS IO ON;") }
        if options.includeTimeStatistics { preamble.append("SET STATISTICS TIME ON;") }
        if !preamble.isEmpty {
            _ = try? await connection.query(preamble.joined(separator: "\n"))
        }

        var timeoutTask: Task<Void, Never>?
        if options.timeoutSeconds > 0 {
            let seconds = options.timeoutSeconds
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
                guard !Task.isCancelled else { return }
                self?.cancel()
            }
        }
        defer { timeoutTask?.cancel() }

        for batch in batches {
            if isCancelled { summary.cancelled = true; break }

            for repetition in 0..<max(1, batch.repeatCount) {
                if isCancelled { summary.cancelled = true; break }
                onEvent(.batchStarted(index: batch.index, startLine: batch.startLine,
                                      repetition: repetition + 1, repeatCount: batch.repeatCount))
                let batchStart = Date()
                let collector = BatchCollector(batch: batch,
                                               options: options,
                                               onEvent: onEvent)
                do {
                    try await connection.execute(batch.text) { event in
                        collector.consume(event)
                    }
                } catch let error as TDSError {
                    if case .cancelled = error {
                        summary.cancelled = true
                    } else {
                        let message = SQLMessage(kind: .error, text: String(describing: error))
                        onEvent(.message(message))
                        summary.errorCount += 1
                    }
                    collector.finish()
                    onEvent(.batchFinished(index: batch.index,
                                           elapsed: Date().timeIntervalSince(batchStart), failed: true))
                    summary.finishedAt = Date()
                    summary.elapsed = Date().timeIntervalSince(overallStart)
                    onEvent(.finished(summary))
                    throw error
                }

                let result = collector.finish()
                summary.totalRows += result.rowCount
                summary.rowsAffected += result.rowsAffected
                summary.errorCount += result.errorCount
                summary.statistics.resultSets += result.resultSetCount
                summary.statistics.serverRoundtrips += 1
                if result.cancelled { summary.cancelled = true }
                onEvent(.batchFinished(index: batch.index,
                                       elapsed: Date().timeIntervalSince(batchStart),
                                       failed: result.errorCount > 0))
                if result.cancelled { break }
            }
            if summary.cancelled { break }
        }

        // Restore plan/statistics switches so the connection is reusable.
        var epilogue: [String] = []
        if options.includeActualExecutionPlan { epilogue.append("SET STATISTICS XML OFF;") }
        if options.includeEstimatedExecutionPlan { epilogue.append("SET SHOWPLAN_XML OFF;") }
        if options.includeIOStatistics { epilogue.append("SET STATISTICS IO OFF;") }
        if options.includeTimeStatistics { epilogue.append("SET STATISTICS TIME OFF;") }
        if !epilogue.isEmpty && !connection.isClosed {
            _ = try? await connection.query(epilogue.joined(separator: "\n"))
        }

        if isCancelled { summary.cancelled = true }
        summary.finishedAt = Date()
        summary.elapsed = Date().timeIntervalSince(overallStart)
        summary.statistics.clientExecutionTime = summary.elapsed
        summary.statistics.rowsReturned = summary.totalRows
        summary.statistics.rowsAffected = summary.rowsAffected
        onEvent(.finished(summary))
        return summary
    }
}

/// Turns the raw token stream of one batch into `QueryEvent`s.
private final class BatchCollector: @unchecked Sendable {
    struct Result {
        var rowCount = 0
        var rowsAffected: Int64 = 0
        var errorCount = 0
        var resultSetCount = 0
        var cancelled = false
    }

    private let batch: SQLBatch
    private let options: QueryExecutionOptions
    private let onEvent: @Sendable (QueryEvent) -> Void
    private let lock = NSLock()

    private var result = Result()
    private var currentID: UUID?
    private var currentColumns: [TDSColumn] = []
    private var currentIsPlan = false
    private var currentRowCount = 0
    private var currentTruncated = false
    private var currentStart = Date()
    private var pendingRows: [[TDSValue]] = []
    private var planXML = ""

    init(batch: SQLBatch, options: QueryExecutionOptions, onEvent: @escaping @Sendable (QueryEvent) -> Void) {
        self.batch = batch
        self.options = options
        self.onEvent = onEvent
    }

    func consume(_ event: TDSStreamEvent) {
        lock.lock()
        defer { lock.unlock() }

        switch event {
        case .columns(let columns):
            closeCurrentLocked()
            let isPlan = columns.count == 1
                && QueryExecutor_showplanNames.contains(columns[0].name)
            let id = UUID()
            currentID = id
            currentColumns = columns
            currentIsPlan = isPlan
            currentRowCount = 0
            currentTruncated = false
            currentStart = Date()
            planXML = ""
            result.resultSetCount += isPlan ? 0 : 1
            if !isPlan {
                onEvent(.resultSetStarted(ResultSetHandle(id: id, batchIndex: batch.index,
                                                          ordinal: result.resultSetCount,
                                                          columns: columns,
                                                          isExecutionPlan: false)))
            }

        case .row(let values):
            guard currentID != nil else { break }
            currentRowCount += 1
            result.rowCount += currentIsPlan ? 0 : 1
            if currentIsPlan {
                if case .string(let xml) = values.first { planXML += xml }
                else if case .xml(let xml) = values.first { planXML += xml }
                break
            }
            if options.maxRows > 0 && currentRowCount > options.maxRows {
                currentTruncated = true
                break
            }
            pendingRows.append(values)
            if pendingRows.count >= options.rowChunkSize { flushRowsLocked() }

        case .done(let info), .doneProc(let info), .doneInProc(let info):
            closeCurrentLocked()
            if info.status.contains(.attention) { result.cancelled = true }
            if info.hasRowCount && info.rowCount >= 0 {
                result.rowsAffected += info.rowCount
                onEvent(.rowsAffected(rows: info.rowCount, batchIndex: batch.index))
            }

        case .info(let message):
            onEvent(.message(SQLMessage(server: message, batchIndex: batch.index,
                                        batchStartLine: batch.startLine)))

        case .error(let message):
            result.errorCount += 1
            onEvent(.message(SQLMessage(server: message, batchIndex: batch.index,
                                        batchStartLine: batch.startLine)))

        case .envChange(let change):
            if case .database(let new, _) = change { onEvent(.databaseChanged(new)) }

        default:
            break
        }
    }

    private func flushRowsLocked() {
        guard let id = currentID, !pendingRows.isEmpty else { return }
        let rows = pendingRows
        pendingRows.removeAll(keepingCapacity: true)
        onEvent(.rows(resultSetID: id, rows: rows, startIndex: currentRowCount - rows.count))
    }

    private func closeCurrentLocked() {
        guard let id = currentID else { return }
        if currentIsPlan {
            if !planXML.isEmpty {
                onEvent(.executionPlan(xml: planXML,
                                       isActual: options.includeActualExecutionPlan,
                                       batchIndex: batch.index))
            }
        } else {
            flushRowsLocked()
            onEvent(.resultSetFinished(resultSetID: id,
                                       rowCount: currentRowCount,
                                       truncated: currentTruncated,
                                       elapsed: Date().timeIntervalSince(currentStart)))
        }
        currentID = nil
        currentColumns = []
        currentIsPlan = false
        planXML = ""
    }

    @discardableResult
    func finish() -> Result {
        lock.lock()
        defer { lock.unlock() }
        closeCurrentLocked()
        return result
    }
}

private let QueryExecutor_showplanNames: Set<String> = [
    "Microsoft SQL Server 2005 XML Showplan",
    "Microsoft SQL Server 2005 XML Plan"
]
