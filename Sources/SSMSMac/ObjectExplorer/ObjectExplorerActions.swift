import Foundation
import AppKit
import SQLServerKit

/// Bridges Object Explorer menu items to the scripting and admin services.
@MainActor
enum ObjectExplorerActions {

    static func selectTopRows(node: ObjectExplorerNode, app: AppState) async {
        guard let server = app.server(for: node),
              let database = node.database, let schema = node.schema, let name = node.name else { return }
        let generator = ScriptGenerator(session: server.session)
        do {
            let sql = try await generator.selectTopRows(database: database, schema: schema,
                                                        table: name, top: app.settings.scriptSelectTopRows)
            let tab = await app.newQueryTab(server: server, database: database, text: sql)
            tab.title = "\(schema).\(name)"
            tab.isDirty = false
            tab.execute()
        } catch {
            app.statusMessage = "Could not script the query: \(error)"
        }
    }

    static func script(node: ObjectExplorerNode, action: ScriptAction, app: AppState) async {
        guard let server = app.server(for: node) else { return }
        let generator = ScriptGenerator(session: server.session)
        var options = ScriptOptions()
        options.selectTopRows = app.settings.scriptSelectTopRows
        do {
            let sql = try await generator.script(node: node, action: action, options: options)
            let tab = await app.newQueryTab(server: server, database: node.database, text: sql)
            tab.title = "\(node.displayPath) (\(action.menuTitle))"
            tab.isDirty = false
        } catch {
            app.statusMessage = "Scripting failed: \(error)"
        }
    }

    /// The tree records an index's table under `parentTable`. Reading `table`, which
    /// `MetadataService` never writes, made these two menu items do nothing at all.
    private static func parentTable(of node: ObjectExplorerNode) -> String? {
        if let table = node.info["parentTable"], !table.isEmpty { return table }
        if let table = node.info["table"], !table.isEmpty { return table }
        return nil
    }

    static func rebuildIndex(node: ObjectExplorerNode, app: AppState) {
        guard let server = app.server(for: node),
              let database = node.database, let schema = node.schema,
              let table = parentTable(of: node), let index = node.name else {
            app.statusMessage = "The parent table of this index is unknown."
            return
        }
        Task {
            let admin = DatabaseAdmin(session: server.session)
            do {
                try await admin.rebuildIndex(database: database, schema: schema,
                                             table: table, index: index, online: false)
                app.statusMessage = "Rebuilt \(index) on \(schema).\(table)."
            } catch {
                app.statusMessage = "Rebuild failed: \(error)"
            }
        }
    }

    static func reorganizeIndex(node: ObjectExplorerNode, app: AppState) {
        guard let server = app.server(for: node),
              let database = node.database, let schema = node.schema,
              let table = parentTable(of: node), let index = node.name else {
            app.statusMessage = "The parent table of this index is unknown."
            return
        }
        Task {
            let admin = DatabaseAdmin(session: server.session)
            do {
                try await admin.reorganizeIndex(database: database, schema: schema,
                                                table: table, index: index)
                app.statusMessage = "Reorganized \(index)."
            } catch {
                app.statusMessage = "Reorganize failed: \(error)"
            }
        }
    }
}
