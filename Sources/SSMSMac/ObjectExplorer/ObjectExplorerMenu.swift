import SwiftUI
import SQLServerKit

/// Context menu for a tree node. Mirrors the SSMS menus, limited to what this app
/// can actually carry out.
struct ObjectExplorerMenu: View {
    @EnvironmentObject var app: AppState
    let node: ObjectExplorerNode
    @ObservedObject var model: ObjectExplorerModel

    var body: some View {
        Group {
            switch node.kind {
            case .server: serverMenu
            case .database: databaseMenu
            case .table, .externalTable: tableMenu
            case .view: viewMenu
            case .storedProcedure: procedureMenu
            case .scalarFunction, .tableValuedFunction, .aggregateFunction: functionMenu
            case .index: indexMenu
            case .column: columnMenu
            case .agentJob: agentJobMenu
            case .schema: schemaMenu
            case .login, .databaseUser, .databaseRole, .applicationRole, .serverRole: principalMenu
            case .folder: folderMenu
            default: genericMenu
            }
        }
    }

    // MARK: - Server

    @ViewBuilder
    private var serverMenu: some View {
        Button("New Query") { newQuery(database: nil) }
        Divider()
        Menu("New") {
            Button("Database…") { sheet { .newDatabase($0.id) } }
            Button("Attach Database…") { sheet { .attachDatabase($0.id) } }
        }
        Menu("Reports") {
            Button("Server Dashboard") { sheet { .serverDashboard($0.id) } }
            Button("Activity Monitor") { sheet { .activityMonitor($0.id) } }
            Button("SQL Server Logs") { sheet { .serverLog($0.id) } }
        }
        Button("SQL Server Agent Jobs") { sheet { .agentJob($0.id, "") } }
        Divider()
        Group {
            Button("Permissions…") { sheet { .permissions($0.id, node) } }
            Button("Properties") { sheet { .serverProperties($0.id) } }
            Divider()
            refreshItem
            Button("Disconnect") {
                guard let server = app.server(for: node) else { return }
                Task { await app.disconnect(server: server) }
            }
        }
    }

    // MARK: - Database

    @ViewBuilder
    private var databaseMenu: some View {
        Button("New Query") { newQuery(database: node.name) }
        Divider()
        Menu("Script Database as") {
            scriptItem("CREATE To", .create)
            scriptItem("DROP To", .drop)
        }
        databaseTasksMenu
        Menu("Reports") {
            Button("Query Store") {
                if let server = app.server(for: node), let name = node.name {
                    app.activeSheet = .queryStore(server.id, name)
                }
            }
            Button("Index Maintenance…") {
                if let server = app.server(for: node), let name = node.name {
                    app.activeSheet = .indexMaintenance(server.id, name)
                }
            }
            Button("Activity Monitor") { sheet { .activityMonitor($0.id) } }
        }
        Divider()
        Group {
            Button("Rename…") { sheet { .renameObject($0.id, node) } }
            Button("Delete…") { sheet { .deleteObject($0.id, node) } }
            Button("Permissions…") { sheet { .permissions($0.id, node) } }
            Divider()
            refreshItem
            Button("Properties") {
                if let server = app.server(for: node), let name = node.name {
                    app.activeSheet = .databaseProperties(server.id, name)
                }
            }
        }
    }

    @ViewBuilder
    private var databaseTasksMenu: some View {
        Menu("Tasks") {
            Button("Back Up…") {
                if let server = app.server(for: node), let name = node.name {
                    app.activeSheet = .backup(server.id, name)
                }
            }
            Button("Restore Database…") {
                if let server = app.server(for: node) { app.activeSheet = .restore(server.id) }
            }
            Divider()
            Button("Detach…") {
                if let server = app.server(for: node), let name = node.name {
                    app.activeSheet = .detachDatabase(server.id, name)
                }
            }
            Button("Shrink…") {
                if let server = app.server(for: node), let name = node.name {
                    app.activeSheet = .shrinkDatabase(server.id, name)
                }
            }
            Divider()
            Button("Generate Scripts…") {
                if let server = app.server(for: node), let name = node.name {
                    app.activeSheet = .generateScripts(server.id, name)
                }
            }
            Button("Import Flat File…") {
                if let server = app.server(for: node), let name = node.name {
                    app.activeSheet = .importFlatFile(server.id, name)
                }
            }
            Divider()
            Button("Update Statistics") {
                ObjectExplorerActions.updateStatistics(node: node, app: app)
            }
            Button("Check Database Integrity") {
                ObjectExplorerActions.checkDatabase(node: node, app: app)
            }
        }
    }

    // MARK: - Tables and views

    @ViewBuilder
    private var tableMenu: some View {
        Button("Select Top \(app.settings.scriptSelectTopRows) Rows") {
            Task { await ObjectExplorerActions.selectTopRows(node: node, app: app) }
        }
        Button("Edit Top \(app.settings.editTopRows) Rows") {
            if let server = app.server(for: node), let database = node.database,
               let schema = node.schema, let name = node.name {
                app.activeSheet = .editData(server.id, database, schema, name)
            }
        }
        Divider()
        Menu("Script Table as") {
            scriptItem("CREATE To", .create)
            scriptItem("DROP To", .drop)
            scriptItem("DROP And CREATE To", .dropAndCreate)
            Divider()
            scriptItem("SELECT To", .select)
            scriptItem("INSERT To", .insert)
            scriptItem("UPDATE To", .update)
            scriptItem("DELETE To", .delete)
        }
        Menu("Storage") {
            Button("Rebuild All Indexes") {
                ObjectExplorerActions.rebuildTableIndexes(node: node, app: app, online: false)
            }
            Button("Rebuild All Indexes (Online)") {
                ObjectExplorerActions.rebuildTableIndexes(node: node, app: app, online: true)
            }
            Button("Update Statistics") {
                ObjectExplorerActions.updateStatistics(node: node, app: app)
            }
        }
        Divider()
        objectCommonItems
    }

    @ViewBuilder
    private var viewMenu: some View {
        Button("Select Top \(app.settings.scriptSelectTopRows) Rows") {
            Task { await ObjectExplorerActions.selectTopRows(node: node, app: app) }
        }
        Button("Modify") { script(.alter) }
        Divider()
        Menu("Script View as") {
            scriptItem("CREATE To", .create)
            scriptItem("ALTER To", .alter)
            scriptItem("DROP To", .drop)
            scriptItem("SELECT To", .select)
        }
        Divider()
        objectCommonItems
    }

    @ViewBuilder
    private var procedureMenu: some View {
        Button("Modify") { script(.alter) }
        Button("Execute Stored Procedure…") { script(.execute) }
        Divider()
        Menu("Script Stored Procedure as") {
            scriptItem("CREATE To", .create)
            scriptItem("ALTER To", .alter)
            scriptItem("DROP To", .drop)
            scriptItem("DROP And CREATE To", .dropAndCreate)
        }
        Divider()
        objectCommonItems
    }

    @ViewBuilder
    private var functionMenu: some View {
        Button("Modify") { script(.alter) }
        Divider()
        Menu("Script Function as") {
            scriptItem("CREATE To", .create)
            scriptItem("ALTER To", .alter)
            scriptItem("DROP To", .drop)
            scriptItem("DROP And CREATE To", .dropAndCreate)
        }
        Divider()
        objectCommonItems
    }

    /// The items every schema-scoped object shares.
    @ViewBuilder
    private var objectCommonItems: some View {
        Button("View Dependencies…") { sheet { .dependencies($0.id, node) } }
        Button("Rename…") { sheet { .renameObject($0.id, node) } }
        Button("Delete…") { sheet { .deleteObject($0.id, node) } }
        Button("Permissions…") { sheet { .permissions($0.id, node) } }
        Divider()
        Button("Copy Full Name") { copyName() }
        refreshItem
        if node.isTableLike {
            Button("Properties") {
                if let server = app.server(for: node), let database = node.database,
                   let schema = node.schema, let name = node.name {
                    app.activeSheet = .tableProperties(server.id, database, schema, name)
                }
            }
        }
    }

    // MARK: - Smaller objects

    @ViewBuilder
    private var indexMenu: some View {
        Button("Rebuild") { ObjectExplorerActions.rebuildIndex(node: node, app: app) }
        Button("Reorganize") { ObjectExplorerActions.reorganizeIndex(node: node, app: app) }
        Button(node.info["isDisabled"] == "1" ? "Enable" : "Disable") {
            ObjectExplorerActions.setIndexEnabled(node: node, app: app,
                                                  enabled: node.info["isDisabled"] == "1")
        }
        Divider()
        Menu("Script Index as") {
            scriptItem("CREATE To", .create)
            scriptItem("DROP To", .drop)
        }
        Button("Rename…") { sheet { .renameObject($0.id, node) } }
        Button("Delete…") { sheet { .deleteObject($0.id, node) } }
        refreshItem
    }

    @ViewBuilder
    private var columnMenu: some View {
        Button("Copy Column Name") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(node.name ?? node.label, forType: .string)
        }
        Button("Rename…") { sheet { .renameObject($0.id, node) } }
        refreshItem
    }

    @ViewBuilder
    private var agentJobMenu: some View {
        Button("Open Job") {
            if let server = app.server(for: node) {
                app.activeSheet = .agentJob(server.id, node.info["jobId"] ?? "")
            }
        }
        Divider()
        Button("Start Job") { ObjectExplorerActions.startAgentJob(node: node, app: app) }
        Button("Stop Job") { ObjectExplorerActions.stopAgentJob(node: node, app: app) }
        Button(node.info["isEnabled"] == "0" ? "Enable" : "Disable") {
            ObjectExplorerActions.setAgentJobEnabled(node: node, app: app,
                                                     enabled: node.info["isEnabled"] == "0")
        }
        Divider()
        refreshItem
    }

    @ViewBuilder
    private var schemaMenu: some View {
        Menu("Script Schema as") {
            scriptItem("CREATE To", .create)
            scriptItem("DROP To", .drop)
        }
        Button("Permissions…") { sheet { .permissions($0.id, node) } }
        Button("Delete…") { sheet { .deleteObject($0.id, node) } }
        Divider()
        Button("Copy Name") { copyName() }
        refreshItem
    }

    @ViewBuilder
    private var principalMenu: some View {
        Menu("Script as") {
            scriptItem("CREATE To", .create)
            scriptItem("DROP To", .drop)
        }
        Button("Permissions…") { sheet { .permissions($0.id, node) } }
        Button("Delete…") { sheet { .deleteObject($0.id, node) } }
        Divider()
        Button("Copy Name") { copyName() }
        refreshItem
    }

    // MARK: - Folders

    @ViewBuilder
    private var folderMenu: some View {
        if let folder = node.folder {
            folderMenu(folder)
        } else {
            refreshItem
        }
    }

    @ViewBuilder
    private func folderMenu(_ folder: ObjectFolderKind) -> some View {
        switch folder {
        case .databases, .systemDatabases:
            Button("New Database…") { sheet { .newDatabase($0.id) } }
            Button("Attach Database…") { sheet { .attachDatabase($0.id) } }
            Divider()
            refreshItem
        case .tables:
            Button("New Query") { newQuery(database: node.database) }
            if let database = node.database {
                Button("Generate Scripts…") {
                    if let server = app.server(for: node) {
                        app.activeSheet = .generateScripts(server.id, database)
                    }
                }
            }
            Divider()
            refreshItem
        case .agentJobs, .agent:
            Button("Open Job List") { sheet { .agentJob($0.id, "") } }
            Divider()
            refreshItem
        case .management:
            Button("SQL Server Logs") { sheet { .serverLog($0.id) } }
            Button("Activity Monitor") { sheet { .activityMonitor($0.id) } }
            Divider()
            refreshItem
        case .indexes:
            Button("Rebuild All Indexes") {
                ObjectExplorerActions.rebuildTableIndexes(node: node, app: app, online: false)
            }
            Divider()
            refreshItem
        case .statistics:
            Button("Update Statistics") {
                ObjectExplorerActions.updateStatistics(node: node, app: app)
            }
            Divider()
            refreshItem
        default:
            refreshItem
        }
    }

    @ViewBuilder
    private var genericMenu: some View {
        if node.isModule {
            Menu("Script as") {
                scriptItem("CREATE To", .create)
                scriptItem("ALTER To", .alter)
                scriptItem("DROP To", .drop)
            }
        } else {
            Menu("Script as") {
                scriptItem("CREATE To", .create)
                scriptItem("DROP To", .drop)
            }
        }
        if ObjectAdmin.dropKeyword(for: node.kind) != nil
            || node.kind == .primaryKey || node.kind == .uniqueKey || node.kind == .foreignKey
            || node.kind == .checkConstraint || node.kind == .defaultConstraint {
            Button("Delete…") { sheet { .deleteObject($0.id, node) } }
        }
        if ObjectAdmin.canRename(node.kind) {
            Button("Rename…") { sheet { .renameObject($0.id, node) } }
        }
        Divider()
        Button("Copy Name") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(node.name ?? node.label, forType: .string)
        }
        refreshItem
    }

    @ViewBuilder
    private var refreshItem: some View {
        Button("Refresh") { Task { await model.refresh(node) } }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func scriptItem(_ title: String, _ action: ScriptAction) -> some View {
        Button(title) { script(action) }
    }

    private func script(_ action: ScriptAction) {
        Task { await ObjectExplorerActions.script(node: node, action: action, app: app) }
    }

    private func newQuery(database: String?) {
        guard let server = app.server(for: node) else { return }
        Task { await app.newQueryTab(server: server, database: database) }
    }

    private func copyName() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(node.qualifiedName ?? node.label, forType: .string)
    }

    /// Every sheet needs the node's server, so the lookup is done once here.
    private func sheet(_ make: (ConnectedServer) -> AppState.AppSheet) {
        guard let server = app.server(for: node) else { return }
        app.activeSheet = make(server)
    }
}
