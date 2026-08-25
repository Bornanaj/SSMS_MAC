import Foundation
import TDSKit

// MARK: - Models

/// One row of the SSMS "Processes" pane: a session plus whatever request it is running.
public struct ActivitySession: Sendable, Hashable, Identifiable {
    public var id: Int { sessionID }

    public var sessionID: Int
    public var loginName: String
    public var hostName: String
    public var programName: String
    public var databaseName: String
    public var status: String
    public var command: String
    public var waitType: String
    public var lastRequestStart: String
    public var lastRequestEnd: String
    public var cpuTimeMs: Int64
    public var logicalReads: Int64
    public var reads: Int64
    public var writes: Int64
    public var memoryUsageKB: Int64
    public var blockingSessionID: Int
    public var waitTimeMs: Int64
    public var openTransactionCount: Int
    public var elapsedMs: Int64
    public var percentComplete: Double
    public var sqlText: String
    public var isUserProcess: Bool

    public var isBlocked: Bool { blockingSessionID != 0 }

    public init(sessionID: Int = 0,
                loginName: String = "",
                hostName: String = "",
                programName: String = "",
                databaseName: String = "",
                status: String = "",
                command: String = "",
                waitType: String = "",
                lastRequestStart: String = "",
                lastRequestEnd: String = "",
                cpuTimeMs: Int64 = 0,
                logicalReads: Int64 = 0,
                reads: Int64 = 0,
                writes: Int64 = 0,
                memoryUsageKB: Int64 = 0,
                blockingSessionID: Int = 0,
                waitTimeMs: Int64 = 0,
                openTransactionCount: Int = 0,
                elapsedMs: Int64 = 0,
                percentComplete: Double = 0,
                sqlText: String = "",
                isUserProcess: Bool = true) {
        self.sessionID = sessionID
        self.loginName = loginName
        self.hostName = hostName
        self.programName = programName
        self.databaseName = databaseName
        self.status = status
        self.command = command
        self.waitType = waitType
        self.lastRequestStart = lastRequestStart
        self.lastRequestEnd = lastRequestEnd
        self.cpuTimeMs = cpuTimeMs
        self.logicalReads = logicalReads
        self.reads = reads
        self.writes = writes
        self.memoryUsageKB = memoryUsageKB
        self.blockingSessionID = blockingSessionID
        self.waitTimeMs = waitTimeMs
        self.openTransactionCount = openTransactionCount
        self.elapsedMs = elapsedMs
        self.percentComplete = percentComplete
        self.sqlText = sqlText
        self.isUserProcess = isUserProcess
    }
}

/// An aggregated wait type, already stripped of the benign background waits.
public struct WaitStatistic: Sendable, Hashable, Identifiable {
    public var id: String { waitType }

    public var waitType: String
    public var waitTimeMs: Int64
    public var waitingTasks: Int64
    public var signalWaitMs: Int64
    /// Share of the total non-benign wait time, 0...100.
    public var percentage: Double

    public init(waitType: String = "",
                waitTimeMs: Int64 = 0,
                waitingTasks: Int64 = 0,
                signalWaitMs: Int64 = 0,
                percentage: Double = 0) {
        self.waitType = waitType
        self.waitTimeMs = waitTimeMs
        self.waitingTasks = waitingTasks
        self.signalWaitMs = signalWaitMs
        self.percentage = percentage
    }
}

/// A cached plan ranked by total CPU, the way the "Recent Expensive Queries" pane ranks them.
public struct ExpensiveQuery: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var queryText: String
    public var executionCount: Int64
    public var avgCpuMs: Double
    public var avgDurationMs: Double
    public var avgLogicalReads: Double
    public var totalWorkerTimeMs: Double
    public var lastExecutionTime: String
    public var databaseName: String

    public init(id: UUID = UUID(),
                queryText: String = "",
                executionCount: Int64 = 0,
                avgCpuMs: Double = 0,
                avgDurationMs: Double = 0,
                avgLogicalReads: Double = 0,
                totalWorkerTimeMs: Double = 0,
                lastExecutionTime: String = "",
                databaseName: String = "") {
        self.id = id
        self.queryText = queryText
        self.executionCount = executionCount
        self.avgCpuMs = avgCpuMs
        self.avgDurationMs = avgDurationMs
        self.avgLogicalReads = avgLogicalReads
        self.totalWorkerTimeMs = totalWorkerTimeMs
        self.lastExecutionTime = lastExecutionTime
        self.databaseName = databaseName
    }
}

/// Per-file IO totals since the instance (or the database, on Azure) came online.
public struct DataFileIOStat: Sendable, Hashable, Identifiable {
    public var id: String { databaseName + "/" + fileName }

    public var databaseName: String
    public var fileName: String
    public var fileType: String
    public var physicalName: String
    public var numberOfReads: Int64
    public var numberOfWrites: Int64
    public var readLatencyMs: Double
    public var writeLatencyMs: Double
    public var sizeMB: Double

    public init(databaseName: String = "",
                fileName: String = "",
                fileType: String = "",
                physicalName: String = "",
                numberOfReads: Int64 = 0,
                numberOfWrites: Int64 = 0,
                readLatencyMs: Double = 0,
                writeLatencyMs: Double = 0,
                sizeMB: Double = 0) {
        self.databaseName = databaseName
        self.fileName = fileName
        self.fileType = fileType
        self.physicalName = physicalName
        self.numberOfReads = numberOfReads
        self.numberOfWrites = numberOfWrites
        self.readLatencyMs = readLatencyMs
        self.writeLatencyMs = writeLatencyMs
        self.sizeMB = sizeMB
    }
}

// MARK: - Activity monitor

/// Reads the DMVs behind SSMS's Activity Monitor. Every query here is safe on
/// SQL Server 2016 through 2022 and on Azure SQL Database.
public struct ActivityMonitor: Sendable {

    private let session: SQLServerSession

    public init(session: SQLServerSession) {
        self.session = session
    }

    // MARK: - Processes

    public func sessions(includeSystem: Bool = false) async throws -> [ActivitySession] {
        // Prefer the request's currently executing statement; fall back to the last batch the
        // connection sent so sleeping sessions still show what they did.
        let statementText = """
            ISNULL(
                CASE WHEN r.statement_start_offset IS NULL THEN t.text
                     ELSE SUBSTRING(t.text, (r.statement_start_offset / 2) + 1,
                              ((CASE r.statement_end_offset
                                     WHEN -1 THEN DATALENGTH(t.text)
                                     ELSE r.statement_end_offset END
                                - r.statement_start_offset) / 2) + 1)
                END, N'')
            """

        let sql = """
        SELECT
            s.session_id                                                        AS SessionId,
            ISNULL(s.login_name, N'')                                           AS LoginName,
            ISNULL(s.host_name, N'')                                            AS HostName,
            ISNULL(s.program_name, N'')                                         AS ProgramName,
            ISNULL(DB_NAME(ISNULL(r.database_id, s.database_id)), N'')          AS DatabaseName,
            ISNULL(r.status, s.status)                                          AS SessionStatus,
            ISNULL(r.command, N'')                                              AS Command,
            ISNULL(r.wait_type, N'')                                            AS WaitType,
            ISNULL(CONVERT(nvarchar(23), s.last_request_start_time, 121), N'')  AS LastRequestStart,
            ISNULL(CONVERT(nvarchar(23), s.last_request_end_time, 121), N'')    AS LastRequestEnd,
            CAST(s.cpu_time AS bigint)                                          AS CpuTimeMs,
            CAST(s.logical_reads AS bigint)                                     AS LogicalReads,
            CAST(s.reads AS bigint)                                             AS Reads,
            CAST(s.writes AS bigint)                                            AS Writes,
            CAST(s.memory_usage AS bigint) * 8                                  AS MemoryUsageKB,
            CAST(ISNULL(r.blocking_session_id, 0) AS int)                       AS BlockingSessionId,
            CAST(ISNULL(r.wait_time, 0) AS bigint)                              AS WaitTimeMs,
            CAST(s.open_transaction_count AS int)                               AS OpenTransactionCount,
            CAST(ISNULL(r.total_elapsed_time, 0) AS bigint)                     AS ElapsedMs,
            CAST(ISNULL(r.percent_complete, 0) AS float)                        AS PercentComplete,
            \(statementText)                                                    AS SqlText,
            CAST(s.is_user_process AS int)                                      AS IsUserProcess
        FROM sys.dm_exec_sessions AS s
        LEFT JOIN sys.dm_exec_requests AS r
            ON r.session_id = s.session_id
        OUTER APPLY (
            SELECT TOP (1) c.most_recent_sql_handle
            FROM sys.dm_exec_connections AS c
            WHERE c.session_id = s.session_id
            ORDER BY c.connect_time DESC
        ) AS c
        OUTER APPLY sys.dm_exec_sql_text(COALESCE(r.sql_handle, c.most_recent_sql_handle)) AS t
        WHERE s.session_id > 0\(includeSystem ? "" : "\n      AND s.is_user_process = 1")
        ORDER BY s.session_id;
        """

        let result = try await session.metadataQuery(sql)
        guard let set = result.resultSets.first else { return [] }
        return set.dictionaries().map { row in
            ActivitySession(
                sessionID: row.int("SessionId"),
                loginName: row.string("LoginName"),
                hostName: row.string("HostName"),
                programName: row.string("ProgramName"),
                databaseName: row.string("DatabaseName"),
                status: row.string("SessionStatus"),
                command: row.string("Command"),
                waitType: row.string("WaitType"),
                lastRequestStart: row.string("LastRequestStart"),
                lastRequestEnd: row.string("LastRequestEnd"),
                cpuTimeMs: row.int64("CpuTimeMs"),
                logicalReads: row.int64("LogicalReads"),
                reads: row.int64("Reads"),
                writes: row.int64("Writes"),
                memoryUsageKB: row.int64("MemoryUsageKB"),
                blockingSessionID: row.int("BlockingSessionId"),
                waitTimeMs: row.int64("WaitTimeMs"),
                openTransactionCount: row.int("OpenTransactionCount"),
                elapsedMs: row.int64("ElapsedMs"),
                percentComplete: row.double("PercentComplete"),
                sqlText: row.string("SqlText").trimmingCharacters(in: .whitespacesAndNewlines),
                isUserProcess: row.bool("IsUserProcess")
            )
        }
    }

    // MARK: - Waits

    /// Wait types that are always accumulating on an idle instance and would otherwise
    /// drown out anything interesting.
    private static let benignWaitTypes = [
        "LAZYWRITER_SLEEP", "WAITFOR", "DIRTY_PAGE_POLL", "REQUEST_FOR_DEADLOCK_SEARCH"
    ]
    private static let benignWaitPrefixes = ["CLR_", "SLEEP_", "BROKER_", "XE_", "SQLTRACE_"]

    public func waits(top: Int = 20) async throws -> [WaitStatistic] {
        let info = await session.serverInfo
        // Azure SQL Database exposes only the database scoped copy of the wait counters.
        let source = info.isAzureSQLDatabase ? "sys.dm_db_wait_stats" : "sys.dm_os_wait_stats"
        let limit = ActivityMonitor.clamp(top, low: 1, high: 500)

        let exact = ActivityMonitor.benignWaitTypes
            .map { SQLIdentifier.literal($0) }
            .joined(separator: ", ")
        let prefixFilter = ActivityMonitor.benignWaitPrefixes
            .map { prefix -> String in
                let pattern = prefix.replacingOccurrences(of: "_", with: "\\_") + "%"
                return "AND w.wait_type NOT LIKE \(SQLIdentifier.literal(pattern)) ESCAPE N'\\'"
            }
            .joined(separator: "\n              ")

        let sql = """
        WITH Interesting AS (
            SELECT w.wait_type,
                   CAST(w.wait_time_ms AS bigint)        AS wait_time_ms,
                   CAST(w.waiting_tasks_count AS bigint) AS waiting_tasks_count,
                   CAST(w.signal_wait_time_ms AS bigint) AS signal_wait_time_ms
            FROM \(source) AS w
            WHERE w.wait_time_ms > 0
              AND w.waiting_tasks_count > 0
              AND w.wait_type NOT IN (\(exact))
              \(prefixFilter)
        )
        SELECT TOP (\(limit))
            i.wait_type                          AS WaitType,
            i.wait_time_ms                       AS WaitTimeMs,
            i.waiting_tasks_count                AS WaitingTasks,
            i.signal_wait_time_ms                AS SignalWaitMs,
            CAST(i.wait_time_ms * 100.0
                 / NULLIF(SUM(i.wait_time_ms) OVER (), 0) AS float) AS Percentage
        FROM Interesting AS i
        ORDER BY i.wait_time_ms DESC;
        """

        let result = try await session.metadataQuery(sql)
        guard let set = result.resultSets.first else { return [] }
        return set.dictionaries().map { row in
            WaitStatistic(waitType: row.string("WaitType"),
                          waitTimeMs: row.int64("WaitTimeMs"),
                          waitingTasks: row.int64("WaitingTasks"),
                          signalWaitMs: row.int64("SignalWaitMs"),
                          percentage: row.double("Percentage"))
        }
    }

    // MARK: - Recent expensive queries

    public func expensiveQueries(top: Int = 25) async throws -> [ExpensiveQuery] {
        let limit = ActivityMonitor.clamp(top, low: 1, high: 500)
        let sql = """
        SELECT TOP (\(limit))
            ISNULL(SUBSTRING(t.text, (qs.statement_start_offset / 2) + 1,
                       ((CASE qs.statement_end_offset
                              WHEN -1 THEN DATALENGTH(t.text)
                              ELSE qs.statement_end_offset END
                         - qs.statement_start_offset) / 2) + 1), N'')       AS QueryText,
            CAST(qs.execution_count AS bigint)                              AS ExecutionCount,
            CAST(qs.total_worker_time / 1000.0
                 / NULLIF(qs.execution_count, 0) AS float)                  AS AvgCpuMs,
            CAST(qs.total_elapsed_time / 1000.0
                 / NULLIF(qs.execution_count, 0) AS float)                  AS AvgDurationMs,
            CAST(qs.total_logical_reads * 1.0
                 / NULLIF(qs.execution_count, 0) AS float)                  AS AvgLogicalReads,
            CAST(qs.total_worker_time / 1000.0 AS float)                    AS TotalWorkerTimeMs,
            ISNULL(CONVERT(nvarchar(23), qs.last_execution_time, 121), N'') AS LastExecutionTime,
            ISNULL(DB_NAME(t.dbid), N'')                                    AS DatabaseName
        FROM sys.dm_exec_query_stats AS qs
        CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) AS t
        WHERE t.text IS NOT NULL
        ORDER BY qs.total_worker_time DESC;
        """

        let result = try await session.metadataQuery(sql)
        guard let set = result.resultSets.first else { return [] }
        return set.dictionaries().map { row in
            ExpensiveQuery(
                queryText: row.string("QueryText").trimmingCharacters(in: .whitespacesAndNewlines),
                executionCount: row.int64("ExecutionCount"),
                avgCpuMs: row.double("AvgCpuMs"),
                avgDurationMs: row.double("AvgDurationMs"),
                avgLogicalReads: row.double("AvgLogicalReads"),
                totalWorkerTimeMs: row.double("TotalWorkerTimeMs"),
                lastExecutionTime: row.string("LastExecutionTime"),
                databaseName: row.string("DatabaseName")
            )
        }
    }

    // MARK: - File IO

    public func fileIO() async throws -> [DataFileIOStat] {
        let info = await session.serverInfo
        // sys.master_files is not reachable on Azure SQL Database, and the DMV there only
        // reports the database you are connected to.
        let sql: String
        if info.isAzureSQLDatabase {
            sql = """
            SELECT
                DB_NAME()                                       AS DatabaseName,
                f.name                                          AS FileName,
                ISNULL(f.type_desc, N'')                        AS FileType,
                ISNULL(f.physical_name, N'')                    AS PhysicalName,
                CAST(vfs.num_of_reads AS bigint)                AS NumberOfReads,
                CAST(vfs.num_of_writes AS bigint)               AS NumberOfWrites,
                CAST(CASE WHEN vfs.num_of_reads = 0 THEN 0
                          ELSE vfs.io_stall_read_ms * 1.0 / vfs.num_of_reads END AS float)
                                                                AS ReadLatencyMs,
                CAST(CASE WHEN vfs.num_of_writes = 0 THEN 0
                          ELSE vfs.io_stall_write_ms * 1.0 / vfs.num_of_writes END AS float)
                                                                AS WriteLatencyMs,
                CAST(vfs.size_on_disk_bytes / 1048576.0 AS float) AS SizeMB
            FROM sys.dm_io_virtual_file_stats(DB_ID(), NULL) AS vfs
            JOIN sys.database_files AS f
                ON f.file_id = vfs.file_id
            ORDER BY f.type, f.file_id;
            """
        } else {
            sql = """
            SELECT
                ISNULL(DB_NAME(vfs.database_id), N'')           AS DatabaseName,
                mf.name                                         AS FileName,
                ISNULL(mf.type_desc, N'')                       AS FileType,
                ISNULL(mf.physical_name, N'')                   AS PhysicalName,
                CAST(vfs.num_of_reads AS bigint)                AS NumberOfReads,
                CAST(vfs.num_of_writes AS bigint)               AS NumberOfWrites,
                CAST(CASE WHEN vfs.num_of_reads = 0 THEN 0
                          ELSE vfs.io_stall_read_ms * 1.0 / vfs.num_of_reads END AS float)
                                                                AS ReadLatencyMs,
                CAST(CASE WHEN vfs.num_of_writes = 0 THEN 0
                          ELSE vfs.io_stall_write_ms * 1.0 / vfs.num_of_writes END AS float)
                                                                AS WriteLatencyMs,
                CAST(vfs.size_on_disk_bytes / 1048576.0 AS float) AS SizeMB
            FROM sys.dm_io_virtual_file_stats(NULL, NULL) AS vfs
            JOIN sys.master_files AS mf
                ON mf.database_id = vfs.database_id
               AND mf.file_id = vfs.file_id
            ORDER BY DB_NAME(vfs.database_id), mf.type, mf.file_id;
            """
        }

        let result = try await session.metadataQuery(sql)
        guard let set = result.resultSets.first else { return [] }
        return set.dictionaries().map { row in
            DataFileIOStat(databaseName: row.string("DatabaseName"),
                           fileName: row.string("FileName"),
                           fileType: row.string("FileType"),
                           physicalName: row.string("PhysicalName"),
                           numberOfReads: row.int64("NumberOfReads"),
                           numberOfWrites: row.int64("NumberOfWrites"),
                           readLatencyMs: row.double("ReadLatencyMs"),
                           writeLatencyMs: row.double("WriteLatencyMs"),
                           sizeMB: row.double("SizeMB"))
        }
    }

    // MARK: - Killing a session

    /// KILL cannot run on the shared metadata connection: it may be the very session that
    /// gets terminated, so it goes out on a connection of its own.
    public func killSession(_ sessionID: Int) async throws {
        guard sessionID > 0 else {
            throw SQLServerError.unsupportedOperation("\(sessionID) is not a valid session id.")
        }
        let ownSPID = await session.serverInfo.sessionID
        guard sessionID != ownSPID else {
            throw SQLServerError.unsupportedOperation(
                "Session \(sessionID) is the Object Explorer's own connection and cannot be killed.")
        }

        let connection = try await session.openConnection()
        do {
            _ = try await connection.query("KILL \(sessionID);")
            try? await connection.close()
        } catch {
            try? await connection.close()
            throw error
        }
    }

    // MARK: - Helpers

    private static func clamp(_ value: Int, low: Int, high: Int) -> Int {
        min(max(value, low), high)
    }
}
