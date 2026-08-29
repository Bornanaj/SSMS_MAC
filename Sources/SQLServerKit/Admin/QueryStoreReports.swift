import Foundation
import TDSKit

// MARK: - Models

/// What to rank queries by, mirroring the metric picker on the SSMS Query Store reports.
public enum QueryStoreMetric: String, Sendable, CaseIterable, Identifiable {
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

    /// The expression the ORDER BY uses. Every one of these is a constant, so it is safe
    /// to interpolate into the report query.
    var totalExpression: String {
        switch self {
        case .executionCount: return "SUM(rs.count_executions)"
        default: return "SUM(\(weightExpression))"
        }
    }

    /// The per-interval weighted value the regression report sums before dividing by the
    /// execution count to get an average.
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

    /// Execution count is a total, not an average, so there is nothing to regress against;
    /// the regression report falls back to duration for it.
    var regressionMetric: QueryStoreMetric {
        self == .executionCount ? .duration : self
    }

    /// Microsecond metrics are reported in milliseconds; page counts and execution counts
    /// are reported as they are.
    public var isMicroseconds: Bool {
        self == .duration || self == .cpuTime
    }

    public var unit: String {
        switch self {
        case .duration, .cpuTime: return "ms"
        case .logicalReads, .logicalWrites, .physicalReads: return "pages"
        case .memoryConsumption: return "pages"
        case .executionCount: return ""
        }
    }
}

/// `sys.database_query_store_options`, which is the Query Store page of Database Properties.
public struct QueryStoreOptions: Sendable, Hashable {
    public var actualState: String
    public var desiredState: String
    public var readOnlyReason: Int
    public var currentStorageSizeMB: Double
    public var maxStorageSizeMB: Double
    public var captureMode: String
    public var cleanupMode: String
    public var staleQueryThresholdDays: Int
    public var intervalLengthMinutes: Int
    public var maxPlansPerQuery: Int
    public var waitStatsCaptureMode: String

    public init(actualState: String = "OFF",
                desiredState: String = "OFF",
                readOnlyReason: Int = 0,
                currentStorageSizeMB: Double = 0,
                maxStorageSizeMB: Double = 0,
                captureMode: String = "",
                cleanupMode: String = "",
                staleQueryThresholdDays: Int = 0,
                intervalLengthMinutes: Int = 0,
                maxPlansPerQuery: Int = 0,
                waitStatsCaptureMode: String = "") {
        self.actualState = actualState
        self.desiredState = desiredState
        self.readOnlyReason = readOnlyReason
        self.currentStorageSizeMB = currentStorageSizeMB
        self.maxStorageSizeMB = maxStorageSizeMB
        self.captureMode = captureMode
        self.cleanupMode = cleanupMode
        self.staleQueryThresholdDays = staleQueryThresholdDays
        self.intervalLengthMinutes = intervalLengthMinutes
        self.maxPlansPerQuery = maxPlansPerQuery
        self.waitStatsCaptureMode = waitStatsCaptureMode
    }

    public var isEnabled: Bool { actualState.uppercased() != "OFF" }

    public var usedPercent: Double {
        guard maxStorageSizeMB > 0 else { return 0 }
        return min(100, currentStorageSizeMB / maxStorageSizeMB * 100)
    }
}

/// One row of the Top Resource Consuming Queries report.
public struct QueryStoreEntry: Sendable, Hashable, Identifiable {
    public var id: String { "\(queryID)/\(planID)" }

    public var queryID: Int64
    public var planID: Int64
    public var objectName: String
    public var queryText: String
    public var executionCount: Int64
    /// The metric the report was ranked by, already converted into `metricUnit`.
    public var metricTotal: Double
    public var metricAverage: Double
    public var avgDurationMs: Double
    public var avgCPUMs: Double
    public var avgLogicalReads: Double
    public var avgMemoryPages: Double
    public var lastExecutionTime: String
    public var isPlanForced: Bool
    public var planCount: Int

    public init(queryID: Int64 = 0,
                planID: Int64 = 0,
                objectName: String = "",
                queryText: String = "",
                executionCount: Int64 = 0,
                metricTotal: Double = 0,
                metricAverage: Double = 0,
                avgDurationMs: Double = 0,
                avgCPUMs: Double = 0,
                avgLogicalReads: Double = 0,
                avgMemoryPages: Double = 0,
                lastExecutionTime: String = "",
                isPlanForced: Bool = false,
                planCount: Int = 0) {
        self.queryID = queryID
        self.planID = planID
        self.objectName = objectName
        self.queryText = queryText
        self.executionCount = executionCount
        self.metricTotal = metricTotal
        self.metricAverage = metricAverage
        self.avgDurationMs = avgDurationMs
        self.avgCPUMs = avgCPUMs
        self.avgLogicalReads = avgLogicalReads
        self.avgMemoryPages = avgMemoryPages
        self.lastExecutionTime = lastExecutionTime
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

// MARK: - Query Store reports

/// The Query Store reports from the Management node: top resource consumers, regressed
/// queries, queries with forced plans, plus the plan forcing actions.
public struct QueryStoreReports: Sendable {

    private let session: SQLServerSession
    private let runner: AdminRunner

    public init(session: SQLServerSession) {
        self.session = session
        self.runner = AdminRunner(session: session)
    }

    private func requireQueryStore() async throws {
        let info = await session.serverInfo
        guard info.supportsQueryStore else {
            throw SQLServerError.unsupportedOperation(
                "Query Store needs SQL Server 2016 or later; this instance reports "
                + "\(info.friendlyVersion).")
        }
    }

    // MARK: Configuration

    public func options(database: String) async throws -> QueryStoreOptions {
        try await requireQueryStore()
        let sql = """
        SELECT
            ISNULL(o.actual_state_desc, N'OFF')                       AS ActualState,
            ISNULL(o.desired_state_desc, N'OFF')                      AS DesiredState,
            CAST(ISNULL(o.readonly_reason, 0) AS int)                 AS ReadOnlyReason,
            CAST(ISNULL(o.current_storage_size_mb, 0) AS float)       AS CurrentStorageMB,
            CAST(ISNULL(o.max_storage_size_mb, 0) AS float)           AS MaxStorageMB,
            ISNULL(o.query_capture_mode_desc, N'')                    AS CaptureMode,
            ISNULL(o.size_based_cleanup_mode_desc, N'')               AS CleanupMode,
            CAST(ISNULL(o.stale_query_threshold_days, 0) AS int)      AS StaleDays,
            CAST(ISNULL(o.interval_length_minutes, 0) AS int)         AS IntervalMinutes,
            CAST(ISNULL(o.max_plans_per_query, 0) AS int)             AS MaxPlans,
            ISNULL(o.wait_stats_capture_mode_desc, N'')               AS WaitStatsMode
        FROM sys.database_query_store_options AS o;
        """
        guard let row = try await runner.read(sql, database: database).first else {
            return QueryStoreOptions()
        }
        return QueryStoreOptions(
            actualState: row.string("ActualState", default: "OFF"),
            desiredState: row.string("DesiredState", default: "OFF"),
            readOnlyReason: row.int("ReadOnlyReason"),
            currentStorageSizeMB: row.double("CurrentStorageMB"),
            maxStorageSizeMB: row.double("MaxStorageMB"),
            captureMode: row.string("CaptureMode"),
            cleanupMode: row.string("CleanupMode"),
            staleQueryThresholdDays: row.int("StaleDays"),
            intervalLengthMinutes: row.int("IntervalMinutes"),
            maxPlansPerQuery: row.int("MaxPlans"),
            waitStatsCaptureMode: row.string("WaitStatsMode")
        )
    }

    /// The ALTER DATABASE statement behind the Query Store page's On / Off / Read-only
    /// radio buttons.
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

    public func setState(database: String, state: String) async throws {
        try await requireQueryStore()
        let info = await session.serverInfo
        let azure = info.isAzureSQLDatabase
        let script = try QueryStoreReports.setStateScript(database: database, state: state,
                                                          useCurrentDatabase: azure)
        try await runner.run(script, database: azure ? database : "master")
    }

    public func purge(database: String) async throws {
        try await requireQueryStore()
        let info = await session.serverInfo
        let azure = info.isAzureSQLDatabase
        let target = azure ? "CURRENT" : SQLIdentifier.quote(database)
        try await runner.run("ALTER DATABASE \(target) SET QUERY_STORE CLEAR ALL;",
                             database: azure ? database : "master")
    }

    // MARK: Top consumers

    public func topQueries(database: String,
                           metric: QueryStoreMetric = .duration,
                           hours: Int = 24,
                           limit: Int = 25) async throws -> [QueryStoreEntry] {
        try await requireQueryStore()
        let window = max(1, hours)
        let top = max(1, limit)
        let divisor = metric.isMicroseconds ? "1000.0" : "1.0"

        let sql = """
        SELECT TOP (\(top))
            CAST(q.query_id AS bigint)                                AS QueryId,
            CAST(p.plan_id AS bigint)                                 AS PlanId,
            ISNULL(OBJECT_NAME(q.object_id), N'')                     AS ObjectName,
            ISNULL(SUBSTRING(qt.query_sql_text, 1, 4000), N'')        AS QueryText,
            CAST(SUM(rs.count_executions) AS bigint)                  AS ExecutionCount,
            CAST(\(metric.totalExpression) / \(divisor) AS float)     AS MetricTotal,
            CAST(SUM(rs.count_executions * rs.avg_duration)
                 / NULLIF(SUM(rs.count_executions), 0) / 1000.0 AS float)      AS AvgDurationMs,
            CAST(SUM(rs.count_executions * rs.avg_cpu_time)
                 / NULLIF(SUM(rs.count_executions), 0) / 1000.0 AS float)      AS AvgCpuMs,
            CAST(SUM(rs.count_executions * rs.avg_logical_io_reads)
                 / NULLIF(SUM(rs.count_executions), 0) AS float)               AS AvgLogicalReads,
            CAST(SUM(rs.count_executions * rs.avg_query_max_used_memory)
                 / NULLIF(SUM(rs.count_executions), 0) AS float)               AS AvgMemoryPages,
            ISNULL(CONVERT(nvarchar(23), MAX(rs.last_execution_time), 121), N'') AS LastExecution,
            CAST(MAX(CASE WHEN p.is_forced_plan = 1 THEN 1 ELSE 0 END) AS int) AS IsForced,
            CAST(COUNT(DISTINCT p.plan_id) AS int)                    AS PlanCount
        FROM sys.query_store_runtime_stats AS rs
        JOIN sys.query_store_runtime_stats_interval AS rsi
             ON rsi.runtime_stats_interval_id = rs.runtime_stats_interval_id
        JOIN sys.query_store_plan AS p ON p.plan_id = rs.plan_id
        JOIN sys.query_store_query AS q ON q.query_id = p.query_id
        JOIN sys.query_store_query_text AS qt ON qt.query_text_id = q.query_text_id
        WHERE rsi.start_time >= DATEADD(hour, -\(window), SYSDATETIMEOFFSET())
        GROUP BY q.query_id, p.plan_id, q.object_id, SUBSTRING(qt.query_sql_text, 1, 4000)
        ORDER BY MetricTotal DESC;
        """

        return try await runner.read(sql, database: database).map { row in
            let executions = row.int64("ExecutionCount")
            let total = row.double("MetricTotal")
            return QueryStoreEntry(
                queryID: row.int64("QueryId"),
                planID: row.int64("PlanId"),
                objectName: row.string("ObjectName"),
                queryText: row.string("QueryText"),
                executionCount: executions,
                metricTotal: total,
                metricAverage: executions > 0 ? total / Double(executions) : 0,
                avgDurationMs: row.double("AvgDurationMs"),
                avgCPUMs: row.double("AvgCpuMs"),
                avgLogicalReads: row.double("AvgLogicalReads"),
                avgMemoryPages: row.double("AvgMemoryPages"),
                lastExecutionTime: row.string("LastExecution"),
                isPlanForced: row.bool("IsForced"),
                planCount: row.int("PlanCount")
            )
        }
    }

    // MARK: Regressed queries

    /// Queries whose recent average is worse than their baseline. `recentHours` is the
    /// window under suspicion; everything older, up to `baselineHours`, is the baseline.
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
        let top = max(1, limit)
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
        SELECT TOP (\(top))
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
        ORDER BY RecentAverage - BaselineAverage DESC;
        """

        return try await runner.read(sql, database: database).map { row in
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

    public func forcedPlans(database: String) async throws -> [QueryStoreEntry] {
        try await requireQueryStore()
        let sql = """
        SELECT
            CAST(q.query_id AS bigint)                                AS QueryId,
            CAST(p.plan_id AS bigint)                                 AS PlanId,
            ISNULL(OBJECT_NAME(q.object_id), N'')                     AS ObjectName,
            ISNULL(SUBSTRING(qt.query_sql_text, 1, 4000), N'')        AS QueryText,
            CAST(ISNULL(p.count_compiles, 0) AS bigint)               AS ExecutionCount,
            CAST(0 AS float)                                          AS MetricTotal,
            CAST(0 AS float)                                          AS AvgDurationMs,
            CAST(0 AS float)                                          AS AvgCpuMs,
            CAST(0 AS float)                                          AS AvgLogicalReads,
            CAST(0 AS float)                                          AS AvgMemoryPages,
            ISNULL(CONVERT(nvarchar(23), p.last_execution_time, 121), N'') AS LastExecution,
            1                                                         AS IsForced,
            CAST(1 AS int)                                            AS PlanCount
        FROM sys.query_store_plan AS p
        JOIN sys.query_store_query AS q ON q.query_id = p.query_id
        JOIN sys.query_store_query_text AS qt ON qt.query_text_id = q.query_text_id
        WHERE p.is_forced_plan = 1
        ORDER BY q.query_id;
        """
        return try await runner.read(sql, database: database).map { row in
            QueryStoreEntry(
                queryID: row.int64("QueryId"),
                planID: row.int64("PlanId"),
                objectName: row.string("ObjectName"),
                queryText: row.string("QueryText"),
                executionCount: row.int64("ExecutionCount"),
                lastExecutionTime: row.string("LastExecution"),
                isPlanForced: true,
                planCount: 1
            )
        }
    }

    public func forcePlan(database: String, queryID: Int64, planID: Int64) async throws {
        try await requireQueryStore()
        try await runner.run("EXEC sys.sp_query_store_force_plan "
                             + "@query_id = \(queryID), @plan_id = \(planID);", database: database)
    }

    public func unforcePlan(database: String, queryID: Int64, planID: Int64) async throws {
        try await requireQueryStore()
        try await runner.run("EXEC sys.sp_query_store_unforce_plan "
                             + "@query_id = \(queryID), @plan_id = \(planID);", database: database)
    }

    /// The stored plan XML, so a Query Store row can be opened in the plan viewer.
    public func planXML(database: String, planID: Int64) async throws -> String {
        try await requireQueryStore()
        let sql = """
        SELECT CONVERT(nvarchar(max), p.query_plan) AS QueryPlan
        FROM sys.query_store_plan AS p
        WHERE p.plan_id = \(planID);
        """
        let rows = try await runner.read(sql, database: database)
        guard let xml = rows.first?.string("QueryPlan"), !xml.isEmpty else {
            throw SQLServerError.objectNotFound("Query Store plan \(planID)")
        }
        return xml
    }
}
