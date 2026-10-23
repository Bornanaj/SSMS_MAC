import SwiftUI
import AppKit
import TDSKit
import SQLServerKit

// MARK: - Preferences

/// A reminder to set up backup verification for a database (SQL Backup's Reminders tab).
struct BackupReminder: Codable, Hashable, Identifiable {
    var id = UUID()
    var server: String
    var database: String
    var created = Date()
}

/// An operation this window ran that msdb does not record: failed one-off backups and restores.
struct LocalBackupLogEntry: Codable, Hashable, Identifiable {
    var id = UUID()
    var date = Date()
    var server: String
    var kind: String
    var database: String
    var succeeded: Bool
    var summary: String
    var details: [String]
}

/// SQL Backup settings kept on this Mac rather than on a server.
@MainActor
final class BackupPreferences: ObservableObject {
    static let shared = BackupPreferences()

    @Published var templates: [BackupTemplate] = [] { didSet { store(templates, "templates") } }
    @Published var reminders: [BackupReminder] = [] { didSet { store(reminders, "reminders") } }
    @Published var thresholds = BackupThresholds() { didSet { store(thresholds, "thresholds") } }
    /// How far back Activity History reads msdb (SQL Backup imports a month by default).
    @Published var historyDays = 31 { didSet { UserDefaults.standard.set(historyDays, forKey: key("historyDays")) } }
    /// Default file name format per server (what `<AUTO>` stands for).
    @Published var defaultFormats: [String: String] = [:] { didSet { store(defaultFormats, "defaultFormats") } }
    @Published var localLog: [LocalBackupLogEntry] = [] { didSet { store(localLog, "localLog") } }

    private init() {
        templates = load("templates") ?? []
        reminders = load("reminders") ?? []
        thresholds = load("thresholds") ?? BackupThresholds()
        defaultFormats = load("defaultFormats") ?? [:]
        localLog = load("localLog") ?? []
        let days = UserDefaults.standard.integer(forKey: key("historyDays"))
        historyDays = days > 0 ? days : 31
    }

    func defaultFormat(for server: String) -> String {
        defaultFormats[server.lowercased()] ?? BackupOptions.defaultFileNameFormat
    }

    func log(_ entry: LocalBackupLogEntry) {
        var entries = localLog
        entries.insert(entry, at: 0)
        localLog = Array(entries.prefix(300))
    }

    private func key(_ name: String) -> String { "sqlBackup.\(name)" }

    private func store<T: Encodable>(_ value: T, _ name: String) {
        if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: key(name)) }
    }

    private func load<T: Decodable>(_ name: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key(name)) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}

// MARK: - Window model

/// Everything behind one SQL Backup window: the server it looks at, its databases with their
/// backup status, the activity history, running operations, jobs and log shipping.
@MainActor
final class BackupWindowModel: ObservableObject {
    enum Tab: String, CaseIterable, Identifiable {
        case activity = "Activity History"
        case inProgress = "In Progress"
        case jobs = "Jobs"
        case logShipping = "Log Shipping"
        case reminders = "Reminders"
        var id: String { rawValue }
    }

    enum Sheet: Identifiable {
        case backup(BackupWizardModel.Mode)
        case restore(String?)
        case scheduleRestore(BackupJobInfo?)
        case logShipping
        case options
        case analyzer(String?)
        case objectRecovery(String?)
        case report
        case jobLog(BackupJobInfo)

        var id: String {
            switch self {
            case .backup(let mode): return "backup-\(mode.id)"
            case .restore(let database): return "restore-\(database ?? "")"
            case .scheduleRestore(let job): return "verify-\(job?.id ?? "")"
            case .logShipping: return "logshipping"
            case .options: return "options"
            case .analyzer(let database): return "analyzer-\(database ?? "")"
            case .objectRecovery(let database): return "olr-\(database ?? "")"
            case .report: return "report"
            case .jobLog(let job): return "log-\(job.id)"
            }
        }
    }

    let pool = CompareSessionPool()
    let preferences = BackupPreferences.shared

    @Published private(set) var profile: ConnectionProfile?
    @Published private(set) var session: SQLServerSession?
    @Published private(set) var capabilities: BackupServerCapabilities?
    @Published private(set) var databases: [DatabaseBackupStatus] = []
    @Published private(set) var activities: [BackupActivity] = []
    @Published private(set) var inProgress: [BackupProgressItem] = []
    @Published private(set) var jobs: [BackupJobInfo] = []
    @Published private(set) var logShipping: [LogShippingStatus] = []
    @Published var selectedDatabase: String?
    @Published var selectedActivityID: String?
    @Published var selectedJobID: String?
    @Published var tab: Tab = .activity
    @Published var sheet: Sheet?
    @Published private(set) var isLoading = false
    @Published private(set) var lastRefresh: Date?
    @Published var statusText = ""
    @Published var statusIsError = false
    @Published var databaseFilter = ""

    private var clockOffset: TimeInterval = 0
    private var refreshTimer: Timer?
    private var progressTimer: Timer?

    var serverNow: Date { Date().addingTimeInterval(clockOffset) }
    var serverName: String { capabilities?.serverName ?? profile?.displayName ?? "" }
    var isConnected: Bool { session != nil && capabilities != nil }
    var defaultFormat: String { preferences.defaultFormat(for: serverName) }

    // MARK: Servers

    /// Connected servers first, then saved connections not already listed.
    func serverChoices(app: AppState) -> [ConnectionProfile] {
        var seen: Set<UUID> = []
        var choices: [ConnectionProfile] = []
        for server in app.servers where seen.insert(server.profile.id).inserted { choices.append(server.profile) }
        for profile in app.connections.profiles where seen.insert(profile.id).inserted { choices.append(profile) }
        return choices
    }

    func configure(launch: CompareLaunch, app: AppState) async {
        if let serverID = launch.serverID, let server = app.server(id: serverID) {
            await connect(server.profile, app: app)
        } else if let first = app.servers.first {
            await connect(first.profile, app: app)
        }
        selectedDatabase = launch.database
        switch launch.action {
        case "backup": sheet = .backup(.backUpNow)
        case "schedule": sheet = .backup(.schedule)
        case "restore": sheet = .restore(launch.database)
        case "verify": sheet = .scheduleRestore(nil)
        default: break
        }
    }

    func connect(_ profile: ConnectionProfile, app: AppState) async {
        self.profile = profile
        isLoading = true
        statusIsError = false
        statusText = "Connecting to \(profile.displayName)…"
        defer { isLoading = false }
        do {
            let endpoint = CompareEndpoint(kind: .database, connection: profile, database: "master")
            let session = try await pool.session(for: endpoint, app: app)
            let capabilities = try await BackupCapabilityProbe(session: session).probe()
            guard capabilities.canBackUp else {
                throw SQLServerError.unsupportedOperation("Azure SQL Database manages its own backups; "
                                                          + "use point-in-time restore in the Azure portal.")
            }
            self.session = session
            self.capabilities = capabilities
            if let serverTime = capabilities.serverTime { clockOffset = serverTime.timeIntervalSince(Date()) }
            selectedDatabase = nil
            await refresh()
            startTimers()
        } catch {
            session = nil
            capabilities = nil
            report(ScriptRunner.describeError(error), isError: true)
        }
    }

    // MARK: Refresh

    func refresh() async {
        guard let session else { return }
        let reader = BackupHistoryReader(session: session)
        let since = serverNow.addingTimeInterval(-Double(preferences.historyDays) * 86_400)
        do {
            async let databases = reader.databases()
            async let activities = reader.activity(since: since)
            let loadedDatabases = try await databases
            let loadedActivities = try await activities
            self.databases = loadedDatabases
            self.activities = loadedActivities + localActivities()
            self.activities.sort { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
            inProgress = (try? await reader.inProgress()) ?? []
            if capabilities?.hasAgent == true {
                jobs = (try? await BackupJobManager(session: session).jobs()) ?? []
            }
            logShipping = (try? await LogShippingMonitor(session: session).status()) ?? []
            lastRefresh = Date()
            if !statusIsError || statusText.hasPrefix("Connecting") {
                statusText = summaryText
                statusIsError = false
            }
        } catch {
            report(ScriptRunner.describeError(error), isError: true)
        }
    }

    func refreshProgress() async {
        guard let session else { return }
        let items = (try? await BackupHistoryReader(session: session).inProgress()) ?? []
        let finished = !inProgress.isEmpty && items.count < inProgress.count
        inProgress = items
        if finished { await refresh() }
    }

    private func startTimers() {
        refreshTimer?.invalidate()
        progressTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        progressTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.tab == .inProgress || !self.inProgress.isEmpty else { return }
                await self.refreshProgress()
            }
        }
    }

    func close() {
        refreshTimer?.invalidate()
        progressTimer?.invalidate()
        pool.closeAll()
    }

    var summaryText: String {
        let thresholds = preferences.thresholds
        let behind: Int = databases.filter {
            let risk = $0.risk(now: serverNow, thresholds: thresholds)
            return risk == .overdue || risk == .never
        }.count
        let failures: Int = activities.filter { !$0.succeeded && ($0.date ?? .distantPast) > serverNow.addingTimeInterval(-86_400) }.count
        var parts: [String] = ["\(databases.count) databases"]
        parts.append(behind == 0 ? "all backed up" : "\(behind) behind on backups")
        if failures > 0 { parts.append("\(failures) failure(s) in the last 24 hours") }
        if let capabilities, !capabilities.isAgentRunning, capabilities.hasAgent { parts.append("SQL Server Agent is not running") }
        return parts.joined(separator: " · ")
    }

    // MARK: Selection

    var filteredDatabases: [DatabaseBackupStatus] {
        guard !databaseFilter.isEmpty else { return databases }
        return databases.filter { $0.name.localizedCaseInsensitiveContains(databaseFilter) }
    }

    var visibleActivities: [BackupActivity] {
        guard let selectedDatabase else { return activities }
        return activities.filter {
            $0.database.caseInsensitiveCompare(selectedDatabase) == .orderedSame
                || ($0.kind == .jobFailure && $0.database.isEmpty)
        }
    }

    var visibleJobs: [BackupJobInfo] {
        guard let selectedDatabase else { return jobs }
        return jobs.filter { job in
            if let backup = job.config?.backup {
                switch backup.databases.scope {
                case .selected: return backup.databases.names.contains { $0.caseInsensitiveCompare(selectedDatabase) == .orderedSame }
                case .all: return true
                case .user: return !(databases.first { $0.name == selectedDatabase }?.isSystem ?? false)
                case .system: return databases.first { $0.name == selectedDatabase }?.isSystem ?? false
                }
            }
            return job.databases.caseInsensitiveCompare(selectedDatabase) == .orderedSame || job.databases.isEmpty
        }
    }

    var visibleInProgress: [BackupProgressItem] {
        guard let selectedDatabase else { return inProgress }
        return inProgress.filter { $0.database.caseInsensitiveCompare(selectedDatabase) == .orderedSame }
    }

    var visibleReminders: [BackupReminder] {
        preferences.reminders.filter {
            $0.server.caseInsensitiveCompare(serverName) == .orderedSame
                && (selectedDatabase == nil || $0.database == selectedDatabase)
        }
    }

    var selectedStatus: DatabaseBackupStatus? {
        guard let selectedDatabase else { return nil }
        return databases.first { $0.name == selectedDatabase }
    }

    // MARK: Local log

    func localActivities() -> [BackupActivity] {
        preferences.localLog.filter { $0.server.caseInsensitiveCompare(serverName) == .orderedSame }.map { entry in
            var activity = BackupActivity(id: "l\(entry.id.uuidString)", kind: entry.kind == "restore" ? .restore : .backup,
                                          database: entry.database, typeCode: "")
            activity.started = entry.date.addingTimeInterval(clockOffset)
            activity.finished = activity.started
            activity.succeeded = entry.succeeded
            activity.message = ([entry.summary] + entry.details).joined(separator: "\n")
            return activity
        }
    }

    /// Failed one-off runs, which leave no trace in msdb.
    func recordFailures(_ run: BackupRunResult) {
        for result in run.results where !result.succeeded && !result.skipped {
            preferences.log(LocalBackupLogEntry(server: serverName, kind: "backup", database: result.database,
                                                succeeded: false, summary: "\(result.type.title) backup failed",
                                                details: result.errors))
        }
    }

    func recordRestoreFailure(database: String, outcome: RestoreOutcome) {
        guard !outcome.succeeded else { return }
        preferences.log(LocalBackupLogEntry(server: serverName, kind: "restore", database: database, succeeded: false,
                                            summary: "Restore failed" + (outcome.failedStep.map { " at: \($0)" } ?? ""),
                                            details: [outcome.error ?? ""]))
    }

    // MARK: Jobs

    func runJob(_ job: BackupJobInfo) async {
        await jobAction("Started \(job.name).") { try await $0.start(jobID: job.id) }
    }

    func stopJob(_ job: BackupJobInfo) async {
        await jobAction("Stopped \(job.name).") { try await $0.stop(jobID: job.id) }
    }

    func setJobEnabled(_ job: BackupJobInfo, _ enabled: Bool) async {
        await jobAction(enabled ? "Enabled \(job.name)." : "Disabled \(job.name).") {
            try await $0.setEnabled(jobID: job.id, enabled)
        }
    }

    func deleteJob(_ job: BackupJobInfo) async {
        await jobAction("Deleted \(job.name).") { try await $0.delete(jobID: job.id) }
    }

    private func jobAction(_ message: String, _ action: (BackupJobManager) async throws -> Void) async {
        guard let session else { return }
        do {
            try await action(BackupJobManager(session: session))
            report(message)
            await refresh()
        } catch {
            report(ScriptRunner.describeError(error), isError: true)
        }
    }

    func cancel(_ item: BackupProgressItem) async {
        guard let session else { return }
        do {
            try await BackupServerSettings(session: session).kill(sessionID: item.sessionID)
            report("Cancelled \(item.command.lowercased()) of \(item.database). A cancelled restore leaves the database restoring.")
            await refreshProgress()
        } catch {
            report(ScriptRunner.describeError(error), isError: true)
        }
    }

    // MARK: Reminders

    func addReminder(database: String) {
        guard !preferences.reminders.contains(where: { $0.server == serverName && $0.database == database }) else { return }
        preferences.reminders.append(BackupReminder(server: serverName, database: database))
    }

    func removeReminders(_ ids: Set<UUID>) {
        preferences.reminders.removeAll { ids.contains($0.id) }
    }

    func report(_ text: String, isError: Bool = false) {
        statusText = text
        statusIsError = isError
    }
}

extension ScriptRunner {
    /// The text of an error the way the rest of the app shows server errors.
    static func describeError(_ error: Error) -> String {
        if case TDSError.server(let message) = error { return message.formatted }
        if let message = error as? TDSServerMessage { return message.formatted }
        return String(describing: error)
    }
}
