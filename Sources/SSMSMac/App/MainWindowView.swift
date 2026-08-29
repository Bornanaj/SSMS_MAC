import SwiftUI
import SQLServerKit

/// The main window: Object Explorer on the left, query tabs on the right.
struct MainWindowView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var settings = AppSettings.shared
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 520)
        } detail: {
            detail
        }
        .sheet(item: $app.activeSheet) { sheet in
            sheetContent(sheet)
        }
        .task {
            if app.servers.isEmpty { app.activeSheet = .connect }
        }
    }

    /// The Object Explorer, with the F7 details list underneath when it is showing.
    @ViewBuilder
    private var sidebar: some View {
        if app.showExplorerDetails {
            VSplitView {
                ObjectExplorerView(model: app.explorer)
                    .frame(minHeight: 180)
                ObjectExplorerDetailsView(model: app.explorer)
                    .frame(minHeight: 140, idealHeight: 220)
            }
        } else {
            ObjectExplorerView(model: app.explorer)
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
            Divider()
            Button("Query Options…") { app.activeSheet = .queryOptions(tab.id) }
        }
    }

    /// Type-erased on purpose. This switch has close to thirty arms, and letting
    /// `ViewBuilder` build a nested `_ConditionalContent` tree that deep is what made the
    /// type checker time out on CI before. One `AnyView` per sheet presentation costs
    /// nothing measurable.
    private func sheetContent(_ sheet: AppState.AppSheet) -> AnyView {
        func wrap<Content: View>(_ content: Content) -> AnyView { AnyView(content) }
        /// Every server-scoped sheet needs its `ConnectedServer`; a stale id just shows
        /// nothing rather than crashing.
        func withServer(_ id: UUID,
                        _ make: (ConnectedServer) -> AnyView) -> AnyView {
            guard let server = app.server(id: id) else { return AnyView(EmptyView()) }
            return make(server)
        }
        func withTab(_ id: UUID, _ make: (QueryTab) -> AnyView) -> AnyView {
            guard let tab = app.tabs.first(where: { $0.id == id }) else {
                return AnyView(EmptyView())
            }
            return make(tab)
        }

        switch sheet {
        case .connect:
            return wrap(ConnectSheet())
        case .activityMonitor(let serverID):
            return withServer(serverID) { wrap(ActivityMonitorView(server: $0)) }
        case .databaseProperties(let serverID, let database):
            return withServer(serverID) {
                wrap(DatabasePropertiesView(server: $0, database: database))
            }
        case .tableProperties(let serverID, let database, let schema, let table):
            return withServer(serverID) {
                wrap(TablePropertiesView(server: $0, database: database,
                                         schema: schema, table: table))
            }
        case .backup(let serverID, let database):
            return withServer(serverID) { wrap(BackupSheet(server: $0, database: database)) }
        case .restore(let serverID):
            return withServer(serverID) { wrap(RestoreSheet(server: $0)) }
        case .importFlatFile(let serverID, let database):
            return withServer(serverID) {
                wrap(ImportFlatFileSheet(server: $0, database: database))
            }
        case .editData(let serverID, let database, let schema, let table):
            return withServer(serverID) {
                wrap(DataEditorSheet(server: $0, database: database, schema: schema, table: table))
            }
        case .indexMaintenance(let serverID, let database):
            return withServer(serverID) {
                wrap(IndexMaintenanceView(server: $0, database: database))
            }
        case .scriptPreview(let title, let sql):
            return wrap(ScriptPreviewSheet(title: title, sql: sql))
        case .executionPlan(let title, let xml):
            return wrap(PlanPreviewSheet(title: title, xml: xml))
        case .exportResults:
            return AnyView(EmptyView())

        // Object and server management
        case .serverProperties(let serverID):
            return withServer(serverID) { wrap(ServerPropertiesView(server: $0)) }
        case .newDatabase(let serverID):
            return withServer(serverID) { wrap(NewDatabaseSheet(server: $0)) }
        case .attachDatabase(let serverID):
            return withServer(serverID) { wrap(AttachDatabaseSheet(server: $0)) }
        case .detachDatabase(let serverID, let database):
            return withServer(serverID) {
                wrap(DetachDatabaseSheet(server: $0, database: database))
            }
        case .shrinkDatabase(let serverID, let database):
            return withServer(serverID) {
                wrap(ShrinkDatabaseSheet(server: $0, database: database))
            }
        case .renameObject(let serverID, let node):
            return withServer(serverID) { wrap(RenameObjectSheet(server: $0, node: node)) }
        case .deleteObject(let serverID, let node):
            return withServer(serverID) { wrap(DeleteObjectSheet(server: $0, node: node)) }
        case .dependencies(let serverID, let node):
            return withServer(serverID) { wrap(DependenciesView(server: $0, node: node)) }
        case .permissions(let serverID, let node):
            return withServer(serverID) { wrap(PermissionsView(server: $0, node: node)) }
        case .generateScripts(let serverID, let database):
            return withServer(serverID) {
                wrap(GenerateScriptsSheet(server: $0, database: database))
            }

        // Monitoring
        case .serverLog(let serverID):
            return withServer(serverID) { wrap(ServerLogView(server: $0)) }
        case .agentJob(let serverID, let jobID):
            return withServer(serverID) { wrap(AgentJobView(server: $0, initialJobID: jobID)) }
        case .queryStore(let serverID, let database):
            return withServer(serverID) { wrap(QueryStoreView(server: $0, database: database)) }
        case .serverDashboard(let serverID):
            return withServer(serverID) { wrap(ServerDashboardView(server: $0)) }

        // Query window
        case .queryOptions(let tabID):
            return withTab(tabID) { wrap(QueryOptionsSheet(tab: $0)) }
        case .templateParameters(let tabID):
            return withTab(tabID) { wrap(TemplateParametersSheet(tab: $0)) }
        case .goToLine(let tabID):
            return withTab(tabID) { wrap(GoToLineSheet(tab: $0)) }
        case .multiServerQuery(let tabID):
            return withTab(tabID) { wrap(MultiServerQuerySheet(tab: $0)) }
        }
    }
}
