import Foundation
import TDSKit

/// One operator as `sys.dm_exec_query_profiles` reports it while the query is still
/// running, with the per-thread rows already summed.
public struct LiveQueryOperator: Sendable, Hashable, Identifiable {
    public var id: Int { nodeID }
    public var nodeID: Int
    public var physicalOperator: String
    public var objectName: String
    public var rowCount: Int64
    public var estimatedRows: Int64
    public var elapsedMilliseconds: Int64
    public var cpuMilliseconds: Int64
    public var logicalReads: Int64
    public var physicalReads: Int64
    /// True once every thread for this operator has closed, i.e. it is finished.
    public var isClosed: Bool
    public var threadCount: Int

    public init(nodeID: Int, physicalOperator: String, objectName: String = "",
                rowCount: Int64 = 0, estimatedRows: Int64 = 0,
                elapsedMilliseconds: Int64 = 0, cpuMilliseconds: Int64 = 0,
                logicalReads: Int64 = 0, physicalReads: Int64 = 0,
                isClosed: Bool = false, threadCount: Int = 1) {
        self.nodeID = nodeID
        self.physicalOperator = physicalOperator
        self.objectName = objectName
        self.rowCount = rowCount
        self.estimatedRows = estimatedRows
        self.elapsedMilliseconds = elapsedMilliseconds
        self.cpuMilliseconds = cpuMilliseconds
        self.logicalReads = logicalReads
        self.physicalReads = physicalReads
        self.isClosed = isClosed
        self.threadCount = threadCount
    }

    /// Rows produced against rows the optimizer expected, capped at 1. An operator that
    /// has already produced more rows than estimated is at 100% and badly estimated,
    /// which `isOverEstimate` says out loud.
    public var progress: Double {
        guard estimatedRows > 0 else { return isClosed ? 1 : 0 }
        return min(1, Double(rowCount) / Double(estimatedRows))
    }

    /// The optimizer expected an order of magnitude fewer rows than arrived — the usual
    /// reason a query that used to be fast suddenly is not.
    public var isOverrun: Bool {
        estimatedRows > 0 && Double(rowCount) > Double(estimatedRows) * 10
    }

    public var elapsedText: String {
        if elapsedMilliseconds >= 1000 {
            return String(format: "%.1f s", Double(elapsedMilliseconds) / 1000)
        }
        return "\(elapsedMilliseconds) ms"
    }
}

/// A single poll of the live statistics.
public struct LiveQuerySnapshot: Sendable, Hashable {
    public var operators: [LiveQueryOperator]
    public var takenAt: Date

    public init(operators: [LiveQueryOperator] = [], takenAt: Date = Date()) {
        self.operators = operators
        self.takenAt = takenAt
    }

    public var isEmpty: Bool { operators.isEmpty }

    public var rowsProduced: Int64 { operators.reduce(0) { $0 + $1.rowCount } }
    public var rowsEstimated: Int64 { operators.reduce(0) { $0 + $1.estimatedRows } }
    public var logicalReads: Int64 { operators.reduce(0) { $0 + $1.logicalReads } }

    /// Overall progress, the number SSMS puts at the top of the Live Query Statistics
    /// window. It is rows produced over rows expected across every operator, so it is a
    /// hint rather than a promise: a bad estimate makes it lie.
    public var progress: Double {
        guard rowsEstimated > 0 else { return 0 }
        return min(1, Double(rowsProduced) / Double(rowsEstimated))
    }

    public var finishedOperators: Int { operators.filter(\.isClosed).count }
}

/// Reads `sys.dm_exec_query_profiles` for a running request.
///
/// The DMV is only populated while profiling is on for that request, which is why the
/// query window turns the actual execution plan on with live statistics: `SET
/// STATISTICS XML ON` is what profiling hangs off on every supported version.
public struct LiveQueryStatsService: Sendable {
    private let session: SQLServerSession

    public init(session: SQLServerSession) {
        self.session = session
    }

    /// 2014 brought the DMV; 2016 made it cheap enough to leave on.
    public static func isSupported(_ info: ServerInfo) -> Bool {
        !info.isAzureSQLDatabase && !info.isAzureSynapse
            && (info.majorVersion == 0 || info.majorVersion >= 12)
    }

    public func requirementText(_ info: ServerInfo) -> String {
        if info.isAzureSQLDatabase || info.isAzureSynapse {
            return "Live query statistics are not available on this Azure service."
        }
        if info.majorVersion > 0 && info.majorVersion < 12 {
            return "Live query statistics need SQL Server 2014 or later."
        }
        return "Live query statistics need VIEW SERVER STATE, and the query has to be "
            + "running with an actual execution plan."
    }

    /// One poll for the given SPID. Returns an empty snapshot when the request has
    /// already finished — that is the normal way a run ends, not an error.
    public func snapshot(sessionID: Int) async throws -> LiveQuerySnapshot {
        guard sessionID > 0 else { return LiveQuerySnapshot() }
        let sql = """
        SELECT p.node_id,
               MAX(p.physical_operator_name) AS physical_operator_name,
               ISNULL(MAX(OBJECT_NAME(p.object_id, p.database_id)), N'') AS object_name,
               SUM(CONVERT(bigint, p.row_count)) AS row_count,
               SUM(CONVERT(bigint, p.estimate_row_count)) AS estimate_row_count,
               MAX(CONVERT(bigint, p.elapsed_time_ms)) AS elapsed_time_ms,
               SUM(CONVERT(bigint, p.cpu_time_ms)) AS cpu_time_ms,
               SUM(CONVERT(bigint, p.logical_read_count)) AS logical_read_count,
               SUM(CONVERT(bigint, p.physical_read_count)) AS physical_read_count,
               MIN(CONVERT(int, CASE WHEN p.close_time = 0 THEN 0 ELSE 1 END)) AS is_closed,
               COUNT(*) AS thread_count
        FROM sys.dm_exec_query_profiles AS p
        WHERE p.session_id = \(max(0, sessionID))
        GROUP BY p.node_id
        ORDER BY p.node_id
        """
        let result = try await session.metadataQuery(sql, database: "master")
        if let failure = result.errors.first { throw failure }
        let operators = (result.resultSets.first?.dictionaries() ?? []).map { row in
            LiveQueryOperator(
                nodeID: row.int("node_id"),
                physicalOperator: row.string("physical_operator_name"),
                objectName: row.string("object_name"),
                rowCount: row.int64("row_count"),
                estimatedRows: row.int64("estimate_row_count"),
                elapsedMilliseconds: row.int64("elapsed_time_ms"),
                cpuMilliseconds: row.int64("cpu_time_ms"),
                logicalReads: row.int64("logical_read_count"),
                physicalReads: row.int64("physical_read_count"),
                isClosed: row.int("is_closed") == 1,
                threadCount: row.int("thread_count"))
        }
        return LiveQuerySnapshot(operators: operators)
    }
}
