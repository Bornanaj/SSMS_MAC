import Foundation
import TDSKit

// MARK: - Models

/// What to rank queries by, mirroring the metric picker on the SSMS Query Store reports.
public enum QueryStoreMetric: String, CaseIterable, Identifiable, Sendable {
    case duration
    case cpuTime
    case logicalReads
    case logicalWrites
    case physicalReads
    case memoryConsumption
    case executionCount

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .duration: return "Duration"
        case .cpuTime: return "CPU time"
        case .logicalReads: return "Logical reads"
        case .logicalWrites: return "Logical writes"
        case .physicalReads: return "Physical reads"
        case .memoryConsumption: return "Memory consumption"
        case .executionCount: return "Execution count"
        }
    }

    public var unit: String {
        switch self {
        case .duration, .cpuTime: return "ms"
        case .logicalReads, .logicalWrites, .physicalReads, .memoryConsumption: return "pages"
        case .executionCount: return ""
        }
    }

    /// Duration and CPU are stored in microseconds; everything else is already a count.
    public var isMicroseconds: Bool { self == .duration || self == .cpuTime }

    /// The per-interval weighted value, summed and then divided by the execution count to
    /// get an average. Every one of these is a constant, so it is safe to interpolate.
    var weightExpression: String {
        switch self {
        case .duration: return "rs.count_executions * rs.avg_duration"
        case .cpuTime: return "rs.count_executions * rs.avg_cpu_time"
        case .logicalReads: return "rs.count_executions * rs.avg_logical_io_reads"
        case .logicalWrites: return "rs.count_executions * rs.avg_logical_io_writes"
        case .physicalReads: return "rs.count_executions * rs.avg_physical_io_reads"
        case .memoryConsumption: return "rs.count_executions * rs.avg_query_max_used_memory"
        case .executionCount: return "rs.count_executions * rs.avg_duration"
        }
    }

    var totalExpression: String {
        self == .executionCount ? "SUM(rs.count_executions)" : "SUM(\(weightExpression))"
    }

    /// Execution count is a total, not an average, so there is nothing to regress against;
    /// the regression report falls back to duration for it.
    public var regressionMetric: QueryStoreMetric {
        self == .executionCount ? .duration : self
    }
}

/// `sys.database_query_store_options`, which is the Query Store page of Database Properties.
public struct QueryStoreOptions: Sendable, Hashable {
    public var actualState: String
    public var desiredState: String
    public var currentStorageMB: Double
    public var maxStorageMB: Double
    public var captureMode: String
    public var cleanupMode: String
    public var staleQueryThresholdDays: Int
    public var intervalMinutes: Int
    public var maxPlansPerQuery: Int
    public var waitStatsCaptureMode: String

    public init(actualState: String = "OFF",
                desiredState: String = "OFF",
                currentStorageMB: Double = 0,
                maxStorageMB: Double = 0,
                captureMode: String = "",
                cleanupMode: String = "",
                staleQueryThresholdDays: Int = 0,
                intervalMinutes: Int = 0,
                maxPlansPerQuery: Int = 0,
                waitStatsCaptureMode: String = "") {
        self.actualState = actualState
        self.desiredState = desiredState
        self.currentStorageMB = currentStorageMB
        self.maxStorageMB = maxStorageMB
        self.captureMode = captureMode
        self.cleanupMode = cleanupMode
        self.staleQueryThresholdDays = staleQueryThresholdDays
        self.intervalMinutes = intervalMinutes
        self.maxPlansPerQuery = maxPlansPerQuery
        self.waitStatsCaptureMode = waitStatsCaptureMode
    }

    public var isEnabled: Bool { actualState.uppercased() != "OFF" }

    /// A read-only Query Store is usually a full one, so the storage share matters.
    public var usedPercent: Double {
        guard maxStorageMB > 0 else { return 0 }
        return min(100, currentStorageMB / maxStorageMB * 100)
    }
}

/// One row of the Top Resource Consuming Queries report.
public struct QueryStoreQuery: Sendable, Hashable, Identifiable {
    public var id: String { "\(queryID)/\(planID)" }

    public var queryID: Int64
    public var planID: Int64
    public var objectName: String
    public var queryText: String
    public var executionCount: Int64
    /// The metric the report was ranked by, converted into that metric's unit.
    public var metricTotal: Double
    public var avgDurationMs: Double
    public var avgCPUMs: Double
    public var avgLogicalReads: Double
    public var lastExecutedAt: String
    public var isPlanForced: Bool
    public var planCount: Int

    public init(queryID: Int64 = 0,
                planID: Int64 = 0,
                objectName: String = "",
                queryText: String = "",
                executionCount: Int64 = 0,
                metricTotal: Double = 0,
                avgDurationMs: Double = 0,
                avgCPUMs: Double = 0,
                avgLogicalReads: Double = 0,
                lastExecutedAt: String = "",
                isPlanForced: Bool = false,
                planCount: Int = 0) {
        self.queryID = queryID
        self.planID = planID
        self.objectName = objectName
        self.queryText = queryText
        self.executionCount = executionCount
        self.metricTotal = metricTotal
        self.avgDurationMs = avgDurationMs
        self.avgCPUMs = avgCPUMs
        self.avgLogicalReads = avgLogicalReads
        self.lastExecutedAt = lastExecutedAt
        self.isPlanForced = isPlanForced
        self.planCount = planCount
    }
}

/// One row of the Regressed Queries report: a recent window against a baseline window.
public struct QueryStoreRegression: Sendable, Hashable, Identifiable {
    public var id: Int64 { queryID }

    public var queryID: Int64
    public var queryText: String
    public var objectName: String
    public var recentAverage: Double
    public var baselineAverage: Double
    public var recentExecutions: Int64
    public var baselineExecutions: Int64

    public init(queryID: Int64 = 0,
                queryText: String = "",
                objectName: String = "",
                recentAverage: Double = 0,
                baselineAverage: Double = 0,
                recentExecutions: Int64 = 0,
                baselineExecutions: Int64 = 0) {
        self.queryID = queryID
        self.queryText = queryText
        self.objectName = objectName
        self.recentAverage = recentAverage
        self.baselineAverage = baselineAverage
        self.recentExecutions = recentExecutions
        self.baselineExecutions = baselineExecutions
    }

    /// How much worse the recent window is, as a percentage of the baseline.
    public var changePercent: Double {
        guard baselineAverage > 0 else { return 0 }
        return (recentAverage - baselineAverage) / baselineAverage * 100
    }
}

// MARK: - Service

/// The Query Store reports SSMS puts under a database's Query Store node: top resource
/// consumers, regressed queries and forced plans, plus plan forcing and the settings.
///
/// Query Store keeps a plan long after the query stopped running, which is what makes
/// these reports worth having — the plan cache has usually evicted it by the time anyone
/// goes looking.
public struct QueryStoreService: Sendable {
    private let session: SQLServerSession

    public init(session: SQLServerSession) {
        self.session = session
    }

    /// Query Store arrived in SQL Server 2016.
    private func requireQueryStore() async throws {
        let info = await session.serverInfo
        guard info.supportsQueryStore else {
            throw SQLServerError.unsupportedOperation(
                "Query Store needs SQL Server 2016 or later; this instance reports "
                    + "\(info.friendlyVersion).")
        }
    }

    // MARK: Settings

    public func options(database: String) async throws -> QueryStoreOptions {
        try await requireQueryStore()
        let sql = """
        SELECT
            ISNULL(o.actual_state_desc, N'OFF')                       AS ActualState,
            ISNULL(o.desired_state_desc, N'OFF')                      AS DesiredState,
            CAST(ISNULL(o.current_storage_size_mb, 0) AS float)       AS CurrentStorageMB,
            CAST(ISNULL(o.max_storage_size_mb, 0) AS float)           AS MaxStorageMB,
            ISNULL(o.query_capture_mode_desc, N'')                    AS CaptureMode,
            ISNULL(o.size_based_cleanup_mode_desc, N'')               AS CleanupMode,
            CAST(ISNULL(o.stale_query_threshold_days, 0) AS int)      AS StaleDays,
            CAST(ISNULL(o.interval_length_minutes, 0) AS int)         AS IntervalMinutes,
            CAST(ISNULL(o.max_plans_per_query, 0) AS int)             AS MaxPlans,
            ISNULL(o.wait_stats_capture_mode_desc, N'')               AS WaitStatsMode
        FROM sys.database_query_store_options AS o
        """
        let result = try await session.metadataQuery(sql, database: database)
        if let failure = result.errors.first { throw failure }
        guard let row = result.resultSets.first?.dictionaries().first else {
            return QueryStoreOptions()
        }
        return QueryStoreOptions(
            actualState: row.string("ActualState", default: "OFF"),
            desiredState: row.string("DesiredState", default: "OFF"),
            currentStorageMB: row.double("CurrentStorageMB"),
            maxStorageMB: row.double("MaxStorageMB"),
            captureMode: row.string("CaptureMode"),
            cleanupMode: row.string("CleanupMode"),
            staleQueryThresholdDays: row.int("StaleDays"),
            intervalMinutes: row.int("IntervalMinutes"),
            maxPlansPerQuery: row.int("MaxPlans"),
            waitStatsCaptureMode: row.string("WaitStatsMode")
        )
    }

    /// The ALTER DATABASE statement behind the On / Read-only / Off choice.
    ///
    /// `useCurrentDatabase` emits `ALTER DATABASE CURRENT`, which is the only form Azure
    /// SQL Database accepts — it has no cross-database ALTER and no reachable `master`.
    public static func setStateScript(database: String,
                                     state: String,
                                     useCurrentDatabase: Bool = false) throws -> String {
        let normalized = state.uppercased().replacingOccurrences(of: " ", with: "_")
        guard ["OFF", "READ_ONLY", "READ_WRITE"].contains(normalized) else {
            throw SQLServerError.unsupportedOperation(
                "Query Store accepts OFF, READ_ONLY or READ_WRITE; '\(state)' is neither.")
        }
        let target = useCurrentDatabase ? "CURRENT" : SQLIdentifier.quote(database)
        if normalized == "OFF" {
            return "ALTER DATABASE \(target) SET QUERY_STORE = OFF;"
        }
        return "ALTER DATABASE \(target) SET QUERY_STORE = ON (OPERATION_MODE = \(normalized));"
    }

    public static func clearScript(database: String, useCurrentDatabase: Bool = false) -> String {
        let target = useCurrentDatabase ? "CURRENT" : SQLIdentifier.quote(database)
        return "ALTER DATABASE \(target) SET QUERY_STORE CLEAR ALL;"
    }

    public func setState(database: String, state: String) async throws {
        try await requireQueryStore()
        let azure = await session.serverInfo.isAzureSQLDatabase
        let script = try QueryStoreService.setStateScript(database: database, state: state,
                                                          useCurrentDatabase: azure)
        try await run(script, database: azure ? database : "master")
    }

    public func clear(database: String) async throws {
        try await requireQueryStore()
        let azure = await session.serverInfo.isAzureSQLDatabase
        try await run(QueryStoreService.clearScript(database: database, useCurrentDatabase: azure),
                      database: azure ? database : "master")
    }

    // MARK: Top consumers

    public func topQueries(database: String,
                           metric: QueryStoreMetric = .duration,
                           hours: Int = 24,
                           limit: Int = 25) async throws -> [QueryStoreQuery] {
        try await requireQueryStore()
        let window = max(1, hours)
        let divisor = metric.isMicroseconds ? "1000.0" : "1.0"

        let sql = """
        SELECT TOP (\(max(1, limit)))
            CAST(q.query_id AS bigint)                                AS QueryId,
            CAST(p.plan_id AS bigint)                                 AS PlanId,
            ISNULL(OBJECT_NAME(q.object_id), N'')                     AS ObjectName,
            ISNULL(SUBSTRING(qt.query_sql_text, 1, 4000), N'')        AS QueryText,
            CAST(SUM(rs.count_executions) AS bigint)                  AS ExecutionCount,
            CAST(\(metric.totalExpression) / \(divisor) AS float)     AS MetricTotal,
            CAST(SUM(rs.count_executions * rs.avg_duration)
                 / NULLIF(SUM(rs.count_executions), 0) / 1000.0 AS float)   AS AvgDurationMs,
            CAST(SUM(rs.count_executions * rs.avg_cpu_time)
                 / NULLIF(SUM(rs.count_executions), 0) / 1000.0 AS float)   AS AvgCpuMs,
            CAST(SUM(rs.count_executions * rs.avg_logical_io_reads)
                 / NULLIF(SUM(rs.count_executions), 0) AS float)            AS AvgLogicalReads,
            ISNULL(CONVERT(nvarchar(23), MAX(rs.last_execution_time), 121), N'') AS LastExecuted,
            CAST(MAX(CASE WHEN p.is_forced_plan = 1 THEN 1 ELSE 0 END) AS int)  AS IsForced,
            CAST((SELECT COUNT(*) FROM sys.query_store_plan AS p2
                  WHERE p2.query_id = q.query_id) AS int)             AS PlanCount
        FROM sys.query_store_runtime_stats AS rs
        JOIN sys.query_store_runtime_stats_interval AS rsi
             ON rsi.runtime_stats_interval_id = rs.runtime_stats_interval_id
        JOIN sys.query_store_plan AS p ON p.plan_id = rs.plan_id
        JOIN sys.query_store_query AS q ON q.query_id = p.query_id
        JOIN sys.query_store_query_text AS qt ON qt.query_text_id = q.query_text_id
        WHERE rsi.start_time >= DATEADD(hour, -\(window), SYSDATETIMEOFFSET())
        GROUP BY q.query_id, p.plan_id, q.object_id, SUBSTRING(qt.query_sql_text, 1, 4000)
        ORDER BY MetricTotal DESC
        """

        let result = try await session.metadataQuery(sql, database: database)
        if let failure = result.errors.first { throw failure }
        return (result.resultSets.first?.dictionaries() ?? []).map { row in
            QueryStoreQuery(
                queryID: row.int64("QueryId"),
                planID: row.int64("PlanId"),
                objectName: row.string("ObjectName"),
                queryText: row.string("QueryText"),
                executionCount: row.int64("ExecutionCount"),
                metricTotal: row.double("MetricTotal"),
                avgDurationMs: row.double("AvgDurationMs"),
                avgCPUMs: row.double("AvgCpuMs"),
                avgLogicalReads: row.double("AvgLogicalReads"),
                lastExecutedAt: row.string("LastExecuted"),
                isPlanForced: row.bool("IsForced"),
                planCount: row.int("PlanCount")
            )
        }
    }

    // MARK: Regressed queries

    /// Queries whose recent average is worse than their baseline. `recentHours` is the
    /// window under suspicion; everything older, back to `baselineHours`, is the baseline.
    public func regressedQueries(database: String,
                                 metric: QueryStoreMetric = .duration,
                                 recentHours: Int = 6,
                                 baselineHours: Int = 48,
                                 minimumExecutions: Int = 5,
                                 limit: Int = 25) async throws -> [QueryStoreRegression] {
        try await requireQueryStore()
        let effective = metric.regressionMetric
        let recent = max(1, recentHours)
        let baseline = max(recent + 1, baselineHours)
        let divisor = effective.isMicroseconds ? "1000.0" : "1.0"
        let minimum = max(1, minimumExecutions)

        let sql = """
        WITH windows AS (
            SELECT
                q.query_id,
                SUBSTRING(qt.query_sql_text, 1, 4000)                 AS QueryText,
                ISNULL(OBJECT_NAME(q.object_id), N'')                 AS ObjectName,
                CASE WHEN rsi.start_time >= DATEADD(hour, -\(recent), SYSDATETIMEOFFSET())
                     THEN 1 ELSE 0 END                                AS IsRecent,
                rs.count_executions,
                \(effective.weightExpression)                         AS MetricWeight
            FROM sys.query_store_runtime_stats AS rs
            JOIN sys.query_store_runtime_stats_interval AS rsi
                 ON rsi.runtime_stats_interval_id = rs.runtime_stats_interval_id
            JOIN sys.query_store_plan AS p ON p.plan_id = rs.plan_id
            JOIN sys.query_store_query AS q ON q.query_id = p.query_id
            JOIN sys.query_store_query_text AS qt ON qt.query_text_id = q.query_text_id
            WHERE rsi.start_time >= DATEADD(hour, -\(baseline), SYSDATETIMEOFFSET())
        )
        SELECT TOP (\(max(1, limit)))
            CAST(w.query_id AS bigint)                                AS QueryId,
            MAX(w.QueryText)                                          AS QueryText,
            MAX(w.ObjectName)                                         AS ObjectName,
            CAST(SUM(CASE WHEN w.IsRecent = 1 THEN w.MetricWeight END)
                 / NULLIF(SUM(CASE WHEN w.IsRecent = 1 THEN w.count_executions END), 0)
                 / \(divisor) AS float)                               AS RecentAverage,
            CAST(SUM(CASE WHEN w.IsRecent = 0 THEN w.MetricWeight END)
                 / NULLIF(SUM(CASE WHEN w.IsRecent = 0 THEN w.count_executions END), 0)
                 / \(divisor) AS float)                               AS BaselineAverage,
            CAST(ISNULL(SUM(CASE WHEN w.IsRecent = 1 THEN w.count_executions END), 0) AS bigint)
                                                                      AS RecentExecutions,
            CAST(ISNULL(SUM(CASE WHEN w.IsRecent = 0 THEN w.count_executions END), 0) AS bigint)
                                                                      AS BaselineExecutions
        FROM windows AS w
        GROUP BY w.query_id
        HAVING SUM(CASE WHEN w.IsRecent = 1 THEN w.count_executions END) >= \(minimum)
           AND SUM(CASE WHEN w.IsRecent = 0 THEN w.count_executions END) >= \(minimum)
           AND SUM(CASE WHEN w.IsRecent = 1 THEN w.MetricWeight END)
               / NULLIF(SUM(CASE WHEN w.IsRecent = 1 THEN w.count_executions END), 0)
             > SUM(CASE WHEN w.IsRecent = 0 THEN w.MetricWeight END)
               / NULLIF(SUM(CASE WHEN w.IsRecent = 0 THEN w.count_executions END), 0)
        ORDER BY RecentAverage - BaselineAverage DESC
        """

        let result = try await session.metadataQuery(sql, database: database)
        if let failure = result.errors.first { throw failure }
        return (result.resultSets.first?.dictionaries() ?? []).map { row in
            QueryStoreRegression(
                queryID: row.int64("QueryId"),
                queryText: row.string("QueryText"),
                objectName: row.string("ObjectName"),
                recentAverage: row.double("RecentAverage"),
                baselineAverage: row.double("BaselineAverage"),
                recentExecutions: row.int64("RecentExecutions"),
                baselineExecutions: row.int64("BaselineExecutions")
            )
        }
    }

    // MARK: Forced plans

    public func forcedPlans(database: String) async throws -> [QueryStoreQuery] {
        try await requireQueryStore()
        let sql = """
        SELECT
            CAST(q.query_id AS bigint)                                AS QueryId,
            CAST(p.plan_id AS bigint)                                 AS PlanId,
            ISNULL(OBJECT_NAME(q.object_id), N'')                     AS ObjectName,
            ISNULL(SUBSTRING(qt.query_sql_text, 1, 4000), N'')        AS QueryText,
            CAST(ISNULL(p.count_compiles, 0) AS bigint)               AS ExecutionCount,
            ISNULL(CONVERT(nvarchar(23), p.last_execution_time, 121), N'') AS LastExecuted,
            CAST(ISNULL(p.force_failure_count, 0) AS int)             AS ForceFailures,
            ISNULL(p.last_force_failure_reason_desc, N'')             AS ForceFailureReason
        FROM sys.query_store_plan AS p
        JOIN sys.query_store_query AS q ON q.query_id = p.query_id
        JOIN sys.query_store_query_text AS qt ON qt.query_text_id = q.query_text_id
        WHERE p.is_forced_plan = 1
        ORDER BY q.query_id
        """
        let result = try await session.metadataQuery(sql, database: database)
        if let failure = result.errors.first { throw failure }
        return (result.resultSets.first?.dictionaries() ?? []).map { row in
            // A forced plan that keeps failing to be applied is the interesting case, so
            // the reason rides along in the object column rather than being dropped.
            let failures = row.int("ForceFailures")
            let reason = row.string("ForceFailureReason")
            var object = row.string("ObjectName")
            if failures > 0, !reason.isEmpty {
                object = object.isEmpty ? "forcing failed: \(reason)"
                    : "\(object) — forcing failed: \(reason)"
            }
            return QueryStoreQuery(
                queryID: row.int64("QueryId"),
                planID: row.int64("PlanId"),
                objectName: object,
                queryText: row.string("QueryText"),
                executionCount: row.int64("ExecutionCount"),
                lastExecutedAt: row.string("LastExecuted"),
                isPlanForced: true,
                planCount: 1
            )
        }
    }

    public func forcePlan(database: String, queryID: Int64, planID: Int64) async throws {
        try await requireQueryStore()
        try await run("EXEC sys.sp_query_store_force_plan @query_id = \(queryID), "
                      + "@plan_id = \(planID);", database: database)
    }

    public func unforcePlan(database: String, queryID: Int64, planID: Int64) async throws {
        try await requireQueryStore()
        try await run("EXEC sys.sp_query_store_unforce_plan @query_id = \(queryID), "
                      + "@plan_id = \(planID);", database: database)
    }

    /// The stored showplan, so a finished query can still be opened in the plan viewer.
    public func planXML(database: String, planID: Int64) async throws -> String {
        try await requireQueryStore()
        let sql = """
        SELECT CONVERT(nvarchar(max), p.query_plan) AS QueryPlan
        FROM sys.query_store_plan AS p
        WHERE p.plan_id = \(planID)
        """
        let result = try await session.metadataQuery(sql, database: database)
        if let failure = result.errors.first { throw failure }
        let xml = result.resultSets.first?.dictionaries().first?.string("QueryPlan") ?? ""
        guard !xml.isEmpty else {
            throw SQLServerError.objectNotFound("Query Store plan \(planID)")
        }
        return xml
    }

    // MARK: Execution

    private func run(_ script: String, database: String?) async throws {
        let connection = try await session.openConnection(database: database)
        defer { Task { try? await connection.close() } }
        let result = try await connection.query(script)
        if let failure = result.errors.first { throw failure }
    }
}
