import SwiftUI
import AppKit
import SQLServerKit

/// The SQL Backup window: the server's databases with their backup status on the left, the
/// Time Line and the activity tabs on the right, and the wizards in the toolbar.
struct BackupWindow: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var settings: AppSettings
    let launch: CompareLaunch

    @StateObject private var model = BackupWindowModel()
    @State private var configured = false

    var body: some View {
        VStack(spacing: 0) {
            if model.isConnected {
                HSplitView {
                    BackupDatabaseSidebar(model: model)
                        .frame(minWidth: 230, idealWidth: 280, maxWidth: 420)
                    VSplitView {
                        BackupTimeLineView(model: model)
                            .frame(minHeight: 170, idealHeight: 260)
                        BackupTabsView(model: model)
                            .frame(minHeight: 220)
                    }
                    .frame(minWidth: 640)
                }
            } else {
                BackupConnectView(model: model)
            }
            Divider()
            statusBar
        }
        .frame(minWidth: 1060, minHeight: 660)
        .navigationTitle(model.serverName.isEmpty ? "SQL Backup" : "SQL Backup — \(model.serverName)")
        .toolbar { toolbarContent }
        .sheet(item: $model.sheet) { sheet in
            sheetContent(sheet)
                .environmentObject(app)
                .environmentObject(settings)
        }
        .onAppear {
            guard !configured else { return }
            configured = true
            Task { await model.configure(launch: launch, app: app) }
        }
        .onDisappear { model.close() }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Menu {
                ForEach(model.serverChoices(app: app)) { profile in
                    Button(profile.displayName) { Task { await model.connect(profile, app: app) } }
                }
            } label: {
                Label(model.serverName.isEmpty ? "Server" : model.serverName, systemImage: "server.rack")
            }
            .help("Choose the SQL Server to manage")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                Button("Back Up…") { model.sheet = .backup(.backUpNow) }
                Button("Schedule Backup Jobs…") { model.sheet = .backup(.schedule) }
            } label: {
                Label("Back Up", systemImage: "externaldrive.badge.plus")
            } primaryAction: {
                model.sheet = .backup(.backUpNow)
            }
            .disabled(!model.isConnected)
            .help("Back up now, or schedule backup jobs")
            Menu {
                Button("Restore…") { model.sheet = .restore(model.selectedDatabase) }
                Button("Schedule Restore Jobs…") { model.sheet = .scheduleRestore(nil) }
                Button("Object Level Recovery…") { model.sheet = .objectRecovery(model.selectedDatabase) }
            } label: {
                Label("Restore", systemImage: "arrow.uturn.backward.circle")
            } primaryAction: {
                model.sheet = .restore(model.selectedDatabase)
            }
            .disabled(!model.isConnected)
            .help("Restore, verify backups with restore jobs, or recover single objects")
            Button {
                model.sheet = .logShipping
            } label: {
                Label("Log Shipping", systemImage: "arrow.left.arrow.right.circle")
            }
            .disabled(model.capabilities?.canSchedule != true)
            .help("Set up log shipping to a standby database")
            Menu {
                Button("Compression Analyzer…") { model.sheet = .analyzer(model.selectedDatabase) }
                Button("Backup Report…") { model.sheet = .report }
                Divider()
                Button("Server Options…") { model.sheet = .options }
            } label: {
                Label("Tools", systemImage: "wrench.and.screwdriver")
            }
            .disabled(!model.isConnected)
            Button {
                Task { await model.refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(!model.isConnected || model.isLoading)
            .help("Read the backup history again (⌘R)")
        }
    }

    // MARK: - Sheets

    @ViewBuilder
    private func sheetContent(_ sheet: BackupWindowModel.Sheet) -> some View {
        if let session = model.session, let capabilities = model.capabilities {
            switch sheet {
            case .backup(let mode):
                BackupWizardView(window: model,
                                 model: BackupWizardModel(mode: mode, window: model, session: session,
                                                          capabilities: capabilities, database: model.selectedDatabase))
            case .restore(let database):
                RestoreWizardView(window: model,
                                  model: RestoreWizardModel(window: model, session: session, capabilities: capabilities,
                                                            database: database))
            case .scheduleRestore(let job):
                ScheduleRestoreSheet(window: model, job: job, session: session, capabilities: capabilities)
            case .logShipping:
                LogShippingSheet(window: model, session: session, capabilities: capabilities)
            case .options:
                BackupServerOptionsSheet(window: model, preferences: model.preferences, session: session,
                                         capabilities: capabilities)
            case .analyzer(let database):
                CompressionAnalyzerSheet(session: session, capabilities: capabilities,
                                         databases: model.databases.filter { $0.operationalState == .operational
                                             && $0.name.lowercased() != "tempdb" }.map(\.name),
                                         database: database ?? "")
            case .objectRecovery(let database):
                ObjectLevelRecoverySheet(window: model, session: session, capabilities: capabilities,
                                         database: database ?? "")
            case .report:
                BackupReportSheet(window: model)
            case .jobLog(let job):
                BackupJobLogSheet(job: job, session: session)
            }
        } else {
            VStack(spacing: 12) {
                Text("Connect to a server first.")
                Button("Close") { model.sheet = nil }
            }
            .padding(30)
        }
    }

    // MARK: - Status bar

    private var statusBar: some View {
        HStack(spacing: 10) {
            if model.isLoading { ProgressView().controlSize(.small) }
            CompareStatusLine(text: model.statusText, isError: model.statusIsError)
            Spacer()
            if let capabilities = model.capabilities {
                Text("\(capabilities.editionTitle) \(capabilities.productVersion)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if let refreshed = model.lastRefresh {
                Text("Updated \(refreshed.formatted(date: .omitted, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

// MARK: - Not connected

struct BackupConnectView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var model: BackupWindowModel

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "externaldrive.badge.timemachine")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("SQL Backup").font(.title2.weight(.semibold))
            Text("Back up, restore, verify and log ship SQL Server databases, and see every backup on a time line.")
                .foregroundStyle(.secondary)
            if model.isLoading {
                ProgressView()
            } else if model.serverChoices(app: app).isEmpty {
                Text("Connect to a server in the main window, or save a connection, to begin.")
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(model.serverChoices(app: app)) { profile in
                        Button {
                            Task { await model.connect(profile, app: app) }
                        } label: {
                            Label(profile.displayName, systemImage: "server.rack").frame(minWidth: 260, alignment: .leading)
                        }
                    }
                }
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Databases

/// The databases on the server with their state and how recently each was backed up.
struct BackupDatabaseSidebar: View {
    @ObservedObject var model: BackupWindowModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter databases", text: $model.databaseFilter).textFieldStyle(.plain)
                if !model.databaseFilter.isEmpty {
                    Button { model.databaseFilter = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                }
            }
            .padding(8)
            Divider()
            List(selection: $model.selectedDatabase) {
                Section {
                    ForEach(model.filteredDatabases) { status in
                        BackupDatabaseListRow(status: status, now: model.serverNow, thresholds: model.preferences.thresholds)
                            .contextMenu { BackupDatabaseMenu(model: model, database: status.name) }
                    }
                } header: {
                    Text("\(model.serverName) · \(model.databases.count) databases")
                }
            }
            .listStyle(.sidebar)
            if let status = model.selectedStatus {
                Divider()
                BackupDatabaseSummary(status: status, now: model.serverNow, thresholds: model.preferences.thresholds)
            }
        }
    }
}

struct BackupDatabaseListRow: View {
    let status: DatabaseBackupStatus
    let now: Date
    let thresholds: BackupThresholds

    var body: some View {
        let risk: BackupRisk = status.risk(now: now, thresholds: thresholds)
        HStack(spacing: 8) {
            DatabaseStateIcon(status: status)
            VStack(alignment: .leading, spacing: 1) {
                Text(status.name).lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if risk == .overdue || risk == .never || risk == .warning {
                Circle()
                    .fill(BackupColors.risk(risk))
                    .frame(width: 8, height: 8)
                    .help(risk.title)
            }
        }
    }

    private var detail: String {
        if status.operationalState != .operational && status.operationalState != .readOnly {
            return status.operationalState.title
        }
        var text: String = "Full \(BackupFormat.age(status.lastFull, now: now).lowercased())"
        if status.recoveryModel.uppercased() != "SIMPLE" && !status.isSystem {
            text += " · log \(BackupFormat.age(status.lastLog, now: now).lowercased())"
        }
        return text
    }
}

/// Facts about the selected database under the list.
struct BackupDatabaseSummary: View {
    let status: DatabaseBackupStatus
    let now: Date
    let thresholds: BackupThresholds

    var body: some View {
        let risk: BackupRisk = status.risk(now: now, thresholds: thresholds)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(status.name).font(.headline).lineLimit(1)
                Spacer()
                if risk != .notApplicable {
                    Text(risk.title).font(.caption.weight(.semibold)).foregroundStyle(BackupColors.risk(risk))
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 2) {
                row("State", status.operationalState.title)
                row("Recovery", status.recoveryModel.capitalized)
                row("Size", BackupFormat.size(Int64(status.sizeMB * 1_048_576)))
                row("Last full", BackupFormat.date(status.lastFull).isEmpty ? "Never" : BackupFormat.date(status.lastFull))
                row("Last diff", BackupFormat.date(status.lastDifferential).isEmpty ? "—" : BackupFormat.date(status.lastDifferential))
                if status.recoveryModel.uppercased() != "SIMPLE" {
                    row("Last log", BackupFormat.date(status.lastLog).isEmpty ? "Never" : BackupFormat.date(status.lastLog))
                }
                if !status.availabilityGroup.isEmpty { row("AG", status.availabilityGroup) }
            }
            .font(.caption)
        }
        .padding(10)
    }

    private func row(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value).lineLimit(1)
        }
    }
}

struct BackupDatabaseMenu: View {
    @ObservedObject var model: BackupWindowModel
    let database: String

    var body: some View {
        Button("Back Up…") { open(.backup(.backUpNow)) }
        Button("Schedule Backup Jobs…") { open(.backup(.schedule)) }
        Divider()
        Button("Restore…") { open(.restore(database)) }
        Button("Schedule Restore Jobs…") { open(.scheduleRestore(nil)) }
        Button("Object Level Recovery…") { open(.objectRecovery(database)) }
        Divider()
        Button("Log Shipping…") { open(.logShipping) }
            .disabled(model.capabilities?.canSchedule != true)
        Button("Compression Analyzer…") { open(.analyzer(database)) }
        Button("Remind Me to Verify Backups") { model.addReminder(database: database) }
    }

    private func open(_ sheet: BackupWindowModel.Sheet) {
        model.selectedDatabase = database
        model.sheet = sheet
    }
}
