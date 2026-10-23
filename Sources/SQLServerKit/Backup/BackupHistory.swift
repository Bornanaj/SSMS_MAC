import Foundation
import TDSKit

// MARK: - LSN

/// A log sequence number. They are numeric(25,0) and exceed Int64, so they are compared as
/// digit strings.
public struct LSN: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    public let digits: String

    public init(_ text: String) {
        var value = text.trimmingCharacters(in: .whitespaces)
        if let dot = value.firstIndex(of: ".") { value = String(value[..<dot]) }
        value = String(value.drop(while: { $0 == "0" }))
        digits = value.allSatisfy(\.isNumber) ? value : ""
    }

    public var isZero: Bool { digits.isEmpty }
    public var description: String { digits.isEmpty ? "0" : digits }

    public static func < (lhs: LSN, rhs: LSN) -> Bool {
        if lhs.digits.count != rhs.digits.count { return lhs.digits.count < rhs.digits.count }
        return lhs.digits < rhs.digits
    }
}

// MARK: - Database status

/// One database as the Registered SQL Servers pane shows it: its state, recovery model and the
/// last backup of each kind.
public struct DatabaseBackupStatus: Identifiable, Hashable, Sendable {
    /// SQL Backup's four states.
    public enum OperationalState: String, Sendable {
        case operational
        case nonOperational
        case readOnly
        case unavailable

        public var title: String {
            switch self {
            case .operational: return "Operational"
            case .nonOperational: return "Non-operational (restoring)"
            case .readOnly: return "Read-only"
            case .unavailable: return "Unavailable"
            }
        }
    }

    public var id: String { name }
    public var name: String
    public var databaseID: Int
    public var stateDescription: String
    public var recoveryModel: String
    public var isReadOnly: Bool
    public var isStandby: Bool
    public var isSnapshot: Bool
    /// A full backup exists that a differential can be based on.
    public var hasDifferentialBase: Bool
    /// The log chain has started, so log backups are possible.
    public var hasLogChain: Bool
    public var sizeMB: Double
    public var lastFull: Date?
    public var lastDifferential: Date?
    public var lastLog: Date?
    public var availabilityGroup: String

    public var isSystem: Bool { databaseID <= 4 }

    public var operationalState: OperationalState {
        switch stateDescription.uppercased() {
        case "ONLINE": return isReadOnly ? .readOnly : .operational
        case "RESTORING": return isStandby ? .readOnly : .nonOperational
        case "RECOVERING", "RECOVERY_PENDING": return .nonOperational
        default: return isStandby ? .readOnly : .unavailable
        }
    }

    public var lastBackup: Date? {
        [lastFull, lastDifferential, lastLog].compactMap { $0 }.max()
    }

    /// Why a backup of this type cannot be taken, or nil when it can.
    public func reasonCannotBackUp(_ type: BackupType) -> String? {
        if isSnapshot { return "Database snapshots cannot be backed up." }
        if stateDescription.uppercased() != "ONLINE" { return "The database is \(stateDescription.lowercased())." }
        if name.lowercased() == "tempdb" { return "tempdb cannot be backed up." }
        switch type {
        case .full:
            return nil
        case .differential:
            if name.lowercased() == "master" { return "master supports full backups only." }
            return hasDifferentialBase ? nil : "There is no full backup to base a differential on."
        case .log:
            if recoveryModel.uppercased() == "SIMPLE" { return "The database uses the simple recovery model." }
            if name.lowercased() == "master" { return "master supports full backups only." }
            return hasLogChain ? nil : "There is no full backup yet, so the log chain has not started."
        }
    }

    /// How far behind its backups are, against the thresholds in the options.
    public func risk(now: Date, thresholds: BackupThresholds) -> BackupRisk {
        guard operationalState == .operational || operationalState == .readOnly, !isSnapshot,
              name.lowercased() != "tempdb" else { return .notApplicable }
        guard let full = [lastFull, lastDifferential].compactMap({ $0 }).max() else { return .never }
        let hours = now.timeIntervalSince(full) / 3600
        if hours > Double(thresholds.fullBackupHours) { return .overdue }
        // System databases are not log backed up, even when the model database is in full recovery.
        if recoveryModel.uppercased() != "SIMPLE", !isReadOnly, !isSystem {
            guard let log = lastLog else { return .overdue }
            if now.timeIntervalSince(log) / 60 > Double(thresholds.logBackupMinutes) { return .overdue }
        }
        if hours > Double(thresholds.fullBackupHours) * 0.75 { return .warning }
        return .ok
    }
}

extension DatabaseBackupStatus {
    /// A database described by hand, for previews and tests; the reader fills the rest from the server.
    public init(name: String, databaseID: Int = 5, stateDescription: String = "ONLINE", recoveryModel: String = "FULL",
                lastFull: Date? = nil, lastDifferential: Date? = nil, lastLog: Date? = nil) {
        self.init(name: name, databaseID: databaseID, stateDescription: stateDescription, recoveryModel: recoveryModel,
                  isReadOnly: false, isStandby: false, isSnapshot: false, hasDifferentialBase: lastFull != nil,
                  hasLogChain: lastFull != nil, sizeMB: 0, lastFull: lastFull, lastDifferential: lastDifferential,
                  lastLog: lastLog, availabilityGroup: "")
    }
}

public enum BackupRisk: String, Sendable {
    case ok
    case warning
    case overdue
    case never
    case notApplicable

    public var title: String {
        switch self {
        case .ok: return "Backed up"
        case .warning: return "Due soon"
        case .overdue: return "Overdue"
        case .never: return "Never backed up"
        case .notApplicable: return ""
        }
    }
}

/// When a database counts as overdue: no full or differential backup for this long, or (in the
/// full and bulk-logged recovery models) no log backup for this long.
public struct BackupThresholds: Codable, Hashable, Sendable {
    public var fullBackupHours: Int
    public var logBackupMinutes: Int

    public init(fullBackupHours: Int = 7 * 24 + 12, logBackupMinutes: Int = 120) {
        self.fullBackupHours = fullBackupHours
        self.logBackupMinutes = logBackupMinutes
    }
}

// MARK: - Activity

/// One line of Activity History: a backup, restore or verification from msdb, a failed job, or
/// an operation this app ran itself.
public struct BackupActivity: Identifiable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case backup
        case restore
        case verify
        case jobFailure
    }

    public var id: String
    public var kind: Kind
    public var database: String
    /// msdb type code: D, I, L, F, G, P, Q (and V for a verification).
    public var typeCode: String
    public var started: Date?
    public var finished: Date?
    public var succeeded: Bool = true
    public var hasWarnings: Bool = false
    public var message: String = ""
    public var backupSize: Int64 = 0
    public var compressedSize: Int64 = 0
    public var databaseSize: Int64 = 0
    public var compressionAlgorithm: String = ""
    public var keyAlgorithm: String = ""
    public var hasChecksums: Bool = false
    public var isCopyOnly: Bool = false
    public var isDamaged: Bool = false
    public var files: [String] = []
    public var mirrorCount: Int = 0
    /// 2 disk, 5 tape, 7 virtual device (third-party tools), 9 URL.
    public var deviceType: Int = 2
    public var userName: String = ""
    public var serverName: String = ""
    public var backupSetID: Int = 0
    public var position: Int = 1
    public var restoredFrom: String = ""
    public var jobName: String = ""

    public init(id: String, kind: Kind, database: String, typeCode: String) {
        self.id = id
        self.kind = kind
        self.database = database
        self.typeCode = typeCode
    }

    public var backupType: BackupType? { BackupType(historyCode: typeCode) }
    public var isEncrypted: Bool { !keyAlgorithm.isEmpty && keyAlgorithm.uppercased() != "NO_ENCRYPTION" }
    public var isThirdParty: Bool { deviceType == 7 }

    public var duration: TimeInterval? {
        guard let started, let finished else { return nil }
        return max(0, finished.timeIntervalSince(started))
    }

    /// SQL Backup's "Compressed By": the space saved against the uncompressed backup.
    public var compressedBy: Double? {
        guard backupSize > 0, compressedSize > 0, compressedSize < backupSize else { return nil }
        return 1 - Double(compressedSize) / Double(backupSize)
    }

    public var typeTitle: String {
        switch typeCode.uppercased() {
        case "D": return isCopyOnly ? "Full (copy-only)" : "Full"
        case "I": return "Differential"
        case "L": return isCopyOnly ? "Log (copy-only)" : "Log"
        case "F": return "File/filegroup"
        case "G": return "Differential file"
        case "P": return "Partial"
        case "Q": return "Differential partial"
        case "V": return "Verification"
        default: return typeCode
        }
    }

    public var kindTitle: String {
        switch kind {
        case .backup: return "Backup"
        case .restore: return "Restore"
        case .verify: return "Verify"
        case .jobFailure: return "Job"
        }
    }

    public var date: Date? { finished ?? started }
}

/// A backup or restore running now (the In Progress tab).
public struct BackupProgressItem: Identifiable, Hashable, Sendable {
    public var id: Int { sessionID }
    public var sessionID: Int
    public var command: String
    public var database: String
    public var percentComplete: Double
    public var estimatedSecondsLeft: Double
    public var started: Date?
    public var loginName: String
    public var programName: String
    public var statement: String
}

// MARK: - Backup sets

/// One backup set with everything a restore needs: LSNs for building the chain, and the files
/// grouped by mirror and stripe.
public struct BackupSetInfo: Identifiable, Hashable, Sendable {
    public var id: Int
    public var database: String
    public var serverName: String
    public var typeCode: String
    public var isCopyOnly: Bool
    public var position: Int
    public var firstLSN: LSN
    public var lastLSN: LSN
    public var checkpointLSN: LSN
    public var databaseBackupLSN: LSN
    public var differentialBaseLSN: LSN
    public var started: Date?
    public var finished: Date?
    public var lastValidRestoreTime: Date?
    public var firstRecoveryForkID: String
    public var lastRecoveryForkID: String
    public var backupSize: Int64
    public var compressedSize: Int64
    public var keyAlgorithm: String
    public var encryptorThumbprint: String
    public var hasChecksums: Bool
    public var isDamaged: Bool
    public var recoveryModel: String
    public var deviceType: Int
    /// `files[mirror][stripe]`.
    public var files: [[String]]
    public var name: String
    public var setDescription: String

    public init(id: Int, database: String, typeCode: String, position: Int = 1, firstLSN: LSN = LSN(""),
                lastLSN: LSN = LSN(""), checkpointLSN: LSN = LSN(""), databaseBackupLSN: LSN = LSN(""),
                differentialBaseLSN: LSN = LSN(""), started: Date? = nil, finished: Date? = nil,
                files: [[String]] = [], isCopyOnly: Bool = false) {
        self.id = id
        self.database = database
        self.serverName = ""
        self.typeCode = typeCode
        self.isCopyOnly = isCopyOnly
        self.position = position
        self.firstLSN = firstLSN
        self.lastLSN = lastLSN
        self.checkpointLSN = checkpointLSN
        self.databaseBackupLSN = databaseBackupLSN
        self.differentialBaseLSN = differentialBaseLSN
        self.started = started
        self.finished = finished
        self.lastValidRestoreTime = nil
        self.firstRecoveryForkID = ""
        self.lastRecoveryForkID = ""
        self.backupSize = 0
        self.compressedSize = 0
        self.keyAlgorithm = ""
        self.encryptorThumbprint = ""
        self.hasChecksums = false
        self.isDamaged = false
        self.recoveryModel = ""
        self.deviceType = 2
        self.files = files
        self.name = ""
        self.setDescription = ""
    }

    public var backupType: BackupType? { BackupType(historyCode: typeCode) }
    public var isFull: Bool { typeCode == "D" }
    public var isDifferential: Bool { typeCode == "I" }
    public var isLog: Bool { typeCode == "L" }
    public var isEncrypted: Bool { !keyAlgorithm.isEmpty && keyAlgorithm.uppercased() != "NO_ENCRYPTION" }
    public var isURL: Bool { deviceType == 9 || (files.first?.first?.lowercased().hasPrefix("http") ?? false)
        || (files.first?.first?.lowercased().hasPrefix("s3://") ?? false) }

    /// The stripes of the first complete mirror.
    public var primaryFiles: [String] { files.first ?? [] }

    public var typeTitle: String {
        var activity = BackupActivity(id: "", kind: .backup, database: database, typeCode: typeCode)
        activity.isCopyOnly = isCopyOnly
        return activity.typeTitle
    }
}

// MARK: - Reader

/// Reads backup and restore history, database state and running operations.
public struct BackupHistoryReader: Sendable {
    private let session: SQLServerSession

    public init(session: SQLServerSession) {
        self.session = session
    }

    private var majorVersion: Int {
        get async { await session.serverInfo.majorVersion }
    }

    // MARK: Databases

    public func databases() async throws -> [DatabaseBackupStatus] {
        let major = await majorVersion
        let hadr = major >= 11
            ? "ISNULL((SELECT TOP (1) ag.name FROM sys.availability_databases_cluster AS adc "
                + "JOIN sys.availability_groups AS ag ON ag.group_id = adc.group_id "
                + "WHERE adc.database_name = d.name), N'')"
            : "N''"
        let sql = """
        SELECT d.name, d.database_id, d.state_desc, d.recovery_model_desc,
               CAST(d.is_read_only AS int) AS is_read_only, CAST(d.is_in_standby AS int) AS is_standby,
               CASE WHEN d.source_database_id IS NULL THEN 0 ELSE 1 END AS is_snapshot,
               CASE WHEN drs.last_log_backup_lsn IS NULL THEN 0 ELSE 1 END AS log_chain,
               CASE WHEN EXISTS (SELECT 1 FROM sys.master_files AS f WHERE f.database_id = d.database_id
                                 AND f.file_id = 1 AND f.differential_base_lsn IS NOT NULL) THEN 1 ELSE 0 END AS has_base,
               (SELECT SUM(CAST(f.size AS bigint)) * 8 / 1024.0 FROM sys.master_files AS f
                WHERE f.database_id = d.database_id) AS size_mb,
               b.last_full, b.last_diff, b.last_log,
               \(hadr) AS ag_name
        FROM sys.databases AS d
        LEFT JOIN sys.database_recovery_status AS drs ON drs.database_id = d.database_id
        LEFT JOIN (SELECT database_name,
                          MAX(CASE WHEN type = 'D' THEN backup_finish_date END) AS last_full,
                          MAX(CASE WHEN type = 'I' THEN backup_finish_date END) AS last_diff,
                          MAX(CASE WHEN type = 'L' THEN backup_finish_date END) AS last_log
                   FROM msdb.dbo.backupset GROUP BY database_name) AS b ON b.database_name = d.name
        WHERE d.database_id <> 2
        ORDER BY CASE WHEN d.database_id <= 4 THEN 0 ELSE 1 END, d.name;
        """
        let result = try await session.metadataQuery(sql, database: "master")
        let rows = result.resultSets.first?.dictionaries() ?? []
        return rows.map { row in
            DatabaseBackupStatus(name: row.string("name"), databaseID: row.int("database_id"),
                                 stateDescription: row.string("state_desc"),
                                 recoveryModel: row.string("recovery_model_desc"),
                                 isReadOnly: row.int("is_read_only") == 1, isStandby: row.int("is_standby") == 1,
                                 isSnapshot: row.int("is_snapshot") == 1, hasDifferentialBase: row.int("has_base") == 1,
                                 hasLogChain: row.int("log_chain") == 1, sizeMB: row.double("size_mb"),
                                 lastFull: row.serverDate("last_full"), lastDifferential: row.serverDate("last_diff"),
                                 lastLog: row.serverDate("last_log"), availabilityGroup: row.string("ag_name"))
        }
    }

    // MARK: Activity

    public func activity(since: Date, database: String? = nil) async throws -> [BackupActivity] {
        let major = await majorVersion
        let filter = database.map { " AND bs.database_name = \(SQLIdentifier.literal($0))" } ?? ""
        let restoreFilter = database.map { " AND rh.destination_database_name = \(SQLIdentifier.literal($0))" } ?? ""
        let key = major >= 12 ? "ISNULL(bs.key_algorithm, N'')" : "N''"
        let algorithm = major >= 16 ? "ISNULL(bs.compression_algorithm, N'')" : "N''"
        let sinceLiteral = ServerTime.literal(since)
        let sql = """
        SELECT bs.backup_set_id, bs.database_name, bs.type, CAST(bs.is_copy_only AS int) AS copy_only,
               bs.backup_start_date, bs.backup_finish_date, CAST(bs.backup_size AS bigint) AS backup_size,
               CAST(ISNULL(bs.compressed_backup_size, bs.backup_size) AS bigint) AS compressed_size,
               \(key) AS key_algorithm, \(algorithm) AS compression_algorithm,
               CAST(bs.has_backup_checksums AS int) AS checksums, CAST(bs.is_damaged AS int) AS damaged,
               bs.user_name, bs.server_name, bs.position, bs.media_set_id,
               (SELECT CAST(SUM(bf.file_size) AS bigint) FROM msdb.dbo.backupfile AS bf
                WHERE bf.backup_set_id = bs.backup_set_id) AS database_size
        FROM msdb.dbo.backupset AS bs
        WHERE bs.backup_finish_date >= \(sinceLiteral)\(filter)
        ORDER BY bs.backup_finish_date DESC;
        SELECT mf.media_set_id, mf.family_sequence_number, mf.mirror, mf.physical_device_name, mf.device_type
        FROM msdb.dbo.backupmediafamily AS mf
        WHERE mf.media_set_id IN (SELECT bs.media_set_id FROM msdb.dbo.backupset AS bs
                                  WHERE bs.backup_finish_date >= \(sinceLiteral)\(filter))
        ORDER BY mf.media_set_id, mf.mirror, mf.family_sequence_number;
        SELECT rh.restore_history_id, rh.restore_date, rh.destination_database_name, rh.user_name, rh.restore_type,
               CAST(ISNULL(rh.recovery, 0) AS int) AS recovery, bs.database_name AS source_database,
               bs.type AS backup_type, bs.server_name, CAST(ISNULL(bs.backup_size, 0) AS bigint) AS backup_size,
               CAST(ISNULL(bs.compressed_backup_size, 0) AS bigint) AS compressed_size, bs.media_set_id,
               CAST(ISNULL(bs.is_copy_only, 0) AS int) AS copy_only
        FROM msdb.dbo.restorehistory AS rh
        LEFT JOIN msdb.dbo.backupset AS bs ON bs.backup_set_id = rh.backup_set_id
        WHERE rh.restore_date >= \(sinceLiteral)\(restoreFilter)
        ORDER BY rh.restore_date DESC;
        """
        let result = try await session.metadataQuery(sql, database: "msdb")
        let sets = result.resultSets
        let backups = sets.first?.dictionaries() ?? []
        let families = sets.count > 1 ? sets[1].dictionaries() : []
        let restores = sets.count > 2 ? sets[2].dictionaries() : []

        var filesByMedia: [Int: [String]] = [:]
        var mirrorsByMedia: [Int: Int] = [:]
        var deviceByMedia: [Int: Int] = [:]
        for row in families {
            let media = row.int("media_set_id")
            let mirror = row.int("mirror")
            mirrorsByMedia[media] = max(mirrorsByMedia[media] ?? 0, mirror)
            deviceByMedia[media] = row.int("device_type")
            if mirror == 0 { filesByMedia[media, default: []].append(row.string("physical_device_name")) }
        }

        var activities: [BackupActivity] = []
        for row in backups {
            let media = row.int("media_set_id")
            var item = BackupActivity(id: "b\(row.int("backup_set_id"))", kind: .backup,
                                      database: row.string("database_name"), typeCode: row.string("type"))
            item.isCopyOnly = row.int("copy_only") == 1
            item.started = row.serverDate("backup_start_date")
            item.finished = row.serverDate("backup_finish_date")
            item.backupSize = row.int64("backup_size")
            item.compressedSize = row.int64("compressed_size")
            item.databaseSize = row.int64("database_size")
            item.keyAlgorithm = row.string("key_algorithm")
            item.compressionAlgorithm = row.string("compression_algorithm")
            if item.compressionAlgorithm.isEmpty && item.compressedSize > 0 && item.compressedSize < item.backupSize {
                item.compressionAlgorithm = "MS_XPRESS"
            }
            item.hasChecksums = row.int("checksums") == 1
            item.isDamaged = row.int("damaged") == 1
            item.succeeded = !item.isDamaged
            item.userName = row.string("user_name")
            item.serverName = row.string("server_name")
            item.position = row.int("position", default: 1)
            item.backupSetID = row.int("backup_set_id")
            item.files = filesByMedia[media] ?? []
            item.mirrorCount = mirrorsByMedia[media] ?? 0
            item.deviceType = deviceByMedia[media] ?? 2
            activities.append(item)
        }
        for row in restores {
            let isVerify = row.string("restore_type").uppercased() == "V"
            var item = BackupActivity(id: "r\(row.int("restore_history_id"))", kind: isVerify ? .verify : .restore,
                                      database: row.string("destination_database_name"),
                                      typeCode: isVerify ? "V" : row.string("backup_type"))
            item.finished = row.serverDate("restore_date")
            item.started = item.finished
            item.userName = row.string("user_name")
            item.serverName = row.string("server_name")
            item.backupSize = row.int64("backup_size")
            item.compressedSize = row.int64("compressed_size")
            item.isCopyOnly = row.int("copy_only") == 1
            item.restoredFrom = row.string("source_database")
            item.files = filesByMedia[row.int("media_set_id")] ?? []
            item.message = row.int("recovery") == 1 ? "Recovered" : "Left restoring"
            activities.append(item)
        }
        activities.append(contentsOf: (try? await jobFailures(since: since)) ?? [])
        return activities.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    /// Failed backup, restore and log shipping jobs: msdb records only successful backups, so
    /// this is where failures come from.
    public func jobFailures(since: Date) async throws -> [BackupActivity] {
        let day = Int(ServerTime.format(since, "yyyyMMdd")) ?? 0
        let sql = """
        SELECT h.instance_id, j.name AS job_name, h.run_date, h.run_time, h.run_duration, h.run_status,
               LEFT(h.message, 2000) AS message, ISNULL(c.name, N'') AS category
        FROM msdb.dbo.sysjobhistory AS h
        JOIN msdb.dbo.sysjobs AS j ON j.job_id = h.job_id
        LEFT JOIN msdb.dbo.syscategories AS c ON c.category_id = j.category_id
        WHERE h.step_id = 0 AND h.run_status IN (0, 3) AND h.run_date >= \(day)
          AND (c.name IN (\(SQLIdentifier.literal(BackupJobManager.backupCategory)),
                          \(SQLIdentifier.literal(BackupJobManager.restoreCategory)), N'Log Shipping')
               OR EXISTS (SELECT 1 FROM msdb.dbo.sysjobsteps AS s WHERE s.job_id = j.job_id
                          AND (s.command LIKE N'%BACKUP %' OR s.command LIKE N'%RESTORE %')))
        ORDER BY h.instance_id DESC;
        """
        let result = try await session.metadataQuery(sql, database: "msdb")
        return (result.resultSets.first?.dictionaries() ?? []).map { row in
            var item = BackupActivity(id: "j\(row.int("instance_id"))", kind: .jobFailure, database: "",
                                      typeCode: "")
            item.jobName = row.string("job_name")
            item.started = ServerTime.fromAgent(date: row.int("run_date"), time: row.int("run_time"))
            let packed = row.int("run_duration")
            let seconds = (packed / 10000) * 3600 + ((packed / 100) % 100) * 60 + packed % 100
            item.finished = item.started.map { $0.addingTimeInterval(TimeInterval(seconds)) }
            item.succeeded = false
            item.message = row.string("message")
            item.database = BackupJobManager.databaseHint(jobName: item.jobName)
            return item
        }
    }

    // MARK: In progress

    public func inProgress() async throws -> [BackupProgressItem] {
        let sql = """
        SELECT r.session_id, r.command, r.percent_complete, r.estimated_completion_time, r.start_time,
               ISNULL(DB_NAME(r.database_id), N'') AS database_name, s.login_name, ISNULL(s.program_name, N'') AS program_name,
               ISNULL(LEFT(t.text, 2000), N'') AS statement
        FROM sys.dm_exec_requests AS r
        JOIN sys.dm_exec_sessions AS s ON s.session_id = r.session_id
        OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) AS t
        WHERE (r.command LIKE N'BACKUP%' OR r.command LIKE N'RESTORE%' OR r.command LIKE N'DBCC%')
          AND r.session_id <> @@SPID;
        """
        let result = try await session.metadataQuery(sql, database: "master")
        return (result.resultSets.first?.dictionaries() ?? []).map { row in
            let statement = row.string("statement")
            var database = row.string("database_name")
            if let named = Self.databaseNamed(in: statement) { database = named }
            return BackupProgressItem(sessionID: row.int("session_id"), command: row.string("command"),
                                      database: database, percentComplete: row.double("percent_complete"),
                                      estimatedSecondsLeft: row.double("estimated_completion_time") / 1000,
                                      started: row.serverDate("start_time"), loginName: row.string("login_name"),
                                      programName: row.string("program_name"), statement: statement)
        }
    }

    /// `BACKUP DATABASE [Sales] …` runs in master, so the database comes from the statement.
    static func databaseNamed(in statement: String) -> String? {
        let tokens = TSQLLexer().significantTokens(statement)
        for (index, token) in tokens.enumerated() where index + 2 < tokens.count {
            let word = token.text.uppercased()
            guard word == "BACKUP" || word == "RESTORE" else { continue }
            let next = tokens[index + 1].text.uppercased()
            guard next == "DATABASE" || next == "LOG" else { continue }
            let name = tokens[index + 2].text
            if name.hasPrefix("@") { return nil }
            return ModuleText.unquote(name)
        }
        return nil
    }

    // MARK: Backup sets

    /// Every backup set of a database recorded on this server, oldest first.
    public func backupSets(database: String) async throws -> [BackupSetInfo] {
        let major = await majorVersion
        let key = major >= 12 ? "ISNULL(bs.key_algorithm, N'')" : "N''"
        let thumbprint = major >= 12 ? "bs.encryptor_thumbprint" : "CAST(NULL AS varbinary(20))"
        let validTime = major >= 16 ? "bs.last_valid_restore_time" : "CAST(NULL AS datetime)"
        let db = SQLIdentifier.literal(database)
        let sql = """
        SELECT bs.backup_set_id, bs.database_name, bs.server_name, bs.type, CAST(bs.is_copy_only AS int) AS copy_only,
               bs.position, CAST(bs.first_lsn AS varchar(40)) AS first_lsn, CAST(bs.last_lsn AS varchar(40)) AS last_lsn,
               CAST(bs.checkpoint_lsn AS varchar(40)) AS checkpoint_lsn,
               CAST(bs.database_backup_lsn AS varchar(40)) AS database_backup_lsn,
               CAST(bs.differential_base_lsn AS varchar(40)) AS differential_base_lsn,
               bs.backup_start_date, bs.backup_finish_date, \(validTime) AS last_valid_restore_time,
               CONVERT(nvarchar(36), bs.first_recovery_fork_guid) AS first_fork,
               CONVERT(nvarchar(36), bs.last_recovery_fork_guid) AS last_fork,
               CAST(bs.backup_size AS bigint) AS backup_size,
               CAST(ISNULL(bs.compressed_backup_size, bs.backup_size) AS bigint) AS compressed_size,
               \(key) AS key_algorithm, \(thumbprint) AS thumbprint,
               CAST(bs.has_backup_checksums AS int) AS checksums, CAST(bs.is_damaged AS int) AS damaged,
               bs.recovery_model, bs.media_set_id, ISNULL(bs.name, N'') AS name, ISNULL(bs.description, N'') AS description
        FROM msdb.dbo.backupset AS bs
        WHERE bs.database_name = \(db)
        ORDER BY bs.backup_finish_date, bs.backup_set_id;
        SELECT mf.media_set_id, mf.family_sequence_number, mf.mirror, mf.physical_device_name, mf.device_type
        FROM msdb.dbo.backupmediafamily AS mf
        WHERE mf.media_set_id IN (SELECT media_set_id FROM msdb.dbo.backupset WHERE database_name = \(db))
        ORDER BY mf.media_set_id, mf.mirror, mf.family_sequence_number;
        """
        let result = try await session.metadataQuery(sql, database: "msdb")
        let sets = result.resultSets.first?.dictionaries() ?? []
        let families = result.resultSets.count > 1 ? result.resultSets[1].dictionaries() : []
        var filesByMedia: [Int: [Int: [String]]] = [:]
        var deviceByMedia: [Int: Int] = [:]
        for row in families {
            let media = row.int("media_set_id")
            filesByMedia[media, default: [:]][row.int("mirror"), default: []].append(row.string("physical_device_name"))
            deviceByMedia[media] = row.int("device_type")
        }
        return sets.map { row in
            let media = row.int("media_set_id")
            var info = BackupSetInfo(id: row.int("backup_set_id"), database: row.string("database_name"),
                                     typeCode: row.string("type"), position: row.int("position", default: 1),
                                     firstLSN: LSN(row.string("first_lsn")), lastLSN: LSN(row.string("last_lsn")),
                                     checkpointLSN: LSN(row.string("checkpoint_lsn")),
                                     databaseBackupLSN: LSN(row.string("database_backup_lsn")),
                                     differentialBaseLSN: LSN(row.string("differential_base_lsn")),
                                     started: row.serverDate("backup_start_date"),
                                     finished: row.serverDate("backup_finish_date"),
                                     isCopyOnly: row.int("copy_only") == 1)
            info.serverName = row.string("server_name")
            info.lastValidRestoreTime = row.serverDate("last_valid_restore_time")
            info.firstRecoveryForkID = row.string("first_fork").uppercased()
            info.lastRecoveryForkID = row.string("last_fork").uppercased()
            info.backupSize = row.int64("backup_size")
            info.compressedSize = row.int64("compressed_size")
            info.keyAlgorithm = row.string("key_algorithm")
            if case .binary(let bytes)? = row["thumbprint"] { info.encryptorThumbprint = SQLLiteral.hex(bytes) }
            info.hasChecksums = row.int("checksums") == 1
            info.isDamaged = row.int("damaged") == 1
            info.recoveryModel = row.string("recovery_model")
            info.deviceType = deviceByMedia[media] ?? 2
            info.name = row.string("name")
            info.setDescription = row.string("description")
            let mirrors = filesByMedia[media] ?? [:]
            info.files = mirrors.keys.sorted().compactMap { mirrors[$0] }
            return info
        }
    }

    /// Database names that have backup history on this server.
    public func databasesWithHistory() async throws -> [String] {
        let sql = "SELECT DISTINCT database_name FROM msdb.dbo.backupset ORDER BY database_name"
        let result = try await session.metadataQuery(sql, database: "msdb")
        return (result.resultSets.first?.dictionaries() ?? []).map { $0.string("database_name") }
    }
}
