import SwiftUI
import AppKit
import UniformTypeIdentifiers
import SQLServerKit

// MARK: - Schedule restore jobs

/// The Schedule Restore Jobs wizard: an Agent job that restores the latest backups of a database
/// into a scratch database, checks it with DBCC CHECKDB and drops it — backup verification.
struct ScheduleRestoreSheet: View {
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var window: BackupWindowModel
    let job: BackupJobInfo?
    let session: SQLServerSession
    let capabilities: BackupServerCapabilities

    @State private var options = RestoreJobOptions()
    @State private var schedules: [BackupSchedule] = []
    @State private var historyDatabases: [String] = []
    @State private var page = 0
    @State private var error: String?
    @State private var done = false
    @State private var isRunning = false
    @State private var showScript = false

    private let pages = ["Backups", "Destination", "Verification", "Schedule", "Summary"]

    var body: some View {
        VStack(spacing: 0) {
            WizardStepHeader(titles: pages, current: page,
                             subtitle: "\(job == nil ? "Schedule Restore Jobs" : "Edit Restore Job") · \(window.serverName)") { page = $0 }
            Divider()
            Group {
                if done {
                    VStack(spacing: 10) {
                        Image(systemName: "checkmark.circle.fill").font(.largeTitle).foregroundStyle(.green)
                        Text(job == nil ? "The restore job was created." : "The restore job was updated.").font(.headline)
                        Text(config.jobName).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView { pageContent.padding(16).frame(maxWidth: .infinity, alignment: .leading) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(width: 820, height: 600)
        .task { await load() }
    }

    private var config: BackupJobConfig { BackupJobConfig(restore: options, schedules: schedules) }

    @ViewBuilder
    private var pageContent: some View {
        switch page {
        case 0:
            VStack(alignment: .leading, spacing: 10) {
                Text("Backups to restore are taken from this server's backup history each time the job runs.")
                    .foregroundStyle(.secondary)
                Picker("Database", selection: $options.sourceDatabase) {
                    Text("Choose…").tag("")
                    ForEach(historyDatabases, id: \.self) { name in Text(name).tag(name) }
                }
                .frame(width: 360)
                Picker("", selection: $options.source) {
                    ForEach(RestoreJobOptions.Source.allCases, id: \.self) { source in Text(source.title).tag(source) }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }
        case 1:
            VStack(alignment: .leading, spacing: 10) {
                TextField("Database to restore to (default: \(options.sourceDatabase)_Verify)", text: $options.destinationDatabase)
                    .textFieldStyle(.roundedBorder).frame(width: 420)
                Toggle("Kill connections to it before each restore", isOn: $options.killConnections).toggleStyle(.checkbox)
                ServerFolderField(placeholder: "Data files folder (\(capabilities.defaultDataFolder))", path: $options.dataFolder,
                                  session: session, capabilities: capabilities)
                ServerFolderField(placeholder: "Log files folder (\(capabilities.defaultLogFolder))", path: $options.logFolder,
                                  session: session, capabilities: capabilities)
                Picker("Leave it", selection: $options.recoveryState) {
                    ForEach(RestoreOptions.RecoveryState.allCases, id: \.self) { state in Text(state.title).tag(state) }
                }
                .frame(width: 460)
            }
        case 2:
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Run a database integrity check after the restore (DBCC CHECKDB)", isOn: $options.checkDB)
                if options.checkDB { CheckDBOptionsEditor(options: $options.checkDBOptions).padding(.leading, 20) }
                Toggle("Check for orphaned users", isOn: $options.orphanCheck)
                Toggle("Verify backup checksums while restoring", isOn: $options.checksum)
                Picker("Afterwards", selection: $options.drop) {
                    ForEach(RestoreOptions.DropPolicy.allCases, id: \.self) { policy in Text(policy.title).tag(policy) }
                }
                .frame(width: 520)
                Divider()
                Picker("Send email", selection: $options.notification.level) {
                    ForEach(NotificationLevel.allCases, id: \.self) { level in Text(level.title).tag(level) }
                }
                .frame(width: 320)
                if options.notification.level != .never {
                    TextField("Recipients, separated by ;", text: $options.notification.recipients).textFieldStyle(.roundedBorder)
                }
            }
            .toggleStyle(.checkbox)
        case 3:
            ScheduleListEditor(title: "Restore schedule", schedules: $schedules,
                               suggestion: BackupSchedule(name: "Daily at 18:30", startTime: 18 * 3600 + 1800,
                                                          startDate: window.serverNow))
        default:
            VStack(alignment: .leading, spacing: 8) {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                    GridRow { Text("Restores").foregroundStyle(.secondary); Text("\(options.source.title) of \(options.sourceDatabase)") }
                    GridRow { Text("As").foregroundStyle(.secondary); Text(options.effectiveDestination) }
                    GridRow { Text("Check").foregroundStyle(.secondary); Text(options.checkDB ? "DBCC CHECKDB" : "None") }
                    GridRow { Text("Afterwards").foregroundStyle(.secondary); Text(options.drop.title) }
                    GridRow { Text("Schedule").foregroundStyle(.secondary)
                        Text(schedules.isEmpty ? "Run by hand" : schedules.map(\.summary).joined(separator: "; ")) }
                }
                Toggle("Show Script", isOn: $showScript).toggleStyle(.switch)
                if showScript {
                    ScriptTextView(text: BackupJobManager(session: session).createScript(config, capabilities: capabilities),
                                   settings: settings)
                        .frame(height: 260)
                }
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 6) {
            if let error { Text(error).font(.caption).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading) }
            HStack {
                if options.sourceDatabase.isEmpty && page > 0 {
                    Text("Choose the database to verify.").font(.caption).foregroundStyle(.red)
                }
                Spacer()
                if done {
                    Button("Close") { dismiss() }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    if page > 0 { Button("Back") { page -= 1 } }
                    if page < pages.count - 1 {
                        Button("Next") { page += 1 }.keyboardShortcut(.defaultAction).disabled(options.sourceDatabase.isEmpty)
                    } else {
                        Button(job == nil ? "Create Job" : "Save Changes") { save() }
                            .keyboardShortcut(.defaultAction)
                            .disabled(options.sourceDatabase.isEmpty || isRunning || !capabilities.canSchedule)
                    }
                }
            }
        }
        .padding(12)
    }

    private func load() async {
        historyDatabases = (try? await BackupHistoryReader(session: session).databasesWithHistory()) ?? []
        if let config = job?.config, let restore = config.restore {
            options = restore
            schedules = config.schedules
        } else {
            options.sourceDatabase = window.selectedDatabase ?? historyDatabases.first ?? ""
            schedules = [BackupSchedule(name: "Daily at 18:30", startTime: 18 * 3600 + 1800, startDate: window.serverNow)]
        }
    }

    private func save() {
        isRunning = true
        Task {
            do {
                let manager = BackupJobManager(session: session)
                if let job {
                    try await manager.update(jobID: job.id, config: config, capabilities: capabilities)
                } else {
                    try await manager.create(config, capabilities: capabilities)
                }
                window.preferences.reminders.removeAll {
                    $0.server == window.serverName && $0.database.caseInsensitiveCompare(options.sourceDatabase) == .orderedSame
                }
                done = true
                await window.refresh()
            } catch {
                self.error = ScriptRunner.describeError(error)
            }
            isRunning = false
        }
    }
}

// MARK: - Compression analyzer

struct CompressionAnalyzerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let session: SQLServerSession
    let capabilities: BackupServerCapabilities
    let databases: [String]
    @State var database: String
    @State private var trials: [CompressionTrial] = []
    @State private var isRunning = false
    @State private var progress: Double = 0
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Compression Analyzer").font(.headline)
            Text("Backs the database up to the null device (copy-only, so the backup chain is untouched) at each "
                 + "compression level this server distinguishes, and compares size and time.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Picker("Database", selection: $database) {
                    ForEach(databases, id: \.self) { name in Text(name).tag(name) }
                }
                .frame(width: 320)
                Button("Analyze") { analyze() }.disabled(isRunning || database.isEmpty)
                if isRunning { ProgressView(value: progress).frame(width: 140) }
            }
            Table(trials) {
                TableColumn("Level") { trial in Text("\(trial.level)") }.width(50)
                TableColumn("Compression") { trial in Text(trial.description) }
                TableColumn("Size") { trial in Text(BackupFormat.size(trial.compressedSize)) }.width(90)
                TableColumn("Smaller by") { trial in Text(String(format: "%.1f%%", trial.ratio * 100)) }.width(90)
                TableColumn("Time") { trial in Text(String(format: "%.1f s", trial.duration)) }.width(70)
            }
            .frame(minHeight: 160)
            if let note = capabilities.compressionNote { Text(note).font(.caption).foregroundStyle(.secondary) }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack { Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(16)
        .frame(width: 640, height: 460)
    }

    private func analyze() {
        isRunning = true
        error = nil
        trials = []
        Task {
            do {
                trials = try await CompressionAnalyzer(session: session, capabilities: capabilities).analyze(database: database) {
                    done, total in Task { @MainActor in progress = total > 0 ? Double(done) / Double(total) : 0 }
                }
            } catch {
                self.error = ScriptRunner.describeError(error)
            }
            isRunning = false
        }
    }
}

// MARK: - Object level recovery

/// Recovers individual objects or rows: the backup is restored as a scratch copy, then Schema
/// Compare and Data Compare show what differs from the live database and deploy what you choose.
struct ObjectLevelRecoverySheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject var app: AppState
    @ObservedObject var window: BackupWindowModel
    let session: SQLServerSession
    let capabilities: BackupServerCapabilities
    @State var database: String

    @State private var sets: [BackupSetInfo] = []
    @State private var selectedSetID: Int?
    @State private var recoveryName = ""
    @State private var isRunning = false
    @State private var restoredName: String?
    @State private var status = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Object Level Recovery").font(.headline)
            Text("Restore a backup as a temporary copy, then compare it with the live database to bring back dropped or "
                 + "changed objects, or individual rows, with Schema Compare and Data Compare.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Picker("Database", selection: $database) {
                ForEach(window.databases.filter { !$0.isSystem }) { status in Text(status.name).tag(status.name) }
            }
            .frame(width: 360)
            .onChange(of: database) { _, _ in Task { await loadSets() } }
            Table(Array(sets.filter { $0.isFull || $0.isDifferential || $0.isLog }.reversed()), selection: $selectedSetID) {
                TableColumn("Finished") { set in Text(BackupFormat.date(set.finished)) }
                TableColumn("Type") { set in Text(set.typeTitle) }
                TableColumn("Size") { set in Text(BackupFormat.size(set.compressedSize)) }
            }
            .frame(minHeight: 160)
            HStack {
                TextField("Name of the temporary copy", text: $recoveryName).textFieldStyle(.roundedBorder).frame(width: 300)
                Button("Restore Copy") { restore() }.disabled(isRunning || selectedSetID == nil || recoveryName.isEmpty)
                if isRunning { ProgressView().controlSize(.small) }
            }
            if let restoredName {
                Label("\(restoredName) is ready.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                HStack {
                    Button("Compare Schema with \(database)…") {
                        openWindow(id: "schema-compare", value: launch(restoredName))
                    }
                    Button("Compare Data with \(database)…") {
                        openWindow(id: "data-compare", value: launch(restoredName))
                    }
                    Button("Drop \(restoredName)") { drop(restoredName) }
                }
                Text("In the compare window, tick only the objects or rows to bring back, then deploy them to \(database).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !status.isEmpty { Text(status).font(.caption).foregroundStyle(.secondary) }
            if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            Spacer()
            HStack { Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(16)
        .frame(width: 700, height: 560)
        .task { await loadSets() }
    }

    private func launch(_ copy: String) -> CompareLaunch {
        let serverID = app.servers.first { $0.profile.id == window.profile?.id }?.id
        return CompareLaunch(serverID: serverID, database: copy, targetDatabase: database)
    }

    private func loadSets() async {
        sets = (try? await BackupHistoryReader(session: session).backupSets(database: database)) ?? []
        selectedSetID = sets.last(where: { $0.isFull || $0.isDifferential || $0.isLog })?.id
        recoveryName = "\(database)_Recovery_\(ServerTime.format(window.serverNow, "yyyyMMdd_HHmm"))"
        restoredName = nil
    }

    private func restore() {
        guard let id = selectedSetID, let target = sets.first(where: { $0.id == id }) else { return }
        isRunning = true
        error = nil
        Task {
            defer { isRunning = false }
            guard case .success(let chain) = RestoreChainBuilder.chain(ending: target, in: sets) else {
                error = "The backups needed for that point could not be found."
                return
            }
            do {
                let files = try await BackupMediaReader(session: session).fileList(for: chain.full)
                var options = RestoreOptions()
                options.destinationDatabase = recoveryName
                options.fileLocation = .serverDefaults
                options.orphanCheck = false
                let planner = RestorePlanner(chain: chain, files: files, options: options, capabilities: capabilities,
                                             destinationExists: false)
                status = "Restoring \(chain.steps.count) backup(s)…"
                let outcome = await RestoreRunner(session: session, planner: planner).run()
                if outcome.succeeded {
                    restoredName = recoveryName
                    status = ""
                    await window.refresh()
                } else {
                    error = outcome.error
                }
            } catch {
                self.error = ScriptRunner.describeError(error)
            }
        }
    }

    private func drop(_ name: String) {
        Task {
            do {
                let connection = try await session.openConnection(database: "master")
                defer { Task { try? await connection.close() } }
                _ = try await connection.query("ALTER DATABASE \(SQLIdentifier.quote(name)) SET SINGLE_USER WITH ROLLBACK IMMEDIATE; "
                                               + "DROP DATABASE \(SQLIdentifier.quote(name));")
                restoredName = nil
                status = "Dropped \(name)."
                await window.refresh()
            } catch {
                self.error = ScriptRunner.describeError(error)
            }
        }
    }
}

// MARK: - Report

struct BackupReportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var window: BackupWindowModel
    @State private var scope: BackupReport.Scope = .all
    @State private var days = 7
    @State private var format: CompareReportFormat = .html
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Backup Report").font(.headline)
            Picker("Report", selection: $scope) {
                ForEach(BackupReport.Scope.allCases) { scope in Text(scope.title).tag(scope) }
            }
            Stepper("Covering the last \(days) day(s)", value: $days, in: 1...365)
            Picker("Format", selection: $format) {
                Text("HTML").tag(CompareReportFormat.html)
                Text("CSV").tag(CompareReportFormat.csv)
                Text("JSON").tag(CompareReportFormat.json)
            }
            .pickerStyle(.segmented)
            Text("The report covers the activity Activity History holds (\(window.preferences.historyDays) days) and "
                 + "lists databases that are behind on backups.")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save Report…") { save() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 460)
    }

    private func save() {
        let now = window.serverNow
        let report = BackupReport(serverName: window.serverName, activities: window.activities, databases: window.databases,
                                  thresholds: window.preferences.thresholds, from: now.addingTimeInterval(-Double(days) * 86_400),
                                  to: now.addingTimeInterval(60), scope: scope, now: now)
        let name = "Backup report \(window.serverName).\(format.fileExtension)"
        guard let url = CompareFilePanels.save(name: name, types: [CompareFilePanels.reportType(format)]) else { return }
        do {
            try report.render(format).write(to: url)
            if format == .html { NSWorkspace.shared.open(url) }
            dismiss()
        } catch {
            self.error = ScriptRunner.describeError(error)
        }
    }
}

// MARK: - Job log

struct BackupJobLogSheet: View {
    @Environment(\.dismiss) private var dismiss
    let job: BackupJobInfo
    let session: SQLServerSession
    @State private var lines: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(job.name).font(.headline)
            ScrollView {
                Text(lines.isEmpty ? "Loading…" : lines.joined(separator: "\n"))
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            HStack { Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(16)
        .frame(width: 760, height: 520)
        .task {
            lines = (try? await BackupJobManager(session: session).log(jobID: job.id)) ?? ["The job history could not be read."]
        }
    }
}
