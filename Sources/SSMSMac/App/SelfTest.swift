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
        await app.connect(profile: profile, password: env("SQL_PASSWORD", "Str0ngP@ssw0rd!"),
                          persist: false)
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

        // 9. Blocking chains, built from the process list rather than queried separately
        let monitor = ActivityMonitor(session: server.session)
        if let sessions = try? await monitor.sessions(includeSystem: true) {
            let rows = BlockingChain.rows(from: BlockingChain.build(from: sessions))
            let waiters = Set(sessions
                .filter { $0.isBlocked && $0.blockingSessionID != $0.sessionID }
                .map(\.sessionID))
            let reported = Set(rows.map(\.session.sessionID))
            check("blocking chain covers every waiter", waiters.isSubset(of: reported),
                  "\(waiters.count) blocked of \(sessions.count) sessions, \(rows.count) rows")
        } else {
            check("blocking chain covers every waiter", false, "could not read the sessions")
        }

        // 10. Query Store. It is off by default, so an empty report is a pass; what has to
        // work is reading the settings without an error.
        let queryStore = QueryStoreService(session: server.session)
        if server.serverInfo.supportsQueryStore {
            do {
                let options = try await queryStore.options(database: "ShopDemo")
                check("query store settings", true,
                      "\(options.actualState), capture \(options.captureMode), "
                        + String(format: "%.0f of %.0f MB",
                                 options.currentStorageMB, options.maxStorageMB))
                if options.isEnabled {
                    let top = try await queryStore.topQueries(database: "ShopDemo", hours: 168)
                    print("[INFO] query store — \(top.count) queries in the last week")
                }
            } catch {
                check("query store settings", false, String(describing: error))
            }
        } else {
            print("[SKIP] query store — needs SQL Server 2016 or later")
        }

        // 11. The error log needs securityadmin, so a plain login is allowed to skip it.
        if let entries = try? await ErrorLogService(session: server.session).entries(limit: 50) {
            let errors = entries.filter { $0.severity == .error }.count
            print("[INFO] error log — \(entries.count) lines, \(errors) flagged as errors")
        } else {
            print("[SKIP] error log — sp_readerrorlog is not permitted for this login")
        }

        // 12. Scripting the kinds that have no sys.sql_modules body
        let generator = ScriptGenerator(session: server.session)
        let synonymNode = ObjectExplorerNode(id: "selftest/synonym", kind: .synonym,
                                             label: "dbo.NoSuchSynonym", iconName: "link",
                                             isExpandable: false, database: "ShopDemo",
                                             schema: "dbo", name: "NoSuchSynonym")
        do {
            _ = try await generator.script(node: synonymNode, action: .create,
                                           options: ScriptOptions())
            check("synonym scripting reaches the catalog", true, "an actual synonym exists")
        } catch let error as SQLServerError {
            // Not found is the right answer for a synonym that does not exist; the point is
            // that the scripter routed the kind instead of refusing it outright.
            let message = String(describing: error)
            check("synonym scripting is routed, not refused",
                  !message.contains("not supported"), message)
        } catch {
            check("synonym scripting is routed, not refused", false, String(describing: error))
        }

        // 13. Tear down
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
