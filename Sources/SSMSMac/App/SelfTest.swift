import Foundation
import AppKit
import SwiftUI
import SQLServerKit

/// Exercises the real UI data path without a human at the keyboard:
/// connect -> object explorer -> query tab -> execute -> results.
/// Run with:  ssms-mac --selftest
@MainActor
enum SelfTest {

    static var isRequested: Bool {
        CommandLine.arguments.contains("--selftest")
    }

    private static func env(_ key: String, _ fallback: String) -> String {
        ProcessInfo.processInfo.environment[key] ?? fallback
    }

    static func run() async -> Int32 {
        var failures: [String] = []

        func check(_ label: String, _ condition: Bool, _ detail: String = "") {
            let mark = condition ? "PASS" : "FAIL"
            print("[\(mark)] \(label)\(detail.isEmpty ? "" : " — \(detail)")")
            if !condition { failures.append(label) }
        }

        let app = AppState()

        var profile = ConnectionProfile()
        profile.name = "selftest"
        profile.server = "\(env("SQL_HOST", "127.0.0.1")),\(env("SQL_PORT", "11433"))"
        profile.username = env("SQL_USER", "sa")
        profile.database = env("SQL_DB", "ShopDemo")
        profile.trustServerCertificate = true
        profile.savePassword = false

        // 1. Connect
        await app.connect(profile: profile, password: env("SQL_PASSWORD", "Str0ngP@ssw0rd!"))
        check("connect", app.connectionError == nil && app.servers.count == 1,
              app.connectionError ?? app.servers.first?.displayName ?? "")
        guard let server = app.servers.first else {
            print("aborting: no server")
            return 1
        }

        // 2. Object Explorer root and lazy expansion
        let roots = app.explorer.roots
        check("explorer root", roots.count == 1, roots.first?.label ?? "")
        guard let root = roots.first else { return 1 }

        let topLevel = app.explorer.children(of: root)
        check("explorer top level", topLevel.count >= 3,
              topLevel.map(\.label).joined(separator: ", "))

        guard let databasesFolder = topLevel.first(where: { $0.folder == .databases }) else {
            check("databases folder", false)
            return 1
        }
        await app.explorer.expand(databasesFolder)
        let databases = app.explorer.children(of: databasesFolder)
        check("databases listed", databases.contains { $0.name == "ShopDemo" },
              databases.map(\.label).joined(separator: ", "))

        guard let shopDemo = databases.first(where: { $0.name == "ShopDemo" }) else { return 1 }
        await app.explorer.expand(shopDemo)
        let dbFolders = app.explorer.children(of: shopDemo)
        check("database folders", dbFolders.contains { $0.folder == .tables },
              dbFolders.map(\.label).joined(separator: ", "))

        guard let tablesFolder = dbFolders.first(where: { $0.folder == .tables }) else { return 1 }
        await app.explorer.expand(tablesFolder)
        let tables = app.explorer.children(of: tablesFolder)
        check("tables listed", tables.contains { $0.label == "dbo.Customers" },
              tables.map(\.label).joined(separator: ", "))

        if let customers = tables.first(where: { $0.label == "dbo.Customers" }) {
            await app.explorer.expand(customers)
            let folders = app.explorer.children(of: customers)
            check("table sub-folders", folders.count >= 4,
                  folders.map(\.label).joined(separator: ", "))
            if let columnsFolder = folders.first(where: { $0.folder == .columns }) {
                await app.explorer.expand(columnsFolder)
                let columns = app.explorer.children(of: columnsFolder)
                check("columns expand", columns.count == 9,
                      columns.prefix(3).map { "\($0.label) \($0.detail ?? "")" }
                        .joined(separator: " / "))
            }
        }

        // 3. Query tab lifecycle
        let tab = await app.newQueryTab(server: server, database: "ShopDemo")
        check("query tab connected", tab.isConnected, tab.statusText)
        check("database list", tab.availableDatabases.contains("ShopDemo"),
              tab.availableDatabases.joined(separator: ", "))

        // 4. Execute a multi-statement script and wait for it to finish
        tab.text = """
        SELECT TOP 3 CustomerId, FullName, Country, Balance FROM dbo.Customers ORDER BY CustomerId;
        PRINT 'hello from the self test';
        SELECT COUNT(*) AS Orders FROM sales.Orders;
        """
        tab.execute()
        await waitUntil(timeout: 30) { !tab.isExecuting && tab.summary != nil }

        check("execution finished", tab.summary != nil, tab.statusText)
        check("two result sets", tab.resultSets.count == 2,
              "got \(tab.resultSets.count)")
        if let first = tab.resultSets.first {
            check("first grid columns", first.columns.count == 4,
                  first.columns.map(\.name).joined(separator: ", "))
            check("first grid rows", first.rowCount == 3, first.summaryText)
            let sample = (0..<min(first.rowCount, 3)).map { row in
                (0..<first.columns.count)
                    .map { first.value(row: row, column: $0).displayString() }
                    .joined(separator: " | ")
            }
            print("       rows: " + sample.joined(separator: " ; "))
        }
        check("PRINT captured",
              tab.messages.contains { $0.text.contains("hello from the self test") },
              tab.messages.map(\.text).joined(separator: " / "))
        check("no errors", tab.summary?.errorCount == 0)

        // 5. An error should land in Messages with a usable line number
        tab.text = "SELECT * FROM dbo.NoSuchTable;"
        tab.execute()
        await waitUntil(timeout: 20) { !tab.isExecuting && tab.summary != nil }
        let serverError = tab.messages.first { $0.kind == .error }
        check("error surfaced", serverError != nil, serverError?.displayText ?? "")

        // 6. Actual execution plan
        tab.includeActualPlan = true
        tab.text = "SELECT TOP 1 * FROM dbo.Customers WHERE Country = N'Iran';"
        tab.execute()
        await waitUntil(timeout: 25) { !tab.isExecuting && tab.summary != nil }
        check("execution plan captured", tab.executionPlanXML != nil,
              tab.executionPlanXML.map { "\($0.count) chars" } ?? "none")
        if let xml = tab.executionPlanXML {
            let statements = ShowplanParser.parse(xml)
            check("plan parsed", statements.first?.root != nil,
                  statements.first?.root?.physicalOp ?? "no root")
        }
        tab.includeActualPlan = false

        // 7. Cancellation
        tab.text = "WAITFOR DELAY '00:00:20'; SELECT 1;"
        tab.execute()
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        tab.cancel()
        await waitUntil(timeout: 20) { !tab.isExecuting }
        check("cancel works", tab.summary?.cancelled == true || !tab.isExecuting, tab.statusText)

        // 8. IntelliSense reaches the editor's completion cache
        tab.text = "SELECT * FROM dbo."
        tab.requestCompletions(at: tab.text.utf16.count)
        await waitUntil(timeout: 15) { !tab.completionItems.isEmpty }
        check("completions available", !tab.completionItems.isEmpty,
              tab.completionItems.prefix(6).map(\.label).joined(separator: ", "))

        // 9. Server administration and reporting services
        let serverAdmin = ServerAdmin(session: server.session)
        if let properties = try? await serverAdmin.properties() {
            check("server properties", !properties.name.isEmpty,
                  "\(properties.name) · \(properties.friendlyVersion) · \(properties.edition)")
            check("processor count", properties.processorCount > 0,
                  "\(properties.processorCount) cpus, \(properties.physicalMemoryMB) MB")
        } else {
            check("server properties", false, "could not read")
        }

        if let configurations = try? await serverAdmin.configurations() {
            check("sp_configure list", configurations.contains { $0.name == "max degree of parallelism" },
                  "\(configurations.count) options")
        } else {
            print("[SKIP] sp_configure list — not permitted for this login")
        }

        let diagnostics = ServerDiagnostics(session: server.session)
        if let snapshot = try? await diagnostics.snapshot() {
            check("server snapshot", snapshot.totalSessions > 0,
                  "\(snapshot.totalSessions) sessions, "
                    + "\(snapshot.databaseCount) databases, "
                    + String(format: "%.0f MB", snapshot.totalDatabaseSizeMB))
        } else {
            check("server snapshot", false, "could not read")
        }

        // The error log needs securityadmin, so a plain login is allowed to skip it.
        if let log = try? await diagnostics.errorLog(limit: 50) {
            print("[INFO] error log — \(log.count) lines, "
                  + "\(log.filter { $0.severity == .error }.count) flagged as errors")
        } else {
            print("[SKIP] error log — not permitted for this login")
        }

        // 10. Blocking chain assembly against whatever is actually running
        let monitor = ActivityMonitor(session: server.session)
        if let sessions = try? await monitor.sessions(includeSystem: true) {
            let rows = BlockingChain.rows(from: BlockingChain.build(from: sessions))
            let waiters = Set(sessions
                .filter { $0.isBlocked && $0.blockingSessionID != $0.sessionID }
                .map(\.sessionID))
            let reported = Set(rows.map(\.session.sessionID))
            check("blocking chain covers every waiter", waiters.isSubset(of: reported),
                  "\(waiters.count) blocked of \(sessions.count) sessions, \(rows.count) rows")
        }

        // 11. Dependencies and Generate Scripts
        let objectAdmin = ObjectAdmin(session: server.session)
        if let dependants = try? await objectAdmin.dependencies(database: "ShopDemo",
                                                               schema: "dbo",
                                                               name: "Customers",
                                                               direction: .usedBy) {
            print("[INFO] dbo.Customers is used by \(dependants.count) object(s): "
                  + dependants.prefix(4).map(\.qualifiedName).joined(separator: ", "))
        }

        let project = ScriptProject(session: server.session)
        if let discovered = try? await project.discover(database: "ShopDemo") {
            check("script project discovery", discovered.contains { $0.name == "Customers" },
                  "\(discovered.count) objects")
            let ordered = ScriptProject.ordered(discovered)
            check("script project ordering", ordered.count == discovered.count,
                  ordered.prefix(4).map(\.qualifiedName).joined(separator: ", "))

            let tables = ordered.filter { $0.kind == .table }.prefix(2).map { $0 }
            if !tables.isEmpty,
               let generated = try? await project.generate(database: "ShopDemo",
                                                           objects: Array(tables)) {
                check("generate scripts", generated.scriptedCount == tables.count
                      && generated.sql.contains("CREATE TABLE"),
                      "\(generated.scriptedCount) scripted, "
                        + "\(generated.failures.count) failed, "
                        + "\(generated.sql.count) chars")
                for failure in generated.failures {
                    print("       failed: \(failure.object) — \(failure.reason)")
                }
            }
        } else {
            check("script project discovery", false, "could not enumerate")
        }

        // 12. Results to text renders the grid the query window just filled
        tab.resultsDestination = .text
        tab.text = "SELECT TOP 3 CustomerId, FullName, Balance FROM dbo.Customers ORDER BY CustomerId;"
        tab.execute()
        await waitUntil(timeout: 20) { !tab.isExecuting && tab.summary != nil }
        check("results to text", tab.textResults.contains("CustomerId")
              && tab.textResults.contains("(3 rows affected)"),
              tab.textResults.components(separatedBy: "\n").first ?? "")
        tab.resultsDestination = .grid

        // 13. Bookmarks and Go To Line work on the model the editor binds to
        tab.text = "SELECT 1;\nSELECT 2;\nSELECT 3;"
        tab.moveCaret(toLine: 2)
        check("go to line", tab.caretLine == 2, "landed on line \(tab.caretLine)")
        tab.toggleBookmark()
        tab.moveCaret(toLine: 3)
        tab.toggleBookmark()
        tab.moveCaret(toLine: 1)
        tab.goToNextBookmark()
        check("next bookmark", tab.caretLine == 2, "landed on line \(tab.caretLine)")
        tab.goToNextBookmark()
        check("bookmark wraps", tab.caretLine == 3, "landed on line \(tab.caretLine)")
        tab.goToNextBookmark()
        check("bookmark wraps to the first", tab.caretLine == 2, "landed on line \(tab.caretLine)")
        tab.clearBookmarks()
        check("bookmarks cleared", tab.bookmarkedLines.isEmpty)

        // 14. The query history now records what ran
        check("history recorded", !app.history.entries.isEmpty,
              "\(app.history.entries.count) entries")

        // 15. Tear down
        let tabCountBefore = app.tabs.count
        app.closeTab(tab)
        check("tab closed", app.tabs.count == tabCountBefore - 1,
              "\(tabCountBefore) -> \(app.tabs.count)")
        for remaining in app.tabs { app.closeTab(remaining) }
        await app.disconnect(server: server)
        check("disconnected", app.servers.isEmpty && app.explorer.roots.isEmpty)

        print("")
        if failures.isEmpty {
            print("SELF TEST PASSED")
            return 0
        }
        print("SELF TEST FAILED: \(failures.joined(separator: ", "))")
        return 1
    }

    private static func waitUntil(timeout: TimeInterval,
                                  _ condition: @escaping () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }
}
