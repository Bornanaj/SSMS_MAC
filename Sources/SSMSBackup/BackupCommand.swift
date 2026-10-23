import Foundation
import TDSKit
import SQLServerKit

@main
struct BackupCommand {
    static func main() async {
        let raw = Array(CommandLine.arguments.dropFirst())
        guard let command = raw.first, !command.hasPrefix("-") else {
            print(usage)
            exit(ExitCode.usage.rawValue)
        }
        let args = Arguments(Array(raw.dropFirst()))
        do {
            let code: ExitCode
            switch command.lowercased() {
            case "backup": code = try await runBackup(args)
            case "restore": code = try await runRestore(args)
            case "verify": code = try await runVerify(args)
            case "status": code = try await runStatus(args)
            case "history", "report": code = try await runHistory(args)
            case "jobs": code = try await runJobs(args)
            case "analyze": code = try await runAnalyze(args)
            case "log-shipping": code = try await runLogShipping(args)
            case "certificates": code = try await runCertificates(args)
            case "help", "--help", "-h":
                print(usage)
                code = .success
            default:
                throw CLIError.usage("Unknown command '\(command)'.\n\n\(usage)")
            }
            exit(code.rawValue)
        } catch let error as CLIError {
            FileHandle.standardError.write(Data("error: \(error.description)\n".utf8))
            if case .usage = error { exit(ExitCode.usage.rawValue) }
            exit(ExitCode.error.rawValue)
        } catch {
            FileHandle.standardError.write(Data("error: \(describe(error))\n".utf8))
            exit(ExitCode.error.rawValue)
        }
    }

    // MARK: - Options

    static func retention(_ text: String?) throws -> BackupRetention {
        guard let text = text?.lowercased().trimmingCharacters(in: .whitespaces), !text.isEmpty else {
            return BackupRetention()
        }
        if text.hasSuffix("h"), let hours = Int(text.dropLast()) { return BackupRetention(rule: .olderThanHours, value: hours) }
        if text.hasSuffix("b"), let count = Int(text.dropLast()) { return BackupRetention(rule: .keepLatest, value: count) }
        if text.hasSuffix("d"), let days = Int(text.dropLast()) { return BackupRetention(rule: .olderThanDays, value: days) }
        if let days = Int(text) { return BackupRetention(rule: .olderThanDays, value: days) }
        throw CLIError.usage("Retention is a number of days (7), hours (12h) or backups to keep (5b), not '\(text)'.")
    }

    static func backupType(_ text: String?) throws -> BackupType {
        switch (text ?? "full").lowercased() {
        case "full", "d": return .full
        case "diff", "differential", "i": return .differential
        case "log", "l", "trn": return .log
        default: throw CLIError.usage("--type is full, diff or log.")
        }
    }

    /// Backup options from the command line, on top of a template when one is given.
    static func backupOptions(_ args: Arguments) throws -> BackupOptions {
        var options = BackupOptions()
        if let path = args.string("template") {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            if let template = try? JSONDecoder().decode(BackupTemplate.self, from: data) {
                options = template.options
            } else {
                options = try JSONDecoder().decode(BackupOptions.self, from: data)
            }
        }
        if args.has("type") { options.type = try backupType(args.string("type")) }
        if args.has("copy-only") { options.copyOnly = args.flag("copy-only") }
        if args.flag("no-truncate") { options.truncateLog = false }
        if args.flag("all-databases") { options.databases = DatabaseSelection(scope: .all, excluded: args.list("exclude")) }
        if args.flag("user-databases") { options.databases = DatabaseSelection(scope: .user, excluded: args.list("exclude")) }
        if args.flag("system-databases") {
            options.databases = DatabaseSelection(scope: .system, excluded: args.list("exclude"))
        }
        let named = args.list("database") + args.list("databases")
        if !named.isEmpty { options.databases = .databases(named) }
        if let folder = args.string("folder") { options.folder = folder }
        if let format = args.string("name-format") { options.fileNameFormat = format }
        if let url = args.string("url") {
            options.destination = .url
            options.urlBase = url
        }
        if let region = args.string("s3-region") { options.s3Region = region }
        if let count = try args.int("split") {
            options.layout = .split
            options.fileCount = count
        }
        let mirrors = args.all("mirror")
        if !mirrors.isEmpty && args.has("split") {
            throw CLIError.usage("--split and --mirror cannot be combined: a mirrored backup is a single file.")
        }
        if !mirrors.isEmpty {
            options.layout = .mirrored
            options.mirrorFolders = mirrors
        }
        if args.has("overwrite") { options.overwrite = args.flag("overwrite") }
        if args.has("erase-files") { options.retention = try retention(args.string("erase-files")) }
        if args.flag("erase-before") { options.retention.beforeBackup = true }
        if args.has("erase-mirror-files") { options.mirrorRetention = try retention(args.string("erase-mirror-files")) }
        if let level = try args.int("compression") {
            guard (0...4).contains(level) else { throw CLIError.usage("--compression is 0 to 4.") }
            options.compressionLevel = level
        }
        if let certificate = args.string("encrypt-certificate") {
            options.encryption.isEnabled = true
            options.encryption.encryptor = certificate
            if let algorithm = args.string("encrypt-algorithm") {
                guard let value = BackupEncryptionAlgorithm(rawValue: algorithm.uppercased()) else {
                    throw CLIError.usage("--encrypt-algorithm is AES_128, AES_192, AES_256 or TRIPLE_DES_3KEY.")
                }
                options.encryption.algorithm = value
            }
        }
        if args.flag("no-checksum") { options.checksum = false }
        if args.flag("checksum") { options.checksum = true }
        if args.flag("continue-after-error") { options.continueAfterError = true }
        if args.has("verify") { options.verify = args.flag("verify") }
        if let value = try args.int("retries") { options.retryCount = value }
        if let value = try args.int("retry-interval") { options.retryIntervalSeconds = value }
        if let value = try args.int("max-transfer-size") { options.maxTransferSize = value }
        if let value = try args.int("buffer-count") { options.bufferCount = value }
        if let value = try args.int("block-size") { options.blockSize = value }
        if args.flag("preferred-replica-only") { options.checkPreferredReplica = true }
        if args.flag("secondary-copy-only") { options.secondaryReplicaCopyOnly = true }
        if let name = args.string("backup-name") { options.backupName = name }
        if let text = args.string("description") { options.backupDescription = text }
        if let recipients = args.string("mail-to") {
            options.notification.recipients = recipients
            options.notification.level = .errorOnly
            switch (args.string("mail-on") ?? "error").lowercased() {
            case "always", "any": options.notification.level = .always
            case "warning", "error-or-warning": options.notification.level = .errorOrWarning
            default: options.notification.level = .errorOnly
            }
            options.notification.mailProfile = args.string("mail-profile") ?? ""
        }
        return options
    }

    // MARK: - backup

    static func runBackup(_ args: Arguments) async throws -> ExitCode {
        let quiet = args.flag("quiet")
        let options = try backupOptions(args)
        let session = try await ConnectionArguments(prefix: "", args: args).connect()
        defer { Task { await session.close() } }
        let capabilities = try await BackupCapabilityProbe(session: session).probe()
        let errors = options.validationErrors(capabilities: capabilities)
        if !errors.isEmpty { throw CLIError.usage(errors.joined(separator: "\n")) }
        if let path = args.string("save-template") {
            let template = BackupTemplate(name: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent,
                                          options: options)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(template).write(to: URL(fileURLWithPath: path))
            log("Template saved to \(path).", quiet: quiet)
        }
        let runner = BackupRunner(session: session, options: options, capabilities: capabilities)
        if args.flag("script") {
            let scripter = BackupScripter(options: options, capabilities: capabilities)
            for entry in try await runner.resolveDatabases() {
                if let reason = entry.skipReason { print("-- \(entry.name): \(reason)"); continue }
                let plan = scripter.plan(database: entry.name, date: capabilities.serverTime ?? Date())
                print(scripter.backupStatement(database: entry.name, plan: plan))
                if options.verify { print(scripter.verifyStatement(plan: plan)) }
                print("GO")
            }
            return .success
        }
        let result = try await runner.run { event in
            guard !quiet else { return }
            switch event.phase {
            case .backingUp, .verifying:
                if let fraction = event.fraction, Int(fraction * 100) % 25 == 0 {
                    log("  \(event.database): \(event.message.lowercased()) \(Int(fraction * 100))%", quiet: false)
                }
            case .preparing:
                log("\(event.database)", quiet: false)
            default:
                break
            }
        }
        for item in result.results {
            let state = item.succeeded ? (item.skipped ? "skipped" : "OK") : (item.skipped ? "skipped" : "FAILED")
            var line = "\(state)  \(item.database)"
            if item.succeeded && !item.skipped {
                line += String(format: "  %.1f s", item.duration)
                if let ratio = item.compressionRatio { line += String(format: ", compressed by %.0f%%", ratio * 100) }
                if item.verified == true { line += ", verified" }
            }
            print(line)
            for file in item.files { print("      \(file)") }
            for file in item.mirrorFiles { print("      mirror: \(file)") }
            for file in item.deletedFiles { print("      deleted: \(file)") }
            for warning in item.warnings { print("      warning: \(warning)") }
            for error in item.errors { print("      error: \(error)") }
        }
        log(result.summary, quiet: quiet)
        if result.hasErrors { return .error }
        return result.hasWarnings ? .warning : .success
    }

    // MARK: - restore

    static func runRestore(_ args: Arguments) async throws -> ExitCode {
        let quiet = args.flag("quiet")
        guard let target = args.string("database") else { throw CLIError.usage("--database (the database to restore to) is required.") }
        let session = try await ConnectionArguments(prefix: "", args: args).connect()
        defer { Task { await session.close() } }
        let capabilities = try await BackupCapabilityProbe(session: session).probe()

        // The tail is backed up before the history is read, so a restore to the latest point
        // restores it too. A script only shows the step.
        var tailTaken = false
        if let tail = args.string("tail-log"), !args.flag("script") {
            let state = try await session.metadataQuery(
                "SELECT state_desc FROM sys.databases WHERE name = \(SQLIdentifier.literal(target))", database: "master")
            if state.resultSets.first?.dictionaries().first?.string("state_desc") == "ONLINE" {
                log("Backing up the tail of \(target)'s log to \(tail)", quiet: quiet)
                try await RestoreRunner.backUpTail(session: session, database: target, path: tail,
                                                   killConnections: !args.flag("no-kill"))
                tailTaken = true
            }
        }

        let files = args.list("files") + args.positional
        var sets: [BackupSetInfo]
        if files.isEmpty {
            let source = args.string("source") ?? target
            sets = try await BackupHistoryReader(session: session).backupSets(database: source)
            if sets.isEmpty { throw CLIError.failed("There is no backup history for \(source) on this server.") }
        } else {
            let read = await BackupMediaReader(session: session).read(paths: files)
            for problem in read.problems { log("warning: \(problem)", quiet: false) }
            sets = read.sets
            if sets.isEmpty { throw CLIError.failed("No backup sets could be read from the files.") }
        }

        let chainResult: Result<RestoreChain, RestoreChainError>
        if let id = try args.int("backup-set-id") {
            guard let target = sets.first(where: { $0.id == id }) else { throw CLIError.failed("No backup set \(id).") }
            chainResult = RestoreChainBuilder.chain(ending: target, in: sets)
        } else if args.flag("full-only") {
            guard let full = sets.filter(\.isFull).max(by: { ($0.finished ?? .distantPast) < ($1.finished ?? .distantPast) })
            else { throw CLIError.failed("There is no full backup.") }
            chainResult = .success(RestoreChain(full: full, differential: nil, logs: []))
        } else {
            var stopAt: Date?
            if let text = args.string("stop-at") {
                guard let date = ServerTime.parse(text) else { throw CLIError.usage("--stop-at is 'yyyy-mm-dd hh:mm:ss'.") }
                stopAt = date
            }
            chainResult = RestoreChainBuilder.chain(pointInTime: stopAt, in: sets)
        }
        let chain: RestoreChain
        switch chainResult {
        case .success(let value): chain = value
        case .failure(let error): throw CLIError.failed(error.description)
        }

        var options = RestoreOptions()
        options.destinationDatabase = target
        options.replaceExisting = args.flag("replace")
        options.killConnections = !args.flag("no-kill")
        if let tail = args.string("tail-log"), !tailTaken {
            options.tailLogBackup = true
            options.tailLogPath = tail
        }
        if tailTaken { options.replaceExisting = true }
        if args.flag("original-locations") { options.fileLocation = .original }
        if args.has("data-folder") || args.has("log-folder") {
            options.fileLocation = .folders
            options.dataFolder = args.string("data-folder") ?? ""
            options.logFolder = args.string("log-folder") ?? ""
        }
        if args.flag("norecovery") { options.recoveryState = .nonOperational }
        if let undo = args.string("standby") {
            options.recoveryState = .readOnly
            if undo != "true" { options.undoFile = undo }
        }
        options.orphanCheck = !args.flag("no-orphan-check")
        options.fixOrphanedUsers = args.flag("fix-orphans")
        options.checkDB = args.flag("checkdb")
        switch (args.string("drop") ?? "never").lowercased() {
        case "always": options.drop = .always
        case "success", "on-success": options.drop = .onSuccess
        default: options.drop = .never
        }
        options.keepCDC = args.flag("keep-cdc")
        options.keepReplication = args.flag("keep-replication")
        if let region = args.string("s3-region") { options.s3Region = region }

        let existing = try await session.metadataQuery(
            "SELECT state_desc FROM sys.databases WHERE name = \(SQLIdentifier.literal(target))", database: "master")
        let state = existing.resultSets.first?.dictionaries().first?.string("state_desc")
        let reader = BackupMediaReader(session: session)
        let fileList = try await reader.fileList(for: chain.full)
        let planner = RestorePlanner(chain: chain, files: fileList, options: options, capabilities: capabilities,
                                     destinationExists: state != nil, destinationIsRestoring: state == "RESTORING")
        let problems = planner.validationErrors()
        if !problems.isEmpty { throw CLIError.usage(problems.joined(separator: "\n")) }
        for note in chain.notes { log("note: \(note)", quiet: quiet) }
        if args.flag("script") {
            print(planner.script())
            return .success
        }
        log("Restoring \(chain.steps.count) backup(s) of \(chain.full.database) as \(planner.destination)"
            + (chain.stopAt.map { " to \(ServerTime.display($0))" } ?? ""), quiet: quiet)
        let outcome = await RestoreRunner(session: session, planner: planner).run { event in
            guard !quiet, event.phase != .finished else { return }
            if event.fraction == 0 { log("  \(event.message)", quiet: false) }
        }
        if args.flag("verbose") { for message in outcome.messages { print(message) } }
        for user in outcome.orphanedUsers {
            print("orphaned user: \(user.name)" + (user.fixed ? " (mapped to its login)" : (user.loginExists ? " (a login of that name exists; use --fix-orphans)" : "")))
        }
        for error in outcome.checkDBErrors { print("DBCC CHECKDB: \(error)") }
        if outcome.dropped { print("Dropped \(planner.destination).") }
        guard outcome.succeeded else {
            log("Restore failed\(outcome.failedStep.map { " at: \($0)" } ?? ""): \(outcome.error ?? "")", quiet: false)
            return .error
        }
        log(String(format: "Restore succeeded in %.1f s.", outcome.duration), quiet: quiet)
        return outcome.hasWarnings ? .warning : .success
    }

    // MARK: - verify

    static func runVerify(_ args: Arguments) async throws -> ExitCode {
        let files = args.list("files") + args.positional
        guard !files.isEmpty else { throw CLIError.usage("Give the backup files to verify.") }
        let session = try await ConnectionArguments(prefix: "", args: args).connect()
        defer { Task { await session.close() } }
        let read = await BackupMediaReader(session: session).read(paths: files)
        for problem in read.problems { print("error: \(problem)") }
        let connection = try await session.openConnection(database: "master")
        defer { Task { try? await connection.close() } }
        var failed = !read.problems.isEmpty
        for set in read.sets {
            let device = set.isURL ? "URL" : "DISK"
            let from = set.primaryFiles.map { "\(device) = \(SQLIdentifier.literal($0))" }.joined(separator: ", ")
            let checksum = set.hasChecksums ? ", CHECKSUM" : ""
            do {
                _ = try await connection.query("RESTORE VERIFYONLY FROM \(from) WITH FILE = \(set.position)\(checksum);")
                print("OK      \(set.database) \(set.typeTitle) \(set.finished.map(ServerTime.display) ?? "") (position \(set.position))")
            } catch {
                failed = true
                print("FAILED  \(set.database) \(set.typeTitle): \(describe(error))")
            }
        }
        return failed ? .error : .success
    }

    // MARK: - status and history

    static func runStatus(_ args: Arguments) async throws -> ExitCode {
        let session = try await ConnectionArguments(prefix: "", args: args).connect()
        defer { Task { await session.close() } }
        let capabilities = try await BackupCapabilityProbe(session: session).probe()
        let databases = try await BackupHistoryReader(session: session).databases()
        var thresholds = BackupThresholds()
        if let hours = try args.int("full-hours") { thresholds.fullBackupHours = hours }
        if let minutes = try args.int("log-minutes") { thresholds.logBackupMinutes = minutes }
        let now = capabilities.serverTime ?? Date()
        print("\(capabilities.serverName) — \(capabilities.editionTitle) \(capabilities.productVersion), "
              + "Agent \(capabilities.isAgentRunning ? "running" : "not running")")
        let header = "Database".padding(toLength: 28, withPad: " ", startingAt: 0) + "State".padding(toLength: 16, withPad: " ", startingAt: 0)
            + "Recovery".padding(toLength: 12, withPad: " ", startingAt: 0) + "Last full".padding(toLength: 21, withPad: " ", startingAt: 0)
            + "Last diff".padding(toLength: 21, withPad: " ", startingAt: 0) + "Last log".padding(toLength: 21, withPad: " ", startingAt: 0) + "Status"
        print(header)
        var behind = false
        for status in databases {
            let risk = status.risk(now: now, thresholds: thresholds)
            if risk == .overdue || risk == .never { behind = true }
            let line = status.name.padding(toLength: 28, withPad: " ", startingAt: 0)
                + status.operationalState.rawValue.padding(toLength: 16, withPad: " ", startingAt: 0)
                + status.recoveryModel.padding(toLength: 12, withPad: " ", startingAt: 0)
                + (status.lastFull.map(ServerTime.display) ?? "-").padding(toLength: 21, withPad: " ", startingAt: 0)
                + (status.lastDifferential.map(ServerTime.display) ?? "-").padding(toLength: 21, withPad: " ", startingAt: 0)
                + (status.lastLog.map(ServerTime.display) ?? "-").padding(toLength: 21, withPad: " ", startingAt: 0)
                + risk.title
            print(line)
        }
        return behind && args.flag("assert-backed-up") ? .warning : .success
    }

    static func runHistory(_ args: Arguments) async throws -> ExitCode {
        let session = try await ConnectionArguments(prefix: "", args: args).connect()
        defer { Task { await session.close() } }
        let capabilities = try await BackupCapabilityProbe(session: session).probe()
        let now = capabilities.serverTime ?? Date()
        let days = try args.int("days") ?? 7
        let since = now.addingTimeInterval(-Double(days) * 86_400)
        let reader = BackupHistoryReader(session: session)
        let activities = try await reader.activity(since: since, database: args.string("database"))
        let scope: BackupReport.Scope
        switch (args.string("scope") ?? "all").lowercased() {
        case "failures", "failed": scope = .failures
        case "problems", "warnings": scope = .problems
        default: scope = .all
        }
        let report = BackupReport(serverName: capabilities.serverName, activities: activities,
                                  databases: try await reader.databases(), thresholds: BackupThresholds(),
                                  from: since, to: now.addingTimeInterval(60), scope: scope, now: now)
        if let output = args.string("output") {
            let format: CompareReportFormat
            switch (args.string("format") ?? URL(fileURLWithPath: output).pathExtension).lowercased() {
            case "csv": format = .csv
            case "json": format = .json
            default: format = .html
            }
            try report.render(format).write(to: URL(fileURLWithPath: output))
            log("Report written to \(output).", quiet: args.flag("quiet"))
        } else {
            for item in report.rows {
                let name = item.database.isEmpty ? item.jobName : item.database
                var line = "\(item.date.map(ServerTime.display) ?? "")  \(item.kindTitle.padding(toLength: 8, withPad: " ", startingAt: 0))"
                line += "\(name.padding(toLength: 24, withPad: " ", startingAt: 0)) \(item.typeTitle.padding(toLength: 18, withPad: " ", startingAt: 0))"
                line += item.succeeded ? " OK    " : " FAILED"
                if item.compressedSize > 0 { line += "  " + ByteCountFormatter.string(fromByteCount: item.compressedSize, countStyle: .file) }
                if let ratio = item.compressedBy { line += String(format: " (%.0f%% smaller)", ratio * 100) }
                if item.isEncrypted { line += " encrypted" }
                if !item.succeeded && !item.message.isEmpty { line += "\n      " + item.message.replacingOccurrences(of: "\n", with: " ") }
                print(line)
            }
        }
        return report.rows.contains { !$0.succeeded } ? .warning : .success
    }

    // MARK: - jobs

    static func schedules(_ args: Arguments, today: Date) throws -> [BackupSchedule] {
        try args.all("schedule").map { text in
            guard let schedule = BackupSchedule.parse(text, today: today) else {
                throw CLIError.usage("Cannot read the schedule '\(text)'. Examples: 'daily 00:00', 'every 15 minutes', "
                                     + "'weekly mon,fri 01:30', 'monthly 1 02:00', 'once 2026-11-01 03:00'.")
            }
            return schedule
        }
    }

    static func runJobs(_ args: Arguments) async throws -> ExitCode {
        let session = try await ConnectionArguments(prefix: "", args: args).connect()
        defer { Task { await session.close() } }
        let capabilities = try await BackupCapabilityProbe(session: session).probe()
        let manager = BackupJobManager(session: session)
        let today = capabilities.serverTime ?? Date()

        if args.flag("create-backup") || args.flag("create-verify") {
            guard capabilities.hasAgent else { throw CLIError.failed("\(capabilities.editionTitle) has no SQL Server Agent.") }
            let config: BackupJobConfig
            if args.flag("create-backup") {
                let options = try backupOptions(args)
                let errors = options.validationErrors(capabilities: capabilities)
                if !errors.isEmpty { throw CLIError.usage(errors.joined(separator: "\n")) }
                var schedules = try schedules(args, today: today)
                if schedules.isEmpty { schedules = [BackupSchedule.suggested(for: options.type, today: today)] }
                config = BackupJobConfig(backup: options, schedules: schedules)
            } else {
                var options = RestoreJobOptions()
                guard let source = args.string("source") else { throw CLIError.usage("--source (the database to verify) is required.") }
                options.sourceDatabase = source
                options.destinationDatabase = args.string("destination") ?? ""
                options.source = args.flag("latest-set") ? .latestSet : .latestFull
                options.checkDB = !args.flag("no-checkdb")
                switch (args.string("drop") ?? "success").lowercased() {
                case "always": options.drop = .always
                case "never": options.drop = .never
                default: options.drop = .onSuccess
                }
                if let folder = args.string("data-folder") { options.dataFolder = folder }
                if let folder = args.string("log-folder") { options.logFolder = folder }
                if let recipients = args.string("mail-to") {
                    options.notification = BackupNotification(level: args.string("mail-on") == "always" ? .always : .errorOnly,
                                                              recipients: recipients, mailProfile: args.string("mail-profile") ?? "")
                }
                var schedules = try schedules(args, today: today)
                if schedules.isEmpty { schedules = [BackupSchedule(name: "Daily at 18:30", startTime: 18 * 3600 + 30 * 60, startDate: today)] }
                config = BackupJobConfig(restore: options, schedules: schedules)
            }
            if args.flag("script") {
                print(manager.createScript(config, capabilities: capabilities))
                return .success
            }
            try await manager.create(config, capabilities: capabilities)
            print("Created job '\(config.jobName)': \(config.schedules.map(\.summary).joined(separator: "; "))")
            return .success
        }

        let jobs = try await manager.jobs()
        func find(_ name: String) throws -> BackupJobInfo {
            guard let job = jobs.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame || $0.id == name.uppercased() })
            else { throw CLIError.failed("No backup job named '\(name)'.") }
            return job
        }
        if let name = args.string("run") {
            try await manager.start(jobID: try find(name).id)
            print("Started '\(name)'.")
            return .success
        }
        if let name = args.string("delete") {
            try await manager.delete(jobID: try find(name).id)
            print("Deleted '\(name)'.")
            return .success
        }
        if let name = args.string("enable") {
            try await manager.setEnabled(jobID: try find(name).id, true)
            return .success
        }
        if let name = args.string("disable") {
            try await manager.setEnabled(jobID: try find(name).id, false)
            return .success
        }
        if let name = args.string("log") {
            for line in try await manager.log(jobID: try find(name).id) { print(line) }
            return .success
        }
        if jobs.isEmpty { print("No backup jobs.") }
        for job in jobs {
            print("\(job.isEnabled ? "on " : "off") \(job.name)")
            print("      \(job.kindTitle) · \(job.databases) · \(job.scheduleSummary)")
            let next = job.nextRun(after: today).map(ServerTime.display) ?? "-"
            let last = job.lastRun.map(ServerTime.display) ?? "-"
            print("      next \(next) · last \(last) \(job.lastOutcome)\(job.isRunning ? " · running now" : "")")
        }
        return .success
    }

    // MARK: - analyze

    static func runAnalyze(_ args: Arguments) async throws -> ExitCode {
        guard let database = args.string("database") else { throw CLIError.usage("--database is required.") }
        let session = try await ConnectionArguments(prefix: "", args: args).connect()
        defer { Task { await session.close() } }
        let capabilities = try await BackupCapabilityProbe(session: session).probe()
        let trials = try await CompressionAnalyzer(session: session, capabilities: capabilities).analyze(database: database)
        print("Level  Compression                                   Size        Smaller by  Time")
        for trial in trials {
            let size = ByteCountFormatter.string(fromByteCount: trial.compressedSize, countStyle: .file)
            print("\(trial.level)      \(trial.description.padding(toLength: 46, withPad: " ", startingAt: 0))"
                  + "\(size.padding(toLength: 12, withPad: " ", startingAt: 0))"
                  + String(format: "%5.1f%%      %.1f s", trial.ratio * 100, trial.duration))
        }
        return .success
    }

    // MARK: - log shipping

    static func runLogShipping(_ args: Arguments) async throws -> ExitCode {
        let primary = try await ConnectionArguments(prefix: "", args: args).connect()
        defer { Task { await primary.close() } }
        if args.flag("status") {
            for status in try await LogShippingMonitor(session: primary).status() {
                print("\(status.primaryServer).\(status.primaryDatabase) → \(status.secondaryServer).\(status.secondaryDatabase)")
                print("    last backup   \(status.lastBackupDate.map(ServerTime.display) ?? "-")  \(status.lastBackupFile)")
                print("    last copied   \(status.lastCopiedDate.map(ServerTime.display) ?? "-")  \(status.lastCopiedFile)")
                print("    last restored \(status.lastRestoredDate.map(ServerTime.display) ?? "-")  \(status.lastRestoredFile)")
            }
            return .success
        }
        let secondary = ConnectionArguments(prefix: "secondary", args: args).server == nil
            ? primary : try await ConnectionArguments(prefix: "secondary", args: args).connect()
        var options = LogShippingOptions()
        guard let database = args.string("database") else { throw CLIError.usage("--database (the primary database) is required.") }
        options.primaryDatabase = database
        options.secondaryDatabase = args.string("secondary-database") ?? database
        options.backupFolder = args.string("backup-folder") ?? ""
        options.backupShare = args.string("share") ?? options.backupFolder
        options.copyFolder = args.string("copy-folder") ?? ""
        if args.flag("standby") { options.restoreMode = .readOnly }
        if let minutes = try args.int("every") {
            options.backupEveryMinutes = minutes
            options.copyEveryMinutes = minutes
        }
        if let minutes = try args.int("retention-minutes") { options.retentionMinutes = minutes }
        options.initialize = !args.flag("no-init")
        let primaryCapabilities = try await BackupCapabilityProbe(session: primary).probe()
        let secondaryCapabilities = try await BackupCapabilityProbe(session: secondary).probe()
        let errors = options.validationErrors(sameServer: primaryCapabilities.serverName == secondaryCapabilities.serverName)
        if !errors.isEmpty { throw CLIError.usage(errors.joined(separator: "\n")) }
        let setup = LogShippingSetup(primary: primary, secondary: secondary, options: options,
                                     primaryCapabilities: primaryCapabilities, secondaryCapabilities: secondaryCapabilities)
        if args.flag("script") {
            print(setup.script())
            return .success
        }
        try await setup.run { message in log(message, quiet: args.flag("quiet")) }
        return .success
    }

    // MARK: - certificates

    static func runCertificates(_ args: Arguments) async throws -> ExitCode {
        let session = try await ConnectionArguments(prefix: "", args: args).connect()
        defer { Task { await session.close() } }
        let keys = BackupEncryptionKeys(session: session)
        if let name = args.string("create") {
            let years = try args.int("years") ?? 10
            let expiry = Date().addingTimeInterval(Double(years) * 365 * 86_400)
            try await keys.create(name: name, subject: args.string("subject") ?? "Backup encryption",
                                  expiry: expiry, masterKeyPassword: args.string("master-key-password"))
            print("Created certificate \(name). Export it with --export now: without it, encrypted backups "
                  + "cannot be restored anywhere else.")
            return .success
        }
        if let name = args.string("export") {
            guard let password = args.string("key-password"), let file = args.string("file") else {
                throw CLIError.usage("--export needs --key-password (protects the private key) and --file.")
            }
            let bundle = try await keys.export(name: name, password: password)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(bundle).write(to: URL(fileURLWithPath: file))
            print("Exported \(name) with its private key to \(file).")
            return .success
        }
        if let file = args.string("import") {
            guard let password = args.string("key-password") else { throw CLIError.usage("--import needs --key-password.") }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let bundle = try decoder.decode(BackupCertificateBundle.self, from: Data(contentsOf: URL(fileURLWithPath: file)))
            try await keys.importBundle(bundle, password: password, masterKeyPassword: args.string("master-key-password"))
            print("Imported certificate \(bundle.name).")
            return .success
        }
        for certificate in try await keys.certificates() {
            let expiry = certificate.expiry.map(ServerTime.display) ?? "-"
            let key = certificate.hasPrivateKey ? "private key" : "no private key"
            let backedUp = certificate.privateKeyLastBackedUp.map { "key backed up \(ServerTime.display($0))" } ?? "key never backed up"
            print("\(certificate.name)  expires \(expiry) · \(key) · \(backedUp) · \(certificate.thumbprint)")
        }
        return .success
    }

    // MARK: - Help

    static let usage = """
    ssms-backup — SQL Server backup, restore and verification

    USAGE
      ssms-backup backup   --server S --database DB [options]
      ssms-backup restore  --server S --database TARGET [--source DB | FILE …] [options]
      ssms-backup verify   --server S FILE …
      ssms-backup status   --server S
      ssms-backup history  --server S [--days 7] [--database DB] [--output report.html]
      ssms-backup jobs     --server S [--create-backup … | --create-verify … | --run NAME | --delete NAME]
      ssms-backup analyze  --server S --database DB
      ssms-backup log-shipping --server PRIMARY --database DB --secondary-server STANDBY …
      ssms-backup certificates --server S [--create NAME | --export NAME | --import FILE]

    CONNECTION
      --server <host[,port]|host\\instance>  --user <login>  --password <pw>
        (or SSMS_USER / SSMS_PASSWORD, SQL_USER / SQL_PASSWORD)
      --auth sql|windows|entra|token  --domain <domain>  --token <access token>
      --encrypt required|strict|off  --verify-certificate

    BACKUP
      --database a,b | --all-databases | --user-databases | --system-databases [--exclude a,b]
      --type full|diff|log          --copy-only           --no-truncate (log)
      --folder <server folder>      --name-format "<TYPE>_<INSTANCE>_<DATABASE>_<DATETIME yyyymmdd_hhnnss>"
        tags: <AUTO> <DATABASE> <INSTANCE> <SERVER> <AVAILABILITYGROUP> <TYPE> <DATETIME format>
      --url https://account.blob.core.windows.net/container | s3://host/bucket  [--s3-region r]
      --split N                     stripe over N files (2–64)
      --mirror <folder>             repeatable, up to 3 (Enterprise/Developer)
      --overwrite                   replace files of the same name (otherwise the backup fails)
      --erase-files 7|12h|5b        delete older backups of the same database and type:
                                    older than 7 days, older than 12 hours, or keep the latest 5
      --erase-before                delete before the backup instead of after it succeeds
      --erase-mirror-files …        the same, in the mirror folders
      --compression 0-4             0 none, 1 fastest … 4 smallest (ZSTD levels on SQL Server 2025)
      --encrypt-certificate NAME    [--encrypt-algorithm AES_128|AES_192|AES_256|TRIPLE_DES_3KEY]
      --checksum | --no-checksum    --continue-after-error   --verify
      --retries N --retry-interval S   retry after file and network errors (default 10 × 30 s)
      --max-transfer-size B  --buffer-count N  --block-size B
      --preferred-replica-only      --secondary-copy-only   (availability groups)
      --backup-name T  --description T
      --mail-to a@x;b@y [--mail-on error|warning|always] [--mail-profile P]   (Database Mail)
      --template file.json          start from a saved template; --save-template file.json saves one
      --script                      print the T-SQL instead of running it

    RESTORE
      --source DB                   restore from DB's backup history (default: the target's own)
      FILE … | --files a,b          restore from backup files on the server instead
      --stop-at "yyyy-mm-dd hh:mm:ss"   point in time (default: latest)
      --backup-set-id N             restore up to this backup set   --full-only   just the latest full
      --replace  --no-kill  --tail-log <file>
      --data-folder F --log-folder F | --original-locations
      --norecovery | --standby [undo file]
      --checkdb  --drop always|success  --fix-orphans  --no-orphan-check  --keep-cdc  --keep-replication
      --script  --verbose

    JOBS (SQL Server Agent)
      --create-backup <backup options> --schedule "daily 00:00" [--schedule …]
      --create-verify --source DB [--destination DB_Verify] [--latest-set] [--no-checkdb]
                      [--drop success|always|never] --schedule "daily 18:30"
        schedules: "daily 00:00", "every 15 minutes", "daily every 2 hours from 08:00 to 18:00",
                   "weekly mon,wed,fri 01:30", "monthly 1 02:00", "once 2026-11-01 03:00", "agent-start"
      --run NAME  --enable NAME  --disable NAME  --delete NAME  --log NAME  --script

    CERTIFICATES (backup encryption keys in master)
      ssms-backup certificates --server S                       list
      --create NAME [--master-key-password P] [--years 10]       create (and master's key when missing)
      --export NAME --key-password P --file cert.sqlcert         export with its private key
      --import cert.sqlcert --key-password P [--master-key-password P]   import on another server

    LOG SHIPPING
      --database DB --secondary-server S2 [--secondary-database DB2] --backup-folder F --share F2 --copy-folder F3
      [--standby] [--every 15] [--retention-minutes 4320] [--no-init] [--script]   |   --status

    EXIT CODES
      0 success · 1 completed with warnings · 2 failed · 64 invalid command line
    """
}
