import Foundation
import TDSKit

// MARK: - Progress

/// What a running backup or restore reports to its window.
public struct BackupProgressEvent: Sendable {
    public enum Phase: String, Sendable {
        case preparing
        case backingUp
        case verifying
        case cleaningUp
        case restoring
        case checking
        case finished
    }

    public var database: String
    public var phase: Phase
    /// 0…1 within the current statement, when the server reports it.
    public var fraction: Double?
    public var message: String
    public var index: Int
    public var total: Int
}

/// Errors a statement raised, kept whole so callers can tell an I/O failure from the rest.
public struct BackupOperationError: Error, CustomStringConvertible, Sendable {
    public var messages: [TDSServerMessage]

    public var description: String {
        messages.map { "Msg \($0.number), Level \($0.severity): \($0.text)" }.joined(separator: "\n")
    }

    /// File and network errors worth retrying (SQL Backup's network resilience). Missing paths
    /// and denied access will not fix themselves, so they fail at once.
    public var isTransientIOError: Bool {
        let ioNumbers: Set<Int32> = [3201, 3202, 3203, 3204, 3271, 3634]
        guard messages.contains(where: { ioNumbers.contains(Int32($0.number)) }) else { return false }
        let permanent = ["error 2(", "error 3(", "error 5(", "error 123(", "no such file", "access is denied",
                         "permission denied", "cannot find the path", "cannot find the file"]
        let text = messages.map { $0.text.lowercased() }.joined(separator: " ")
        return !permanent.contains { text.contains($0) }
    }
}

/// Runs one statement on a connection, streaming its info messages.
struct StreamingStatement {
    final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var infos: [TDSServerMessage] = []
        private var errors: [TDSServerMessage] = []
        private var rows: [[String: TDSValue]] = []
        private var columns: [TDSColumn] = []

        func add(_ event: TDSStreamEvent) -> TDSServerMessage? {
            lock.lock()
            defer { lock.unlock() }
            switch event {
            case .info(let message):
                infos.append(message)
                return message
            case .error(let message):
                errors.append(message)
                return message
            case .columns(let list):
                columns = list
            case .row(let values):
                var row: [String: TDSValue] = [:]
                for column in columns where column.index < values.count { row[column.name] = values[column.index] }
                rows.append(row)
            default:
                break
            }
            return nil
        }

        var snapshot: (infos: [TDSServerMessage], errors: [TDSServerMessage], rows: [[String: TDSValue]]) {
            lock.lock()
            defer { lock.unlock() }
            return (infos, errors, rows)
        }
    }

    struct Output {
        var messages: [String]
        var rows: [[String: TDSValue]]
    }

    /// Info messages arrive while the statement runs; `onMessage` sees each as it comes.
    static func run(_ sql: String, on connection: TDSConnection,
                    onMessage: (@Sendable (TDSServerMessage) -> Void)? = nil) async throws -> Output {
        let collector = Collector()
        try await withTaskCancellationHandler {
            try await connection.execute(sql) { event in
                if let message = collector.add(event) { onMessage?(message) }
            }
        } onCancel: {
            connection.cancel()
        }
        let snapshot = collector.snapshot
        let failures = snapshot.errors.filter { $0.severity >= 11 }
        if !failures.isEmpty { throw BackupOperationError(messages: failures) }
        return Output(messages: snapshot.infos.map(\.text), rows: snapshot.rows)
    }

    /// "35 percent processed." as 0.35.
    static func fraction(of message: TDSServerMessage) -> Double? {
        let text = message.text.trimmingCharacters(in: .whitespaces)
        guard text.hasSuffix("percent processed."), let number = Int(text.prefix { $0.isNumber }) else { return nil }
        return Double(number) / 100
    }
}

// MARK: - Backup runner

/// Runs a one-off backup of one or more databases, the way the Back Up wizard's last step does.
public struct BackupRunner: Sendable {
    public let session: SQLServerSession
    public let options: BackupOptions
    public let capabilities: BackupServerCapabilities
    public let defaultFormat: String

    public typealias Progress = @Sendable (BackupProgressEvent) -> Void

    public init(session: SQLServerSession, options: BackupOptions, capabilities: BackupServerCapabilities,
                defaultFormat: String = BackupOptions.defaultFileNameFormat) {
        self.session = session
        self.options = options
        self.capabilities = capabilities
        self.defaultFormat = defaultFormat
    }

    var scripter: BackupScripter { BackupScripter(options: options, capabilities: capabilities, defaultFormat: defaultFormat) }

    /// The databases the selection covers, each with the reason it will be skipped, if any.
    public func resolveDatabases() async throws -> [(name: String, skipReason: String?)] {
        let statuses = try await BackupHistoryReader(session: session).databases()
        return Self.resolve(options.databases, type: options.type, statuses: statuses)
    }

    /// The databases a selection stands for, each with the reason it cannot be backed up, if any.
    public static func resolve(_ selection: DatabaseSelection, type: BackupType,
                        statuses: [DatabaseBackupStatus]) -> [(name: String, skipReason: String?)] {
        let excluded = Set(selection.excluded.map { $0.lowercased() })
        let byName = Dictionary(statuses.map { ($0.name.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        var names: [String]
        switch selection.scope {
        case .selected: names = selection.names
        case .all: names = statuses.map(\.name)
        case .user: names = statuses.filter { !$0.isSystem }.map(\.name)
        case .system: names = statuses.filter { $0.isSystem }.map(\.name)
        }
        names = names.filter { !excluded.contains($0.lowercased()) && $0.lowercased() != "tempdb" }
        return names.compactMap { name in
            guard let status = byName[name.lowercased()] else { return (name, "The database does not exist.") }
            // Scopes silently leave out what cannot be backed up; explicit picks say why not.
            if selection.scope != .selected, status.isSnapshot || status.stateDescription.uppercased() != "ONLINE" {
                return nil
            }
            if selection.scope != .selected, type != .full, status.reasonCannotBackUp(type) != nil { return nil }
            return (status.name, status.reasonCannotBackUp(type))
        }
    }

    public func run(progress: Progress? = nil) async throws -> BackupRunResult {
        let started = Date()
        let databases = try await resolveDatabases()
        let connection = try await session.openConnection(database: "master")
        defer { Task { try? await connection.close() } }

        var results: [DatabaseBackupResult] = []
        for (index, entry) in databases.enumerated() {
            try Task.checkCancellation()
            var result = DatabaseBackupResult(database: entry.name, type: options.type)
            if let reason = entry.skipReason {
                result.skipped = options.databases.scope != .selected
                result.errors.append(reason)
                results.append(result)
                continue
            }
            result = await backUp(entry.name, on: connection, index: index, total: databases.count, progress: progress)
            results.append(result)
        }
        var run = BackupRunResult(results: results, startedAt: started, duration: Date().timeIntervalSince(started))
        if options.notification.isEnabled,
           options.notification.shouldSend(errors: run.hasErrors, warnings: run.hasWarnings) {
            do {
                try await sendMail(run, on: connection)
                run.emailSent = true
            } catch {
                for index in run.results.indices where run.results[index].succeeded {
                    run.results[index].warnings.append("The notification email could not be sent: "
                                                       + ScriptRunner.describe(error))
                    break
                }
            }
        }
        progress?(BackupProgressEvent(database: "", phase: .finished, fraction: 1, message: run.summary,
                                      index: databases.count, total: databases.count))
        return run
    }

    // MARK: One database

    func backUp(_ database: String, on connection: TDSConnection, index: Int, total: Int,
                progress: Progress?) async -> DatabaseBackupResult {
        var result = DatabaseBackupResult(database: database, type: options.type)
        let started = Date()
        result.startedAt = started
        @Sendable func report(_ phase: BackupProgressEvent.Phase, _ message: String, _ fraction: Double? = nil) {
            progress?(BackupProgressEvent(database: database, phase: phase, fraction: fraction, message: message,
                                          index: index, total: total))
        }
        report(.preparing, "Preparing")
        do {
            let facts = try await StreamingStatement.run(Self.factsQuery(database, capabilities: capabilities),
                                                         on: connection)
            let row = facts.rows.first ?? [:]
            let now = row.serverDate("now") ?? Date()
            if options.checkPreferredReplica && row.int("preferred", default: 1) == 0 {
                result.skipped = true
                result.succeeded = true
                result.warnings.append("Not backed up: this is not the preferred backup replica.")
                result.duration = Date().timeIntervalSince(started)
                return result
            }
            var copyOnly = options.copyOnly
            if options.secondaryReplicaCopyOnly && options.type == .full && row.int("is_primary", default: 1) == 0 {
                copyOnly = true
            }
            let plan = scripter.plan(database: database, date: now, availabilityGroup: row.string("ag"))
            result.files = plan.files
            result.mirrorFiles = plan.mirrorFiles.flatMap { $0 }

            if !plan.isURL {
                for folder in [plan.folder] + plan.mirrorFolders where !folder.isEmpty {
                    _ = try await StreamingStatement.run(
                        "EXEC master.dbo.xp_create_subdir \(SQLIdentifier.literal(folder));", on: connection)
                }
                if !options.overwrite {
                    _ = try await StreamingStatement.run(BackupScripter.existenceCheck(paths: plan.allFiles),
                                                         on: connection)
                }
            }
            var warnings: [String] = []
            if options.retention.beforeBackup {
                let deleted = try await retention(database, plan: plan, on: connection, warnings: &warnings)
                result.deletedFiles += deleted
            }

            let context = scripter.context(database: database, date: now, availabilityGroup: row.string("ag"))
            let name = options.backupName.isEmpty ? nil : BackupFileNaming.expand(options.backupName, context: context)
            let description = options.backupDescription.isEmpty ? nil
                : BackupFileNaming.expand(options.backupDescription, context: context)
            let statement = scripter.backupStatement(database: database, plan: plan, copyOnly: copyOnly,
                                                     name: name, description: description)
            result.script = statement
            report(.backingUp, "Backing up", 0)
            var attempts = 0
            let output = try await withRetries(attempts: &attempts, warnings: &warnings) {
                try await StreamingStatement.run(statement, on: connection) { message in
                    if let fraction = StreamingStatement.fraction(of: message) {
                        report(.backingUp, "Backing up", fraction)
                    }
                }
            }
            result.attempts = attempts
            result.messages += output.messages

            if options.verify {
                report(.verifying, "Verifying", 0)
                do {
                    let verify = try await StreamingStatement.run(scripter.verifyStatement(plan: plan), on: connection) {
                        message in
                        if let fraction = StreamingStatement.fraction(of: message) {
                            report(.verifying, "Verifying", fraction)
                        }
                    }
                    result.messages += verify.messages
                    result.verified = true
                } catch {
                    result.verified = false
                    warnings.append("The backup was created but failed verification: \(ScriptRunner.describe(error))")
                }
            }
            if !options.retention.beforeBackup {
                report(.cleaningUp, "Deleting old backup files")
                let deleted = try await retention(database, plan: plan, on: connection, warnings: &warnings)
                result.deletedFiles += deleted
            }
            result.warnings += warnings
            if let sizes = try? await StreamingStatement.run(Self.sizeQuery(database), on: connection),
               let row = sizes.rows.first {
                result.backupSize = row.int64("backup_size")
                result.compressedSize = row.int64("compressed_size")
            }
            result.succeeded = true
        } catch {
            result.errors.append(ScriptRunner.describe(error))
        }
        result.duration = Date().timeIntervalSince(started)
        return result
    }

    /// Runs `operation`, retrying transient file and network errors.
    func withRetries<T>(attempts: inout Int, warnings: inout [String],
                        _ operation: () async throws -> T) async throws -> T {
        var attempt = 0
        while true {
            attempt += 1
            attempts = attempt
            do {
                let value = try await operation()
                if attempt > 1 {
                    warnings.append("The backup succeeded after \(attempt) attempts.")
                }
                return value
            } catch let error as BackupOperationError where error.isTransientIOError && attempt <= options.retryCount {
                try await Task.sleep(nanoseconds: UInt64(max(1, options.retryIntervalSeconds)) * 1_000_000_000)
            }
        }
    }

    /// Deletes old files in the primary folder and in each mirror folder. A clean-up failure is a
    /// warning: the backup itself is fine.
    func retention(_ database: String, plan: BackupFilePlan, on connection: TDSConnection,
                   warnings: inout [String]) async throws -> [String] {
        guard !plan.isURL else { return [] }
        var deleted: [String] = []
        var scripts: [String] = []
        if options.retention.isEnabled {
            scripts.append(BackupScripter.retentionScript(rule: options.retention, type: options.type,
                                                          databaseExpression: SQLIdentifier.literal(database),
                                                          folderExpression: SQLIdentifier.literal(plan.folder)))
        }
        if options.mirrorRetention.isEnabled {
            for (offset, folder) in plan.mirrorFolders.enumerated() {
                scripts.append(BackupScripter.retentionScript(rule: options.mirrorRetention, type: options.type,
                                                              databaseExpression: SQLIdentifier.literal(database),
                                                              folderExpression: SQLIdentifier.literal(folder),
                                                              suffix: "m\(offset)"))
            }
        }
        for script in scripts {
            do {
                let output = try await StreamingStatement.run(script, on: connection)
                for message in output.messages where message.hasPrefix(BackupScripter.deletedFilePrefix) {
                    deleted.append(String(message.dropFirst(BackupScripter.deletedFilePrefix.count)))
                }
            } catch {
                warnings.append("Old backup files could not be deleted: \(ScriptRunner.describe(error))")
            }
        }
        return deleted
    }

    static func factsQuery(_ database: String, capabilities: BackupServerCapabilities) -> String {
        let name = SQLIdentifier.literal(database)
        let hadr = capabilities.isHadrEnabled && capabilities.majorVersion >= 11
        let preferred = hadr ? "sys.fn_hadr_backup_is_preferred_replica(\(name))" : "1"
        let primary = hadr && capabilities.majorVersion >= 12 ? "ISNULL(sys.fn_hadr_is_primary_replica(\(name)), 1)" : "1"
        let ag = hadr
            ? "ISNULL((SELECT TOP (1) ag.name FROM sys.availability_databases_cluster AS adc "
                + "JOIN sys.availability_groups AS ag ON ag.group_id = adc.group_id "
                + "WHERE adc.database_name = \(name)), N'')"
            : "N''"
        return "SELECT SYSDATETIME() AS now, CAST(\(preferred) AS int) AS preferred, "
            + "CAST(\(primary) AS int) AS is_primary, \(ag) AS ag;"
    }

    static func sizeQuery(_ database: String) -> String {
        "SELECT TOP (1) CAST(backup_size AS bigint) AS backup_size, "
            + "CAST(ISNULL(compressed_backup_size, backup_size) AS bigint) AS compressed_size "
            + "FROM msdb.dbo.backupset WHERE database_name = \(SQLIdentifier.literal(database)) "
            + "ORDER BY backup_set_id DESC;"
    }

    // MARK: Email

    func sendMail(_ run: BackupRunResult, on connection: TDSConnection) async throws {
        let outcome = run.hasErrors ? "FAILED" : (run.hasWarnings ? "completed with warnings" : "succeeded")
        let subject = "\(options.type.title) backup on \(capabilities.serverName) \(outcome)"
        var body: [String] = ["\(options.type.title) backup on \(capabilities.serverName): \(run.summary)", ""]
        for result in run.results {
            body.append("\(result.database): " + (result.succeeded ? "succeeded" : (result.skipped ? "skipped" : "FAILED")))
            for file in result.files { body.append("    \(file)") }
            for error in result.errors { body.append("    Error: \(error)") }
            for warning in result.warnings { body.append("    Warning: \(warning)") }
            for file in result.deletedFiles { body.append("    Deleted \(file)") }
        }
        let sql = BackupMail.sendScript(notification: options.notification, subject: subject,
                                        body: body.joined(separator: "\n"))
        _ = try await StreamingStatement.run(sql, on: connection)
    }
}

/// Database Mail calls shared by one-off runs and jobs.
public enum BackupMail {
    public static func sendScript(notification: BackupNotification, subject: String, body: String) -> String {
        var arguments: [String] = []
        if !notification.mailProfile.isEmpty {
            arguments.append("@profile_name = \(SQLIdentifier.literal(notification.mailProfile))")
        }
        arguments.append("@recipients = \(SQLIdentifier.literal(notification.recipients))")
        arguments.append("@subject = \(SQLIdentifier.literal(subject))")
        arguments.append("@body = \(SQLIdentifier.literal(body))")
        return "EXEC msdb.dbo.sp_send_dbmail " + arguments.joined(separator: ", ") + ";"
    }
}

// MARK: - Restore runner

/// A user whose login is missing on the restore target.
public struct OrphanedUser: Sendable, Hashable, Identifiable {
    public var id: String { name }
    public var name: String
    public var sid: String
    /// A login with the same name exists, so the user can be mapped back to it.
    public var loginExists: Bool
    public var fixed: Bool = false
}

public struct RestoreOutcome: Sendable {
    public var succeeded: Bool
    public var messages: [String]
    public var orphanedUsers: [OrphanedUser]
    public var checkDBErrors: [String]
    public var dropped: Bool
    public var failedStep: String?
    public var error: String?
    public var duration: TimeInterval
    public var hasWarnings: Bool { !orphanedUsers.filter { !$0.fixed }.isEmpty }
}

/// Runs a restore plan step by step.
public struct RestoreRunner: Sendable {
    public let session: SQLServerSession
    public let planner: RestorePlanner

    public typealias Progress = @Sendable (BackupProgressEvent) -> Void

    public init(session: SQLServerSession, planner: RestorePlanner) {
        self.session = session
        self.planner = planner
    }

    public func run(progress: Progress? = nil) async -> RestoreOutcome {
        let started = Date()
        var outcome = RestoreOutcome(succeeded: false, messages: [], orphanedUsers: [], checkDBErrors: [],
                                     dropped: false, failedStep: nil, error: nil, duration: 0)
        let steps = planner.steps()
        let destination = planner.destination
        let connection: TDSConnection
        do {
            connection = try await session.openConnection(database: "master")
        } catch {
            outcome.error = ScriptRunner.describe(error)
            return outcome
        }
        defer { Task { try? await connection.close() } }

        var failed = false
        for (index, step) in steps.enumerated() {
            if step.kind == .drop {
                let shouldDrop = planner.options.drop == .always || (!failed && outcome.checkDBErrors.isEmpty)
                guard shouldDrop else { continue }
            } else if failed {
                continue
            }
            let phase: BackupProgressEvent.Phase = step.kind == .checkDB ? .checking
                : (step.kind == .drop ? .cleaningUp : .restoring)
            progress?(BackupProgressEvent(database: destination, phase: phase, fraction: 0, message: step.title,
                                          index: index, total: steps.count))
            do {
                let output = try await StreamingStatement.run(step.sql, on: connection) { message in
                    if let fraction = StreamingStatement.fraction(of: message) {
                        progress?(BackupProgressEvent(database: destination, phase: phase, fraction: fraction,
                                                      message: step.title, index: index, total: steps.count))
                    }
                }
                outcome.messages.append("-- \(step.title)")
                outcome.messages += output.messages
                switch step.kind {
                case .orphanCheck:
                    outcome.orphanedUsers = output.rows.map {
                        OrphanedUser(name: $0.string("user_name"), sid: $0.string("sid"),
                                     loginExists: $0.int("login_exists") == 1)
                    }
                    if planner.options.fixOrphanedUsers {
                        await fixOrphans(&outcome, on: connection)
                    }
                case .drop:
                    outcome.dropped = true
                default:
                    break
                }
            } catch {
                let text = ScriptRunner.describe(error)
                outcome.messages.append(text)
                if step.kind == .checkDB {
                    outcome.checkDBErrors.append(text)
                } else if step.kind == .orphanCheck {
                    outcome.messages.append("The orphaned-user check could not run.")
                } else {
                    failed = true
                    outcome.failedStep = step.title
                    outcome.error = text
                }
            }
        }
        outcome.succeeded = !failed && outcome.checkDBErrors.isEmpty
        if outcome.error == nil, let first = outcome.checkDBErrors.first { outcome.error = first }
        outcome.duration = Date().timeIntervalSince(started)
        progress?(BackupProgressEvent(database: destination, phase: .finished, fraction: 1,
                                      message: outcome.succeeded ? "Restore complete" : "Restore failed",
                                      index: steps.count, total: steps.count))
        return outcome
    }

    /// Backs up the tail of a database's log, leaving it restoring, before it is overwritten.
    /// Callers read the history again afterwards so a restore to the latest point includes the
    /// tail itself, and nothing committed since the last log backup is lost.
    public static func backUpTail(session: SQLServerSession, database: String, path: String,
                                  killConnections: Bool) async throws {
        let target = SQLIdentifier.quote(database)
        var sql = ""
        if killConnections { sql += "ALTER DATABASE \(target) SET SINGLE_USER WITH ROLLBACK IMMEDIATE;\n" }
        sql += "BACKUP LOG \(target) TO DISK = \(SQLIdentifier.literal(path))\n"
            + "    WITH NORECOVERY, FORMAT, INIT, NAME = N'Tail-log backup', STATS = 10;"
        let connection = try await session.openConnection(database: "master")
        defer { Task { try? await connection.close() } }
        do {
            _ = try await StreamingStatement.run(sql, on: connection)
        } catch {
            if killConnections {
                _ = try? await StreamingStatement.run(
                    "IF DATABASEPROPERTYEX(\(SQLIdentifier.literal(database)), 'Status') = 'ONLINE' "
                        + "ALTER DATABASE \(target) SET MULTI_USER;", on: connection)
            }
            throw error
        }
    }

    func fixOrphans(_ outcome: inout RestoreOutcome, on connection: TDSConnection) async {
        for index in outcome.orphanedUsers.indices where outcome.orphanedUsers[index].loginExists {
            let user = outcome.orphanedUsers[index].name
            let sql = RestorePlanner.fixOrphanScript(database: planner.destination, users: [user])
            if (try? await StreamingStatement.run(sql + "\nUSE [master];", on: connection)) != nil {
                outcome.orphanedUsers[index].fixed = true
                outcome.messages.append("Mapped user \(user) to the login of the same name.")
            }
        }
    }
}
