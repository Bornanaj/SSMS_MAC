import SwiftUI
import AppKit
import SQLServerKit

/// The tabs under the Time Line: Activity History, In Progress, Jobs, Log Shipping, Reminders.
struct BackupTabsView: View {
    @ObservedObject var model: BackupWindowModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $model.tab) {
                    ForEach(BackupWindowModel.Tab.allCases) { tab in Text(title(tab)).tag(tab) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                if let selected = model.selectedDatabase {
                    Button {
                        model.selectedDatabase = nil
                    } label: {
                        Label("\(selected) — show all", systemImage: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .help("Show every database")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider()
            switch model.tab {
            case .activity: ActivityHistoryTab(model: model)
            case .inProgress: InProgressTab(model: model)
            case .jobs: BackupJobsTab(model: model)
            case .logShipping: LogShippingTab(model: model)
            case .reminders: RemindersTab(model: model, preferences: model.preferences)
            }
        }
    }

    private func title(_ tab: BackupWindowModel.Tab) -> String {
        switch tab {
        case .inProgress: return model.inProgress.isEmpty ? tab.rawValue : "\(tab.rawValue) (\(model.inProgress.count))"
        case .reminders:
            let count: Int = model.visibleReminders.count
            return count == 0 ? tab.rawValue : "\(tab.rawValue) (\(count))"
        default: return tab.rawValue
        }
    }
}

// MARK: - Activity history

struct ActivityHistoryTab: View {
    @ObservedObject var model: BackupWindowModel
    @State private var outcome: Outcome = .all

    enum Outcome: String, CaseIterable, Identifiable {
        case all = "All"
        case backups = "Backups"
        case restores = "Restores"
        case failures = "Failures"
        var id: String { rawValue }
    }

    private var rows: [BackupActivity] {
        switch outcome {
        case .all: return model.visibleActivities
        case .backups: return model.visibleActivities.filter { $0.kind == .backup || $0.kind == .verify }
        case .restores: return model.visibleActivities.filter { $0.kind == .restore }
        case .failures: return model.visibleActivities.filter { !$0.succeeded || $0.hasWarnings }
        }
    }

    private var selected: BackupActivity? {
        guard let id = model.selectedActivityID else { return nil }
        return model.activities.first { $0.id == id }
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack {
                    Picker("Show", selection: $outcome) {
                        ForEach(Outcome.allCases) { outcome in Text(outcome.rawValue).tag(outcome) }
                    }
                    .frame(width: 200)
                    Spacer()
                    Text("\(rows.count) operation(s) in the last \(model.preferences.historyDays) days")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                activityTable
            }
            .frame(minWidth: 520)
            ActivityDetailView(model: model, activity: selected)
                .frame(minWidth: 240, idealWidth: 300, maxWidth: 420)
        }
    }

    private var activityTable: some View {
        Table(rows, selection: $model.selectedActivityID) {
            TableColumn("") { activity in ActivityOutcomeIcon(activity: activity) }.width(22)
            TableColumn("Type") { activity in
                HStack(spacing: 4) {
                    ActivityKindIcon(activity: activity)
                    Text(activity.kind == .jobFailure ? "Job failed" : "\(activity.kindTitle) · \(activity.typeTitle)")
                }
            }
            .width(min: 120, ideal: 160)
            TableColumn("Database") { activity in Text(activity.database) }.width(min: 90, ideal: 140)
            TableColumn("Finished") { activity in Text(BackupFormat.date(activity.date)) }.width(min: 120, ideal: 140)
            TableColumn("Duration") { activity in Text(BackupFormat.duration(activity.duration)) }.width(60)
            TableColumn("Size") { activity in
                Text(BackupFormat.size(activity.compressedSize > 0 ? activity.compressedSize : activity.backupSize))
            }
            .width(70)
            TableColumn("Compressed by") { activity in
                Text(activity.compressedBy.map { String(format: "%.0f%%", $0 * 100) } ?? "")
            }
            .width(80)
            TableColumn("Details") { activity in
                Text(activity.succeeded ? activity.files.first ?? activity.jobName : activity.message)
                    .lineLimit(1)
                    .foregroundStyle(activity.succeeded ? Color.secondary : Color.red)
            }
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first, let activity = model.activities.first(where: { $0.id == id }) {
                ActivityMenu(model: model, activity: activity)
            }
        }
    }
}

struct ActivityMenu: View {
    @ObservedObject var model: BackupWindowModel
    let activity: BackupActivity

    var body: some View {
        if activity.kind == .backup && activity.succeeded && !activity.isThirdParty {
            Button("Restore…") { model.sheet = .restore(activity.database) }
        }
        if !activity.files.isEmpty {
            Button("Copy File Paths") { copy(activity.files.joined(separator: "\n")) }
        }
        if !activity.message.isEmpty {
            Button("Copy Message") { copy(activity.message) }
        }
        if activity.kind == .backup {
            Button("Schedule Restore Jobs for \(activity.database)…") {
                model.selectedDatabase = activity.database
                model.sheet = .scheduleRestore(nil)
            }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// The selected operation's details beside the history.
struct ActivityDetailView: View {
    @ObservedObject var model: BackupWindowModel
    let activity: BackupActivity?

    var body: some View {
        ScrollView {
            if let activity {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        ActivityOutcomeIcon(activity: activity)
                        Text("\(activity.kindTitle) · \(activity.typeTitle)").font(.headline)
                    }
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                        ForEach(Array(lines(activity).enumerated()), id: \.offset) { _, line in
                            GridRow {
                                Text(line.0).foregroundStyle(.secondary)
                                Text(line.1).textSelection(.enabled)
                            }
                            .font(.caption)
                        }
                    }
                    if !activity.files.isEmpty {
                        Text("Files").font(.caption.weight(.semibold))
                        ForEach(activity.files, id: \.self) { file in
                            Text(file).font(.caption.monospaced()).textSelection(.enabled).lineLimit(3)
                        }
                    }
                    if !activity.message.isEmpty {
                        Text("Messages").font(.caption.weight(.semibold))
                        Text(activity.message)
                            .font(.caption.monospaced())
                            .foregroundStyle(activity.succeeded ? Color.primary : Color.red)
                            .textSelection(.enabled)
                    }
                    if activity.kind == .backup && activity.succeeded && !activity.isThirdParty {
                        Button("Restore…") { model.sheet = .restore(activity.database) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            } else {
                Text("Select an operation to see its details.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
            }
        }
    }

    private func lines(_ activity: BackupActivity) -> [(String, String)] {
        var lines: [(String, String)] = [("Database", activity.database)]
        if let started = activity.started { lines.append(("Started", ServerTime.display(started))) }
        if let finished = activity.finished { lines.append(("Finished", ServerTime.display(finished))) }
        if activity.duration != nil { lines.append(("Duration", BackupFormat.duration(activity.duration))) }
        if activity.databaseSize > 0 { lines.append(("Database size", BackupFormat.size(activity.databaseSize))) }
        if activity.backupSize > 0 { lines.append(("Backup size", BackupFormat.size(activity.backupSize))) }
        if activity.compressedSize > 0 && activity.compressedSize < activity.backupSize {
            lines.append(("Compressed size", BackupFormat.size(activity.compressedSize)))
            if let ratio = activity.compressedBy { lines.append(("Compressed by", String(format: "%.1f%%", ratio * 100))) }
            if !activity.compressionAlgorithm.isEmpty { lines.append(("Compression", activity.compressionAlgorithm)) }
        }
        if activity.kind == .backup {
            lines.append(("Encryption", activity.isEncrypted ? activity.keyAlgorithm : "None"))
            lines.append(("Checksums", activity.hasChecksums ? "Yes" : "No"))
            if activity.isCopyOnly { lines.append(("Copy-only", "Yes")) }
            if activity.mirrorCount > 1 { lines.append(("Mirrored", "\(activity.mirrorCount) copies")) }
            if activity.isDamaged { lines.append(("Damaged", "Backed up with CONTINUE_AFTER_ERROR")) }
            if activity.isThirdParty { lines.append(("Made by", "Another tool (virtual device)")) }
        }
        if !activity.restoredFrom.isEmpty { lines.append(("Restored from", activity.restoredFrom)) }
        if !activity.userName.isEmpty { lines.append(("User", activity.userName)) }
        if !activity.jobName.isEmpty { lines.append(("Job", activity.jobName)) }
        return lines
    }
}

// MARK: - In progress

struct InProgressTab: View {
    @ObservedObject var model: BackupWindowModel
    @State private var confirmCancel: BackupProgressItem?

    var body: some View {
        if model.visibleInProgress.isEmpty {
            Text("No backups or restores are running.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Table(model.visibleInProgress) {
                TableColumn("Operation") { item in Text(item.command.capitalized) }.width(min: 100, ideal: 130)
                TableColumn("Database") { item in Text(item.database) }.width(min: 90, ideal: 140)
                TableColumn("Progress") { item in
                    HStack {
                        ProgressView(value: min(max(item.percentComplete / 100, 0), 1)).frame(width: 110)
                        Text(String(format: "%.0f%%", item.percentComplete)).font(.caption.monospacedDigit())
                    }
                }
                .width(170)
                TableColumn("Time left") { item in
                    Text(item.estimatedSecondsLeft > 0 ? BackupFormat.duration(item.estimatedSecondsLeft) : "")
                }
                .width(70)
                TableColumn("Started") { item in Text(BackupFormat.date(item.started)) }.width(min: 110, ideal: 140)
                TableColumn("By") { item in Text(item.programName.isEmpty ? item.loginName : "\(item.loginName) (\(item.programName))") }
                TableColumn("") { item in
                    Button("Cancel") { confirmCancel = item }
                }
                .width(70)
            }
            .confirmationDialog("Cancel this operation?", isPresented: Binding(get: { confirmCancel != nil },
                                                                              set: { if !$0 { confirmCancel = nil } })) {
                Button("Cancel \(confirmCancel?.command.lowercased() ?? "operation")", role: .destructive) {
                    if let item = confirmCancel { Task { await model.cancel(item) } }
                    confirmCancel = nil
                }
                Button("Keep Running", role: .cancel) { confirmCancel = nil }
            } message: {
                Text("The server session is killed. A cancelled restore leaves the database in the restoring state.")
            }
        }
    }
}

// MARK: - Jobs

struct BackupJobsTab: View {
    @ObservedObject var model: BackupWindowModel
    @State private var confirmDelete: BackupJobInfo?

    private var selected: BackupJobInfo? {
        guard let id = model.selectedJobID else { return nil }
        return model.jobs.first { $0.id == id }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if model.capabilities?.hasAgent == false {
                Text("This edition of SQL Server has no SQL Server Agent, so backups cannot be scheduled here.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                jobTable
            }
        }
        .confirmationDialog("Delete \(confirmDelete?.name ?? "")?",
                            isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button("Delete Job", role: .destructive) {
                if let job = confirmDelete { Task { await model.deleteJob(job) } }
                confirmDelete = nil
            }
            Button("Cancel", role: .cancel) { confirmDelete = nil }
        } message: {
            Text("The SQL Server Agent job and its history are deleted. Backup files it made are kept.")
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Menu {
                Button("Backup Job…") { model.sheet = .backup(.schedule) }
                Button("Restore Job…") { model.sheet = .scheduleRestore(nil) }
            } label: {
                Label("New", systemImage: "plus")
            }
            .fixedSize()
            Button("Edit…") { if let job = selected { edit(job) } }
                .disabled(selected?.isManaged != true)
            Button("Run Now") { if let job = selected { Task { await model.runJob(job) } } }
                .disabled(selected == nil || selected?.isRunning == true)
            Button("Stop") { if let job = selected { Task { await model.stopJob(job) } } }
                .disabled(selected?.isRunning != true)
            Button(selected?.isEnabled == false ? "Enable" : "Disable") {
                if let job = selected { Task { await model.setJobEnabled(job, !job.isEnabled) } }
            }
            .disabled(selected == nil)
            Button("History…") { if let job = selected { model.sheet = .jobLog(job) } }
                .disabled(selected == nil)
            Button("Delete…") { confirmDelete = selected }
                .disabled(selected == nil)
            Spacer()
            if let capabilities = model.capabilities, capabilities.hasAgent, !capabilities.isAgentRunning {
                Label("SQL Server Agent is not running", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    private var jobTable: some View {
        let now: Date = model.serverNow
        return Table(model.visibleJobs, selection: $model.selectedJobID) {
            TableColumn("") { job in
                Image(systemName: job.isRunning ? "play.circle.fill" : (job.isEnabled ? "clock" : "pause.circle"))
                    .foregroundStyle(job.isRunning ? Color.green : (job.isEnabled ? Color.accentColor : Color.secondary))
                    .help(job.isRunning ? "Running" : (job.isEnabled ? "Enabled" : "Disabled"))
            }
            .width(22)
            TableColumn("Name") { job in Text(job.name).foregroundStyle(job.isEnabled ? Color.primary : Color.secondary) }
                .width(min: 160, ideal: 260)
            TableColumn("Type") { job in Text(job.kindTitle) }.width(min: 90, ideal: 130)
            TableColumn("Databases") { job in Text(job.databases).lineLimit(1) }.width(min: 90, ideal: 160)
            TableColumn("Schedule") { job in Text(job.scheduleSummary).lineLimit(1) }.width(min: 120, ideal: 200)
            TableColumn("Last run") { job in
                HStack(spacing: 4) {
                    if job.lastRun != nil {
                        Image(systemName: job.lastOutcome == "Succeeded" ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(job.lastOutcome == "Succeeded" ? Color.green : Color.red)
                    }
                    Text(BackupFormat.date(job.lastRun))
                }
                .help(job.lastMessage)
            }
            .width(min: 120, ideal: 150)
            TableColumn("Next run") { job in Text(BackupFormat.date(job.nextRun(after: now))) }.width(min: 110, ideal: 140)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first, let job = model.jobs.first(where: { $0.id == id }) {
                if job.isManaged { Button("Edit…") { edit(job) } }
                Button("Run Now") { Task { await model.runJob(job) } }
                if job.isRunning { Button("Stop") { Task { await model.stopJob(job) } } }
                Button(job.isEnabled ? "Disable" : "Enable") { Task { await model.setJobEnabled(job, !job.isEnabled) } }
                Button("History…") { model.sheet = .jobLog(job) }
                Divider()
                Button("Delete…") { confirmDelete = job }
            }
        } primaryAction: { ids in
            if let id = ids.first, let job = model.jobs.first(where: { $0.id == id }), job.isManaged { edit(job) }
        }
    }

    private func edit(_ job: BackupJobInfo) {
        switch job.config?.kind {
        case .backup?: model.sheet = .backup(.edit(job))
        case .restoreVerification?: model.sheet = .scheduleRestore(job)
        case nil: break
        }
    }
}

// MARK: - Log shipping

struct LogShippingTab: View {
    @ObservedObject var model: BackupWindowModel
    @State private var selection: String?
    @State private var confirm: Action?

    enum Action: Identifiable {
        case remove(LogShippingStatus)
        case bringOnline(LogShippingStatus)
        var id: String {
            switch self {
            case .remove(let status): return "remove-\(status.id)"
            case .bringOnline(let status): return "online-\(status.id)"
            }
        }
    }

    private var selected: LogShippingStatus? {
        guard let selection else { return nil }
        return model.logShipping.first { $0.id == selection }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button("Set Up Log Shipping…") { model.sheet = .logShipping }
                    .disabled(model.capabilities?.canSchedule != true)
                Button("Remove…") { if let status = selected { confirm = .remove(status) } }
                    .disabled(selected == nil)
                Button("Bring Standby Online…") { if let status = selected { confirm = .bringOnline(status) } }
                    .disabled(selected == nil || !isStandbyHere(selected))
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            Divider()
            if model.logShipping.isEmpty {
                Text("This server takes part in no log shipping.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                table
            }
        }
        .confirmationDialog(confirmTitle, isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } })) {
            Button(confirmButton, role: .destructive) {
                if let confirm { Task { await perform(confirm) } }
                confirm = nil
            }
            Button("Cancel", role: .cancel) { confirm = nil }
        } message: {
            Text(confirmMessage)
        }
    }

    private var table: some View {
        let now: Date = model.serverNow
        return Table(model.logShipping, selection: $selection) {
            TableColumn("") { status in
                Image(systemName: status.isHealthy(now: now) ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(status.isHealthy(now: now) ? Color.green : Color.orange)
            }
            .width(22)
            TableColumn("Primary") { status in Text("\(status.primaryServer).\(status.primaryDatabase)") }.width(min: 140, ideal: 200)
            TableColumn("Standby") { status in
                Text(status.secondaryServer.isEmpty ? "" : "\(status.secondaryServer).\(status.secondaryDatabase)")
            }
            .width(min: 140, ideal: 200)
            TableColumn("Last backup") { status in Text(BackupFormat.date(status.lastBackupDate)).help(status.lastBackupFile) }
            TableColumn("Last copied") { status in Text(BackupFormat.date(status.lastCopiedDate)).help(status.lastCopiedFile) }
            TableColumn("Last restored") { status in Text(BackupFormat.date(status.lastRestoredDate)).help(status.lastRestoredFile) }
            TableColumn("Latency") { status in Text(status.lastRestoredDate == nil ? "" : "\(status.restoreLatencyMinutes) min") }
                .width(60)
            TableColumn("Standby state") { status in
                Text(status.secondaryDatabase.isEmpty ? "" : (status.restoreMode == 1 ? "Read-only (STANDBY)" : "Restoring"))
            }
            .width(min: 90, ideal: 130)
        }
    }

    private func isStandbyHere(_ status: LogShippingStatus?) -> Bool {
        guard let status else { return false }
        return model.databases.contains { $0.name.caseInsensitiveCompare(status.secondaryDatabase) == .orderedSame }
            && status.secondaryServer.caseInsensitiveCompare(model.serverName) == .orderedSame
    }

    private func isPrimaryHere(_ status: LogShippingStatus) -> Bool {
        status.primaryServer.caseInsensitiveCompare(model.serverName) == .orderedSame
    }

    private var confirmTitle: String {
        switch confirm {
        case .remove(let status)?: return "Remove log shipping of \(status.primaryDatabase)?"
        case .bringOnline(let status)?: return "Bring \(status.secondaryDatabase) online?"
        case nil: return ""
        }
    }

    private var confirmButton: String {
        switch confirm {
        case .remove?: return "Remove Log Shipping"
        case .bringOnline?: return "Bring Online"
        case nil: return ""
        }
    }

    private var confirmMessage: String {
        switch confirm {
        case .remove:
            return "The log shipping jobs and configuration on this server are deleted. The databases are left as they are; "
                + "remove the other side from its own server."
        case .bringOnline:
            return "Log shipping into the standby stops and it is recovered (RESTORE WITH RECOVERY). Restore any remaining "
                + "log backups first: once online, the standby cannot take further logs."
        case nil:
            return ""
        }
    }

    private func perform(_ action: Action) async {
        guard let session = model.session else { return }
        let monitor = LogShippingMonitor(session: session)
        do {
            switch action {
            case .remove(let status):
                var sql: [String] = []
                if isStandbyHere(status) {
                    sql.append(LogShippingMonitor.removeSecondarySQL(secondaryDatabase: status.secondaryDatabase))
                }
                if isPrimaryHere(status) {
                    sql.append(LogShippingMonitor.removePrimarySQL(primaryDatabase: status.primaryDatabase,
                                                                   secondaryServer: status.secondaryServer,
                                                                   secondaryDatabase: status.secondaryDatabase))
                }
                guard !sql.isEmpty else {
                    model.report("Neither side of this pair is on \(model.serverName).", isError: true)
                    return
                }
                try await monitor.execute(sql.joined(separator: "\n"))
                model.report("Removed log shipping of \(status.primaryDatabase).")
            case .bringOnline(let status):
                try await monitor.execute(LogShippingMonitor.bringOnlineSQL(secondaryDatabase: status.secondaryDatabase))
                model.report("\(status.secondaryDatabase) is online.")
            }
            await model.refresh()
        } catch {
            model.report(ScriptRunner.describeError(error), isError: true)
        }
    }
}

// MARK: - Reminders

struct RemindersTab: View {
    @ObservedObject var model: BackupWindowModel
    @ObservedObject var preferences: BackupPreferences
    @State private var selection: Set<UUID> = []

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button("Schedule Restore Job…") {
                    if let reminder = model.visibleReminders.first(where: { selection.contains($0.id) }) {
                        model.selectedDatabase = reminder.database
                    }
                    model.sheet = .scheduleRestore(nil)
                }
                .disabled(selection.isEmpty)
                Button("Dismiss") { model.removeReminders(selection); selection = [] }
                    .disabled(selection.isEmpty)
                Spacer()
                Text("A backup is only as good as a restore of it: schedule restore jobs that verify new backups.")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            Divider()
            if model.visibleReminders.isEmpty {
                Text("No reminders.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(model.visibleReminders, selection: $selection) {
                    TableColumn("") { _ in Image(systemName: "bell.badge").foregroundStyle(.orange) }.width(22)
                    TableColumn("Reminder") { reminder in
                        Text("Schedule restore jobs to verify the backups of \(reminder.database)")
                    }
                    TableColumn("Created") { reminder in Text(reminder.created.formatted(date: .abbreviated, time: .shortened)) }
                        .width(min: 120, ideal: 160)
                }
            }
        }
    }
}
