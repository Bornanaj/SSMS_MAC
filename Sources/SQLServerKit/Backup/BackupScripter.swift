import Foundation

/// The files one database's backup is written to.
public struct BackupFilePlan: Sendable, Hashable {
    /// Folder (or container URL) the files are in, tags expanded.
    public var folder: String
    public var files: [String]
    public var mirrorFolders: [String]
    /// One array per mirror, each with as many files as `files`.
    public var mirrorFiles: [[String]]
    public var isURL: Bool

    public var allFiles: [String] { files + mirrorFiles.flatMap { $0 } }
}

/// Builds the native T-SQL for a backup: the BACKUP statement, its verification and the
/// retention clean-up. The same pieces are used for one-off backups and inside scheduled jobs.
public struct BackupScripter: Sendable {
    public var options: BackupOptions
    public var capabilities: BackupServerCapabilities
    /// The default file name format from Server Options, which `<AUTO>` stands for.
    public var defaultFormat: String

    public init(options: BackupOptions, capabilities: BackupServerCapabilities,
                defaultFormat: String = BackupOptions.defaultFileNameFormat) {
        self.options = options
        self.capabilities = capabilities
        self.defaultFormat = defaultFormat
    }

    // MARK: - Files

    public func context(database: String, date: Date, availabilityGroup: String = "") -> BackupFileNaming.Context {
        BackupFileNaming.Context(database: database, type: options.type, instance: capabilities.instanceTag,
                                 server: capabilities.machineName.isEmpty ? capabilities.serverName
                                     : capabilities.machineName,
                                 availabilityGroup: availabilityGroup, date: date, defaultFormat: defaultFormat)
    }

    /// The folder the files go to, before tags are expanded.
    public var folderTemplate: String {
        let folder = options.folder.trimmingCharacters(in: .whitespaces)
        return folder.isEmpty ? capabilities.backupFolder : folder
    }

    public func plan(database: String, date: Date, availabilityGroup: String = "") -> BackupFilePlan {
        let context = self.context(database: database, date: date, availabilityGroup: availabilityGroup)
        let base = BackupFileNaming.expand(options.effectiveFileNameFormat, context: context)
        let count = options.layout == .split ? max(2, min(64, options.fileCount)) : 1
        let names = BackupFileNaming.stripeNames(base: base, count: count, fileExtension: options.type.fileExtension)

        if options.destination == .url {
            let container = BackupFileNaming.expand(options.urlBase, context: context)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
            let files = names.map { container + "/" + $0 }
            return BackupFilePlan(folder: container, files: files, mirrorFolders: [], mirrorFiles: [], isURL: true)
        }
        let folder = BackupFileNaming.expandFolder(folderTemplate, context: context)
        let files = names.map { capabilities.join(folder, $0) }
        var mirrorFolders: [String] = []
        var mirrorFiles: [[String]] = []
        if options.layout == .mirrored {
            for template in options.mirrorFolders.prefix(3) where !template.trimmingCharacters(in: .whitespaces).isEmpty {
                let expanded = BackupFileNaming.expandFolder(template, context: context)
                mirrorFolders.append(expanded)
                mirrorFiles.append(names.map { capabilities.join(expanded, $0) })
            }
        }
        return BackupFilePlan(folder: folder, files: files, mirrorFolders: mirrorFolders, mirrorFiles: mirrorFiles,
                              isURL: false)
    }

    // MARK: - Statements

    /// `BACKUP DATABASE … TO … WITH …`.
    public func backupStatement(database: String, plan: BackupFilePlan, copyOnly: Bool? = nil,
                                name: String? = nil, description: String? = nil) -> String {
        let device = plan.isURL ? "URL" : "DISK"
        let verb = options.type == .log ? "BACKUP LOG" : "BACKUP DATABASE"
        var lines: [String] = ["\(verb) \(SQLIdentifier.quote(database))"]
        lines.append("    TO " + plan.files.map { "\(device) = \(SQLIdentifier.literal($0))" }
            .joined(separator: ",\n       "))
        for mirror in plan.mirrorFiles {
            lines.append("    MIRROR TO " + mirror.map { "\(device) = \(SQLIdentifier.literal($0))" }
                .joined(separator: ",\n              "))
        }
        let clauses = withClauses(copyOnly: copyOnly ?? options.copyOnly, name: name, description: description,
                                  isURL: plan.isURL)
        lines.append("    WITH " + clauses.joined(separator: ",\n         ") + ";")
        return lines.joined(separator: "\n")
    }

    /// The WITH options, which depend only on the options (not on the database).
    public func withClauses(copyOnly: Bool, name: String?, description: String?, isURL: Bool) -> [String] {
        var clauses: [String] = []
        if options.type == .differential { clauses.append("DIFFERENTIAL") }
        if copyOnly && options.type != .differential { clauses.append("COPY_ONLY") }
        if options.type == .log && !options.truncateLog { clauses.append("NO_TRUNCATE") }
        // Files are checked before the backup when overwriting is off, so FORMAT only ever replaces
        // a file the user asked to replace. It also keeps one backup set per file, which encrypted
        // backups and URL targets require and which makes retention by file safe.
        clauses.append("FORMAT")
        clauses.append("INIT")
        if let name, !name.isEmpty { clauses.append("NAME = \(SQLIdentifier.literal(String(name.prefix(128))))") }
        if let description, !description.isEmpty {
            clauses.append("DESCRIPTION = \(SQLIdentifier.literal(String(description.prefix(255))))")
        }
        if let compression = capabilities.compressionClause(level: options.compressionLevel) {
            clauses.append(compression)
        }
        if options.encryption.isEnabled && capabilities.canEncrypt { clauses.append(options.encryption.clause) }
        if options.checksum {
            clauses.append("CHECKSUM")
            if options.continueAfterError { clauses.append("CONTINUE_AFTER_ERROR") }
        }
        if options.maxTransferSize > 0 { clauses.append("MAXTRANSFERSIZE = \(options.maxTransferSize)") }
        if options.bufferCount > 0 { clauses.append("BUFFERCOUNT = \(options.bufferCount)") }
        if options.blockSize > 0 { clauses.append("BLOCKSIZE = \(options.blockSize)") }
        if isURL, let region = s3OptionsJSON { clauses.append("BACKUP_OPTIONS = \(SQLIdentifier.literal(region))") }
        clauses.append("STATS = 5")
        return clauses
    }

    var s3OptionsJSON: String? {
        let region = options.s3Region.trimmingCharacters(in: .whitespaces)
        guard options.urlBase.lowercased().hasPrefix("s3://"), !region.isEmpty else { return nil }
        return "{\"s3\": {\"region\":\"\(region)\"}}"
    }

    /// `RESTORE VERIFYONLY`, which checks the backup is complete and readable (and its checksums).
    public func verifyStatement(plan: BackupFilePlan) -> String {
        let device = plan.isURL ? "URL" : "DISK"
        var clauses: [String] = ["FILE = 1"]
        if options.checksum { clauses.append("CHECKSUM") }
        if plan.isURL, let region = s3OptionsJSON {
            clauses.append("RESTORE_OPTIONS = \(SQLIdentifier.literal(region))")
        }
        clauses.append("STATS = 10")
        return "RESTORE VERIFYONLY\n    FROM " + plan.files.map { "\(device) = \(SQLIdentifier.literal($0))" }
            .joined(separator: ",\n         ") + "\n    WITH " + clauses.joined(separator: ", ") + ";"
    }

    // MARK: - Retention

    /// T-SQL that deletes older backup files of one database and type from one folder.
    ///
    /// Candidates come from msdb history rather than a directory listing: only files SQL Server
    /// itself wrote for this database and type, directly in this folder, are touched, and a file
    /// still shared with a backup set that is being kept is left alone. Expressions are T-SQL so
    /// the same text runs inside a job, where the database and folder are only known at run time.
    ///
    /// T-SQL variables live for the whole batch and a table variable declared inside a loop keeps
    /// its rows between iterations, so every name carries `suffix` (unique per use in a batch) and
    /// the tables are emptied before use.
    public static func retentionScript(rule: BackupRetention, type: BackupType, databaseExpression: String,
                                       folderExpression: String, suffix: String = "1") -> String {
        guard rule.isEnabled else { return "" }
        let condition: String
        switch rule.rule {
        case .olderThanDays: condition = "bs.backup_finish_date < DATEADD(DAY, -\(rule.value), GETDATE())"
        case .olderThanHours: condition = "bs.backup_finish_date < DATEADD(HOUR, -\(rule.value), GETDATE())"
        case .keepLatest, .none: condition = "1 = 1"
        }
        let folder = "@r_folder_\(suffix)"
        let sets = "@r_sets_\(suffix)"
        let files = "@r_files_\(suffix)"
        let path = "@r_path_\(suffix)"
        let exists = "@r_exists_\(suffix)"
        let cursor = "r_cursor_\(suffix)"
        var lines: [String] = []
        lines.append("-- Retention: \(rule.summary)")
        lines.append("DECLARE \(folder) nvarchar(4000), \(path) nvarchar(260), \(exists) int;")
        lines.append("DECLARE \(sets) TABLE (id int PRIMARY KEY, finished datetime);")
        lines.append("DECLARE \(files) TABLE (path nvarchar(260) PRIMARY KEY);")
        lines.append("DELETE FROM \(sets); DELETE FROM \(files);")
        lines.append("SET \(folder) = \(folderExpression);")
        lines.append("IF RIGHT(\(folder), 1) NOT IN (N'/', N'\\') SET \(folder) += "
                     + "CASE WHEN CHARINDEX(N'/', \(folder)) > 0 THEN N'/' ELSE N'\\' END;")
        lines.append("INSERT \(sets) (id, finished)")
        lines.append("SELECT bs.backup_set_id, bs.backup_finish_date FROM msdb.dbo.backupset AS bs")
        lines.append("WHERE bs.database_name = \(databaseExpression) AND bs.type = '\(type.historyCode)'")
        lines.append("  AND EXISTS (SELECT 1 FROM msdb.dbo.backupmediafamily AS mf")
        lines.append("              WHERE mf.media_set_id = bs.media_set_id")
        lines.append("                AND LEFT(mf.physical_device_name, LEN(\(folder))) = \(folder)")
        lines.append("                AND CHARINDEX(N'/', STUFF(mf.physical_device_name, 1, LEN(\(folder)), N'')) = 0")
        lines.append("                AND CHARINDEX(N'\\', STUFF(mf.physical_device_name, 1, LEN(\(folder)), N'')) = 0);")
        if rule.rule == .keepLatest {
            lines.append("DELETE FROM \(sets) WHERE id IN (SELECT TOP (\(rule.value)) id FROM \(sets) "
                         + "ORDER BY finished DESC, id DESC);")
        } else {
            lines.append("DELETE FROM \(sets) WHERE id IN (SELECT r.id FROM \(sets) AS r JOIN msdb.dbo.backupset AS bs "
                         + "ON bs.backup_set_id = r.id WHERE NOT (\(condition)));")
        }
        lines.append("INSERT \(files) (path)")
        lines.append("SELECT DISTINCT mf.physical_device_name FROM msdb.dbo.backupmediafamily AS mf")
        lines.append("JOIN msdb.dbo.backupset AS bs ON bs.media_set_id = mf.media_set_id")
        lines.append("WHERE bs.backup_set_id IN (SELECT id FROM \(sets))")
        lines.append("  AND LEFT(mf.physical_device_name, LEN(\(folder))) = \(folder)")
        lines.append("EXCEPT")
        lines.append("SELECT mf.physical_device_name FROM msdb.dbo.backupmediafamily AS mf")
        lines.append("JOIN msdb.dbo.backupset AS bs ON bs.media_set_id = mf.media_set_id")
        lines.append("WHERE bs.backup_set_id NOT IN (SELECT id FROM \(sets));")
        // A failure in an earlier pass of a job's loop can leave the cursor allocated.
        lines.append("IF CURSOR_STATUS('local', N'\(cursor)') >= -1 DEALLOCATE \(cursor);")
        lines.append("DECLARE \(cursor) CURSOR LOCAL FAST_FORWARD FOR SELECT path FROM \(files);")
        lines.append("OPEN \(cursor);")
        lines.append("FETCH NEXT FROM \(cursor) INTO \(path);")
        lines.append("WHILE @@FETCH_STATUS = 0")
        lines.append("BEGIN")
        lines.append("    SET \(exists) = 0;")
        lines.append("    EXEC master.dbo.xp_fileexist \(path), \(exists) OUTPUT;")
        lines.append("    IF \(exists) = 1")
        lines.append("    BEGIN")
        lines.append("        EXEC master.dbo.xp_delete_file 0, \(path);")
        lines.append("        PRINT N'\(deletedFilePrefix)' + \(path);")
        lines.append("    END")
        lines.append("    FETCH NEXT FROM \(cursor) INTO \(path);")
        lines.append("END")
        lines.append("CLOSE \(cursor);")
        lines.append("DEALLOCATE \(cursor);")
        return lines.joined(separator: "\n")
    }

    /// The message retention prints for each deleted file, so callers can list them.
    public static let deletedFilePrefix = "Deleted old backup file "

    // MARK: - Checks

    /// Fails when a file the backup is about to write already exists and overwriting is off.
    public static func existenceCheck(paths: [String]) -> String {
        var lines: [String] = ["DECLARE @x_exists int;"]
        for path in paths {
            lines.append("SET @x_exists = 0;")
            lines.append("EXEC master.dbo.xp_fileexist \(SQLIdentifier.literal(path)), @x_exists OUTPUT;")
            lines.append("IF @x_exists = 1 RAISERROR(N'The backup file %s already exists. Turn on overwriting "
                         + "or include <DATETIME> in the file name.', 16, 1, \(SQLIdentifier.literal(path)));")
        }
        return lines.joined(separator: "\n")
    }
}
