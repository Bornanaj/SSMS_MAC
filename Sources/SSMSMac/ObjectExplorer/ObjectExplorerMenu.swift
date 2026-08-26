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
            case .table: tableMenu
            case .view: viewMenu
            case .storedProcedure: procedureMenu
            case .scalarFunction, .tableValuedFunction, .aggregateFunction: functionMenu
            case .index: indexMenu
            case .column: columnMenu
            default: genericMenu
            }
        }
    }

    // MARK: - Menus

    @ViewBuilder
    private var serverMenu: some View {
        Button("New Query") { newQuery(database: nil) }
        Divider()
        Button("Activity Monitor") {
            if let server = app.server(for: node) { app.activeSheet = .activityMonitor(server.id) }
        }
        Button("Reports…") {
            if let server = app.server(for: node) { app.activeSheet = .reports(server.id, nil) }
        }
        Button("SQL Server Agent Jobs…") {
            if let server = app.server(for: node) { app.activeSheet = .agentJobs(server.id) }
        }
        Button("Logins…") {
            if let server = app.server(for: node) { app.activeSheet = .logins(server.id) }
        }
        Divider()
        refreshItem
        Button("Disconnect") {
            guard let server = app.server(for: node) else { return }
            Task { await app.disconnect(server: server) }
        }
    }

    @ViewBuilder
    private var databaseMenu: some View {
        Button("New Query") { newQuery(database: node.name) }
        Divider()
        Menu("Script Database as") {
            scriptItem("CREATE To", .create)
            scriptItem("DROP To", .drop)
        }
        Button("Generate Scripts…") {
            if let server = app.server(for: node), let name = node.name {
                app.activeSheet = .generateScripts(server.id, name)
            }
        }
        Menu("Tasks") {
            Button("Detach…") {
                if let server = app.server(for: node), let name = node.name {
                    app.activeSheet = .detachDatabase(server.id, name)
                }
            }
            Button("Attach…") {
                if let server = app.server(for: node) {
                    app.activeSheet = .attachDatabase(server.id)
                }
            }
            Divider()
            Button("Shrink…") {
                if let server = app.server(for: node), let name = node.name {
                    app.activeSheet = .shrinkDatabase(server.id, name)
                }
            }
            Button("Disk Usage…") {
                if let server = app.server(for: node), let name = node.name {
                    app.activeSheet = .diskUsage(server.id, name)
                }
            }
            Divider()
            Button("Back Up…") {
                if let server = app.server(for: node), let name = node.name {
                    app.activeSheet = .backup(server.id, name)
                }
            }
            Button("Restore Database…") {
                if let server = app.server(for: node) { app.activeSheet = .restore(server.id) }
            }
            Divider()
            Button("Import Flat File…") {
                if let server = app.server(for: node), let name = node.name {
                    app.activeSheet = .importFlatFile(server.id, name)
                }
            }
            Divider()
            Button("Index Maintenance…") {
                if let server = app.server(for: node), let name = node.name {
                    app.activeSheet = .indexMaintenance(server.id, name)
                }
            }
        }
        Button("Security…") {
            if let server = app.server(for: node), let name = node.name {
                app.activeSheet = .databaseSecurity(server.id, name)
            }
        }
        Button("Permissions…") {
            if let server = app.server(for: node), let name = node.name {
                app.activeSheet = .permissions(server.id, name, nil, nil)
            }
        }
        Button("Reports…") {
            if let server = app.server(for: node), let name = node.name {
                app.activeSheet = .reports(server.id, name)
            }
        }
        Divider()
        refreshItem
        Button("Properties") {
            if let server = app.server(for: node), let name = node.name {
                app.activeSheet = .databaseProperties(server.id, name)
            }
        }
    }

    @ViewBuilder
    private var tableMenu: some View {
        Button("Select Top 1000 Rows") {
            Task { await ObjectExplorerActions.selectTopRows(node: node, app: app) }
        }
        Button("Edit Top 200 Rows") {
            if let server = app.server(for: node), let database = node.database,
               let schema = node.schema, let name = node.name {
                app.activeSheet = .editData(server.id, database, schema, name)
            }
        }
        Divider()
        Button("Design") {
            if let server = app.server(for: node), let database = node.database,
               let schema = node.schema, let name = node.name {
                app.activeSheet = .designTable(server.id, database, schema, name)
            }
        }
        dependenciesItem
        Button("Permissions…") {
            if let server = app.server(for: node), let database = node.database,
               let schema = node.schema, let name = node.name {
                app.activeSheet = .permissions(server.id, database, schema, name)
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
        Divider()
        Button("Copy Full Name") { copyName() }
        refreshItem
        Button("Properties") {
            if let server = app.server(for: node), let database = node.database,
               let schema = node.schema, let name = node.name {
                app.activeSheet = .tableProperties(server.id, database, schema, name)
            }
        }
    }

    @ViewBuilder
    private var viewMenu: some View {
        Button("Select Top 1000 Rows") {
            Task { await ObjectExplorerActions.selectTopRows(node: node, app: app) }
        }
        dependenciesItem
        Divider()
        Menu("Script View as") {
            scriptItem("CREATE To", .create)
            scriptItem("ALTER To", .alter)
            scriptItem("DROP To", .drop)
            scriptItem("SELECT To", .select)
        }
        Divider()
        Button("Copy Full Name") { copyName() }
        refreshItem
    }

    @ViewBuilder
    private var procedureMenu: some View {
        Button("Modify") { script(.alter) }
        Button("Execute Stored Procedure…") { script(.execute) }
        dependenciesItem
        Divider()
        Menu("Script Stored Procedure as") {
            scriptItem("CREATE To", .create)
            scriptItem("ALTER To", .alter)
            scriptItem("DROP To", .drop)
        }
        Divider()
        Button("Copy Full Name") { copyName() }
        refreshItem
    }

    @ViewBuilder
    private var functionMenu: some View {
        Button("Modify") { script(.alter) }
        dependenciesItem
        Divider()
        Menu("Script Function as") {
            scriptItem("CREATE To", .create)
            scriptItem("ALTER To", .alter)
            scriptItem("DROP To", .drop)
        }
        Divider()
        Button("Copy Full Name") { copyName() }
        refreshItem
    }

    @ViewBuilder
    private var indexMenu: some View {
        Button("Rebuild") { ObjectExplorerActions.rebuildIndex(node: node, app: app) }
        Button("Reorganize") { ObjectExplorerActions.reorganizeIndex(node: node, app: app) }
        Divider()
        Menu("Script Index as") {
            scriptItem("CREATE To", .create)
            scriptItem("DROP To", .drop)
        }
        refreshItem
    }

    @ViewBuilder
    private var columnMenu: some View {
        Button("Copy Column Name") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(node.name ?? node.label, forType: .string)
        }
        refreshItem
    }

    @ViewBuilder
    private var genericMenu: some View {
        if node.isModule {
            Menu("Script as") {
                scriptItem("CREATE To", .create)
                scriptItem("DROP To", .drop)
            }
        }
        Button("Copy Name") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(node.name ?? node.label, forType: .string)
        }
        refreshItem
    }

    @ViewBuilder
    private var dependenciesItem: some View {
        Button("View Dependencies…") {
            if let server = app.server(for: node), let database = node.database,
               let schema = node.schema, let name = node.name {
                app.activeSheet = .dependencies(server.id, database, schema, name)
            }
        }
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
}
