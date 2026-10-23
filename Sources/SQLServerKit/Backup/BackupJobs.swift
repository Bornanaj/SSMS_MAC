import Foundation
import TDSKit

// MARK: - Restore job options

/// The Schedule Restore Jobs wizard: restore the latest backups of a database into a scratch
/// database, check it, and (usually) drop it again — automated backup verification.
public struct RestoreJobOptions: Codable, Hashable, Sendable {
    public enum Source: String, Codable, CaseIterable, Sendable {
        case latestFull
        case latestSet

        public var title: String {
            switch self {
            case .latestFull: return "Latest full backup"
            case .latestSet: return "Latest backup set (full, differential and logs)"
            }
        }
    }

    public var sourceDatabase: String = ""
    public var source: Source = .latestFull
    public var destinationDatabase: String = ""
    public var killConnections: Bool = true
    public var dataFolder: String = ""
    public var logFolder: String = ""
    public var recoveryState: RestoreOptions.RecoveryState = .operational
    public var undoFile: String = ""
    public var checkDB: Bool = true
    public var checkDBOptions: CheckDBOptions = CheckDBOptions()
    public var drop: RestoreOptions.DropPolicy = .onSuccess
    public var orphanCheck: Bool = true
    public var checksum: Bool = true
    public var notification: BackupNotification = BackupNotification()

    public init() {}

    public var effectiveDestination: String {
        let name = destinationDatabase.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "\(sourceDatabase)_Verify" : name
    }
}

// MARK: - Job configuration

/// What a job created by this window does. It is stored, encoded, in a comment at the top of
/// the job step, so the job can be reopened in its wizard and edited later.
public struct BackupJobConfig: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case backup
        case restoreVerification
    }

    public var formatVersion: Int = 1
    public var kind: Kind
    public var backup: BackupOptions?
    public var restore: RestoreJobOptions?
    public var schedules: [BackupSchedule]
    public var defaultFormat: String = BackupOptions.defaultFileNameFormat

    public init(backup: BackupOptions, schedules: [BackupSchedule],
                defaultFormat: String = BackupOptions.defaultFileNameFormat) {
        kind = .backup
        self.backup = backup
        self.restore = nil
        self.schedules = schedules
        self.defaultFormat = defaultFormat
    }

    public init(restore: RestoreJobOptions, schedules: [BackupSchedule]) {
        kind = .restoreVerification
        self.backup = nil
        self.restore = restore
        self.schedules = schedules
    }

    static let marker = "SSMSMAC-BACKUP-CONFIG:"

    /// The comment line that carries the configuration.
    public func comment() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = (try? encoder.encode(self)) ?? Data()
        return "/* \(Self.marker)\(data.base64EncodedString()) */"
    }

    public static func parse(fromCommand command: String) -> BackupJobConfig? {
        guard let start = command.range(of: marker) else { return nil }
        let rest = command[start.upperBound...]
        guard let end = rest.range(of: " */") else { return nil }
        guard let data = Data(base64Encoded: String(rest[..<end.lowerBound])) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(BackupJobConfig.self, from: data)
    }

    /// The Agent job name, which also tells the time line which database a failure belongs to.
    public var jobName: String {
        switch kind {
        case .backup:
            let options = backup ?? BackupOptions()
            let type = options.copyOnly ? "\(options.type.tag) (copy-only)" : options.type.tag
            return String("SQL Backup - \(type) - \(options.databases.summary)".prefix(128))
        case .restoreVerification:
            let options = restore ?? RestoreJobOptions()
            return String("SQL Backup - Verify - \(options.sourceDatabase) as \(options.effectiveDestination)".prefix(128))
        }
    }
}

// MARK: - Job step T-SQL

/// Generates the T-SQL of job steps. Everything that depends on the run (date, database list,
/// file names) is computed inside the step; everything else is fixed when the job is created.
public enum BackupJobScripts {

    /// The step of a scheduled backup job.
    public static func backupStep(_ options: BackupOptions, capabilities: BackupServerCapabilities,
                                  defaultFormat: String, schedules: [BackupSchedule] = []) -> String {
        let config = BackupJobConfig(backup: options, schedules: schedules, defaultFormat: defaultFormat)
        let scripter = BackupScripter(options: options, capabilities: capabilities, defaultFormat: defaultFormat)
        let hadr = capabilities.isHadrEnabled && capabilities.majorVersion >= 11
        let isURL = options.destination == .url
        let stripes = options.layout == .split ? max(2, min(64, options.fileCount)) : 1
        let delaySeconds = max(1, min(86_399, options.retryIntervalSeconds))
        let delay = String(format: "%02d:%02d:%02d", delaySeconds / 3600, (delaySeconds / 60) % 60, delaySeconds % 60)
        let verb = options.type == .log ? "LOG" : "DATABASE"
        var s: [String] = []
        s.append(config.comment())
        s.append("-- Created by SSMS for Mac (SQL Backup). Edit this job from the SQL Backup window.")
        s.append("SET NOCOUNT ON;")
        s.append("DECLARE @type_tag nvarchar(10) = N'\(options.type.tag)';")
        s.append("DECLARE @instance sysname = ISNULL(CAST(SERVERPROPERTY('InstanceName') AS sysname), N'(local)');")
        s.append("DECLARE @server sysname = CAST(SERVERPROPERTY('MachineName') AS sysname);")
        s.append("DECLARE @separator nchar(1) = N'\(capabilities.pathSeparator)';")
        s.append("DECLARE @retries int = \(max(0, options.retryCount)), @retry_delay char(8) = '\(delay)';")
        s.append("DECLARE @db sysname, @ag sysname, @started datetime2, @folder nvarchar(4000), @dir nvarchar(4000),")
        s.append("        @base nvarchar(4000), @path nvarchar(4000), @files nvarchar(max), @mirror nvarchar(max),")
        s.append("        @sql nvarchar(max), @verify nvarchar(max), @exists int, @attempt int, @done bit, @skip bit,")
        s.append("        @copy_only nvarchar(20), @state nvarchar(60), @recovery int;")
        for index in options.mirrorFolders.indices.prefix(3) {
            s.append("DECLARE @mirror_folder_\(index) nvarchar(4000), @mirror_files_\(index) nvarchar(max);")
        }
        s.append("DECLARE @errors nvarchar(max) = N'', @warnings nvarchar(max) = N'', @report nvarchar(max) = N'';")
        s.append("DECLARE @dbs TABLE (ord int IDENTITY(1, 1), name sysname);")
        s.append(selectionInsert(options))
        s.append("DECLARE db_cursor CURSOR LOCAL FAST_FORWARD FOR SELECT name FROM @dbs ORDER BY ord;")
        s.append("OPEN db_cursor;")
        s.append("FETCH NEXT FROM db_cursor INTO @db;")
        s.append("WHILE @@FETCH_STATUS = 0")
        s.append("BEGIN")
        s.append("    SET @skip = 0; SET @state = NULL; SET @recovery = NULL;")
        s.append("    BEGIN TRY")
        s.append("        SELECT @state = d.state_desc, @recovery = d.recovery_model FROM sys.databases AS d WHERE d.name = @db;")
        s.append("        IF @state IS NULL RAISERROR(N'The database does not exist.', 16, 1);")
        s.append("        IF @state <> N'ONLINE' RAISERROR(N'The database is %s.', 16, 1, @state);")
        switch options.type {
        case .log:
            s.append("        IF @recovery = 3 RAISERROR(N'The database uses the simple recovery model, so its log cannot be backed up.', 16, 1);")
            s.append("        IF (SELECT last_log_backup_lsn FROM sys.database_recovery_status WHERE database_id = DB_ID(@db)) IS NULL")
            s.append("            RAISERROR(N'There is no full backup yet, so the log chain has not started.', 16, 1);")
        case .differential:
            s.append("        IF NOT EXISTS (SELECT 1 FROM sys.master_files WHERE database_id = DB_ID(@db) AND file_id = 1")
            s.append("                       AND differential_base_lsn IS NOT NULL)")
            s.append("            RAISERROR(N'There is no full backup to base a differential on.', 16, 1);")
        case .full:
            break
        }
        if hadr && options.checkPreferredReplica {
            s.append("        IF sys.fn_hadr_backup_is_preferred_replica(@db) = 0")
            s.append("        BEGIN")
            s.append("            SET @skip = 1;")
            s.append("            SET @report += @db + N': skipped, not the preferred backup replica' + NCHAR(10);")
            s.append("        END")
        }
        s.append("        IF @skip = 0")
        s.append("        BEGIN")
        s.append("            SET @started = SYSDATETIME();")
        if hadr {
            s.append("            SET @ag = (SELECT TOP (1) ag.name FROM sys.availability_databases_cluster AS adc")
            s.append("                       JOIN sys.availability_groups AS ag ON ag.group_id = adc.group_id")
            s.append("                       WHERE adc.database_name = @db);")
        }
        s.append("            SET @ag = ISNULL(@ag, N'');")
        s.append("            SET @copy_only = N'\(options.copyOnly && options.type != .differential ? ", COPY_ONLY" : "")';")
        if hadr && options.secondaryReplicaCopyOnly && options.type == .full && capabilities.majorVersion >= 12 {
            s.append("            IF ISNULL(sys.fn_hadr_is_primary_replica(@db), 1) = 0 SET @copy_only = N', COPY_ONLY';")
        }
        let nameExpression = BackupFileNaming.sqlExpression(options.effectiveFileNameFormat, defaultFormat: defaultFormat)
        s.append("            SET @base = \(nameExpression);")
        s.append("            SET @files = N''; SET @mirror = N'';")
        if isURL {
            let urlExpression = BackupFileNaming.sqlExpression(options.urlBase.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")),
                                                               defaultFormat: defaultFormat)
            s.append("            SET @dir = \(urlExpression) + N'/';")
            s.append("            SET @folder = @dir;")
            appendStripes(&s, stripes: stripes, ext: options.type.fileExtension, device: "URL", directory: "@dir",
                          target: "@files", checkExists: false)
        } else {
            let folderExpression = BackupFileNaming.sqlExpression(scripter.folderTemplate, defaultFormat: defaultFormat)
            s.append("            SET @folder = \(folderExpression);")
            s.append("            EXEC master.dbo.xp_create_subdir @folder;")
            s.append("            SET @dir = CASE WHEN RIGHT(@folder, 1) IN (N'/', N'\\') THEN @folder ELSE @folder + @separator END;")
            appendStripes(&s, stripes: stripes, ext: options.type.fileExtension, device: "DISK", directory: "@dir",
                          target: "@files", checkExists: !options.overwrite)
            if options.layout == .mirrored {
                for (index, template) in options.mirrorFolders.prefix(3).enumerated()
                where !template.trimmingCharacters(in: .whitespaces).isEmpty {
                    let expression = BackupFileNaming.sqlExpression(template, defaultFormat: defaultFormat)
                    s.append("            SET @mirror_folder_\(index) = \(expression);")
                    s.append("            EXEC master.dbo.xp_create_subdir @mirror_folder_\(index);")
                    s.append("            SET @dir = CASE WHEN RIGHT(@mirror_folder_\(index), 1) IN (N'/', N'\\') "
                             + "THEN @mirror_folder_\(index) ELSE @mirror_folder_\(index) + @separator END;")
                    s.append("            SET @mirror_files_\(index) = N'';")
                    appendStripes(&s, stripes: stripes, ext: options.type.fileExtension, device: "DISK", directory: "@dir",
                                  target: "@mirror_files_\(index)", checkExists: !options.overwrite)
                    s.append("            SET @mirror += N' MIRROR TO ' + @mirror_files_\(index);")
                }
            }
        }
        let clauses = scripter.withClauses(copyOnly: false, name: nil, description: nil, isURL: isURL)
        var named = ""
        if !options.backupName.isEmpty {
            let expression = BackupFileNaming.sqlExpression(options.backupName, defaultFormat: defaultFormat)
            named += " + N', NAME = N''' + REPLACE(LEFT(\(expression), 128), N'''', N'''''') + N''''"
        }
        if !options.backupDescription.isEmpty {
            let expression = BackupFileNaming.sqlExpression(options.backupDescription, defaultFormat: defaultFormat)
            named += " + N', DESCRIPTION = N''' + REPLACE(LEFT(\(expression), 255), N'''', N'''''') + N''''"
        }
        s.append("            SET @sql = N'BACKUP \(verb) ' + QUOTENAME(@db) + N' TO ' + @files + @mirror + N' WITH ' + "
                 + "\(SQLIdentifier.literal(clauses.joined(separator: ", "))) + @copy_only\(named);")
        var verifyClauses = "FILE = 1"
        if options.checksum { verifyClauses += ", CHECKSUM" }
        if isURL, let region = scripter.s3OptionsJSON {
            verifyClauses += ", RESTORE_OPTIONS = " + SQLIdentifier.literal(region)
        }
        s.append("            SET @verify = N'RESTORE VERIFYONLY FROM ' + @files + N' WITH ' + \(SQLIdentifier.literal(verifyClauses));")
        if options.retention.isEnabled && options.retention.beforeBackup && !isURL {
            appendGuarded(&s, retention(options.retention, options.type, folder: "@folder", suffix: "p"),
                          warning: "old files could not be deleted")
        }
        s.append("            SET @attempt = 0; SET @done = 0;")
        s.append("            WHILE @done = 0")
        s.append("            BEGIN")
        s.append("                SET @attempt += 1;")
        s.append("                BEGIN TRY")
        s.append("                    EXEC (@sql);")
        s.append("                    SET @done = 1;")
        s.append("                END TRY")
        s.append("                BEGIN CATCH")
        s.append("                    IF @attempt > @retries THROW;")
        s.append("                    SET @warnings += @db + N': attempt ' + CAST(@attempt AS nvarchar(10)) + N' failed ('")
        s.append("                        + ERROR_MESSAGE() + N'); retrying.' + NCHAR(10);")
        s.append("                    WAITFOR DELAY @retry_delay;")
        s.append("                END CATCH")
        s.append("            END")
        s.append("            SET @report += @db + N': backed up in ' + CAST(DATEDIFF(SECOND, @started, SYSDATETIME()) AS nvarchar(20))")
        s.append("                + N' s to ' + @files + NCHAR(10);")
        if options.verify {
            s.append("            BEGIN TRY")
            s.append("                EXEC (@verify);")
            s.append("                SET @report += N'    verified' + NCHAR(10);")
            s.append("            END TRY")
            s.append("            BEGIN CATCH")
            s.append("                SET @warnings += @db + N': the backup was created but failed verification: ' + ERROR_MESSAGE() + NCHAR(10);")
            s.append("            END CATCH")
        }
        if options.retention.isEnabled && !options.retention.beforeBackup && !isURL {
            appendGuarded(&s, retention(options.retention, options.type, folder: "@folder", suffix: "p"),
                          warning: "old files could not be deleted")
        }
        if options.mirrorRetention.isEnabled && options.layout == .mirrored && !isURL {
            for index in options.mirrorFolders.indices.prefix(3)
            where !options.mirrorFolders[index].trimmingCharacters(in: .whitespaces).isEmpty {
                appendGuarded(&s, retention(options.mirrorRetention, options.type, folder: "@mirror_folder_\(index)",
                                            suffix: "m\(index)"),
                              warning: "old mirror files could not be deleted")
            }
        }
        s.append("        END")
        s.append("    END TRY")
        s.append("    BEGIN CATCH")
        s.append("        SET @errors += @db + N': ' + ERROR_MESSAGE() + NCHAR(10);")
        s.append("    END CATCH")
        s.append("    FETCH NEXT FROM db_cursor INTO @db;")
        s.append("END")
        s.append("CLOSE db_cursor;")
        s.append("DEALLOCATE db_cursor;")
        s.append("PRINT @report;")
        s.append("IF @warnings <> N'' PRINT N'Warnings:' + NCHAR(10) + @warnings;")
        appendMail(&s, notification: options.notification,
                   subject: "N'\(options.type.title) backup on ' + @server + N' '")
        s.append("IF @errors <> N'' RAISERROR(N'The backup failed: %s', 16, 1, @errors);")
        return s.joined(separator: "\n")
    }

    /// `INSERT @dbs` for the selection: the named databases, or a query for a scope.
    static func selectionInsert(_ options: BackupOptions) -> String {
        let selection = options.databases
        if selection.scope == .selected {
            let values = selection.names.map { "(\(SQLIdentifier.literal($0)))" }.joined(separator: ", ")
            return values.isEmpty ? "-- No databases selected." : "INSERT @dbs (name) VALUES \(values);"
        }
        var conditions: [String] = ["d.database_id <> 2", "d.source_database_id IS NULL", "d.state = 0"]
        switch selection.scope {
        case .user: conditions.append("d.database_id > 4")
        case .system: conditions.append("d.database_id IN (1, 3, 4)")
        case .all, .selected: break
        }
        if !selection.excluded.isEmpty {
            conditions.append("d.name NOT IN (" + selection.excluded.map(SQLIdentifier.literal).joined(separator: ", ") + ")")
        }
        // Scopes leave out databases the type does not apply to, as SQL Backup does.
        switch options.type {
        case .log:
            conditions.append("d.recovery_model <> 3")
            conditions.append("d.database_id <> 1")
            conditions.append("EXISTS (SELECT 1 FROM sys.database_recovery_status AS r WHERE r.database_id = d.database_id "
                              + "AND r.last_log_backup_lsn IS NOT NULL)")
        case .differential:
            conditions.append("d.database_id <> 1")
            conditions.append("EXISTS (SELECT 1 FROM sys.master_files AS f WHERE f.database_id = d.database_id "
                              + "AND f.file_id = 1 AND f.differential_base_lsn IS NOT NULL)")
        case .full:
            break
        }
        return "INSERT @dbs (name) SELECT d.name FROM sys.databases AS d WHERE "
            + conditions.joined(separator: " AND ") + " ORDER BY d.name;"
    }

    static func appendStripes(_ s: inout [String], stripes: Int, ext: String, device: String, directory: String,
                              target: String, checkExists: Bool) {
        for stripe in 1...stripes {
            let suffix = stripes > 1 ? "_\(stripe)of\(stripes)" : ""
            s.append("            SET @path = \(directory) + @base + N'\(suffix).\(ext)';")
            if checkExists {
                s.append("            SET @exists = 0; EXEC master.dbo.xp_fileexist @path, @exists OUTPUT;")
                s.append("            IF @exists = 1 RAISERROR(N'The backup file %s already exists. Turn on overwriting or "
                         + "include <DATETIME> in the file name.', 16, 1, @path);")
            }
            s.append("            SET \(target) += CASE WHEN \(target) = N'' THEN N'' ELSE N', ' END + N'\(device) = N''' "
                     + "+ REPLACE(@path, N'''', N'''''') + N'''';")
        }
    }

    static func retention(_ rule: BackupRetention, _ type: BackupType, folder: String, suffix: String) -> String {
        BackupScripter.retentionScript(rule: rule, type: type, databaseExpression: "@db", folderExpression: folder,
                                       suffix: suffix)
    }

    /// Wraps clean-up work so its failure is a warning, not a failed backup.
    static func appendGuarded(_ s: inout [String], _ script: String, warning: String) {
        s.append("            BEGIN TRY")
        for line in script.split(separator: "\n", omittingEmptySubsequences: false) {
            s.append("                " + line)
        }
        s.append("            END TRY")
        s.append("            BEGIN CATCH")
        s.append("                SET @warnings += @db + N': \(warning): ' + ERROR_MESSAGE() + NCHAR(10);")
        s.append("            END CATCH")
    }

    /// Emails through Database Mail at the level chosen, with errors and warnings in the body:
    /// the "error or warning" level native Agent notifications do not have.
    static func appendMail(_ s: inout [String], notification: BackupNotification, subject: String) {
        guard notification.isEnabled else { return }
        let condition: String
        switch notification.level {
        case .never: return
        case .errorOnly: condition = "@errors <> N''"
        case .errorOrWarning: condition = "@errors <> N'' OR @warnings <> N''"
        case .always: condition = "1 = 1"
        }
        s.append("IF \(condition)")
        s.append("BEGIN")
        s.append("    DECLARE @mail_subject nvarchar(255) = \(subject)")
        s.append("        + CASE WHEN @errors <> N'' THEN N'FAILED' WHEN @warnings <> N'' THEN N'completed with warnings' "
                 + "ELSE N'succeeded' END;")
        s.append("    DECLARE @mail_body nvarchar(max) = @report")
        s.append("        + CASE WHEN @errors <> N'' THEN NCHAR(10) + N'Errors:' + NCHAR(10) + @errors ELSE N'' END")
        s.append("        + CASE WHEN @warnings <> N'' THEN NCHAR(10) + N'Warnings:' + NCHAR(10) + @warnings ELSE N'' END;")
        var arguments: [String] = []
        if !notification.mailProfile.isEmpty {
            arguments.append("@profile_name = \(SQLIdentifier.literal(notification.mailProfile))")
        }
        arguments.append("@recipients = \(SQLIdentifier.literal(notification.recipients))")
        arguments.append("@subject = @mail_subject")
        arguments.append("@body = @mail_body")
        s.append("    BEGIN TRY")
        s.append("        EXEC msdb.dbo.sp_send_dbmail " + arguments.joined(separator: ", ") + ";")
        s.append("    END TRY")
        s.append("    BEGIN CATCH")
        s.append("        PRINT N'The notification email could not be sent: ' + ERROR_MESSAGE();")
        s.append("    END CATCH")
        s.append("END")
    }

    // MARK: Restore verification

    /// The step of a scheduled restore (backup verification) job. It reads the backups from this
    /// server's msdb, so it verifies backups taken on the same instance.
    public static func restoreStep(_ options: RestoreJobOptions, capabilities: BackupServerCapabilities,
                                   schedules: [BackupSchedule] = []) -> String {
        let config = BackupJobConfig(restore: options, schedules: schedules)
        let dataFolder = options.dataFolder.isEmpty ? capabilities.defaultDataFolder : options.dataFolder
        let logFolder = options.logFolder.isEmpty ? capabilities.defaultLogFolder : options.logFolder
        let separator = capabilities.pathSeparator
        let undo = options.undoFile.isEmpty
            ? capabilities.join(capabilities.backupFolder, "UNDO_\(options.effectiveDestination).dat") : options.undoFile
        var s: [String] = []
        s.append(config.comment())
        s.append("-- Created by SSMS for Mac (SQL Backup): restores the latest backups of a database and checks them.")
        s.append("SET NOCOUNT ON;")
        s.append("DECLARE @source sysname = \(SQLIdentifier.literal(options.sourceDatabase));")
        s.append("DECLARE @target sysname = \(SQLIdentifier.literal(options.effectiveDestination));")
        s.append("DECLARE @server sysname = CAST(SERVERPROPERTY('MachineName') AS sysname);")
        s.append("DECLARE @data_folder nvarchar(4000) = \(SQLIdentifier.literal(dataFolder));")
        s.append("DECLARE @log_folder nvarchar(4000) = \(SQLIdentifier.literal(logFolder));")
        s.append("DECLARE @separator nchar(1) = N'\(separator)';")
        s.append("DECLARE @full int, @diff int, @log int, @base int, @last numeric(25, 0), @next numeric(25, 0),")
        s.append("        @sql nvarchar(max), @moves nvarchar(max), @files nvarchar(max), @ok bit = 0, @checked bit = 1,")
        s.append("        @errors nvarchar(max) = N'', @warnings nvarchar(max) = N'', @report nvarchar(max) = N'',")
        s.append("        @position int, @logs int = 0;")
        s.append("IF RIGHT(@data_folder, 1) NOT IN (N'/', N'\\') SET @data_folder += @separator;")
        s.append("IF RIGHT(@log_folder, 1) NOT IN (N'/', N'\\') SET @log_folder += @separator;")
        s.append("BEGIN TRY")
        s.append("    IF @target IN (N'master', N'model', N'msdb', N'tempdb') OR @target = @source")
        s.append("        RAISERROR(N'The verification database must be a different, user database.', 16, 1);")
        s.append("    SELECT TOP (1) @full = backup_set_id FROM msdb.dbo.backupset")
        s.append("    WHERE database_name = @source AND type = 'D' AND is_damaged = 0 ORDER BY backup_finish_date DESC;")
        s.append("    IF @full IS NULL RAISERROR(N'There is no full backup of %s in the backup history.', 16, 1, @source);")
        if options.source == .latestSet {
            s.append("    SELECT TOP (1) @diff = d.backup_set_id FROM msdb.dbo.backupset AS d")
            s.append("    WHERE d.database_name = @source AND d.type = 'I' AND d.is_damaged = 0")
            s.append("      AND d.database_backup_lsn = (SELECT checkpoint_lsn FROM msdb.dbo.backupset WHERE backup_set_id = @full)")
            s.append("    ORDER BY d.backup_finish_date DESC;")
        }
        s.append("    SET @moves = N'';")
        s.append("    SELECT @moves += N', MOVE N''' + REPLACE(bf.logical_name, N'''', N'''''') + N''' TO N'''")
        s.append("        + REPLACE(CASE WHEN bf.file_type = N'L' THEN @log_folder ELSE @data_folder END + @target + N'_'")
        s.append("        + CAST(bf.file_number AS nvarchar(10)) + CASE bf.file_type WHEN N'L' THEN N'.ldf' WHEN N'F' THEN N''")
        s.append("        ELSE CASE WHEN bf.file_number = 1 THEN N'.mdf' ELSE N'.ndf' END END, N'''', N'''''') + N''''")
        s.append("    FROM msdb.dbo.backupfile AS bf WHERE bf.backup_set_id = @full AND bf.is_present = 1 ORDER BY bf.file_number;")
        if options.killConnections {
            s.append("    IF DB_ID(@target) IS NOT NULL AND DATABASEPROPERTYEX(@target, 'Status') = 'ONLINE'")
            s.append("    BEGIN")
            s.append("        SET @sql = N'ALTER DATABASE ' + QUOTENAME(@target) + N' SET SINGLE_USER WITH ROLLBACK IMMEDIATE';")
            s.append("        EXEC (@sql);")
            s.append("    END")
        }
        let checksum = options.checksum ? ", CHECKSUM" : ""
        s.append("    SET @base = @full;")
        s.append("    WHILE @base IS NOT NULL")
        s.append("    BEGIN")
        s.append("        SET @files = N'';")
        s.append("        SELECT @files += CASE WHEN @files = N'' THEN N'' ELSE N', ' END")
        s.append("            + CASE WHEN mf.device_type = 9 THEN N'URL' ELSE N'DISK' END + N' = N'''")
        s.append("            + REPLACE(mf.physical_device_name, N'''', N'''''') + N''''")
        s.append("        FROM msdb.dbo.backupmediafamily AS mf JOIN msdb.dbo.backupset AS bs ON bs.media_set_id = mf.media_set_id")
        s.append("        WHERE bs.backup_set_id = @base AND mf.mirror = 0 ORDER BY mf.family_sequence_number;")
        s.append("        SELECT @position = position, @last = last_lsn FROM msdb.dbo.backupset WHERE backup_set_id = @base;")
        s.append("        IF @base = @full")
        s.append("            SET @sql = N'RESTORE DATABASE ' + QUOTENAME(@target) + N' FROM ' + @files + N' WITH FILE = '")
        s.append("                + CAST(@position AS nvarchar(10)) + @moves + N', REPLACE, NORECOVERY\(checksum), STATS = 10';")
        s.append("        ELSE IF @base = @diff")
        s.append("            SET @sql = N'RESTORE DATABASE ' + QUOTENAME(@target) + N' FROM ' + @files + N' WITH FILE = '")
        s.append("                + CAST(@position AS nvarchar(10)) + N', NORECOVERY\(checksum), STATS = 10';")
        s.append("        ELSE")
        s.append("        BEGIN")
        s.append("            SET @sql = N'RESTORE LOG ' + QUOTENAME(@target) + N' FROM ' + @files + N' WITH FILE = '")
        s.append("                + CAST(@position AS nvarchar(10)) + N', NORECOVERY\(checksum)';")
        s.append("            SET @logs += 1;")
        s.append("        END")
        s.append("        EXEC (@sql);")
        if options.source == .latestSet {
            s.append("        IF @base = @full AND @diff IS NOT NULL")
            s.append("            SET @base = @diff;")
            s.append("        ELSE")
            s.append("        BEGIN")
            s.append("            SET @log = NULL;")
            s.append("            SELECT TOP (1) @log = backup_set_id FROM msdb.dbo.backupset")
            s.append("            WHERE database_name = @source AND type = 'L' AND is_copy_only = 0 AND is_damaged = 0")
            s.append("              AND first_lsn <= @last AND last_lsn > @last ORDER BY last_lsn;")
            s.append("            SET @base = @log;")
            s.append("        END")
        } else {
            s.append("        SET @base = NULL;")
        }
        s.append("    END")
        switch options.recoveryState {
        case .operational:
            s.append("    SET @sql = N'RESTORE DATABASE ' + QUOTENAME(@target) + N' WITH RECOVERY';")
        case .readOnly:
            s.append("    SET @sql = N'RESTORE DATABASE ' + QUOTENAME(@target) + N' WITH STANDBY = N'''")
            s.append("        + REPLACE(\(SQLIdentifier.literal(undo)), N'''', N'''''') + N'''';")
        case .nonOperational:
            s.append("    SET @sql = N'';")
        }
        s.append("    IF @sql <> N'' EXEC (@sql);")
        s.append("    SET @report += N'Restored ' + @source + N' as ' + @target + N' from its full backup'")
        s.append("        + CASE WHEN @diff IS NOT NULL THEN N', a differential' ELSE N'' END")
        s.append("        + CASE WHEN @logs > 0 THEN N' and ' + CAST(@logs AS nvarchar(10)) + N' log backup(s)' ELSE N'' END + NCHAR(10);")
        s.append("    SET @ok = 1;")
        s.append("END TRY")
        s.append("BEGIN CATCH")
        s.append("    SET @errors += N'Restore: ' + ERROR_MESSAGE() + NCHAR(10);")
        s.append("END CATCH")
        let usable = options.recoveryState != .nonOperational
        if usable && options.checkDB {
            s.append("IF @ok = 1")
            s.append("BEGIN TRY")
            s.append("    SET @sql = N'DBCC CHECKDB (' + QUOTENAME(@target) + N')\(options.checkDBOptions.withClause)';")
            s.append("    EXEC (@sql);")
            s.append("    SET @report += N'DBCC CHECKDB found no errors.' + NCHAR(10);")
            s.append("END TRY")
            s.append("BEGIN CATCH")
            s.append("    SET @checked = 0;")
            s.append("    SET @errors += N'DBCC CHECKDB: ' + ERROR_MESSAGE() + NCHAR(10);")
            s.append("END CATCH")
        }
        if usable && options.orphanCheck {
            let authentication = capabilities.majorVersion >= 11 ? " AND dp.authentication_type = 1" : ""
            s.append("IF @ok = 1")
            s.append("BEGIN TRY")
            s.append("    DECLARE @orphans nvarchar(max) = N'';")
            s.append("    SET @sql = N'SELECT @o += dp.name + N'' '' FROM ' + QUOTENAME(@target) + N'.sys.database_principals AS dp")
            s.append("        LEFT JOIN sys.server_principals AS sp ON sp.sid = dp.sid")
            s.append("        WHERE dp.type = ''S'' AND dp.principal_id > 4 AND sp.sid IS NULL\(authentication.replacingOccurrences(of: "'", with: "''"))")
            s.append("        AND dp.name NOT IN (N''guest'', N''INFORMATION_SCHEMA'', N''sys'', N''dbo'')';")
            s.append("    EXEC sp_executesql @sql, N'@o nvarchar(max) OUTPUT', @o = @orphans OUTPUT;")
            s.append("    IF @orphans <> N'' SET @warnings += N'Orphaned users (no matching login): ' + @orphans + NCHAR(10);")
            s.append("END TRY")
            s.append("BEGIN CATCH")
            s.append("    SET @warnings += N'The orphaned-user check failed: ' + ERROR_MESSAGE() + NCHAR(10);")
            s.append("END CATCH")
        }
        switch options.drop {
        case .never:
            break
        case .always, .onSuccess:
            let condition = options.drop == .always ? "DB_ID(@target) IS NOT NULL"
                : "@ok = 1 AND @checked = 1 AND @errors = N'' AND DB_ID(@target) IS NOT NULL"
            s.append("IF \(condition)")
            s.append("BEGIN TRY")
            s.append("    SET @sql = N'ALTER DATABASE ' + QUOTENAME(@target) + N' SET SINGLE_USER WITH ROLLBACK IMMEDIATE; '")
            s.append("        + N'DROP DATABASE ' + QUOTENAME(@target);")
            s.append("    IF DATABASEPROPERTYEX(@target, 'Status') <> 'ONLINE' SET @sql = N'DROP DATABASE ' + QUOTENAME(@target);")
            s.append("    EXEC (@sql);")
            s.append("    SET @report += N'Dropped ' + @target + NCHAR(10);")
            s.append("END TRY")
            s.append("BEGIN CATCH")
            s.append("    SET @warnings += N'The verification database could not be dropped: ' + ERROR_MESSAGE() + NCHAR(10);")
            s.append("END CATCH")
        }
        s.append("PRINT @report;")
        s.append("IF @warnings <> N'' PRINT N'Warnings:' + NCHAR(10) + @warnings;")
        appendMail(&s, notification: options.notification,
                   subject: "N'Restore verification of \(options.sourceDatabase.replacingOccurrences(of: "'", with: "''")) on ' + @server + N' '")
        s.append("IF @errors <> N'' RAISERROR(N'The restore verification failed: %s', 16, 1, @errors);")
        return s.joined(separator: "\n")
    }

    // MARK: Agent job

    /// Creates the job, its step and its schedules in one transaction.
    public static func createJobScript(name: String, description: String, category: String, command: String,
                                       schedules: [BackupSchedule], enabled: Bool = true) -> String {
        var s: [String] = []
        s.append("SET XACT_ABORT ON;")
        s.append("BEGIN TRANSACTION;")
        s.append("IF NOT EXISTS (SELECT 1 FROM msdb.dbo.syscategories WHERE name = \(SQLIdentifier.literal(category)) AND category_class = 1)")
        s.append("    EXEC msdb.dbo.sp_add_category @class = N'JOB', @type = N'LOCAL', @name = \(SQLIdentifier.literal(category));")
        s.append("DECLARE @job_id uniqueidentifier, @schedule_id int;")
        s.append("EXEC msdb.dbo.sp_add_job @job_name = \(SQLIdentifier.literal(name)), @enabled = \(enabled ? 1 : 0),")
        s.append("     @description = \(SQLIdentifier.literal(String(description.prefix(512)))),")
        s.append("     @category_name = \(SQLIdentifier.literal(category)), @job_id = @job_id OUTPUT;")
        s.append("EXEC msdb.dbo.sp_add_jobstep @job_id = @job_id, @step_name = N'Run', @subsystem = N'TSQL',")
        s.append("     @database_name = N'master', @command = \(SQLIdentifier.literal(command)),")
        s.append("     @on_success_action = 1, @on_fail_action = 2, @flags = 8;")
        appendSchedules(&s, schedules: schedules, jobName: name)
        s.append("EXEC msdb.dbo.sp_add_jobserver @job_id = @job_id, @server_name = N'(local)';")
        s.append("COMMIT TRANSACTION;")
        return s.joined(separator: "\n")
    }

    /// Rewrites an existing job's step and schedules, keeping its history.
    public static func updateJobScript(jobID: String, name: String, description: String, command: String,
                                       schedules: [BackupSchedule]) -> String {
        var s: [String] = []
        s.append("SET XACT_ABORT ON;")
        s.append("BEGIN TRANSACTION;")
        s.append("DECLARE @job_id uniqueidentifier = \(SQLIdentifier.literal(jobID)), @schedule_id int;")
        s.append("EXEC msdb.dbo.sp_update_job @job_id = @job_id, @new_name = \(SQLIdentifier.literal(name)),")
        s.append("     @description = \(SQLIdentifier.literal(String(description.prefix(512))));")
        s.append("EXEC msdb.dbo.sp_update_jobstep @job_id = @job_id, @step_id = 1, @command = \(SQLIdentifier.literal(command));")
        s.append("DECLARE @old TABLE (schedule_id int PRIMARY KEY);")
        s.append("INSERT @old SELECT schedule_id FROM msdb.dbo.sysjobschedules WHERE job_id = @job_id;")
        s.append("WHILE EXISTS (SELECT 1 FROM @old)")
        s.append("BEGIN")
        s.append("    SELECT TOP (1) @schedule_id = schedule_id FROM @old;")
        s.append("    EXEC msdb.dbo.sp_detach_schedule @job_id = @job_id, @schedule_id = @schedule_id, @delete_unused_schedule = 1;")
        s.append("    DELETE FROM @old WHERE schedule_id = @schedule_id;")
        s.append("END")
        appendSchedules(&s, schedules: schedules, jobName: name)
        s.append("COMMIT TRANSACTION;")
        return s.joined(separator: "\n")
    }

    static func appendSchedules(_ s: inout [String], schedules: [BackupSchedule], jobName: String) {
        for (index, schedule) in schedules.enumerated() {
            let name = schedule.name.isEmpty ? "\(jobName) (\(index + 1))" : "\(jobName): \(schedule.name)"
            s.append("EXEC msdb.dbo.sp_add_schedule @schedule_name = \(SQLIdentifier.literal(String(name.prefix(128)))),")
            s.append("     " + schedule.agentArguments.joined(separator: ", ") + ", @schedule_id = @schedule_id OUTPUT;")
            s.append("EXEC msdb.dbo.sp_attach_schedule @job_id = @job_id, @schedule_id = @schedule_id;")
        }
    }
}

// MARK: - Job manager

/// A backup-related Agent job, as the Jobs tab lists it.
public struct BackupJobInfo: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var isEnabled: Bool
    public var category: String
    public var jobDescription: String
    public var owner: String
    public var command: String
    public var config: BackupJobConfig?
    public var schedules: [BackupSchedule]
    public var nextRun: Date?
    public var lastRun: Date?
    public var lastOutcome: String
    public var lastMessage: String
    public var averageDuration: TimeInterval?
    public var isRunning: Bool

    public var isManaged: Bool { config != nil }

    public var kindTitle: String {
        if let config {
            switch config.kind {
            case .backup: return "\(config.backup?.type.title ?? "") backup"
            case .restoreVerification: return "Restore verification"
            }
        }
        if category == "Log Shipping" { return "Log shipping" }
        return "Other backup job"
    }

    public var databases: String {
        if let config {
            switch config.kind {
            case .backup: return config.backup?.databases.summary ?? ""
            case .restoreVerification: return config.restore?.sourceDatabase ?? ""
            }
        }
        return BackupJobManager.databaseHint(jobName: name)
    }

    public var scheduleSummary: String {
        schedules.isEmpty ? "Not scheduled" : schedules.map(\.summary).joined(separator: "; ")
    }

    /// Agent refreshes its own next-run column only every twenty minutes or so, so new jobs show
    /// none; the schedules themselves say when the job runs next.
    public func nextRun(after now: Date) -> Date? {
        guard isEnabled else { return nil }
        let horizon = now.addingTimeInterval(62 * 86_400)
        let computed = schedules.compactMap { $0.occurrences(from: now, to: horizon, limit: 1).first }.min()
        if let stored = nextRun, stored > now { return min(stored, computed ?? stored) }
        return computed
    }
}

public struct BackupJobManager: Sendable {
    public static let backupCategory = "SQL Backup (SSMS for Mac)"
    public static let restoreCategory = "SQL Backup Verification (SSMS for Mac)"

    private let session: SQLServerSession

    public init(session: SQLServerSession) {
        self.session = session
    }

    /// The database part of a job name ("SQL Backup - FULL - Sales" → "Sales").
    public static func databaseHint(jobName: String) -> String {
        if jobName.hasPrefix("LSBackup_") { return String(jobName.dropFirst("LSBackup_".count)) }
        if jobName.hasPrefix("LSRestore_") { return String(jobName.dropFirst("LSRestore_".count)) }
        guard jobName.hasPrefix("SQL Backup - "), let range = jobName.range(of: " - ", options: .backwards) else {
            return ""
        }
        let tail = String(jobName[range.upperBound...])
        if let asRange = tail.range(of: " as ") { return String(tail[..<asRange.lowerBound]) }
        return tail
    }

    /// Backup jobs: ours, log shipping, and any other job whose steps back up or restore.
    public func jobs() async throws -> [BackupJobInfo] {
        let categories = [Self.backupCategory, Self.restoreCategory, "Log Shipping"]
            .map(SQLIdentifier.literal).joined(separator: ", ")
        let sql = """
        SELECT CONVERT(nvarchar(36), j.job_id) AS job_id, j.name, CAST(j.enabled AS int) AS enabled,
               ISNULL(c.name, N'') AS category, ISNULL(j.description, N'') AS description,
               ISNULL(SUSER_SNAME(j.owner_sid), N'') AS owner,
               ISNULL((SELECT TOP (1) s.command FROM msdb.dbo.sysjobsteps AS s WHERE s.job_id = j.job_id
                       ORDER BY s.step_id), N'') AS command,
               (SELECT TOP (1) h.run_status FROM msdb.dbo.sysjobhistory AS h WHERE h.job_id = j.job_id AND h.step_id = 0
                ORDER BY h.instance_id DESC) AS last_status,
               (SELECT TOP (1) h.run_date FROM msdb.dbo.sysjobhistory AS h WHERE h.job_id = j.job_id AND h.step_id = 0
                ORDER BY h.instance_id DESC) AS last_date,
               (SELECT TOP (1) h.run_time FROM msdb.dbo.sysjobhistory AS h WHERE h.job_id = j.job_id AND h.step_id = 0
                ORDER BY h.instance_id DESC) AS last_time,
               (SELECT TOP (1) LEFT(h.message, 1000) FROM msdb.dbo.sysjobhistory AS h WHERE h.job_id = j.job_id
                AND h.step_id = 0 ORDER BY h.instance_id DESC) AS last_message,
               (SELECT AVG(CAST((h.run_duration / 10000) * 3600 + ((h.run_duration / 100) % 100) * 60
                                + h.run_duration % 100 AS float))
                FROM (SELECT TOP (10) run_duration FROM msdb.dbo.sysjobhistory AS x WHERE x.job_id = j.job_id
                      AND x.step_id = 0 AND x.run_status = 1 ORDER BY x.instance_id DESC) AS h) AS average_seconds,
               (SELECT MIN(js.next_run_date * CAST(1000000 AS bigint) + js.next_run_time)
                FROM msdb.dbo.sysjobschedules AS js WHERE js.job_id = j.job_id AND js.next_run_date > 0) AS next_run,
               CASE WHEN EXISTS (SELECT 1 FROM msdb.dbo.sysjobactivity AS a WHERE a.job_id = j.job_id
                                 AND a.start_execution_date IS NOT NULL AND a.stop_execution_date IS NULL
                                 AND a.session_id = (SELECT MAX(session_id) FROM msdb.dbo.syssessions))
                    THEN 1 ELSE 0 END AS running
        FROM msdb.dbo.sysjobs AS j
        LEFT JOIN msdb.dbo.syscategories AS c ON c.category_id = j.category_id
        WHERE c.name IN (\(categories))
           OR EXISTS (SELECT 1 FROM msdb.dbo.sysjobsteps AS s WHERE s.job_id = j.job_id
                      AND (s.command LIKE N'%BACKUP DATABASE%' OR s.command LIKE N'%BACKUP LOG%'
                           OR s.command LIKE N'%RESTORE DATABASE%' OR s.command LIKE N'%sqlbackup%'))
        ORDER BY j.name;
        SELECT CONVERT(nvarchar(36), js.job_id) AS job_id, s.name, CAST(s.enabled AS int) AS enabled, s.freq_type,
               s.freq_interval, s.freq_subday_type, s.freq_subday_interval, s.freq_relative_interval,
               s.freq_recurrence_factor, s.active_start_date, s.active_end_date, s.active_start_time, s.active_end_time
        FROM msdb.dbo.sysjobschedules AS js
        JOIN msdb.dbo.sysschedules AS s ON s.schedule_id = js.schedule_id;
        """
        let result = try await session.metadataQuery(sql, database: "msdb")
        let jobs = result.resultSets.first?.dictionaries() ?? []
        let scheduleRows = result.resultSets.count > 1 ? result.resultSets[1].dictionaries() : []
        var schedulesByJob: [String: [BackupSchedule]] = [:]
        for row in scheduleRows {
            let schedule = BackupSchedule(name: row.string("name"), isEnabled: row.int("enabled") == 1,
                                          freqType: row.int("freq_type"), freqInterval: row.int("freq_interval"),
                                          subdayType: row.int("freq_subday_type"),
                                          subdayInterval: row.int("freq_subday_interval"),
                                          relativeInterval: row.int("freq_relative_interval"),
                                          recurrenceFactor: row.int("freq_recurrence_factor"),
                                          activeStartDate: row.int("active_start_date"),
                                          activeEndDate: row.int("active_end_date"),
                                          activeStartTime: row.int("active_start_time"),
                                          activeEndTime: row.int("active_end_time"))
            schedulesByJob[row.string("job_id").uppercased(), default: []].append(schedule)
        }
        return jobs.map { row in
            let id = row.string("job_id").uppercased()
            let command = row.string("command")
            let next = row.int64("next_run")
            let status: String
            switch row.isNull("last_status") ? -1 : row.int("last_status") {
            case 0: status = "Failed"
            case 1: status = "Succeeded"
            case 2: status = "Retry"
            case 3: status = "Cancelled"
            case 4: status = "In progress"
            default: status = "Never run"
            }
            let average = row.isNull("average_seconds") ? nil : row.double("average_seconds")
            return BackupJobInfo(id: id, name: row.string("name"), isEnabled: row.int("enabled") == 1,
                                 category: row.string("category"), jobDescription: row.string("description"),
                                 owner: row.string("owner"), command: command,
                                 config: BackupJobConfig.parse(fromCommand: command),
                                 schedules: schedulesByJob[id] ?? [],
                                 nextRun: next > 0 ? ServerTime.fromAgent(date: Int(next / 1_000_000),
                                                                          time: Int(next % 1_000_000)) : nil,
                                 lastRun: ServerTime.fromAgent(date: row.int("last_date"), time: row.int("last_time")),
                                 lastOutcome: status, lastMessage: row.string("last_message"),
                                 averageDuration: average, isRunning: row.int("running") == 1)
        }
    }

    /// The script that creates the job for a configuration.
    public func createScript(_ config: BackupJobConfig, capabilities: BackupServerCapabilities) -> String {
        let (command, category, description) = Self.parts(config, capabilities: capabilities)
        return BackupJobScripts.createJobScript(name: config.jobName, description: description, category: category,
                                                command: command, schedules: config.schedules)
    }

    public func create(_ config: BackupJobConfig, capabilities: BackupServerCapabilities) async throws {
        try await run(createScript(config, capabilities: capabilities))
    }

    public func update(jobID: String, config: BackupJobConfig, capabilities: BackupServerCapabilities) async throws {
        let (command, _, description) = Self.parts(config, capabilities: capabilities)
        try await run(BackupJobScripts.updateJobScript(jobID: jobID, name: config.jobName, description: description,
                                                       command: command, schedules: config.schedules))
    }

    static func parts(_ config: BackupJobConfig,
                      capabilities: BackupServerCapabilities) -> (command: String, category: String, description: String) {
        switch config.kind {
        case .backup:
            let options = config.backup ?? BackupOptions()
            let command = BackupJobScripts.backupStep(options, capabilities: capabilities,
                                                      defaultFormat: config.defaultFormat, schedules: config.schedules)
            return (command, backupCategory,
                    "\(options.type.title) backup of \(options.databases.summary). Managed by SSMS for Mac SQL Backup.")
        case .restoreVerification:
            let options = config.restore ?? RestoreJobOptions()
            let command = BackupJobScripts.restoreStep(options, capabilities: capabilities, schedules: config.schedules)
            return (command, restoreCategory,
                    "Restores the latest backups of \(options.sourceDatabase) as \(options.effectiveDestination) and "
                        + "checks them. Managed by SSMS for Mac SQL Backup.")
        }
    }

    public func delete(jobID: String) async throws {
        try await run("EXEC msdb.dbo.sp_delete_job @job_id = \(SQLIdentifier.literal(jobID)), @delete_unused_schedule = 1;")
    }

    public func setEnabled(jobID: String, _ enabled: Bool) async throws {
        try await run("EXEC msdb.dbo.sp_update_job @job_id = \(SQLIdentifier.literal(jobID)), @enabled = \(enabled ? 1 : 0);")
    }

    public func start(jobID: String) async throws {
        try await run("EXEC msdb.dbo.sp_start_job @job_id = \(SQLIdentifier.literal(jobID));")
    }

    public func stop(jobID: String) async throws {
        try await run("EXEC msdb.dbo.sp_stop_job @job_id = \(SQLIdentifier.literal(jobID));")
    }

    /// The last runs' messages (Show Log): job outcome and step output, newest first.
    public func log(jobID: String, runs: Int = 5) async throws -> [String] {
        let sql = """
        SELECT TOP (\(runs * 3)) h.step_id, h.run_status, h.run_date, h.run_time, h.message
        FROM msdb.dbo.sysjobhistory AS h WHERE h.job_id = \(SQLIdentifier.literal(jobID)) ORDER BY h.instance_id DESC;
        SELECT TOP (1) l.log FROM msdb.dbo.sysjobstepslogs AS l
        JOIN msdb.dbo.sysjobsteps AS s ON s.step_uid = l.step_uid
        WHERE s.job_id = \(SQLIdentifier.literal(jobID)) ORDER BY l.date_modified DESC;
        """
        let result = try await session.metadataQuery(sql, database: "msdb")
        var lines: [String] = []
        if result.resultSets.count > 1, let log = result.resultSets[1].dictionaries().first?.string("log"), !log.isEmpty {
            lines.append("Output of the last run:")
            lines.append(log)
            lines.append("")
        }
        for row in result.resultSets.first?.dictionaries() ?? [] {
            let when = ServerTime.fromAgent(date: row.int("run_date"), time: row.int("run_time")).map(ServerTime.display) ?? ""
            let outcome = row.int("run_status") == 1 ? "succeeded" : (row.int("run_status") == 0 ? "FAILED" : "other")
            lines.append("\(when)  step \(row.int("step_id"))  \(outcome)")
            lines.append("    " + row.string("message"))
        }
        return lines
    }

    private func run(_ sql: String) async throws {
        let connection = try await session.openConnection(database: "msdb")
        defer { Task { try? await connection.close() } }
        _ = try await connection.query(sql)
    }
}
