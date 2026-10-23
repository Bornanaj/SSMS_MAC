import Foundation
import TDSKit
import SQLServerKit

/// Offline suites for SQL Backup: file naming, schedules, restore chains, the generated
/// BACKUP / RESTORE / retention scripts, option checks, job configuration, database selection,
/// backup status and reports — everything that can be checked without a server.
func runBackupTests(_ t: TestRunner) {

    // MARK: - Fixtures

    func date(_ text: String) -> Date {
        ServerTime.parse(text) ?? Date(timeIntervalSince1970: 0)
    }

    let started = date("2026-10-23 14:05:09")

    func server(major: Int, engineEdition: Int = 3, edition: String = "Developer Edition (64-bit)",
                qat: Bool = false) -> BackupServerCapabilities {
        var capabilities = BackupServerCapabilities()
        capabilities.serverName = "SQL1"
        capabilities.machineName = "SQL1"
        capabilities.majorVersion = major
        capabilities.engineEdition = engineEdition
        capabilities.edition = edition
        capabilities.platform = .linux
        capabilities.defaultBackupFolder = "/var/opt/mssql/backup"
        capabilities.defaultDataFolder = "/var/opt/mssql/data"
        capabilities.defaultLogFolder = "/var/opt/mssql/log"
        capabilities.hasQAT = qat
        return capabilities
    }

    // MARK: - File naming

    t.suite("backup file names") {
        let context = BackupFileNaming.Context(database: "Sales/EU", type: .full, instance: "(local)", server: "SQL1",
                                               date: started)
        t.equal(BackupFileNaming.expand(BackupOptions.defaultFileNameFormat, context: context),
                "FULL_(local)_Sales_EU_20261023_140509", "default format, with the slash in the name replaced")
        t.equal(BackupFileNaming.expand("<AUTO>", context: context),
                "FULL_(local)_Sales_EU_20261023_140509", "<AUTO> is the default format")
        t.equal(BackupFileNaming.expand("<DATABASE>_<DATETIME yyyy-mm-dd hh.nn>", context: context),
                "Sales_EU_2026-10-23 14.05", "mm after hh is minutes")
        t.equal(BackupFileNaming.expand("<DATETIME yy mm dd>", context: context), "26 10 23", "two digit year")
        t.equal(BackupFileNaming.expand("<SERVER>-<AVAILABILITYGROUP>-<TYPE>", context: context), "SQL1-(local)-FULL",
                "availability group falls back to the instance")
        t.equal(BackupFileNaming.expand("<FOO>_<TYPE>", context: context), "<FOO>_FULL", "unknown tags stay literal")
        var log = context
        log.type = .log
        log.availabilityGroup = "AG1"
        t.equal(BackupFileNaming.expand("<TYPE>_<AVAILABILITYGROUP>", context: log), "LOG_AG1", "log tag and AG name")

        t.equal(BackupFileNaming.stripeNames(base: "x", count: 1, fileExtension: "bak"), ["x.bak"], "one file")
        t.equal(BackupFileNaming.stripeNames(base: "x", count: 3, fileExtension: "trn"),
                ["x_1of3.trn", "x_2of3.trn", "x_3of3.trn"], "striped files are numbered")

        let expression = BackupFileNaming.sqlExpression("<TYPE>_<DATABASE>_<DATETIME yyyymmdd>.bak")
        t.expect(expression.contains("@type_tag") && expression.contains("@db") && expression.contains("@started"),
                 "the T-SQL name uses the job's variables", expression)
        t.expect(expression.contains("N'.bak'"), "literals are quoted", expression)
        t.expect(BackupFileNaming.sqlExpression("<AUTO>").contains("@instance"), "<AUTO> expands in T-SQL too")
    }

    // MARK: - Schedules

    t.suite("backup schedules") {
        let today = date("2026-10-19")

        let daily = BackupSchedule.parse("daily 01:30", today: today)
        t.equal(daily?.frequency, .daily, "daily")
        t.equal(daily?.startTime, 5400, "daily start time")
        t.equal(daily?.summary, "Every day at 01:30", "daily summary")

        let quarterHour = BackupSchedule.parse("every 15 minutes", today: today)
        t.expect(quarterHour?.repeats == true && quarterHour?.repeatInterval == 15 && quarterHour?.repeatUnit == .minutes,
                 "every 15 minutes repeats")
        t.equal(quarterHour?.summary, "Every day, every 15 minutes", "repeating summary")
        t.equal(quarterHour?.occurrences(from: today, to: today.addingTimeInterval(3600)).count, 5,
                "four quarter hours and the hour itself")

        let window = BackupSchedule.parse("daily every 2 hours from 08:00 to 18:00", today: today)
        t.equal(window?.summary, "Every day, every 2 hours between 08:00 and 18:00", "window summary")
        let windowTimes = window?.occurrences(from: today, to: today.addingTimeInterval(86_399)) ?? []
        t.equal(windowTimes.map { ServerTime.format($0, "HH:mm") }, ["08:00", "10:00", "12:00", "14:00", "16:00", "18:00"],
                "runs inside the window only")

        let weekly = BackupSchedule.parse("weekly mon,wed 01:30", today: today)
        t.equal(weekly?.weekdays, 2 | 8, "Monday and Wednesday bits")
        t.equal(weekly?.summary, "Every week on Monday, Wednesday at 01:30", "weekly summary")
        let weeklyTimes = weekly?.occurrences(from: today, to: date("2026-11-01")) ?? []
        t.equal(weeklyTimes.map { ServerTime.format($0, "yyyy-MM-dd HH:mm") },
                ["2026-10-19 01:30", "2026-10-21 01:30", "2026-10-26 01:30", "2026-10-28 01:30"], "weekly occurrences")
        let arguments = weekly?.agentArguments ?? []
        t.expect(arguments.contains("@freq_type = 8") && arguments.contains("@freq_interval = 10")
                 && arguments.contains("@active_start_time = 13000") && arguments.contains("@active_start_date = 20261019"),
                 "sp_add_schedule arguments", arguments.joined(separator: ", "))

        let monthly = BackupSchedule.parse("monthly 1 02:00", today: today)
        t.equal(monthly?.occurrences(from: today, to: date("2026-12-31")).map { ServerTime.format($0, "MM-dd") },
                ["11-01", "12-01"], "monthly on the first")

        let once = BackupSchedule.parse("once 2026-11-01 03:00", today: today)
        t.equal(once?.occurrences(from: today, to: date("2026-12-31")).map(ServerTime.display), ["2026-11-01 03:00:00"],
                "once")
        t.equal(BackupSchedule.parse("agent-start", today: today)?.occurrences(from: today, to: date("2026-12-31")).count,
                0, "agent start has no times")
        t.expect(BackupSchedule.parse("fortnightly", today: today) == nil, "unknown words are rejected")
        t.expect(BackupSchedule.parse("daily 25:00", today: today) == nil, "invalid times are rejected")

        var lastFriday = BackupSchedule(frequency: .monthlyRelative, relativeOrdinal: 16, relativeDay: 6,
                                        startTime: 22 * 3600, startDate: today)
        lastFriday.name = "Last Friday"
        t.equal(lastFriday.occurrences(from: today, to: date("2026-11-30")).map { ServerTime.format($0, "yyyy-MM-dd") },
                ["2026-10-30", "2026-11-27"], "last Friday of the month")
        t.equal(lastFriday.summary, "Last friday of every month at 22:00", "relative summary")

        // What msdb stores comes back as the same schedule.
        let stored = BackupSchedule(name: "w", isEnabled: true, freqType: 8, freqInterval: 10, subdayType: 1,
                                    subdayInterval: 0, relativeInterval: 0, recurrenceFactor: 1, activeStartDate: 20261019,
                                    activeEndDate: 99991231, activeStartTime: 13000, activeEndTime: 235959)
        t.equal(stored.summary, weekly?.summary ?? "", "msdb columns round trip")
        t.equal(BackupSchedule.suggested(for: .log, today: today).summary, "Every day, every 1 hour", "suggested log schedule")
    }

    // MARK: - LSNs and restore chains

    t.suite("LSN ordering") {
        t.equal(LSN("000123"), LSN("123"), "leading zeros are ignored")
        t.expect(LSN("99") < LSN("100"), "numeric, not text, order")
        t.expect(LSN("31000000012300001") < LSN("31000000012400001"), "long LSNs compare digit by digit")
        t.expect(LSN("").isZero && LSN("x1").isZero, "missing LSNs are zero")
    }

    t.suite("restore chains") {
        func set(_ id: Int, _ type: String, first: String, last: String, checkpoint: String = "", base: String = "",
                 finished: String, copyOnly: Bool = false) -> BackupSetInfo {
            BackupSetInfo(id: id, database: "Sales", typeCode: type, firstLSN: LSN(first), lastLSN: LSN(last),
                          checkpointLSN: LSN(checkpoint), databaseBackupLSN: LSN(base),
                          started: date(finished).addingTimeInterval(-30), finished: date(finished),
                          files: [["/b/\(id).bak"]], isCopyOnly: copyOnly)
        }
        let full = set(1, "D", first: "100", last: "200", checkpoint: "150", finished: "2026-10-20 00:00:00")
        let log1 = set(2, "L", first: "90", last: "300", base: "150", finished: "2026-10-20 06:00:00")
        let diff = set(3, "I", first: "350", last: "400", checkpoint: "380", base: "150", finished: "2026-10-20 12:00:00")
        let log2 = set(4, "L", first: "300", last: "500", base: "150", finished: "2026-10-20 18:00:00")
        let log3 = set(5, "L", first: "500", last: "600", base: "150", finished: "2026-10-21 00:00:00")
        let copy = set(6, "D", first: "610", last: "620", checkpoint: "615", finished: "2026-10-21 03:00:00", copyOnly: true)
        let all: [BackupSetInfo] = [full, log1, diff, log2, log3]

        func ids(_ result: Result<RestoreChain, RestoreChainError>) -> [Int] {
            (try? result.get())?.steps.map(\.id) ?? []
        }

        t.equal(ids(RestoreChainBuilder.chain(pointInTime: nil, in: all)), [1, 3, 4, 5],
                "latest: full, newest differential, then the logs after it")
        t.equal(ids(RestoreChainBuilder.chain(ending: log1, in: all)), [1, 2], "ending at the first log")
        t.equal(ids(RestoreChainBuilder.chain(ending: diff, in: all)), [1, 3], "ending at the differential")
        t.equal(ids(RestoreChainBuilder.chain(ending: log3, in: all)), [1, 3, 4, 5], "ending at the last log")

        let moment = date("2026-10-20 20:00:00")
        let pointInTime = try? RestoreChainBuilder.chain(pointInTime: moment, in: all).get()
        t.equal(pointInTime?.steps.map(\.id) ?? [], [1, 3, 4, 5], "point in time uses the log that covers it")
        t.equal(pointInTime?.stopAt, moment, "and stops there")
        let beforeDiff = try? RestoreChainBuilder.chain(pointInTime: date("2026-10-20 05:00:00"), in: all).get()
        t.equal(beforeDiff?.steps.map(\.id) ?? [], [1, 2], "before the differential the logs follow the full")

        let broken: [BackupSetInfo] = [full, log1, diff, log3]
        if case .failure(.brokenLogChain) = RestoreChainBuilder.chain(ending: log3, in: broken) {
            t.expect(true, "a missing log breaks the chain")
        } else {
            t.expect(false, "a missing log breaks the chain")
        }
        if case .failure(.pointInTimeTooEarly) = RestoreChainBuilder.chain(pointInTime: date("2026-10-19 00:00:00"), in: all) {
            t.expect(true, "a time before every full backup is rejected")
        } else {
            t.expect(false, "a time before every full backup is rejected")
        }
        t.equal(RestoreChainBuilder.chain(pointInTime: nil, in: [log1, log2]).failureValue, .noFullBackup,
                "logs alone cannot be restored")
        t.equal(ids(RestoreChainBuilder.chain(pointInTime: nil, in: all + [copy])), [6],
                "a newer copy-only full restores on its own")
        t.equal(ids(RestoreChainBuilder.chain(ending: log3, in: all + [copy])), [1, 3, 4, 5],
                "a copy-only full does not disturb the log chain")
    }

    // MARK: - Scripts

    t.suite("backup scripts") {
        var options = BackupOptions()
        options.databases = .databases(["Sales"])
        options.compressionLevel = 1
        let capabilities = server(major: 16)
        let scripter = BackupScripter(options: options, capabilities: capabilities)
        let plan = scripter.plan(database: "Sales", date: started)
        t.equal(plan.files, ["/var/opt/mssql/backup/FULL_(local)_Sales_20261023_140509.bak"], "file in the default folder")
        let statement = scripter.backupStatement(database: "Sales", plan: plan)
        t.expect(statement.hasPrefix("BACKUP DATABASE [Sales]\n    TO DISK = N'/var/opt/mssql/backup/"), "BACKUP DATABASE",
                 statement)
        for clause in ["FORMAT", "INIT", "COMPRESSION (ALGORITHM = MS_XPRESS)", "CHECKSUM", "STATS = 5"] {
            t.expect(statement.contains(clause), "WITH \(clause)", statement)
        }
        t.expect(!statement.contains("COPY_ONLY") && !statement.contains("DIFFERENTIAL"), "a plain full backup")

        var split = options
        split.layout = .split
        split.fileCount = 4
        split.type = .log
        split.folder = "/backups/<DATABASE>"
        let splitScripter = BackupScripter(options: split, capabilities: capabilities)
        let splitPlan = splitScripter.plan(database: "Sales", date: started)
        t.equal(splitPlan.files.count, 4, "four stripes")
        t.equal(splitPlan.files.last, "/backups/Sales/LOG_(local)_Sales_20261023_140509_4of4.trn", "folder tags and stripes")
        t.expect(splitScripter.backupStatement(database: "Sales", plan: splitPlan).hasPrefix("BACKUP LOG [Sales]"), "BACKUP LOG")

        var mirrored = options
        mirrored.layout = .mirrored
        mirrored.mirrorFolders = ["/mirror"]
        mirrored.type = .differential
        mirrored.copyOnly = true
        let mirroredScripter = BackupScripter(options: mirrored, capabilities: capabilities)
        let mirroredStatement = mirroredScripter.backupStatement(database: "Sales",
                                                                 plan: mirroredScripter.plan(database: "Sales", date: started))
        t.expect(mirroredStatement.contains("MIRROR TO DISK = N'/mirror/DIFF_(local)_Sales_20261023_140509.bak'"),
                 "MIRROR TO", mirroredStatement)
        t.expect(mirroredStatement.contains("DIFFERENTIAL") && !mirroredStatement.contains("COPY_ONLY"),
                 "differentials are never copy-only")

        var encrypted = options
        encrypted.encryption = BackupEncryption(isEnabled: true, algorithm: .aes256, encryptor: "BackupKey")
        let encryptedStatement = BackupScripter(options: encrypted, capabilities: capabilities)
            .backupStatement(database: "Sales", plan: plan)
        t.expect(encryptedStatement.contains("ENCRYPTION (ALGORITHM = AES_256, SERVER CERTIFICATE = [BackupKey])"),
                 "certificate encryption", encryptedStatement)

        let verify = scripter.verifyStatement(plan: plan)
        t.expect(verify.hasPrefix("RESTORE VERIFYONLY") && verify.contains("CHECKSUM"), "verify statement", verify)
        t.expect(BackupScripter.existenceCheck(paths: plan.files).contains("xp_fileexist"), "existence check")
    }

    t.suite("compression levels") {
        t.equal(server(major: 15).compressionClause(level: 3), "COMPRESSION", "2019 has one algorithm")
        t.equal(server(major: 16).compressionClause(level: 0), "NO_COMPRESSION", "level 0 turns compression off")
        t.equal(server(major: 16).compressionClause(level: 4), "COMPRESSION (ALGORITHM = MS_XPRESS)",
                "2022 without an accelerator")
        t.equal(server(major: 16, qat: true).compressionClause(level: 4), "COMPRESSION (ALGORITHM = QAT_DEFLATE)",
                "2022 with Intel QAT")
        t.equal(server(major: 17).compressionClause(level: 2), "COMPRESSION (ALGORITHM = ZSTD, LEVEL = MEDIUM)", "2025 ZSTD")
        t.expect(server(major: 16, engineEdition: 4, edition: "Express Edition").compressionClause(level: 1) == nil,
                 "Express cannot compress")
        t.expect(!server(major: 16, engineEdition: 2, edition: "Standard Edition").canMirror, "Standard cannot mirror")
    }

    t.suite("retention scripts") {
        let days = BackupScripter.retentionScript(rule: BackupRetention(rule: .olderThanDays, value: 7), type: .full,
                                                  databaseExpression: "N'Sales'", folderExpression: "N'/b'", suffix: "x")
        t.expect(days.contains("DATEADD(DAY, -7, GETDATE())"), "age condition", days)
        t.expect(days.contains("@r_sets_x") && days.contains("r_cursor_x"), "names carry the suffix")
        t.expect(days.contains("bs.type = 'D'") && days.contains("xp_delete_file 0"), "full backups only, deleted by file")
        t.expect(days.contains("CURSOR_STATUS('local', N'r_cursor_x')"), "a cursor left open is cleaned up first")
        let latest = BackupScripter.retentionScript(rule: BackupRetention(rule: .keepLatest, value: 3), type: .log,
                                                    databaseExpression: "@db", folderExpression: "@folder")
        t.expect(latest.contains("SELECT TOP (3) id") && latest.contains("bs.type = 'L'"), "keep the newest three", latest)
        t.equal(BackupScripter.retentionScript(rule: BackupRetention(), type: .full, databaseExpression: "@db",
                                               folderExpression: "@f"), "", "no rule, no script")
    }

    t.suite("restore scripts") {
        let full = BackupSetInfo(id: 1, database: "Sales", typeCode: "D", lastLSN: LSN("200"), checkpointLSN: LSN("150"),
                                 finished: date("2026-10-20 00:00:00"), files: [["/b/full_1of2.bak", "/b/full_2of2.bak"]])
        let log = BackupSetInfo(id: 2, database: "Sales", typeCode: "L", firstLSN: LSN("90"), lastLSN: LSN("300"),
                                finished: date("2026-10-20 06:00:00"), files: [["/b/log.trn"]])
        let stop = date("2026-10-20 05:00:00")
        let chain = RestoreChain(full: full, differential: nil, logs: [log], stopAt: stop)
        let files = [RestoreFileInfo(logicalName: "Sales", physicalName: "/data/Sales.mdf", type: "ROWS"),
                     RestoreFileInfo(logicalName: "Sales_log", physicalName: "/data/Sales_log.ldf", type: "LOG")]
        var options = RestoreOptions()
        options.destinationDatabase = "Sales_Copy"
        options.checkDB = true
        let planner = RestorePlanner(chain: chain, files: files, options: options, capabilities: server(major: 16),
                                     destinationExists: false, destinationIsRestoring: false)
        let moves = planner.relocations()
        t.equal(moves.map(\.physical), ["/var/opt/mssql/data/Sales_Copy.mdf", "/var/opt/mssql/log/Sales_Copy_log.ldf"],
                "files renamed into the server's default folders")
        let steps = planner.steps()
        let sql: [String] = steps.map(\.sql)
        t.expect(sql.first?.contains("FROM DISK = N'/b/full_1of2.bak',\n         DISK = N'/b/full_2of2.bak'") == true,
                 "every stripe is read", sql.first ?? "")
        t.expect(sql.first?.contains("NORECOVERY") == true && sql.first?.contains("REPLACE") == false,
                 "the full restore waits for the log and replaces nothing")
        t.expect(sql.count > 1 && sql[1].contains("STOPAT = '2026-10-20T05:00:00.000'") && sql[1].contains("RECOVERY"),
                 "the last log stops at the point in time and recovers", sql.count > 1 ? sql[1] : "")
        t.expect(sql.contains { $0.contains("DBCC CHECKDB (N'Sales_Copy')") }, "integrity check afterwards")

        var overwrite = options
        overwrite.destinationDatabase = "Sales"
        overwrite.replaceExisting = true
        overwrite.recoveryState = .readOnly
        let overwriting = RestorePlanner(chain: RestoreChain(full: full, differential: nil, logs: []), files: files,
                                         options: overwrite, capabilities: server(major: 16), destinationExists: true,
                                         destinationIsRestoring: false).steps()
        let first: String = overwriting.first?.sql ?? ""
        t.expect(first.hasPrefix("ALTER DATABASE [Sales] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;") && first.contains("REPLACE"),
                 "overwriting kills connections in the same batch and replaces", first)
        t.expect(first.contains("STANDBY = N'/var/opt/mssql/backup/UNDO_Sales.dat'"), "read-only standby with an undo file")
    }

    // MARK: - Options, jobs and selection

    t.suite("backup option checks") {
        var options = BackupOptions()
        t.expect(options.validationErrors(capabilities: nil).contains("Select at least one database."), "nothing selected")
        options.databases = .databases(["A", "B"])
        options.fileNameFormat = "backup_<DATETIME yyyymmdd>"
        t.expect(options.validationErrors(capabilities: nil).contains { $0.contains("<DATABASE>") },
                 "several databases need <DATABASE> in the name")
        options.fileNameFormat = ""
        t.expect(options.validationErrors(capabilities: nil).isEmpty, "the default name is fine",
                 options.validationErrors(capabilities: nil).joined(separator: "; "))
        options.type = .differential
        options.copyOnly = true
        t.expect(options.validationErrors(capabilities: nil).contains("A differential backup cannot be copy-only."),
                 "copy-only differential")
        options.copyOnly = false
        options.layout = .mirrored
        options.mirrorFolders = ["/m"]
        t.expect(options.validationErrors(capabilities: server(major: 16, engineEdition: 2, edition: "Standard Edition"))
            .contains { $0.contains("Enterprise") }, "mirroring needs Enterprise")
        options.layout = .single
        options.encryption.isEnabled = true
        t.expect(options.validationErrors(capabilities: nil).contains { $0.contains("certificate") }, "encryption needs a certificate")
    }

    t.suite("backup job configuration") {
        var options = BackupOptions()
        options.databases = DatabaseSelection(scope: .user, excluded: ["Scratch"])
        options.type = .log
        options.retention = BackupRetention(rule: .olderThanHours, value: 48)
        let schedule = BackupSchedule.parse("every 15 minutes", today: date("2026-10-19")) ?? BackupSchedule()
        let config = BackupJobConfig(backup: options, schedules: [schedule])
        let command = "SET NOCOUNT ON;\n\(config.comment())\nDECLARE @db sysname;"
        let parsed = BackupJobConfig.parse(fromCommand: command)
        t.expect(parsed == config, "the configuration survives the job step")
        t.equal(parsed?.backup?.databases.summary, "All user databases except Scratch", "selection summary")
        t.expect(BackupJobConfig.parse(fromCommand: "BACKUP DATABASE x TO DISK = 'y'") == nil, "other jobs have none")
        t.expect(config.jobName.hasPrefix("SQL Backup - LOG"), "job name says the type", config.jobName)
    }

    t.suite("database selection") {
        let now = date("2026-10-23 12:00:00")
        let statuses: [DatabaseBackupStatus] = [
            DatabaseBackupStatus(name: "master", databaseID: 1, recoveryModel: "SIMPLE", lastFull: now),
            DatabaseBackupStatus(name: "tempdb", databaseID: 2, recoveryModel: "SIMPLE"),
            DatabaseBackupStatus(name: "model", databaseID: 3, lastFull: now),
            DatabaseBackupStatus(name: "msdb", databaseID: 4, recoveryModel: "SIMPLE", lastFull: now),
            DatabaseBackupStatus(name: "Sales", databaseID: 5, lastFull: now),
            DatabaseBackupStatus(name: "Fresh", databaseID: 6),
            DatabaseBackupStatus(name: "Archive", databaseID: 7, stateDescription: "OFFLINE")
        ]
        func names(_ selection: DatabaseSelection, _ type: BackupType) -> [String] {
            BackupRunner.resolve(selection, type: type, statuses: statuses).map(\.name)
        }
        t.equal(names(DatabaseSelection(scope: .user), .full), ["Sales", "Fresh"], "user databases skip offline ones")
        t.equal(names(DatabaseSelection(scope: .user), .log), ["Sales"], "log scope skips databases without a chain")
        t.equal(names(DatabaseSelection(scope: .system), .full), ["master", "model", "msdb"], "never tempdb")
        t.equal(names(DatabaseSelection(scope: .all, excluded: ["MSDB", "master"]), .full), ["model", "Sales", "Fresh"],
                "exclusions ignore case")
        let explicit = BackupRunner.resolve(.databases(["Fresh", "Nope"]), type: .log, statuses: statuses)
        t.expect(explicit.count == 2 && explicit[0].skipReason != nil, "an explicit pick says why it cannot be backed up")
        t.equal(explicit.last?.skipReason, "The database does not exist.", "missing database")
    }

    t.suite("backup status") {
        let now = date("2026-10-23 12:00:00")
        let thresholds = BackupThresholds(fullBackupHours: 180, logBackupMinutes: 120)
        func risk(_ status: DatabaseBackupStatus) -> BackupRisk { status.risk(now: now, thresholds: thresholds) }
        let hour: TimeInterval = 3600
        t.equal(risk(DatabaseBackupStatus(name: "A", lastFull: now - hour, lastLog: now - 0.5 * hour)), .ok, "up to date")
        t.equal(risk(DatabaseBackupStatus(name: "A", lastFull: now - hour)), .overdue, "full recovery without log backups")
        t.equal(risk(DatabaseBackupStatus(name: "A", lastFull: now - 3 * hour, lastLog: now - 3 * hour)), .overdue,
                "log backups too old")
        t.equal(risk(DatabaseBackupStatus(name: "A", recoveryModel: "SIMPLE", lastFull: now - 200 * hour)), .overdue,
                "full backup too old")
        t.equal(risk(DatabaseBackupStatus(name: "A", recoveryModel: "SIMPLE", lastFull: now - 140 * hour)), .warning,
                "three quarters of the way there")
        t.equal(risk(DatabaseBackupStatus(name: "A")), .never, "never backed up")
        t.equal(risk(DatabaseBackupStatus(name: "model", databaseID: 3, lastFull: now - hour)), .ok,
                "system databases need no log backups")
        t.equal(risk(DatabaseBackupStatus(name: "A", stateDescription: "RESTORING")), .notApplicable, "restoring")
    }

    t.suite("backup reports") {
        let now = date("2026-10-23 12:00:00")
        var good = BackupActivity(id: "1", kind: .backup, database: "Sales", typeCode: "D")
        good.started = now - 120
        good.finished = now - 60
        good.backupSize = 1000
        good.compressedSize = 250
        var bad = BackupActivity(id: "2", kind: .backup, database: "Sales, \"EU\"", typeCode: "L")
        bad.finished = now - 30
        bad.succeeded = false
        bad.message = "Operating system error 5"
        let databases = [DatabaseBackupStatus(name: "Fresh")]
        let report = BackupReport(serverName: "SQL1", activities: [good, bad], databases: databases, thresholds: BackupThresholds(),
                                  from: now - 86_400, to: now, scope: .all, now: now)
        t.equal(good.compressedBy ?? 0, 0.75, "compressed by three quarters")
        let csv = report.csv().split(separator: "\n")
        t.equal(csv.count, 3, "header and two rows")
        t.expect(csv.last?.contains("\"Sales, \"\"EU\"\"\"") == true, "CSV quoting", String(csv.last ?? ""))
        t.equal(report.atRisk.map(\.0.name), ["Fresh"], "databases at risk")
        var failures = report
        failures.scope = .failures
        t.equal(failures.rows.map(\.id), ["2"], "failures only")
        t.expect((try? JSONSerialization.jsonObject(with: report.json())) != nil, "valid JSON")
        t.expect(report.html().contains("Operating system error 5"), "HTML lists the failure")
    }

    t.suite("server time") {
        t.equal(ServerTime.literal(started), "'2026-10-23T14:05:09.000'", "STOPAT literal")
        t.equal(ServerTime.fromAgent(date: 20261023, time: 140509), started, "Agent's packed date and time")
        t.equal(ServerTime.display(started), "2026-10-23 14:05:09", "display")
    }
}

extension Result {
    var failureValue: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
