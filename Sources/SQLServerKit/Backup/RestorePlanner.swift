import Foundation
import TDSKit

// MARK: - Options

/// DBCC CHECKDB options for the integrity check after a restore.
public struct CheckDBOptions: Codable, Hashable, Sendable {
    public var physicalOnly: Bool = false
    public var tablock: Bool = false
    public var dataPurity: Bool = false
    public var extendedLogicalChecks: Bool = false
    public var allErrorMessages: Bool = true
    public var noInfoMessages: Bool = true

    public init() {}

    public var withClause: String {
        var options: [String] = []
        if noInfoMessages { options.append("NO_INFOMSGS") }
        if allErrorMessages { options.append("ALL_ERRORMSGS") }
        if tablock { options.append("TABLOCK") }
        if physicalOnly {
            options.append("PHYSICAL_ONLY")
        } else {
            if dataPurity { options.append("DATA_PURITY") }
            if extendedLogicalChecks { options.append("EXTENDED_LOGICAL_CHECKS") }
        }
        return options.isEmpty ? "" : " WITH " + options.joined(separator: ", ")
    }
}

/// Everything the Restore wizard collects after the backups are chosen.
public struct RestoreOptions: Codable, Hashable, Sendable {
    public enum RecoveryState: String, Codable, CaseIterable, Sendable {
        case operational
        case nonOperational
        case readOnly

        public var title: String {
            switch self {
            case .operational: return "Operational (RESTORE WITH RECOVERY)"
            case .nonOperational: return "Non-operational (RESTORE WITH NORECOVERY)"
            case .readOnly: return "Read-only (RESTORE WITH STANDBY)"
            }
        }
    }

    public enum FileLocation: String, Codable, CaseIterable, Sendable {
        case original
        case serverDefaults
        case folders
        case custom

        public var title: String {
            switch self {
            case .original: return "Original locations from the backup"
            case .serverDefaults: return "SQL Server default data and log folders"
            case .folders: return "Data and log files to folders I choose"
            case .custom: return "Each file where I choose"
            }
        }
    }

    public enum DropPolicy: String, Codable, CaseIterable, Sendable {
        case never
        case always
        case onSuccess

        public var title: String {
            switch self {
            case .never: return "Keep the restored database"
            case .always: return "Always drop the restored database afterwards"
            case .onSuccess: return "Drop it if the restore and integrity check succeed"
            }
        }
    }

    public enum BrokerOption: String, Codable, CaseIterable, Sendable {
        case keep
        case enable = "ENABLE_BROKER"
        case new = "NEW_BROKER"
        case errorConversations = "ERROR_BROKER_CONVERSATIONS"
    }

    public var destinationDatabase: String = ""
    public var replaceExisting: Bool = false
    public var killConnections: Bool = true
    public var tailLogBackup: Bool = false
    public var tailLogPath: String = ""
    public var fileLocation: FileLocation = .serverDefaults
    public var dataFolder: String = ""
    public var logFolder: String = ""
    /// Logical file name to physical path, when `fileLocation` is `.custom`.
    public var fileMoves: [String: String] = [:]
    public var recoveryState: RecoveryState = .operational
    public var undoFile: String = ""
    public var orphanCheck: Bool = true
    public var fixOrphanedUsers: Bool = false
    public var checkDB: Bool = false
    public var checkDBOptions: CheckDBOptions = CheckDBOptions()
    public var drop: DropPolicy = .never
    public var keepCDC: Bool = false
    public var keepReplication: Bool = false
    public var broker: BrokerOption = .keep
    public var restrictedUser: Bool = false
    public var checksum: Bool = true
    public var continueAfterError: Bool = false
    public var s3Region: String = ""

    public init() {}
}

// MARK: - Plan

/// One statement of a restore, run in order.
public struct RestoreStep: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable {
        case prepare
        case tailLog
        case restore
        case orphanCheck
        case checkDB
        case drop
    }

    public var id: Int
    public var kind: Kind
    public var title: String
    public var sql: String
}

/// Turns a chain and options into the restore script.
public struct RestorePlanner: Sendable {
    public var chain: RestoreChain
    public var files: [RestoreFileInfo]
    public var options: RestoreOptions
    public var capabilities: BackupServerCapabilities
    /// The destination already exists on the server.
    public var destinationExists: Bool
    public var destinationIsRestoring: Bool

    public init(chain: RestoreChain, files: [RestoreFileInfo], options: RestoreOptions,
                capabilities: BackupServerCapabilities, destinationExists: Bool, destinationIsRestoring: Bool = false) {
        self.chain = chain
        self.files = files
        self.options = options
        self.capabilities = capabilities
        self.destinationExists = destinationExists
        self.destinationIsRestoring = destinationIsRestoring
    }

    public var sourceDatabase: String { chain.full.database }
    public var destination: String {
        let name = options.destinationDatabase.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? sourceDatabase : name
    }

    // MARK: Files

    /// Where each file of the backup will be restored.
    public func relocations() -> [(logical: String, physical: String)] {
        files.map { file in
            let original = file.physicalName
            let name = renamedFile(capabilities.fileName(of: original))
            switch options.fileLocation {
            case .original:
                // Restoring under a new name next to the source would collide with its files.
                if destination.caseInsensitiveCompare(sourceDatabase) == .orderedSame {
                    return (file.logicalName, original)
                }
                return (file.logicalName, capabilities.join(capabilities.folder(of: original), name))
            case .serverDefaults:
                let folder = file.type == "LOG" ? capabilities.defaultLogFolder : capabilities.defaultDataFolder
                return (file.logicalName, capabilities.join(folder, name))
            case .folders:
                let chosen = file.type == "LOG" ? options.logFolder : options.dataFolder
                let folder = chosen.isEmpty ? capabilities.folder(of: original) : chosen
                return (file.logicalName, capabilities.join(folder, name))
            case .custom:
                let fallback = capabilities.join(file.type == "LOG" ? capabilities.defaultLogFolder
                                                     : capabilities.defaultDataFolder, name)
                return (file.logicalName, options.fileMoves[file.logicalName] ?? fallback)
            }
        }
    }

    /// `Sales.mdf` becomes `Sales_Copy.mdf` when restoring Sales as Sales_Copy.
    func renamedFile(_ name: String) -> String {
        guard destination.caseInsensitiveCompare(sourceDatabase) != .orderedSame else { return name }
        if let range = name.range(of: sourceDatabase, options: .caseInsensitive) {
            return name.replacingCharacters(in: range, with: destination)
        }
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        return ext.isEmpty ? "\(destination)_\(stem)" : "\(destination)_\(stem).\(ext)"
    }

    public var undoFile: String {
        let chosen = options.undoFile.trimmingCharacters(in: .whitespaces)
        return chosen.isEmpty ? capabilities.join(capabilities.backupFolder, "UNDO_\(destination).dat") : chosen
    }

    // MARK: Statements

    public func steps() -> [RestoreStep] {
        var steps: [RestoreStep] = []
        func add(_ kind: RestoreStep.Kind, _ title: String, _ sql: String) {
            steps.append(RestoreStep(id: steps.count, kind: kind, title: title, sql: sql))
        }
        let target = SQLIdentifier.quote(destination)
        let literalName = SQLIdentifier.literal(destination)
        let overwriting = destinationExists && !destinationIsRestoring
        let killFirst = overwriting && options.killConnections

        if options.tailLogBackup && overwriting {
            var sql = ""
            if killFirst { sql += "ALTER DATABASE \(target) SET SINGLE_USER WITH ROLLBACK IMMEDIATE;\n" }
            sql += "BACKUP LOG \(target) TO DISK = \(SQLIdentifier.literal(options.tailLogPath))\n"
                + "    WITH NORECOVERY, FORMAT, INIT, NAME = N'Tail-log backup', STATS = 10;"
            add(.tailLog, "Back up the tail of the log", sql)
        }

        let restoreSteps = chain.steps
        for (index, set) in restoreSteps.enumerated() {
            let isLast = index == restoreSteps.count - 1
            let verb = set.isLog ? "RESTORE LOG" : "RESTORE DATABASE"
            let device = set.isURL ? "URL" : "DISK"
            var clauses: [String] = ["FILE = \(set.position)"]
            if index == 0 {
                for move in relocations() {
                    clauses.append("MOVE \(SQLIdentifier.literal(move.logical)) TO \(SQLIdentifier.literal(move.physical))")
                }
                if destinationExists && (options.replaceExisting || options.tailLogBackup || destinationIsRestoring) {
                    clauses.append("REPLACE")
                }
            }
            if options.checksum && set.hasChecksums {
                clauses.append("CHECKSUM")
                if options.continueAfterError { clauses.append("CONTINUE_AFTER_ERROR") }
            }
            if set.isLog, let stopAt = chain.stopAt { clauses.append("STOPAT = \(ServerTime.literal(stopAt))") }
            if isLast {
                switch options.recoveryState {
                case .operational:
                    clauses.append("RECOVERY")
                    if options.keepCDC { clauses.append("KEEP_CDC") }
                    if options.keepReplication { clauses.append("KEEP_REPLICATION") }
                    if options.broker != .keep { clauses.append(options.broker.rawValue) }
                    if options.restrictedUser { clauses.append("RESTRICTED_USER") }
                case .nonOperational:
                    clauses.append("NORECOVERY")
                case .readOnly:
                    clauses.append("STANDBY = \(SQLIdentifier.literal(undoFile))")
                }
            } else {
                clauses.append("NORECOVERY")
            }
            if set.isURL, !options.s3Region.isEmpty, set.primaryFiles.first?.lowercased().hasPrefix("s3://") == true {
                clauses.append("RESTORE_OPTIONS = \(SQLIdentifier.literal("{\"s3\": {\"region\":\"\(options.s3Region)\"}}"))")
            }
            clauses.append("STATS = 5")
            let from = set.primaryFiles.map { "\(device) = \(SQLIdentifier.literal($0))" }
                .joined(separator: ",\n         ")
            var sql = "\(verb) \(target)\n    FROM \(from)\n    WITH " + clauses.joined(separator: ",\n         ") + ";"
            if index == 0 && killFirst && !(options.tailLogBackup && overwriting) {
                // The connection that takes the single slot must be the one that restores, in one batch.
                sql = """
                ALTER DATABASE \(target) SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
                BEGIN TRY
                \(sql)
                END TRY
                BEGIN CATCH
                    IF DATABASEPROPERTYEX(\(literalName), 'Status') = 'ONLINE'
                        ALTER DATABASE \(target) SET MULTI_USER;
                    THROW;
                END CATCH
                """
            }
            add(.restore, "Restore \(set.typeTitle.lowercased()) backup of \(ServerTime.display(set.finished ?? Date()))", sql)
        }

        let usable = options.recoveryState != .nonOperational
        if usable && options.orphanCheck {
            add(.orphanCheck, "Check for orphaned users", orphanQuery())
        }
        if usable && options.checkDB {
            add(.checkDB, "Check database integrity",
                "DBCC CHECKDB (\(literalName))\(options.checkDBOptions.withClause);")
        }
        if options.drop != .never {
            add(.drop, "Drop the restored database",
                "IF DB_ID(\(literalName)) IS NOT NULL\nBEGIN\n"
                + "    ALTER DATABASE \(target) SET SINGLE_USER WITH ROLLBACK IMMEDIATE;\n"
                + "    DROP DATABASE \(target);\nEND")
        }
        return steps
    }

    /// SQL logins' users whose SID has no matching login: what SQL Backup's ORPHAN_CHECK lists.
    func orphanQuery() -> String {
        let db = SQLIdentifier.quote(destination)
        let authentication = capabilities.majorVersion >= 11 ? " AND dp.authentication_type = 1" : ""
        return """
        SELECT dp.name AS user_name, CONVERT(varchar(100), dp.sid, 1) AS sid,
               CASE WHEN EXISTS (SELECT 1 FROM sys.server_principals AS sp2 WHERE sp2.name = dp.name AND sp2.type = 'S')
                    THEN 1 ELSE 0 END AS login_exists
        FROM \(db).sys.database_principals AS dp
        LEFT JOIN sys.server_principals AS sp ON sp.sid = dp.sid
        WHERE dp.type = 'S' AND dp.principal_id > 4 AND sp.sid IS NULL\(authentication)
          AND dp.name NOT IN (N'guest', N'INFORMATION_SCHEMA', N'sys', N'dbo');
        """
    }

    /// Maps orphaned users back to the login of the same name.
    public static func fixOrphanScript(database: String, users: [String]) -> String {
        users.map { user in
            "USE \(SQLIdentifier.quote(database)); ALTER USER \(SQLIdentifier.quote(user)) WITH LOGIN = \(SQLIdentifier.quote(user));"
        }.joined(separator: "\n")
    }

    public func script() -> String {
        var lines: [String] = ["-- Restore \(sourceDatabase) as \(destination)"]
        if let stopAt = chain.stopAt { lines.append("-- Point in time: \(ServerTime.display(stopAt))") }
        lines.append("USE [master];")
        lines.append("GO")
        for step in steps() {
            lines.append("-- \(step.title)")
            lines.append(step.sql)
            lines.append("GO")
        }
        return lines.joined(separator: "\n")
    }

    /// Problems that stop the restore, shown before it starts.
    public func validationErrors() -> [String] {
        var errors: [String] = []
        let name = destination
        if name.isEmpty { errors.append("Enter the name of the database to restore to.") }
        if ["master", "model", "msdb", "tempdb"].contains(name.lowercased()) {
            errors.append("System databases cannot be restored from this wizard; restore master in single-user mode "
                          + "from Transact-SQL.")
        }
        if destinationExists && !destinationIsRestoring && !options.replaceExisting && !options.tailLogBackup {
            errors.append("\(name) already exists. Choose to overwrite it, or back up its tail first.")
        }
        if options.tailLogBackup && options.tailLogPath.trimmingCharacters(in: .whitespaces).isEmpty {
            errors.append("Enter where to write the tail-log backup.")
        }
        let targets = relocations().map { $0.physical.lowercased() }
        if Set(targets).count != targets.count { errors.append("Two files would be restored to the same path.") }
        return errors
    }
}

// MARK: - File list

public extension BackupMediaReader {
    /// RESTORE FILELISTONLY for one backup set: the files a restore creates.
    func fileList(for set: BackupSetInfo) async throws -> [RestoreFileInfo] {
        let sql = "RESTORE FILELISTONLY FROM \(Self.fromClause(set.primaryFiles)) WITH FILE = \(set.position);"
        let connection = try await session.openConnection(database: "master")
        defer { Task { try? await connection.close() } }
        let result = try await connection.query(sql)
        return (result.resultSets.first?.dictionaries() ?? []).map { row in
            let code = row.string("Type").uppercased()
            let type: String = code == "L" ? "LOG" : (code == "S" || code == "F" ? "FILESTREAM" : "ROWS")
            return RestoreFileInfo(logicalName: row.string("LogicalName"), physicalName: row.string("PhysicalName"),
                                   type: type, fileGroup: row.string("FileGroupName"),
                                   sizeMB: row.double("Size") / 1_048_576.0, maxSizeMB: row.double("MaxSize") / 1_048_576.0,
                                   fileID: row.int("FileId", default: row.int("FileID")))
        }
    }
}
