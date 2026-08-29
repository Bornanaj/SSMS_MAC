import Foundation
import TDSKit

// MARK: - Error log

public enum ServerLogKind: Int, Sendable, CaseIterable, Identifiable {
    case sqlServer = 1
    case sqlAgent = 2

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .sqlServer: return "SQL Server"
        case .sqlAgent: return "SQL Server Agent"
        }
    }
}

/// One line of the error log, as `sp_readerrorlog` returns it.
public struct ServerLogEntry: Sendable, Hashable, Identifiable {
    public var id: Int
    public var date: String
    /// "spid58", "Server", "Logon" — the source column SSMS shows.
    public var source: String
    public var message: String
    /// Errors and warnings are picked out of the text so the viewer can flag them.
    public var severity: Severity

    public enum Severity: Sendable, Hashable {
        case information, warning, error
    }

    public init(id: Int, date: String, source: String, message: String) {
        self.id = id
        self.date = date
        self.source = source
        self.message = message
        self.severity = ServerLogEntry.classify(message)
    }

    /// The log has no severity column, so it is inferred the way the SSMS log viewer
    /// infers its icons: from the wording of the line.
    static func classify(_ message: String) -> Severity {
        let lowered = message.lowercased()
        if lowered.contains("error:") || lowered.contains(" failed")
            || lowered.hasPrefix("error") || lowered.contains("cannot ")
            || lowered.contains("severity: 1") || lowered.contains("severity: 2") {
            return .error
        }
        if lowered.contains("warning") || lowered.contains("deprecated")
            || lowered.contains("could not") {
            return .warning
        }
        return .information
    }
}

/// One archived log file, as `sp_enumerrorlogs` reports it.
public struct ServerLogArchive: Sendable, Hashable, Identifiable {
    public var id: Int { archiveNumber }
    public var archiveNumber: Int
    public var date: String
    public var sizeBytes: Int64

    public init(archiveNumber: Int, date: String = "", sizeBytes: Int64 = 0) {
        self.archiveNumber = archiveNumber
        self.date = date
        self.sizeBytes = sizeBytes
    }

    public var title: String {
        archiveNumber == 0 ? "Current" : "Archive #\(archiveNumber)"
    }
}

// MARK: - Dashboard

/// A point-in-time reading of the counters the SSMS server dashboard reports.
///
/// Cumulative counters are kept raw. Turning them into per-second rates needs two
/// readings, which `ServerRates` does.
public struct ServerSnapshot: Sendable, Hashable {
    public var capturedAt: Date
    public var userConnections: Int64
    public var batchRequestsTotal: Int64
    public var transactionsTotal: Int64
    public var compilationsTotal: Int64
    public var recompilationsTotal: Int64
    public var lockWaitsTotal: Int64
    public var deadlocksTotal: Int64
    public var fullScansTotal: Int64
    public var bufferCacheHitRatioPercent: Double
    public var pageLifeExpectancySeconds: Int64
    public var totalServerMemoryMB: Double
    public var targetServerMemoryMB: Double
    public var sqlProcessCPUPercent: Double
    public var otherProcessCPUPercent: Double
    public var activeRequests: Int
    public var blockedRequests: Int
    public var totalSessions: Int
    public var databaseCount: Int
    public var totalDatabaseSizeMB: Double

    public init(capturedAt: Date = Date(),
                userConnections: Int64 = 0,
                batchRequestsTotal: Int64 = 0,
                transactionsTotal: Int64 = 0,
                compilationsTotal: Int64 = 0,
                recompilationsTotal: Int64 = 0,
                lockWaitsTotal: Int64 = 0,
                deadlocksTotal: Int64 = 0,
                fullScansTotal: Int64 = 0,
                bufferCacheHitRatioPercent: Double = 0,
                pageLifeExpectancySeconds: Int64 = 0,
                totalServerMemoryMB: Double = 0,
                targetServerMemoryMB: Double = 0,
                sqlProcessCPUPercent: Double = 0,
                otherProcessCPUPercent: Double = 0,
                activeRequests: Int = 0,
                blockedRequests: Int = 0,
                totalSessions: Int = 0,
                databaseCount: Int = 0,
                totalDatabaseSizeMB: Double = 0) {
        self.capturedAt = capturedAt
        self.userConnections = userConnections
        self.batchRequestsTotal = batchRequestsTotal
        self.transactionsTotal = transactionsTotal
        self.compilationsTotal = compilationsTotal
        self.recompilationsTotal = recompilationsTotal
        self.lockWaitsTotal = lockWaitsTotal
        self.deadlocksTotal = deadlocksTotal
        self.fullScansTotal = fullScansTotal
        self.bufferCacheHitRatioPercent = bufferCacheHitRatioPercent
        self.pageLifeExpectancySeconds = pageLifeExpectancySeconds
        self.totalServerMemoryMB = totalServerMemoryMB
        self.targetServerMemoryMB = targetServerMemoryMB
        self.sqlProcessCPUPercent = sqlProcessCPUPercent
        self.otherProcessCPUPercent = otherProcessCPUPercent
        self.activeRequests = activeRequests
        self.blockedRequests = blockedRequests
        self.totalSessions = totalSessions
        self.databaseCount = databaseCount
        self.totalDatabaseSizeMB = totalDatabaseSizeMB
    }
}

/// Per-second rates derived from two snapshots.
public struct ServerRates: Sendable, Hashable {
    public var interval: TimeInterval
    public var batchRequestsPerSecond: Double
    public var transactionsPerSecond: Double
    public var compilationsPerSecond: Double
    public var recompilationsPerSecond: Double
    public var lockWaitsPerSecond: Double
    public var deadlocksPerSecond: Double
    public var fullScansPerSecond: Double

    public init(interval: TimeInterval = 0,
                batchRequestsPerSecond: Double = 0,
                transactionsPerSecond: Double = 0,
                compilationsPerSecond: Double = 0,
                recompilationsPerSecond: Double = 0,
                lockWaitsPerSecond: Double = 0,
                deadlocksPerSecond: Double = 0,
                fullScansPerSecond: Double = 0) {
        self.interval = interval
        self.batchRequestsPerSecond = batchRequestsPerSecond
        self.transactionsPerSecond = transactionsPerSecond
        self.compilationsPerSecond = compilationsPerSecond
        self.recompilationsPerSecond = recompilationsPerSecond
        self.lockWaitsPerSecond = lockWaitsPerSecond
        self.deadlocksPerSecond = deadlocksPerSecond
        self.fullScansPerSecond = fullScansPerSecond
    }

    /// A counter that went backwards means the instance restarted between readings, so
    /// the rate is reported as zero rather than as a large negative number.
    public static func between(_ earlier: ServerSnapshot, _ later: ServerSnapshot) -> ServerRates {
        let interval = later.capturedAt.timeIntervalSince(earlier.capturedAt)
        guard interval > 0 else { return ServerRates() }
        func rate(_ from: Int64, _ to: Int64) -> Double {
            let delta = to - from
            guard delta >= 0 else { return 0 }
            return Double(delta) / interval
        }
        return ServerRates(
            interval: interval,
            batchRequestsPerSecond: rate(earlier.batchRequestsTotal, later.batchRequestsTotal),
            transactionsPerSecond: rate(earlier.transactionsTotal, later.transactionsTotal),
            compilationsPerSecond: rate(earlier.compilationsTotal, later.compilationsTotal),
            recompilationsPerSecond: rate(earlier.recompilationsTotal, later.recompilationsTotal),
            lockWaitsPerSecond: rate(earlier.lockWaitsTotal, later.lockWaitsTotal),
            deadlocksPerSecond: rate(earlier.deadlocksTotal, later.deadlocksTotal),
            fullScansPerSecond: rate(earlier.fullScansTotal, later.fullScansTotal)
        )
    }
}

/// One row of the dashboard's database list.
public struct DatabaseSizeSummary: Sendable, Hashable, Identifiable {
    public var id: String { name }
    public var name: String
    public var state: String
    public var recoveryModel: String
    public var dataSizeMB: Double
    public var logSizeMB: Double
    public var lastFullBackup: String

    public init(name: String = "",
                state: String = "",
                recoveryModel: String = "",
                dataSizeMB: Double = 0,
                logSizeMB: Double = 0,
                lastFullBackup: String = "") {
        self.name = name
        self.state = state
        self.recoveryModel = recoveryModel
        self.dataSizeMB = dataSizeMB
        self.logSizeMB = logSizeMB
        self.lastFullBackup = lastFullBackup
    }

    public var totalSizeMB: Double { dataSizeMB + logSizeMB }
}

// MARK: - Diagnostics service

/// The reporting half of SSMS's Management folder: the error log viewer and the
/// server dashboard.
public struct ServerDiagnostics: Sendable {

    private let session: SQLServerSession
    private let runner: AdminRunner

    public init(session: SQLServerSession) {
        self.session = session
        self.runner = AdminRunner(session: session)
    }

    // MARK: Error log

    public func logArchives(kind: ServerLogKind = .sqlServer) async throws -> [ServerLogArchive] {
        try await runner.requireBoxProduct("The error log")
        // sp_enumerrorlogs takes the same 1/2 log-type argument as sp_readerrorlog.
        let rows = try await runner.read("EXEC master.dbo.sp_enumerrorlogs \(kind.rawValue);",
                                        database: "master")
        let archives = rows.map { row in
            ServerLogArchive(
                archiveNumber: row.int("Archive #", default: row.int("Archive")),
                date: row.string("Date"),
                sizeBytes: row.int64("Log File Size (Byte)")
            )
        }
        // A server that answers with nothing still has a current log to read.
        return archives.isEmpty ? [ServerLogArchive(archiveNumber: 0)] : archives
    }

    /// `search` is passed as a parameter, not concatenated, so a log filter can contain
    /// anything the user types.
    public func errorLog(kind: ServerLogKind = .sqlServer,
                         archive: Int = 0,
                         search: String = "",
                         limit: Int = 5000) async throws -> [ServerLogEntry] {
        try await runner.requireBoxProduct("The error log")
        let archiveNumber = max(0, archive)
        let searchLiteral = search.isEmpty ? "NULL" : SQLIdentifier.literal(search)
        let sql = """
        EXEC master.dbo.sp_readerrorlog \(archiveNumber), \(kind.rawValue), \(searchLiteral);
        """
        let rows = try await runner.read(sql, database: "master")
        return rows.prefix(max(limit, 1)).enumerated().map { index, row in
            ServerLogEntry(
                id: index,
                date: row.string("LogDate"),
                source: row.string("ProcessInfo"),
                message: row.string("Text")
            )
        }
    }

    /// SSMS has a Recycle button on the log viewer; the log rolls without a restart.
    public func cycleErrorLog() async throws {
        try await runner.requireBoxProduct("Recycling the error log")
        try await runner.run("EXEC master.dbo.sp_cycle_errorlog;", database: "master")
    }

    // MARK: Dashboard

    public func snapshot() async throws -> ServerSnapshot {
        let info = await session.serverInfo
        var snapshot = ServerSnapshot()

        // sys.dm_exec_sessions and sys.databases work everywhere, including Azure.
        let sessionSQL = """
        SELECT
            CAST((SELECT COUNT(*) FROM sys.dm_exec_sessions WHERE is_user_process = 1) AS int)
                AS UserSessions,
            CAST((SELECT COUNT(*) FROM sys.dm_exec_requests
                  WHERE session_id <> @@SPID) AS int)                     AS ActiveRequests,
            CAST((SELECT COUNT(*) FROM sys.dm_exec_requests
                  WHERE blocking_session_id <> 0) AS int)                 AS BlockedRequests;
        """
        if let row = try await runner.read(sessionSQL).first {
            snapshot.totalSessions = row.int("UserSessions")
            snapshot.activeRequests = row.int("ActiveRequests")
            snapshot.blockedRequests = row.int("BlockedRequests")
        }

        let sizes = (try? await databaseSizes()) ?? []
        snapshot.databaseCount = sizes.count
        snapshot.totalDatabaseSizeMB = sizes.reduce(0) { $0 + $1.totalSizeMB }

        guard !info.isAzureSQLDatabase else { return snapshot }

        // Performance counters are keyed by an instance-qualified object name, which
        // differs on a named instance, so the object name is matched by suffix.
        let counterSQL = """
        SELECT
            RTRIM(counter_name)                        AS CounterName,
            RTRIM(instance_name)                       AS InstanceName,
            CAST(cntr_value AS bigint)                 AS CounterValue,
            CAST(cntr_type AS int)                     AS CounterType,
            RTRIM(object_name)                         AS ObjectName
        FROM sys.dm_os_performance_counters
        WHERE counter_name IN (
                N'User Connections', N'Batch Requests/sec', N'Transactions/sec',
                N'SQL Compilations/sec', N'SQL Re-Compilations/sec',
                N'Lock Waits/sec', N'Number of Deadlocks/sec', N'Full Scans/sec',
                N'Buffer cache hit ratio', N'Buffer cache hit ratio base',
                N'Page life expectancy', N'Total Server Memory (KB)',
                N'Target Server Memory (KB)')
          AND (instance_name IN (N'', N'_Total') OR instance_name IS NULL);
        """
        if let counters = try? await runner.read(counterSQL, database: "master") {
            var hitRatio: Int64 = 0
            var hitRatioBase: Int64 = 0
            for row in counters {
                let name = row.string("CounterName")
                let value = row.int64("CounterValue")
                switch name {
                case "User Connections": snapshot.userConnections = value
                case "Batch Requests/sec": snapshot.batchRequestsTotal = value
                case "Transactions/sec": snapshot.transactionsTotal = value
                case "SQL Compilations/sec": snapshot.compilationsTotal = value
                case "SQL Re-Compilations/sec": snapshot.recompilationsTotal = value
                case "Lock Waits/sec": snapshot.lockWaitsTotal = value
                case "Number of Deadlocks/sec": snapshot.deadlocksTotal = value
                case "Full Scans/sec": snapshot.fullScansTotal = value
                case "Buffer cache hit ratio": hitRatio = value
                case "Buffer cache hit ratio base": hitRatioBase = value
                case "Page life expectancy": snapshot.pageLifeExpectancySeconds = value
                case "Total Server Memory (KB)":
                    snapshot.totalServerMemoryMB = Double(value) / 1024
                case "Target Server Memory (KB)":
                    snapshot.targetServerMemoryMB = Double(value) / 1024
                default: break
                }
            }
            if hitRatioBase > 0 {
                snapshot.bufferCacheHitRatioPercent = Double(hitRatio) / Double(hitRatioBase) * 100
            }
        }

        if let cpu = try? await cpuUtilization() {
            snapshot.sqlProcessCPUPercent = cpu.sql
            snapshot.otherProcessCPUPercent = cpu.other
        }

        return snapshot
    }

    /// The scheduler monitor ring buffer is the only place SQL Server publishes host CPU.
    private func cpuUtilization() async throws -> (sql: Double, other: Double) {
        let sql = """
        SELECT TOP (1)
            CAST(x.value('(./Record/SchedulerMonitorEvent/SystemHealth/ProcessUtilization)[1]',
                         'int') AS int) AS SqlCpu,
            CAST(x.value('(./Record/SchedulerMonitorEvent/SystemHealth/SystemIdle)[1]',
                         'int') AS int) AS SystemIdle
        FROM (SELECT CAST(record AS xml) AS x, timestamp
              FROM sys.dm_os_ring_buffers
              WHERE ring_buffer_type = N'RING_BUFFER_SCHEDULER_MONITOR'
                AND record LIKE N'%<SystemHealth>%') AS r
        ORDER BY r.timestamp DESC;
        """
        guard let row = try await runner.read(sql, database: "master").first else { return (0, 0) }
        let sqlCPU = Double(row.int("SqlCpu"))
        let idle = Double(row.int("SystemIdle"))
        return (sqlCPU, max(0, 100 - idle - sqlCPU))
    }

    public func databaseSizes() async throws -> [DatabaseSizeSummary] {
        let info = await session.serverInfo

        // Azure SQL Database cannot see other databases' files, and msdb does not exist.
        if info.isAzureSQLDatabase {
            let sql = """
            SELECT
                DB_NAME()                                              AS DatabaseName,
                N'ONLINE'                                              AS StateDesc,
                N'FULL'                                                AS RecoveryModel,
                CAST(ISNULL(SUM(CASE WHEN f.type = 0 THEN f.size END), 0) * 8.0 / 1024 AS float)
                                                                       AS DataMB,
                CAST(ISNULL(SUM(CASE WHEN f.type = 1 THEN f.size END), 0) * 8.0 / 1024 AS float)
                                                                       AS LogMB
            FROM sys.database_files AS f;
            """
            return try await runner.read(sql).map(Self.sizeSummary(from:))
        }

        let sql = """
        SELECT
            d.name                                                     AS DatabaseName,
            ISNULL(d.state_desc, N'')                                  AS StateDesc,
            ISNULL(d.recovery_model_desc, N'')                         AS RecoveryModel,
            CAST(ISNULL(SUM(CASE WHEN mf.type = 0 THEN mf.size END), 0) * 8.0 / 1024 AS float)
                                                                       AS DataMB,
            CAST(ISNULL(SUM(CASE WHEN mf.type = 1 THEN mf.size END), 0) * 8.0 / 1024 AS float)
                                                                       AS LogMB,
            ISNULL(CONVERT(nvarchar(23),
                (SELECT MAX(b.backup_finish_date)
                 FROM msdb.dbo.backupset AS b
                 WHERE b.database_name = d.name AND b.type = 'D'), 121), N'') AS LastFullBackup
        FROM sys.databases AS d
        LEFT JOIN sys.master_files AS mf ON mf.database_id = d.database_id
        WHERE HAS_DBACCESS(d.name) = 1
        GROUP BY d.name, d.state_desc, d.recovery_model_desc
        ORDER BY d.name;
        """
        return try await runner.read(sql, database: "master").map(Self.sizeSummary(from:))
    }

    private static func sizeSummary(from row: [String: TDSValue]) -> DatabaseSizeSummary {
        DatabaseSizeSummary(
            name: row.string("DatabaseName"),
            state: row.string("StateDesc"),
            recoveryModel: row.string("RecoveryModel"),
            dataSizeMB: row.double("DataMB"),
            logSizeMB: row.double("LogMB"),
            lastFullBackup: row.string("LastFullBackup")
        )
    }
}
