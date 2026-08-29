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

    // MARK: - Indexes and statistics

    /// The tree stores an index's table in `parentTable`, which is also where the
    /// Constraints, Statistics and Triggers folders put theirs.
    private static func parentTable(of node: ObjectExplorerNode) -> String? {
        if let table = node.info["parentTable"], !table.isEmpty { return table }
        // A folder that carries its object forward has the table in `name`.
        if node.kind == .folder, let name = node.name, !name.isEmpty { return name }
        return nil
    }

    static func rebuildIndex(node: ObjectExplorerNode, app: AppState) {
        guard let server = app.server(for: node),
              let database = node.database, let schema = node.schema,
              let table = parentTable(of: node), let index = node.name else {
            app.statusMessage = "The parent table of this index is unknown."
            return
        }
        run(app: app, describing: "Rebuild \(index)") {
            try await DatabaseAdmin(session: server.session)
                .rebuildIndex(database: database, schema: schema, table: table,
                              index: index, online: false)
        }
    }

    static func reorganizeIndex(node: ObjectExplorerNode, app: AppState) {
        guard let server = app.server(for: node),
              let database = node.database, let schema = node.schema,
              let table = parentTable(of: node), let index = node.name else {
            app.statusMessage = "The parent table of this index is unknown."
            return
        }
        run(app: app, describing: "Reorganize \(index)") {
            try await DatabaseAdmin(session: server.session)
                .reorganizeIndex(database: database, schema: schema, table: table, index: index)
        }
    }

    static func setIndexEnabled(node: ObjectExplorerNode, app: AppState, enabled: Bool) {
        guard let server = app.server(for: node),
              let database = node.database, let schema = node.schema,
              let table = parentTable(of: node), let index = node.name else {
            app.statusMessage = "The parent table of this index is unknown."
            return
        }
        run(app: app, describing: "\(enabled ? "Enable" : "Disable") \(index)") {
            try await DatabaseAdmin(session: server.session)
                .setIndexEnabled(database: database, schema: schema, table: table,
                                 index: index, enabled: enabled)
        }
    }

    static func rebuildTableIndexes(node: ObjectExplorerNode, app: AppState, online: Bool) {
        guard let server = app.server(for: node),
              let database = node.database, let schema = node.schema,
              let table = node.name else {
            app.statusMessage = "This node has no table to rebuild."
            return
        }
        run(app: app, describing: "Rebuild indexes on \(schema).\(table)") {
            try await DatabaseAdmin(session: server.session)
                .rebuildIndexes(database: database, schema: schema, table: table, online: online)
        }
    }

    /// Works on a table node, on its Statistics folder, and on a database node — which is
    /// what the three menus that call it pass in.
    static func updateStatistics(node: ObjectExplorerNode, app: AppState) {
        guard let server = app.server(for: node), let database = node.database else {
            app.statusMessage = "This node has no database."
            return
        }
        let schema = node.schema ?? "dbo"
        let table = node.kind == .database ? nil : node.name
        let label = table.map { "\(schema).\($0)" } ?? database
        run(app: app, describing: "Update statistics on \(label)") {
            try await DatabaseAdmin(session: server.session)
                .updateStatistics(database: database, schema: schema, table: table)
        }
    }

    // MARK: - Database checks

    /// DBCC CHECKDB prints its findings as messages, so they land in a new query window
    /// rather than in the status bar.
    static func checkDatabase(node: ObjectExplorerNode, app: AppState) {
        guard let server = app.server(for: node), let database = node.name ?? node.database else {
            return
        }
        app.statusMessage = "Running DBCC CHECKDB on \(database)…"
        Task {
            do {
                let lines = try await DatabaseAdmin(session: server.session)
                    .checkDatabase(database)
                let report = "/* DBCC CHECKDB (\(database)) */\n\n"
                    + lines.map { "-- " + $0 }.joined(separator: "\n") + "\n"
                app.openScript(report, server: server, database: database,
                               title: "CHECKDB \(database)")
                app.statusMessage = "DBCC CHECKDB finished on \(database)."
            } catch {
                app.statusMessage = "DBCC CHECKDB failed: \(error)"
            }
        }
    }

    // MARK: - Agent jobs

    static func startAgentJob(node: ObjectExplorerNode, app: AppState) {
        guard let server = app.server(for: node), let jobID = node.info["jobId"] else { return }
        run(app: app, describing: "Start \(node.label)") {
            try await AgentJobAdmin(session: server.session).start(jobID: jobID)
        }
    }

    static func stopAgentJob(node: ObjectExplorerNode, app: AppState) {
        guard let server = app.server(for: node), let jobID = node.info["jobId"] else { return }
        run(app: app, describing: "Stop \(node.label)") {
            try await AgentJobAdmin(session: server.session).stop(jobID: jobID)
        }
    }

    static func setAgentJobEnabled(node: ObjectExplorerNode, app: AppState, enabled: Bool) {
        guard let server = app.server(for: node), let jobID = node.info["jobId"] else { return }
        run(app: app, describing: "\(enabled ? "Enable" : "Disable") \(node.label)") {
            try await AgentJobAdmin(session: server.session)
                .setEnabled(jobID: jobID, enabled: enabled)
        }
    }

    // MARK: - Plumbing

    /// One place where an admin action reports success or failure into the status bar.
    private static func run(app: AppState,
                            describing label: String,
                            _ work: @escaping () async throws -> Void) {
        app.statusMessage = "\(label)…"
        Task {
            do {
                try await work()
                app.statusMessage = "\(label) finished."
            } catch {
                app.statusMessage = "\(label) failed: \(error)"
            }
        }
    }
}
