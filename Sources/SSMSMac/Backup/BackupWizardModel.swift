import SwiftUI
import AppKit
import SQLServerKit

/// State of the Back Up / Schedule Backup Jobs / Edit Backup Job wizard.
@MainActor
final class BackupWizardModel: ObservableObject {
    enum Mode: Identifiable, Equatable {
        case backUpNow
        case schedule
        case edit(BackupJobInfo)

        var id: String {
            switch self {
            case .backUpNow: return "now"
            case .schedule: return "schedule"
            case .edit(let job): return "edit-\(job.id)"
            }
        }

        var title: String {
            switch self {
            case .backUpNow: return "Back Up"
            case .schedule: return "Schedule Backup Jobs"
            case .edit: return "Edit Backup Job"
            }
        }
    }

    enum Step: String, CaseIterable, Identifiable {
        case databases = "Type and Databases"
        case files = "Files"
        case processing = "Compression and Encryption"
        case verification = "Verification and Email"
        case schedules = "Schedules"
        case summary = "Summary"
        var id: String { rawValue }
    }

    let mode: Mode
    let session: SQLServerSession
    let capabilities: BackupServerCapabilities
    let databases: [DatabaseBackupStatus]
    let defaultFormat: String
    let serverName: String

    @Published var options: BackupOptions
    /// Schedule mode: the backup types to create jobs for, each with its own schedules.
    @Published var types: Set<BackupType> = [.full]
    @Published var schedules: [BackupType: [BackupSchedule]] = [:]
    @Published var createReminder = true
    @Published var step: Step = .databases
    @Published var certificates: [BackupCertificate] = []
    @Published var mailProfiles: [String] = []
    @Published var credentials: [String] = []
    @Published var templateName = ""

    @Published private(set) var isRunning = false
    @Published private(set) var progress: [String: Double] = [:]
    @Published private(set) var phases: [String: String] = [:]
    @Published private(set) var result: BackupRunResult?
    @Published private(set) var createdJobs: [String] = []
    @Published var errorText: String?
    private var runTask: Task<Void, Never>?

    init(mode: Mode, window: BackupWindowModel, session: SQLServerSession, capabilities: BackupServerCapabilities,
         database: String?) {
        self.mode = mode
        self.session = session
        self.capabilities = capabilities
        self.databases = window.databases
        self.defaultFormat = window.defaultFormat
        self.serverName = window.serverName
        var options = BackupOptions()
        options.compressionLevel = capabilities.canCompress ? 1 : 0
        options.checksum = true
        var types: Set<BackupType> = [.full]
        var schedules: [BackupType: [BackupSchedule]] = [:]
        let today = window.serverNow
        switch mode {
        case .edit(let job):
            if let config = job.config, let backup = config.backup {
                options = backup
                types = [backup.type]
                schedules = [backup.type: config.schedules]
            }
        case .schedule:
            options.databases = database.map { .databases([$0]) } ?? DatabaseSelection(scope: .user)
            for type in BackupType.allCases { schedules[type] = [BackupSchedule.suggested(for: type, today: today)] }
        case .backUpNow:
            options.databases = database.map { .databases([$0]) } ?? DatabaseSelection()
        }
        // Every stored property must be set before the published ones can be assigned through self.
        self.options = options
        self.types = types
        self.schedules = schedules
    }

    var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    var steps: [Step] {
        mode == .backUpNow ? Step.allCases.filter { $0 != .schedules } : Step.allCases
    }

    var stepIndex: Int { steps.firstIndex(of: step) ?? 0 }

    func next() { if stepIndex + 1 < steps.count { step = steps[stepIndex + 1] } }
    func back() { if stepIndex > 0 { step = steps[stepIndex - 1] } }

    /// The types jobs are created for (or the one type of a one-off backup or an edited job).
    var effectiveTypes: [BackupType] {
        mode == .schedule ? BackupType.allCases.filter { types.contains($0) } : [options.type]
    }

    func options(for type: BackupType) -> BackupOptions {
        var copy = options
        copy.type = type
        if type == .differential { copy.copyOnly = false }
        return copy
    }

    // MARK: Lookups

    func loadLookups() async {
        certificates = (try? await BackupEncryptionKeys(session: session).certificates()) ?? []
        if capabilities.databaseMailEnabled {
            mailProfiles = (try? await DatabaseMailService(session: session).profiles()) ?? []
        }
        credentials = (try? await CloudCredential.list(session: session)) ?? []
    }

    // MARK: Databases

    func isSelected(_ name: String) -> Bool {
        options.databases.names.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    func setSelected(_ name: String, _ value: Bool) {
        var names = options.databases.names.filter { $0.caseInsensitiveCompare(name) != .orderedSame }
        if value { names.append(name) }
        options.databases.names = databases.map(\.name).filter { candidate in names.contains(candidate) }
    }

    func isExcluded(_ name: String) -> Bool {
        options.databases.excluded.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    func setExcluded(_ name: String, _ value: Bool) {
        var names = options.databases.excluded.filter { $0.caseInsensitiveCompare(name) != .orderedSame }
        if value { names.append(name) }
        options.databases.excluded = names
    }

    /// Why a database cannot get the backup type in question (first selected type when scheduling).
    func reason(_ status: DatabaseBackupStatus) -> String? {
        status.reasonCannotBackUp(effectiveTypes.first ?? options.type)
    }

    /// Databases a scope or selection resolves to now.
    var resolvedDatabases: [String] {
        BackupRunnerPreview.resolve(options.databases, type: effectiveTypes.first ?? .full, statuses: databases)
    }

    // MARK: Validation

    func errors(for step: Step) -> [String] {
        switch step {
        case .databases:
            var errors: [String] = []
            if mode == .schedule && types.isEmpty { errors.append("Choose at least one backup type.") }
            if options.databases.scope == .selected && options.databases.names.isEmpty {
                errors.append("Select at least one database.")
            }
            if options.type == .differential && options.copyOnly && mode != .schedule {
                errors.append("A differential backup cannot be copy-only.")
            }
            return errors
        case .files:
            return options.validationErrors(capabilities: capabilities).filter {
                $0.contains("file") || $0.contains("URL") || $0.contains("mirror") || $0.contains("Mirrored")
                    || $0.contains("S3") || $0.contains("<DATABASE>") || $0.contains("Keep at least")
            }
        case .processing:
            return options.validationErrors(capabilities: capabilities).filter {
                $0.contains("certificate") || $0.contains("encrypted")
            }
        case .verification:
            if options.notification.level != .never && options.notification.recipients.trimmingCharacters(in: .whitespaces).isEmpty {
                return ["Enter the email addresses to notify."]
            }
            return []
        case .schedules:
            return []
        case .summary:
            var errors: [String] = []
            for type in effectiveTypes {
                errors += options(for: type).validationErrors(capabilities: capabilities)
            }
            if mode != .backUpNow && !capabilities.canSchedule {
                errors.append(capabilities.hasAgent ? "SQL Server Agent is not running on \(serverName)."
                              : "\(capabilities.editionTitle) has no SQL Server Agent to run scheduled jobs.")
            }
            var seen: Set<String> = []
            return errors.filter { seen.insert($0).inserted }
        }
    }

    var canGoNext: Bool { errors(for: step).isEmpty }

    // MARK: Preview

    func filePreview() -> String {
        let first = resolvedDatabases.first ?? options.databases.names.first ?? "Database"
        let scripter = BackupScripter(options: options(for: effectiveTypes.first ?? .full), capabilities: capabilities,
                                      defaultFormat: defaultFormat)
        let plan = scripter.plan(database: first, date: capabilities.serverTime ?? Date())
        return (plan.files + plan.mirrorFiles.flatMap { $0 }).joined(separator: "\n")
    }

    func script() -> String {
        switch mode {
        case .backUpNow:
            let scripter = BackupScripter(options: options, capabilities: capabilities, defaultFormat: defaultFormat)
            var parts: [String] = []
            for name in resolvedDatabases {
                let plan = scripter.plan(database: name, date: capabilities.serverTime ?? Date())
                parts.append("-- \(name)")
                parts.append(scripter.backupStatement(database: name, plan: plan))
                if options.verify { parts.append(scripter.verifyStatement(plan: plan)) }
                if options.retention.isEnabled && !plan.isURL {
                    parts.append(BackupScripter.retentionScript(rule: options.retention, type: options.type,
                                                                databaseExpression: SQLIdentifier.literal(name),
                                                                folderExpression: SQLIdentifier.literal(plan.folder)))
                }
                parts.append("GO")
            }
            return parts.joined(separator: "\n")
        case .schedule:
            let manager = BackupJobManager(session: session)
            return effectiveTypes.map { type in
                manager.createScript(config(for: type), capabilities: capabilities)
            }.joined(separator: "\nGO\n\n")
        case .edit(let job):
            let config = config(for: options.type)
            return BackupJobScripts.updateJobScript(jobID: job.id, name: config.jobName, description: job.jobDescription,
                                                    command: BackupJobScripts.backupStep(options, capabilities: capabilities,
                                                                                         defaultFormat: defaultFormat,
                                                                                         schedules: config.schedules),
                                                    schedules: config.schedules)
        }
    }

    func config(for type: BackupType) -> BackupJobConfig {
        BackupJobConfig(backup: options(for: type), schedules: schedules[type] ?? [], defaultFormat: defaultFormat)
    }

    var summary: [(String, String)] {
        var lines: [(String, String)] = []
        lines.append(("Server", serverName))
        let typeNames: String = effectiveTypes.map(\.title).joined(separator: ", ") + (options.copyOnly ? " (copy-only)" : "")
        lines.append(("Backup type", typeNames))
        lines.append(("Databases", options.databases.summary))
        if options.destination == .url {
            lines.append(("Destination", options.urlBase))
        } else {
            let folder = options.folder.isEmpty ? capabilities.backupFolder + " (default)" : options.folder
            lines.append(("Folder", folder))
        }
        lines.append(("File names", options.effectiveFileNameFormat))
        switch options.layout {
        case .single: lines.append(("Files", "One file per backup"))
        case .split: lines.append(("Files", "Split into \(options.fileCount) files"))
        case .mirrored: lines.append(("Files", "Mirrored to " + options.mirrorFolders.joined(separator: ", ")))
        }
        lines.append(("Existing files", options.overwrite ? "Overwritten" : "The backup fails if a file exists"))
        lines.append(("Old backups", options.retention.summary + (options.retention.beforeBackup ? " (before the backup)" : "")))
        lines.append(("Compression", capabilities.compressionDescription(level: options.compressionLevel)))
        lines.append(("Encryption", options.encryption.isEnabled
            ? "\(options.encryption.algorithm.title) with certificate \(options.encryption.encryptor)" : "None"))
        lines.append(("Retries", options.retryCount == 0 ? "None"
            : "Up to \(options.retryCount) after file or network errors, \(options.retryIntervalSeconds) s apart"))
        var checks: [String] = []
        if options.checksum { checks.append("CHECKSUM") }
        if options.verify { checks.append("RESTORE VERIFYONLY") }
        lines.append(("Checks", checks.isEmpty ? "None" : checks.joined(separator: ", ")))
        lines.append(("Email", options.notification.isEnabled
            ? "\(options.notification.level.title) to \(options.notification.recipients)" : "None"))
        if mode != .backUpNow {
            for type in effectiveTypes {
                let list = (schedules[type] ?? []).map(\.summary).joined(separator: "; ")
                lines.append(("\(type.title) schedule", list.isEmpty ? "Run by hand" : list))
            }
        }
        return lines
    }

    // MARK: Templates

    func saveTemplate(_ preferences: BackupPreferences) {
        let name = templateName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        var templates = preferences.templates.filter { $0.name.caseInsensitiveCompare(name) != .orderedSame }
        templates.append(BackupTemplate(name: name, options: options))
        preferences.templates = templates.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func apply(_ template: BackupTemplate) {
        let selection = options.databases
        options = template.options
        if template.options.databases.scope == .selected && template.options.databases.names.isEmpty {
            options.databases = selection
        }
    }

    // MARK: Run

    func run(window: BackupWindowModel) {
        guard !isRunning else { return }
        isRunning = true
        errorText = nil
        result = nil
        createdJobs = []
        progress = [:]
        phases = [:]
        runTask = Task { [weak self] in
            guard let self else { return }
            await self.perform(window: window)
            self.isRunning = false
            await window.refresh()
        }
    }

    private func perform(window: BackupWindowModel) async {
        switch mode {
        case .backUpNow:
            let runner = BackupRunner(session: session, options: options, capabilities: capabilities,
                                      defaultFormat: defaultFormat)
            do {
                let run = try await runner.run { [weak self] event in
                    Task { @MainActor in self?.update(event) }
                }
                result = run
                window.recordFailures(run)
            } catch {
                errorText = ScriptRunner.describeError(error)
            }
        case .schedule:
            let manager = BackupJobManager(session: session)
            for type in effectiveTypes {
                let config = config(for: type)
                do {
                    try await manager.create(config, capabilities: capabilities)
                    createdJobs.append(config.jobName)
                } catch {
                    errorText = "\(config.jobName): \(ScriptRunner.describeError(error))"
                    return
                }
            }
            if createReminder && types.contains(.full) {
                for name in resolvedDatabases { window.addReminder(database: name) }
            }
        case .edit(let job):
            do {
                try await BackupJobManager(session: session).update(jobID: job.id, config: config(for: options.type),
                                                                    capabilities: capabilities)
                createdJobs = [config(for: options.type).jobName]
            } catch {
                errorText = ScriptRunner.describeError(error)
            }
        }
    }

    private func update(_ event: BackupProgressEvent) {
        guard !event.database.isEmpty else { return }
        if let fraction = event.fraction { progress[event.database] = fraction }
        phases[event.database] = event.message
    }

    func cancel() {
        runTask?.cancel()
    }
}

/// The resolution of a selection, without a server round trip (the wizard has the statuses).
enum BackupRunnerPreview {
    static func resolve(_ selection: DatabaseSelection, type: BackupType, statuses: [DatabaseBackupStatus]) -> [String] {
        let excluded = Set(selection.excluded.map { $0.lowercased() })
        switch selection.scope {
        case .selected:
            return selection.names
        case .all, .user, .system:
            return statuses.filter { status in
                guard !excluded.contains(status.name.lowercased()), status.reasonCannotBackUp(type) == nil else { return false }
                switch selection.scope {
                case .user: return !status.isSystem
                case .system: return status.isSystem
                default: return true
                }
            }.map(\.name)
        }
    }
}
