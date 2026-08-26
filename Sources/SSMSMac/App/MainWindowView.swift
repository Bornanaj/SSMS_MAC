import SwiftUI
import SQLServerKit

/// The main window: Object Explorer on the left, query tabs on the right.
struct MainWindowView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var settings = AppSettings.shared
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            ObjectExplorerView(model: app.explorer)
                .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 520)
        } detail: {
            detail
        }
        .sheet(item: $app.activeSheet) { sheet in
            sheetContent(sheet)
        }
        .sheet(isPresented: $app.showGoToLine) {
            GoToLineSheet(lineCount: max(1, app.selectedTab?.lineCount ?? 1),
                          currentLine: app.selectedTab?.currentLine ?? 1) { line in
                NotificationCenter.default.post(name: .ssmsGoToLine, object: nil,
                                                userInfo: ["line": line])
            }
        }
        .sheet(isPresented: Binding(get: { app.pendingTemplateScript != nil },
                                    set: { if !$0 { app.pendingTemplateScript = nil } })) {
            if let script = app.pendingTemplateScript {
                TemplateParametersSheet(sql: script) { substituted in
                    app.selectedTab?.text = substituted
                    app.pendingTemplateScript = nil
                }
            }
        }
        .task {
            if app.servers.isEmpty { app.activeSheet = .connect }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if app.tabs.isEmpty {
            ContentUnavailableView {
                Label("No query windows", systemImage: "doc.text")
            } description: {
                Text("Open a new query window to start writing T-SQL.")
            } actions: {
                Button("New Query") {
                    Task { await app.newQueryTab(server: app.servers.first, database: nil) }
                }
                .disabled(app.servers.isEmpty)
                Button("Connect…") { app.activeSheet = .connect }
            }
        } else {
            VStack(spacing: 0) {
                tabStrip
                Divider()
                if let tab = app.selectedTab {
                    QueryWindowView(tab: tab, settings: settings)
                        .id(tab.id)
                }
            }
        }
    }

    private var tabStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 1) {
                ForEach(app.tabs) { tab in
                    tabChip(tab)
                }
                Button {
                    Task {
                        let server = app.selectedTab.flatMap { current in
                            app.servers.first { $0.id == current.sessionID }
                        } ?? app.servers.first
                        await app.newQueryTab(server: server, database: app.selectedTab?.database)
                    }
                } label: {
                    Image(systemName: "plus")
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                }
                .buttonStyle(.plain)
                .disabled(app.servers.isEmpty)
                Spacer()
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func tabChip(_ tab: QueryTab) -> some View {
        let isSelected = app.selectedTabID == tab.id
        return HStack(spacing: 5) {
            if let color = Theme.color(hex: tab.accentColorHex) {
                Circle().fill(color).frame(width: 6, height: 6)
            }
            Text(tab.displayTitle)
                .lineLimit(1)
                .font(.caption)
            Button {
                app.closeTab(tab)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
            .opacity(isSelected ? 1 : 0.45)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(isSelected ? Color.accentColor.opacity(0.20) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture { app.selectedTabID = tab.id }
        .contextMenu {
            Button("Close") { app.closeTab(tab) }
            Button("Close Others") {
                for other in app.tabs where other.id != tab.id { app.closeTab(other) }
            }
        }
    }

    @ViewBuilder
    private func sheetContent(_ sheet: AppState.AppSheet) -> some View {
        switch sheet {
        case .connect:
            ConnectSheet()
        case .activityMonitor(let serverID):
            if let server = app.server(id: serverID) {
                ActivityMonitorView(server: server)
            }
        case .databaseProperties(let serverID, let database):
            if let server = app.server(id: serverID) {
                DatabasePropertiesView(server: server, database: database)
            }
        case .tableProperties(let serverID, let database, let schema, let table):
            if let server = app.server(id: serverID) {
                TablePropertiesView(server: server, database: database, schema: schema, table: table)
            }
        case .backup(let serverID, let database):
            if let server = app.server(id: serverID) {
                BackupSheet(server: server, database: database)
            }
        case .restore(let serverID):
            if let server = app.server(id: serverID) {
                RestoreSheet(server: server)
            }
        case .importFlatFile(let serverID, let database):
            if let server = app.server(id: serverID) {
                ImportFlatFileSheet(server: server, database: database)
            }
        case .editData(let serverID, let database, let schema, let table):
            if let server = app.server(id: serverID) {
                DataEditorSheet(server: server, database: database, schema: schema, table: table)
            }
        case .indexMaintenance(let serverID, let database):
            if let server = app.server(id: serverID) {
                IndexMaintenanceView(server: server, database: database)
            }
        case .generateScripts(let serverID, let database):
            if let server = app.server(id: serverID) {
                GenerateScriptsSheet(server: server, database: database)
            }
        case .dependencies(let serverID, let database, let schema, let name):
            if let server = app.server(id: serverID) {
                DependenciesSheet(server: server, database: database,
                                  schema: schema, name: name)
            }
        case .designTable(let serverID, let database, let schema, let table):
            if let server = app.server(id: serverID) {
                TableDesignerSheet(server: server, database: database,
                                   schema: schema, table: table)
            }
        case .detachDatabase(let serverID, let database):
            if let server = app.server(id: serverID) {
                DetachDatabaseSheet(server: server, database: database)
            }
        case .attachDatabase(let serverID):
            if let server = app.server(id: serverID) {
                AttachDatabaseSheet(server: server)
            }
        case .shrinkDatabase(let serverID, let database):
            if let server = app.server(id: serverID) {
                ShrinkDatabaseSheet(server: server, database: database)
            }
        case .diskUsage(let serverID, let database):
            if let server = app.server(id: serverID) {
                DiskUsageSheet(server: server, database: database)
            }
        case .queryOptions:
            QueryOptionsSheet(options: app.selectedTab?.setOptions ?? QuerySetOptions()) { updated in
                app.selectedTab?.setOptions = updated
            }
        case .templates:
            TemplateExplorerView { body in
                Task {
                    let server = app.servers.first { $0.id == app.selectedTab?.sessionID }
                        ?? app.servers.first
                    if let tab = app.selectedTab {
                        tab.text = body
                    } else {
                        await app.newQueryTab(server: server, database: nil, text: body)
                    }
                    app.activeSheet = nil
                }
            }
        case .logins(let serverID):
            if let server = app.server(id: serverID) {
                LoginsSheet(server: server)
            }
        case .databaseSecurity(let serverID, let database):
            if let server = app.server(id: serverID) {
                DatabaseSecuritySheet(server: server, database: database)
            }
        case .permissions(let serverID, let database, let schema, let object):
            if let server = app.server(id: serverID) {
                PermissionsSheet(server: server, database: database,
                                 schema: schema, object: object)
            }
        case .agentJobs(let serverID):
            if let server = app.server(id: serverID) {
                AgentJobsSheet(server: server)
            }
        case .reports(let serverID, let database):
            if let server = app.server(id: serverID) {
                ReportsSheet(server: server, initialDatabase: database)
            }
        case .serverProperties(let serverID):
            if let server = app.server(id: serverID) {
                ServerPropertiesSheet(server: server)
            }
        case .scriptPreview(let title, let sql):
            ScriptPreviewSheet(title: title, sql: sql)
        case .exportResults:
            EmptyView()
        }
    }
}
