import Foundation
import TDSKit

/// A tabular report result, kept as plain strings because reports are small and are
/// only ever displayed.
public struct ReportResult: Sendable {
    public var columns: [String]
    public var rows: [[String]]
    /// Column indexes that should right-align, i.e. the numeric ones.
    public var numericColumns: Set<Int>

    public init(columns: [String], rows: [[String]], numericColumns: Set<Int> = []) {
        self.columns = columns
        self.rows = rows
        self.numericColumns = numericColumns
    }

    public var isEmpty: Bool { rows.isEmpty }
}

/// The reports SSMS ships under "Reports > Standard Reports".
public enum ServerReportKind: String, CaseIterable, Identifiable, Sendable {
    case serverDashboard
    case configurationChanges
    case diskUsageByDatabase
    case diskUsageByTable
    case backupHistory
    case topQueriesByCPU
    case topQueriesByDuration
    case topQueriesByIO
    case objectExecutionStatistics
    case indexUsage
    case missingIndexes
    case indexFragmentation
    case blockingTransactions
    case memoryUsage
    case activeConnections
    case databaseGrowthEvents
    case schemaChangeHistory
    case tableRowCounts

    public var id: String { rawValue }

    public enum Scope: Sendable { case server, database }

    public var scope: Scope {
        switch self {
        case .serverDashboard, .configurationChanges, .diskUsageByDatabase, .backupHistory,
             .topQueriesByCPU, .topQueriesByDuration, .topQueriesByIO, .blockingTransactions,
             .memoryUsage, .activeConnections, .databaseGrowthEvents, .schemaChangeHistory:
            return .server
        case .diskUsageByTable, .objectExecutionStatistics, .indexUsage, .missingIndexes,
             .indexFragmentation, .tableRowCounts:
            return .database
        }
    }

    public var category: String {
        switch self {
        case .serverDashboard, .configurationChanges, .memoryUsage, .activeConnections:
            return "Server"
        case .diskUsageByDatabase, .diskUsageByTable, .databaseGrowthEvents, .tableRowCounts:
            return "Disk usage"
        case .backupHistory, .schemaChangeHistory:
            return "History"
        case .topQueriesByCPU, .topQueriesByDuration, .topQueriesByIO,
             .objectExecutionStatistics, .blockingTransactions:
            return "Performance"
        case .indexUsage, .missingIndexes, .indexFragmentation:
            return "Indexes"
        }
    }

    public var title: String {
        switch self {
        case .serverDashboard: return "Server Dashboard"
        case .configurationChanges: return "Configuration Changes"
        case .diskUsageByDatabase: return "Disk Usage by Database"
        case .diskUsageByTable: return "Disk Usage by Table"
        case .backupHistory: return "Backup and Restore Events"
        case .topQueriesByCPU: return "Top Queries by Total CPU Time"
        case .topQueriesByDuration: return "Top Queries by Average Duration"
        case .topQueriesByIO: return "Top Queries by Total I/O"
        case .objectExecutionStatistics: return "Object Execution Statistics"
        case .indexUsage: return "Index Usage Statistics"
        case .missingIndexes: return "Missing Index Suggestions"
        case .indexFragmentation: return "Index Physical Statistics"
        case .blockingTransactions: return "Blocking Transactions"
        case .memoryUsage: return "Memory Consumption"
        case .activeConnections: return "Active Connections"
        case .databaseGrowthEvents: return "Database Growth Events"
        case .schemaChangeHistory: return "Schema Changes History"
        case .tableRowCounts: return "Table Row Counts"
        }
    }

    public var summary: String {
        switch self {
        case .serverDashboard: return "Edition, uptime, connections and configuration at a glance"
        case .configurationChanges: return "sp_configure settings and whether they are pending"
        case .diskUsageByDatabase: return "Data and log size per database, with free space"
        case .diskUsageByTable: return "Reserved, data, index and unused space per table"
        case .backupHistory: return "Recent backups and restores from msdb"
        case .topQueriesByCPU: return "Cached plans ordered by total worker time"
        case .topQueriesByDuration: return "Cached plans ordered by average elapsed time"
        case .topQueriesByIO: return "Cached plans ordered by logical reads and writes"
        case .objectExecutionStatistics: return "Stored procedure execution counts and cost"
        case .indexUsage: return "Seeks, scans, lookups and updates per index"
        case .missingIndexes: return "Indexes the optimiser wished for, with impact"
        case .indexFragmentation: return "Fragmentation and page counts per index"
        case .blockingTransactions: return "Sessions blocking others right now"
        case .memoryUsage: return "Memory clerks ordered by allocation"
        case .activeConnections: return "Who is connected, from where, and with what"
        case .databaseGrowthEvents: return "Autogrow events from the default trace"
        case .schemaChangeHistory: return "DDL captured by the default trace"
        case .tableRowCounts: return "Row counts per table from partition statistics"
        }
    }

    /// Some reports simply do not exist on Azure SQL Database.
    public func isAvailable(on info: ServerInfo) -> Bool {
        guard info.isAzureSQLDatabase else { return true }
        switch self {
        case .backupHistory, .databaseGrowthEvents, .schemaChangeHistory,
             .configurationChanges, .diskUsageByDatabase:
            return false
        default:
            return true
        }
    }
}

public struct ServerReports: Sendable {
    private let session: SQLServerSession

    public init(session: SQLServerSession) {
        self.session = session
    }

    public func run(_ kind: ServerReportKind, database: String?) async throws -> ReportResult {
        let info = await session.serverInfo
        guard kind.isAvailable(on: info) else {
            throw SQLServerError.unsupportedOperation(
                "\(kind.title) is not available on Azure SQL Database.")
        }
        let sql = ServerReports.sql(for: kind, info: info)
        let target = kind.scope == .database ? database : ServerReports.serverScope(kind, info)
        let result = try await session.metadataQuery(sql, database: target)
        guard let set = result.resultSets.last else {
            return ReportResult(columns: [], rows: [])
        }
        return ServerReports.convert(set)
    }

    private static func serverScope(_ kind: ServerReportKind, _ info: ServerInfo) -> String? {
        switch kind {
        case .backupHistory, .databaseGrowthEvents, .schemaChangeHistory: return "msdb"
        default: return info.isAzureSQLDatabase ? nil : "master"
        }
    }

    static func convert(_ set: TDSResultSet) -> ReportResult {
        var numeric = Set<Int>()
        for column in set.columns where column.typeInfo.dataType.isNumeric {
            numeric.insert(column.index)
        }
        let rows = set.rows.map { row in
            row.map { $0.displayString(nullText: "") }
        }
        return ReportResult(columns: set.columns.map(\.name), rows: rows, numericColumns: numeric)
    }

    // MARK: - The SQL behind each report

    static func sql(for kind: ServerReportKind, info: ServerInfo) -> String {
        switch kind {
        case .serverDashboard:
            return """
            SELECT N'Server name' AS [Property],
                   CAST(SERVERPROPERTY('ServerName') AS nvarchar(200)) AS [Value]
            UNION ALL SELECT N'Edition', CAST(SERVERPROPERTY('Edition') AS nvarchar(200))
            UNION ALL SELECT N'Product version', CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(200))
            UNION ALL SELECT N'Product level', CAST(SERVERPROPERTY('ProductLevel') AS nvarchar(200))
            UNION ALL SELECT N'Collation', CAST(SERVERPROPERTY('Collation') AS nvarchar(200))
            UNION ALL SELECT N'Is clustered',
                   CASE WHEN CAST(SERVERPROPERTY('IsClustered') AS int) = 1 THEN N'Yes' ELSE N'No' END
            UNION ALL SELECT N'Started at',
                   CONVERT(nvarchar(30), (SELECT sqlserver_start_time FROM sys.dm_os_sys_info), 120)
            UNION ALL SELECT N'Uptime',
                   CAST(DATEDIFF(hour, (SELECT sqlserver_start_time FROM sys.dm_os_sys_info),
                                 GETDATE()) AS nvarchar(20)) + N' hours'
            UNION ALL SELECT N'Logical CPUs',
                   CAST((SELECT cpu_count FROM sys.dm_os_sys_info) AS nvarchar(20))
            UNION ALL SELECT N'Databases', CAST((SELECT COUNT(*) FROM sys.databases) AS nvarchar(20))
            UNION ALL SELECT N'User sessions',
                   CAST((SELECT COUNT(*) FROM sys.dm_exec_sessions WHERE is_user_process = 1)
                        AS nvarchar(20))
            UNION ALL SELECT N'Open transactions',
                   CAST((SELECT COUNT(*) FROM sys.dm_tran_active_transactions) AS nvarchar(20))
            """

        case .configurationChanges:
            return """
            SELECT name AS [Setting], CAST(value AS nvarchar(40)) AS [Configured],
                   CAST(value_in_use AS nvarchar(40)) AS [In use],
                   CASE WHEN value <> value_in_use THEN N'Restart pending' ELSE N'' END AS [Note],
                   CAST(minimum AS nvarchar(40)) AS [Minimum],
                   CAST(maximum AS nvarchar(40)) AS [Maximum],
                   ISNULL(description, N'') AS [Description]
            FROM sys.configurations
            ORDER BY name
            """

        case .diskUsageByDatabase:
            return """
            SELECT DB_NAME(database_id) AS [Database],
                   CAST(SUM(CASE WHEN type = 0 THEN size END) * 8.0 / 1024 AS decimal(18,2))
                       AS [Data MB],
                   CAST(SUM(CASE WHEN type = 1 THEN size END) * 8.0 / 1024 AS decimal(18,2))
                       AS [Log MB],
                   CAST(SUM(size) * 8.0 / 1024 AS decimal(18,2)) AS [Total MB],
                   COUNT(*) AS [Files]
            FROM sys.master_files
            GROUP BY database_id
            ORDER BY SUM(size) DESC
            """

        case .diskUsageByTable:
            return """
            SELECT SCHEMA_NAME(t.schema_id) + N'.' + t.name AS [Table],
                   SUM(p.rows) AS [Rows],
                   CAST(SUM(a.total_pages) * 8.0 / 1024 AS decimal(18,2)) AS [Reserved MB],
                   CAST(SUM(a.data_pages) * 8.0 / 1024 AS decimal(18,2)) AS [Data MB],
                   CAST((SUM(a.used_pages) - SUM(a.data_pages)) * 8.0 / 1024 AS decimal(18,2))
                       AS [Index MB],
                   CAST((SUM(a.total_pages) - SUM(a.used_pages)) * 8.0 / 1024 AS decimal(18,2))
                       AS [Unused MB]
            FROM sys.tables AS t
            JOIN sys.indexes AS i ON i.object_id = t.object_id
            JOIN sys.partitions AS p ON p.object_id = i.object_id AND p.index_id = i.index_id
            JOIN sys.allocation_units AS a ON a.container_id = p.partition_id
            WHERE i.index_id <= 1
            GROUP BY t.schema_id, t.name
            ORDER BY SUM(a.total_pages) DESC
            """

        case .tableRowCounts:
            return """
            SELECT SCHEMA_NAME(t.schema_id) + N'.' + t.name AS [Table],
                   SUM(p.rows) AS [Rows],
                   MAX(CONVERT(nvarchar(30), t.create_date, 120)) AS [Created],
                   MAX(CONVERT(nvarchar(30), t.modify_date, 120)) AS [Modified]
            FROM sys.tables AS t
            JOIN sys.partitions AS p ON p.object_id = t.object_id AND p.index_id IN (0, 1)
            GROUP BY t.schema_id, t.name
            ORDER BY SUM(p.rows) DESC
            """

        case .backupHistory:
            return """
            SELECT TOP (300)
                   b.database_name AS [Database],
                   CASE b.type WHEN 'D' THEN N'Full' WHEN 'I' THEN N'Differential'
                               WHEN 'L' THEN N'Log' WHEN 'F' THEN N'File'
                               ELSE b.type END AS [Type],
                   CONVERT(nvarchar(30), b.backup_start_date, 120) AS [Started],
                   CONVERT(nvarchar(30), b.backup_finish_date, 120) AS [Finished],
                   CAST(b.backup_size / 1048576.0 AS decimal(18,2)) AS [Size MB],
                   DATEDIFF(second, b.backup_start_date, b.backup_finish_date) AS [Seconds],
                   ISNULL(m.physical_device_name, N'') AS [Device],
                   ISNULL(b.user_name, N'') AS [User]
            FROM msdb.dbo.backupset AS b
            LEFT JOIN msdb.dbo.backupmediafamily AS m ON m.media_set_id = b.media_set_id
            ORDER BY b.backup_start_date DESC
            """

        case .topQueriesByCPU:
            return topQueries(orderBy: "qs.total_worker_time")

        case .topQueriesByDuration:
            return topQueries(orderBy: "qs.total_elapsed_time / NULLIF(qs.execution_count, 0)")

        case .topQueriesByIO:
            return topQueries(orderBy: "(qs.total_logical_reads + qs.total_logical_writes)")

        case .objectExecutionStatistics:
            return """
            SELECT TOP (200)
                   SCHEMA_NAME(o.schema_id) + N'.' + o.name AS [Object],
                   o.type_desc AS [Type],
                   s.execution_count AS [Executions],
                   CAST(s.total_worker_time / 1000.0 AS decimal(18,2)) AS [Total CPU ms],
                   CAST(s.total_worker_time / 1000.0
                        / NULLIF(s.execution_count, 0) AS decimal(18,2)) AS [Avg CPU ms],
                   CAST(s.total_elapsed_time / 1000.0
                        / NULLIF(s.execution_count, 0) AS decimal(18,2)) AS [Avg duration ms],
                   s.total_logical_reads AS [Logical reads],
                   CONVERT(nvarchar(30), s.last_execution_time, 120) AS [Last executed]
            FROM sys.dm_exec_procedure_stats AS s
            JOIN sys.objects AS o ON o.object_id = s.object_id
            WHERE s.database_id = DB_ID()
            ORDER BY s.total_worker_time DESC
            """

        case .indexUsage:
            return """
            SELECT SCHEMA_NAME(t.schema_id) + N'.' + t.name AS [Table],
                   i.name AS [Index], i.type_desc AS [Type],
                   ISNULL(s.user_seeks, 0) AS [Seeks],
                   ISNULL(s.user_scans, 0) AS [Scans],
                   ISNULL(s.user_lookups, 0) AS [Lookups],
                   ISNULL(s.user_updates, 0) AS [Updates],
                   CASE WHEN ISNULL(s.user_seeks, 0) + ISNULL(s.user_scans, 0)
                             + ISNULL(s.user_lookups, 0) = 0
                        THEN N'Never read' ELSE N'' END AS [Note],
                   ISNULL(CONVERT(nvarchar(30), s.last_user_seek, 120), N'') AS [Last seek]
            FROM sys.indexes AS i
            JOIN sys.tables AS t ON t.object_id = i.object_id
            LEFT JOIN sys.dm_db_index_usage_stats AS s
                 ON s.object_id = i.object_id AND s.index_id = i.index_id
                 AND s.database_id = DB_ID()
            WHERE i.index_id > 0 AND i.name IS NOT NULL
            ORDER BY ISNULL(s.user_updates, 0) DESC,
                     ISNULL(s.user_seeks, 0) + ISNULL(s.user_scans, 0) ASC
            """

        case .missingIndexes:
            return """
            SELECT TOP (100)
                   OBJECT_SCHEMA_NAME(d.object_id, d.database_id) + N'.'
                       + OBJECT_NAME(d.object_id, d.database_id) AS [Table],
                   CAST(s.avg_total_user_cost * s.avg_user_impact
                        * (s.user_seeks + s.user_scans) AS decimal(18,2)) AS [Impact score],
                   CAST(s.avg_user_impact AS decimal(9,2)) AS [Avg impact %],
                   s.user_seeks AS [Seeks],
                   s.user_scans AS [Scans],
                   ISNULL(d.equality_columns, N'') AS [Equality columns],
                   ISNULL(d.inequality_columns, N'') AS [Inequality columns],
                   ISNULL(d.included_columns, N'') AS [Included columns]
            FROM sys.dm_db_missing_index_group_stats AS s
            JOIN sys.dm_db_missing_index_groups AS g ON g.index_group_handle = s.group_handle
            JOIN sys.dm_db_missing_index_details AS d ON d.index_handle = g.index_handle
            WHERE d.database_id = DB_ID()
            ORDER BY [Impact score] DESC
            """

        case .indexFragmentation:
            return """
            SELECT SCHEMA_NAME(t.schema_id) + N'.' + t.name AS [Table],
                   i.name AS [Index], i.type_desc AS [Type],
                   CAST(s.avg_fragmentation_in_percent AS decimal(9,2)) AS [Fragmentation %],
                   s.page_count AS [Pages],
                   CAST(s.page_count * 8.0 / 1024 AS decimal(18,2)) AS [Size MB],
                   CASE WHEN s.avg_fragmentation_in_percent > 30 THEN N'Rebuild'
                        WHEN s.avg_fragmentation_in_percent > 5 THEN N'Reorganize'
                        ELSE N'None' END AS [Recommendation]
            FROM sys.dm_db_index_physical_stats(DB_ID(), NULL, NULL, NULL, 'LIMITED') AS s
            JOIN sys.indexes AS i ON i.object_id = s.object_id AND i.index_id = s.index_id
            JOIN sys.tables AS t ON t.object_id = i.object_id
            WHERE s.page_count > 100 AND i.name IS NOT NULL
            ORDER BY s.avg_fragmentation_in_percent DESC
            """

        case .blockingTransactions:
            return """
            SELECT r.session_id AS [Session],
                   r.blocking_session_id AS [Blocked by],
                   s.login_name AS [Login],
                   ISNULL(DB_NAME(r.database_id), N'') AS [Database],
                   r.status AS [Status],
                   r.wait_type AS [Wait type],
                   r.wait_time AS [Wait ms],
                   ISNULL(s.host_name, N'') AS [Host],
                   ISNULL(SUBSTRING(t.text, 1, 200), N'') AS [Statement]
            FROM sys.dm_exec_requests AS r
            JOIN sys.dm_exec_sessions AS s ON s.session_id = r.session_id
            OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) AS t
            WHERE r.blocking_session_id <> 0
               OR r.session_id IN (SELECT blocking_session_id FROM sys.dm_exec_requests
                                   WHERE blocking_session_id <> 0)
            ORDER BY r.blocking_session_id DESC, r.wait_time DESC
            """

        case .memoryUsage:
            return """
            SELECT TOP (40) type AS [Memory clerk],
                   CAST(SUM(pages_kb) / 1024.0 AS decimal(18,2)) AS [Allocated MB],
                   COUNT(*) AS [Clerks]
            FROM sys.dm_os_memory_clerks
            GROUP BY type
            ORDER BY SUM(pages_kb) DESC
            """

        case .activeConnections:
            return """
            SELECT s.session_id AS [Session],
                   ISNULL(s.login_name, N'') AS [Login],
                   ISNULL(s.host_name, N'') AS [Host],
                   ISNULL(s.program_name, N'') AS [Program],
                   ISNULL(DB_NAME(s.database_id), N'') AS [Database],
                   s.status AS [Status],
                   s.cpu_time AS [CPU ms],
                   s.logical_reads AS [Logical reads],
                   CONVERT(nvarchar(30), s.login_time, 120) AS [Connected at],
                   ISNULL(c.client_net_address, N'') AS [Client address]
            FROM sys.dm_exec_sessions AS s
            LEFT JOIN sys.dm_exec_connections AS c ON c.session_id = s.session_id
            WHERE s.is_user_process = 1
            ORDER BY s.cpu_time DESC
            """

        case .databaseGrowthEvents:
            return defaultTrace(eventClasses: "92, 93",
                                label: "Growth")

        case .schemaChangeHistory:
            return defaultTrace(eventClasses: "46, 47, 164",
                                label: "Change")
        }
    }

    private static func topQueries(orderBy: String) -> String {
        """
        SELECT TOP (100)
               CAST(qs.total_worker_time / 1000.0 AS decimal(18,2)) AS [Total CPU ms],
               CAST(qs.total_worker_time / 1000.0
                    / NULLIF(qs.execution_count, 0) AS decimal(18,2)) AS [Avg CPU ms],
               CAST(qs.total_elapsed_time / 1000.0
                    / NULLIF(qs.execution_count, 0) AS decimal(18,2)) AS [Avg duration ms],
               qs.execution_count AS [Executions],
               qs.total_logical_reads AS [Logical reads],
               qs.total_logical_writes AS [Logical writes],
               ISNULL(DB_NAME(t.dbid), N'') AS [Database],
               CONVERT(nvarchar(30), qs.last_execution_time, 120) AS [Last executed],
               SUBSTRING(t.text,
                         (qs.statement_start_offset / 2) + 1,
                         ((CASE qs.statement_end_offset
                             WHEN -1 THEN DATALENGTH(t.text)
                             ELSE qs.statement_end_offset END - qs.statement_start_offset) / 2) + 1)
                   AS [Statement]
        FROM sys.dm_exec_query_stats AS qs
        CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) AS t
        ORDER BY \(orderBy) DESC
        """
    }

    /// The default trace is the only free source for growth and DDL history.
    private static func defaultTrace(eventClasses: String, label: String) -> String {
        """
        DECLARE @path nvarchar(260);
        SELECT @path = REVERSE(SUBSTRING(REVERSE(path),
                                         CHARINDEX(N'\\', REVERSE(path)), 260)) + N'log.trc'
        FROM sys.traces WHERE is_default = 1;

        IF @path IS NULL
            SELECT N'The default trace is not enabled on this instance.' AS [Note];
        ELSE
            SELECT TOP (300)
                   CONVERT(nvarchar(30), t.StartTime, 120) AS [When],
                   ISNULL(t.DatabaseName, N'') AS [Database],
                   ISNULL(t.ObjectName, N'') AS [Object],
                   ISNULL(e.name, N'\(label)') AS [Event],
                   ISNULL(t.LoginName, N'') AS [Login],
                   ISNULL(t.ApplicationName, N'') AS [Application],
                   ISNULL(t.HostName, N'') AS [Host],
                   ISNULL(CAST(t.Duration / 1000 AS nvarchar(20)), N'') AS [Duration ms]
            FROM sys.fn_trace_gettable(@path, DEFAULT) AS t
            LEFT JOIN sys.trace_events AS e ON e.trace_event_id = t.EventClass
            WHERE t.EventClass IN (\(eventClasses))
            ORDER BY t.StartTime DESC;
        """
    }
}
