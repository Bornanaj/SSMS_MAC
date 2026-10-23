import Foundation
import TDSKit

/// The Log Shipping wizard's choices, mapped onto SQL Server's own log shipping
/// (`sp_add_log_shipping_*`): a backup job on the primary, copy and restore jobs on the standby.
public struct LogShippingOptions: Codable, Hashable, Sendable {
    public enum RestoreMode: String, Codable, CaseIterable, Sendable {
        case nonOperational
        case readOnly

        public var title: String {
            switch self {
            case .nonOperational: return "Non-operational (NORECOVERY)"
            case .readOnly: return "Read-only (STANDBY), so the standby can be queried between restores"
            }
        }
    }

    public var primaryDatabase: String = ""
    public var secondaryDatabase: String = ""
    /// Where the primary writes log backups, as the primary sees it.
    public var backupFolder: String = ""
    /// The same folder as the standby reaches it (a share, or the same path on one machine).
    public var backupShare: String = ""
    /// Where the standby copies log backups to before restoring them.
    public var copyFolder: String = ""
    /// Minutes log backups are kept, in the backup folder and in the copy folder.
    public var retentionMinutes: Int = 4320
    public var compression: Bool = true
    public var restoreMode: RestoreMode = .nonOperational
    public var disconnectUsers: Bool = true
    public var restoreDelayMinutes: Int = 0
    public var backupEveryMinutes: Int = 15
    public var copyEveryMinutes: Int = 15
    /// Run the copy and restore this many minutes after the backup, as SQL Backup offsets the restore.
    public var restoreOffsetMinutes: Int = 5
    public var backupThresholdMinutes: Int = 60
    public var restoreThresholdMinutes: Int = 45
    /// Take a full backup of the primary and restore it on the standby first.
    public var initialize: Bool = true
    public var dataFolder: String = ""
    public var logFolder: String = ""

    public init() {}

    public var undoFileName: String { "UNDO_\(secondaryDatabase).dat" }

    public func validationErrors(sameServer: Bool) -> [String] {
        var errors: [String] = []
        if primaryDatabase.isEmpty { errors.append("Choose the database to ship.") }
        if secondaryDatabase.isEmpty { errors.append("Enter the standby database name.") }
        if sameServer && primaryDatabase.caseInsensitiveCompare(secondaryDatabase) == .orderedSame {
            errors.append("On the same server the standby database needs a different name.")
        }
        if backupFolder.isEmpty { errors.append("Enter the folder the primary writes log backups to.") }
        if backupShare.isEmpty { errors.append("Enter the share the standby reads them from.") }
        if copyFolder.isEmpty { errors.append("Enter the standby's copy folder.") }
        if !copyFolder.isEmpty && copyFolder == backupShare && !sameServer {
            errors.append("The copy folder must differ from the share.")
        }
        if backupEveryMinutes < 1 || copyEveryMinutes < 1 { errors.append("Jobs run at least every minute.") }
        return errors
    }
}

/// Status of one log shipping pair, from the monitor tables on each side.
public struct LogShippingStatus: Identifiable, Hashable, Sendable {
    public var id: String { "\(primaryServer).\(primaryDatabase)->\(secondaryServer).\(secondaryDatabase)" }
    public var primaryServer: String
    public var primaryDatabase: String
    public var secondaryServer: String
    public var secondaryDatabase: String
    public var lastBackupFile: String = ""
    public var lastBackupDate: Date?
    public var lastCopiedFile: String = ""
    public var lastCopiedDate: Date?
    public var lastRestoredFile: String = ""
    public var lastRestoredDate: Date?
    public var restoreLatencyMinutes: Int = 0
    public var backupThresholdMinutes: Int = 60
    public var restoreThresholdMinutes: Int = 45
    public var restoreMode: Int = 0

    /// Healthy when the last restore is within the threshold of the monitor's own time.
    public func isHealthy(now: Date) -> Bool {
        guard let restored = lastRestoredDate else { return false }
        return now.timeIntervalSince(restored) / 60 <= Double(restoreThresholdMinutes)
    }
}

public struct LogShippingSetup: Sendable {
    public let primary: SQLServerSession
    public let secondary: SQLServerSession
    public let options: LogShippingOptions
    public let primaryCapabilities: BackupServerCapabilities
    public let secondaryCapabilities: BackupServerCapabilities

    public typealias Progress = @Sendable (String) -> Void

    public init(primary: SQLServerSession, secondary: SQLServerSession, options: LogShippingOptions,
                primaryCapabilities: BackupServerCapabilities, secondaryCapabilities: BackupServerCapabilities) {
        self.primary = primary
        self.secondary = secondary
        self.options = options
        self.primaryCapabilities = primaryCapabilities
        self.secondaryCapabilities = secondaryCapabilities
    }

    var primaryServerName: String { primaryCapabilities.serverName }
    var secondaryServerName: String { secondaryCapabilities.serverName }

    /// Every statement, labelled with the server it runs on, for the wizard's summary.
    public func script(initialFile: String = "<initial backup file>") -> String {
        var lines: [String] = []
        if options.initialize {
            lines.append("-- On \(primaryServerName): full backup to initialize the standby")
            lines.append(initialBackupSQL(file: initialFile))
            lines.append("GO")
            lines.append("-- On \(secondaryServerName): restore it, leaving the database ready for log restores")
            lines.append("RESTORE DATABASE \(SQLIdentifier.quote(options.secondaryDatabase)) FROM DISK = "
                         + "\(SQLIdentifier.literal(shareFile(initialFile))) WITH MOVE …, REPLACE, \(restoreRecoveryClause);")
            lines.append("GO")
        }
        lines.append("-- On \(primaryServerName)")
        lines.append(primarySQL())
        lines.append("GO")
        lines.append("-- On \(secondaryServerName)")
        lines.append(secondarySQL())
        lines.append("GO")
        lines.append("-- On \(primaryServerName)")
        lines.append(primarySecondarySQL())
        lines.append("GO")
        return lines.joined(separator: "\n")
    }

    var restoreRecoveryClause: String {
        switch options.restoreMode {
        case .nonOperational: return "NORECOVERY"
        case .readOnly:
            return "STANDBY = \(SQLIdentifier.literal(secondaryCapabilities.join(secondaryCapabilities.backupFolder, options.undoFileName)))"
        }
    }

    func initialBackupSQL(file: String) -> String {
        var clauses: [String] = ["FORMAT", "INIT", "CHECKSUM", "NAME = N'Log shipping initialization'"]
        if let compression = primaryCapabilities.compressionClause(level: options.compression ? 1 : 0) {
            clauses.append(compression)
        }
        clauses.append("STATS = 10")
        return "BACKUP DATABASE \(SQLIdentifier.quote(options.primaryDatabase)) TO DISK = \(SQLIdentifier.literal(file))\n"
            + "    WITH " + clauses.joined(separator: ", ") + ";"
    }

    func shareFile(_ primaryPath: String) -> String {
        secondaryCapabilities.join(options.backupShare, primaryCapabilities.fileName(of: primaryPath))
    }

    func schedule(_ name: String, everyMinutes: Int, offsetMinutes: Int) -> BackupSchedule {
        BackupSchedule(name: name, frequency: .daily, repeats: true, repeatInterval: max(1, everyMinutes),
                       repeatUnit: .minutes, startTime: max(0, offsetMinutes) * 60 % 86_400, endTime: 86_399)
    }

    func scheduleSQL(jobVariable: String, _ schedule: BackupSchedule, name: String) -> String {
        "EXEC msdb.dbo.sp_add_schedule @schedule_name = \(SQLIdentifier.literal(name)), "
            + schedule.agentArguments.joined(separator: ", ") + ", @schedule_id = @schedule_id OUTPUT;\n"
            + "EXEC msdb.dbo.sp_attach_schedule @job_id = \(jobVariable), @schedule_id = @schedule_id;\n"
            + "EXEC msdb.dbo.sp_update_job @job_id = \(jobVariable), @enabled = 1;"
    }

    func primarySQL() -> String {
        let db = SQLIdentifier.literal(options.primaryDatabase)
        let backupJob = "LSBackup_\(options.primaryDatabase)"
        let compression = primaryCapabilities.canCompress ? (options.compression ? 1 : 0) : 2
        let backupSchedule = scheduleSQL(jobVariable: "@backup_job",
                                         schedule("Backup", everyMinutes: options.backupEveryMinutes, offsetMinutes: 0),
                                         name: "\(backupJob) schedule")
        return """
        DECLARE @backup_job uniqueidentifier, @primary_id uniqueidentifier, @schedule_id int;
        EXEC master.dbo.sp_add_log_shipping_primary_database @database = \(db),
             @backup_directory = \(SQLIdentifier.literal(options.backupFolder)),
             @backup_share = \(SQLIdentifier.literal(options.backupShare)),
             @backup_job_name = \(SQLIdentifier.literal(backupJob)),
             @backup_retention_period = \(max(1, options.retentionMinutes)),
             @backup_compression = \(compression),
             @backup_threshold = \(max(1, options.backupThresholdMinutes)), @threshold_alert_enabled = 1,
             @history_retention_period = 5760,
             @backup_job_id = @backup_job OUTPUT, @primary_id = @primary_id OUTPUT, @overwrite = 1;
        \(backupSchedule)
        """
    }

    func secondarySQL() -> String {
        let copyJob = "LSCopy_\(primaryServerName)_\(options.primaryDatabase)"
        let restoreJob = "LSRestore_\(primaryServerName)_\(options.primaryDatabase)"
        let offset = max(0, options.restoreOffsetMinutes)
        let copySchedule = scheduleSQL(jobVariable: "@copy_job",
                                       schedule("Copy", everyMinutes: options.copyEveryMinutes, offsetMinutes: offset),
                                       name: "\(String(copyJob.prefix(110))) schedule")
        let restoreSchedule = scheduleSQL(jobVariable: "@restore_job",
                                          schedule("Restore", everyMinutes: options.copyEveryMinutes,
                                                   offsetMinutes: offset + 1),
                                          name: "\(String(restoreJob.prefix(110))) schedule")
        return """
        DECLARE @copy_job uniqueidentifier, @restore_job uniqueidentifier, @secondary_id uniqueidentifier, @schedule_id int;
        EXEC master.dbo.sp_add_log_shipping_secondary_primary @primary_server = \(SQLIdentifier.literal(primaryServerName)),
             @primary_database = \(SQLIdentifier.literal(options.primaryDatabase)),
             @backup_source_directory = \(SQLIdentifier.literal(options.backupShare)),
             @backup_destination_directory = \(SQLIdentifier.literal(options.copyFolder)),
             @copy_job_name = \(SQLIdentifier.literal(String(copyJob.prefix(128)))),
             @restore_job_name = \(SQLIdentifier.literal(String(restoreJob.prefix(128)))),
             @file_retention_period = \(max(1, options.retentionMinutes)),
             @copy_job_id = @copy_job OUTPUT, @restore_job_id = @restore_job OUTPUT,
             @secondary_id = @secondary_id OUTPUT, @overwrite = 1;
        EXEC master.dbo.sp_add_log_shipping_secondary_database @secondary_database = \(SQLIdentifier.literal(options.secondaryDatabase)),
             @primary_server = \(SQLIdentifier.literal(primaryServerName)),
             @primary_database = \(SQLIdentifier.literal(options.primaryDatabase)),
             @restore_delay = \(max(0, options.restoreDelayMinutes)), @restore_all = 1,
             @restore_mode = \(options.restoreMode == .readOnly ? 1 : 0),
             @disconnect_users = \(options.disconnectUsers ? 1 : 0),
             @restore_threshold = \(max(1, options.restoreThresholdMinutes)), @threshold_alert_enabled = 1,
             @history_retention_period = 5760, @overwrite = 1;
        \(copySchedule)
        \(restoreSchedule)
        """
    }

    func primarySecondarySQL() -> String {
        "EXEC master.dbo.sp_add_log_shipping_primary_secondary @primary_database = \(SQLIdentifier.literal(options.primaryDatabase)), "
            + "@secondary_server = \(SQLIdentifier.literal(secondaryServerName)), "
            + "@secondary_database = \(SQLIdentifier.literal(options.secondaryDatabase)), @overwrite = 1;"
    }

    /// Sets everything up, initializing the standby first when asked.
    public func run(progress: Progress? = nil) async throws {
        if options.initialize {
            let stamp = ServerTime.format(primaryCapabilities.serverTime ?? Date(), "yyyyMMdd_HHmmss")
            let file = primaryCapabilities.join(options.backupFolder, "LSINIT_\(BackupFileNaming.sanitize(options.primaryDatabase))_\(stamp).bak")
            progress?("Backing up \(options.primaryDatabase) on \(primaryServerName)")
            try await execute("EXEC master.dbo.xp_create_subdir \(SQLIdentifier.literal(options.backupFolder));", on: primary)
            try await execute(initialBackupSQL(file: file), on: primary)

            progress?("Restoring it as \(options.secondaryDatabase) on \(secondaryServerName)")
            try await execute("EXEC master.dbo.xp_create_subdir \(SQLIdentifier.literal(options.copyFolder));", on: secondary)
            let shared = shareFile(file)
            let reader = BackupMediaReader(session: secondary)
            let read = await reader.read(paths: [shared])
            guard let set = read.sets.first(where: { $0.isFull }) else {
                throw SQLServerError.unsupportedOperation(read.problems.first
                    ?? "The standby cannot read the initial backup at \(shared). Check the share path.")
            }
            let files = try await reader.fileList(for: set)
            var restore = RestoreOptions()
            restore.destinationDatabase = options.secondaryDatabase
            restore.replaceExisting = true
            restore.killConnections = true
            restore.fileLocation = options.dataFolder.isEmpty && options.logFolder.isEmpty ? .serverDefaults : .folders
            restore.dataFolder = options.dataFolder
            restore.logFolder = options.logFolder
            restore.recoveryState = options.restoreMode == .readOnly ? .readOnly : .nonOperational
            restore.orphanCheck = false
            let exists = try await databaseExists(options.secondaryDatabase, on: secondary)
            let planner = RestorePlanner(chain: RestoreChain(full: set, differential: nil, logs: []), files: files,
                                         options: restore, capabilities: secondaryCapabilities,
                                         destinationExists: exists.exists, destinationIsRestoring: exists.restoring)
            let outcome = await RestoreRunner(session: secondary, planner: planner).run()
            if !outcome.succeeded { throw SQLServerError.unsupportedOperation(outcome.error ?? "The standby restore failed.") }
        }
        progress?("Creating the backup job on \(primaryServerName)")
        try await execute(primarySQL(), on: primary)
        progress?("Creating the copy and restore jobs on \(secondaryServerName)")
        try await execute(secondarySQL(), on: secondary)
        progress?("Registering the standby with the primary")
        try await execute(primarySecondarySQL(), on: primary)
        progress?("Log shipping is set up")
    }

    func databaseExists(_ name: String, on session: SQLServerSession) async throws -> (exists: Bool, restoring: Bool) {
        let result = try await session.metadataQuery(
            "SELECT state_desc FROM sys.databases WHERE name = \(SQLIdentifier.literal(name))", database: "master")
        guard let row = result.resultSets.first?.dictionaries().first else { return (false, false) }
        return (true, row.string("state_desc").uppercased() == "RESTORING")
    }

    func execute(_ sql: String, on session: SQLServerSession) async throws {
        let connection = try await session.openConnection(database: "master")
        defer { Task { try? await connection.close() } }
        _ = try await StreamingStatement.run(sql, on: connection)
    }
}

/// Monitoring and removal, per server.
public struct LogShippingMonitor: Sendable {
    private let session: SQLServerSession

    public init(session: SQLServerSession) {
        self.session = session
    }

    /// Pairs this server takes part in, as primary or as standby.
    public func status() async throws -> [LogShippingStatus] {
        let sql = """
        SELECT p.primary_server, p.primary_database, ISNULL(ps.secondary_server, N'') AS secondary_server,
               ISNULL(ps.secondary_database, N'') AS secondary_database, ISNULL(p.last_backup_file, N'') AS last_backup_file,
               p.last_backup_date, p.backup_threshold
        FROM msdb.dbo.log_shipping_monitor_primary AS p
        LEFT JOIN msdb.dbo.log_shipping_primary_databases AS pd ON pd.primary_database = p.primary_database
        LEFT JOIN msdb.dbo.log_shipping_primary_secondaries AS ps ON ps.primary_id = pd.primary_id;
        SELECT s.secondary_server, s.secondary_database, s.primary_server, s.primary_database,
               ISNULL(s.last_copied_file, N'') AS last_copied_file, s.last_copied_date,
               ISNULL(s.last_restored_file, N'') AS last_restored_file, s.last_restored_date,
               ISNULL(s.last_restored_latency, 0) AS latency, s.restore_threshold,
               ISNULL(sd.restore_mode, 0) AS restore_mode
        FROM msdb.dbo.log_shipping_monitor_secondary AS s
        LEFT JOIN msdb.dbo.log_shipping_secondary_databases AS sd ON sd.secondary_database = s.secondary_database;
        """
        let result = try await session.metadataQuery(sql, database: "msdb")
        var pairs: [String: LogShippingStatus] = [:]
        for row in result.resultSets.first?.dictionaries() ?? [] {
            var status = LogShippingStatus(primaryServer: row.string("primary_server"),
                                           primaryDatabase: row.string("primary_database"),
                                           secondaryServer: row.string("secondary_server"),
                                           secondaryDatabase: row.string("secondary_database"))
            status.lastBackupFile = row.string("last_backup_file")
            status.lastBackupDate = row.serverDate("last_backup_date")
            status.backupThresholdMinutes = row.int("backup_threshold", default: 60)
            pairs[status.id] = status
        }
        if result.resultSets.count > 1 {
            for row in result.resultSets[1].dictionaries() {
                let key = LogShippingStatus(primaryServer: row.string("primary_server"),
                                            primaryDatabase: row.string("primary_database"),
                                            secondaryServer: row.string("secondary_server"),
                                            secondaryDatabase: row.string("secondary_database")).id
                var status = pairs[key] ?? LogShippingStatus(primaryServer: row.string("primary_server"),
                                                             primaryDatabase: row.string("primary_database"),
                                                             secondaryServer: row.string("secondary_server"),
                                                             secondaryDatabase: row.string("secondary_database"))
                status.lastCopiedFile = row.string("last_copied_file")
                status.lastCopiedDate = row.serverDate("last_copied_date")
                status.lastRestoredFile = row.string("last_restored_file")
                status.lastRestoredDate = row.serverDate("last_restored_date")
                status.restoreLatencyMinutes = row.int("latency")
                status.restoreThresholdMinutes = row.int("restore_threshold", default: 45)
                status.restoreMode = row.int("restore_mode")
                pairs[key] = status
            }
        }
        return pairs.values.sorted { $0.id < $1.id }
    }

    /// Removes the primary side of a pair.
    public static func removePrimarySQL(primaryDatabase: String, secondaryServer: String, secondaryDatabase: String) -> String {
        var lines: [String] = []
        if !secondaryServer.isEmpty {
            lines.append("EXEC master.dbo.sp_delete_log_shipping_primary_secondary @primary_database = "
                         + "\(SQLIdentifier.literal(primaryDatabase)), @secondary_server = \(SQLIdentifier.literal(secondaryServer)), "
                         + "@secondary_database = \(SQLIdentifier.literal(secondaryDatabase));")
        }
        lines.append("EXEC master.dbo.sp_delete_log_shipping_primary_database @database = \(SQLIdentifier.literal(primaryDatabase));")
        return lines.joined(separator: "\n")
    }

    public static func removeSecondarySQL(secondaryDatabase: String) -> String {
        "EXEC master.dbo.sp_delete_log_shipping_secondary_database @secondary_database = \(SQLIdentifier.literal(secondaryDatabase));"
    }

    /// Fails over manually: stops shipping into the standby and recovers it, as SQL Backup's
    /// failover procedure ends.
    public static func bringOnlineSQL(secondaryDatabase: String) -> String {
        removeSecondarySQL(secondaryDatabase: secondaryDatabase) + "\n"
            + "RESTORE DATABASE \(SQLIdentifier.quote(secondaryDatabase)) WITH RECOVERY;"
    }

    public func execute(_ sql: String) async throws {
        let connection = try await session.openConnection(database: "master")
        defer { Task { try? await connection.close() } }
        _ = try await StreamingStatement.run(sql, on: connection)
    }
}
