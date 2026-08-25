import Foundation
import NIOCore
import NIOPosix
import TDSKit
import SQLServerKit

// Smoke-test harness for TDSKit and SQLServerKit against a real SQL Server.

func env(_ key: String, _ fallback: String) -> String {
    ProcessInfo.processInfo.environment[key] ?? fallback
}

let host = env("SQL_HOST", "127.0.0.1")
let port = Int(env("SQL_PORT", "11433")) ?? 11433
let user = env("SQL_USER", "sa")
let password = env("SQL_PASSWORD", "Str0ngP@ssw0rd!")
let database = env("SQL_DB", "ShopDemo")

func makeProfile() -> ConnectionProfile {
    var profile = ConnectionProfile()
    profile.name = "smoke"
    profile.server = "\(host),\(port)"
    profile.username = user
    profile.database = database
    profile.trustServerCertificate = true
    if env("SQL_ENCRYPT", "required") == "disabled" { profile.encryption = .disabled }
    if let size = Int(env("SQL_PACKET", "")) { profile.packetSize = size }
    return profile
}

func printResult(_ result: TDSQueryResult, limit: Int = 10) {
    for (index, set) in result.resultSets.enumerated() {
        print("  result \(index + 1): \(set.rows.count) rows")
        print("    " + set.columns.map { "\($0.name)[\($0.sqlTypeName)]" }.joined(separator: " | "))
        for row in set.rows.prefix(limit) {
            print("    " + row.map { $0.displayString() }.joined(separator: " | "))
        }
    }
    for message in result.messages { print("  info: \(message.text)") }
    for error in result.errors { print("  ERROR: \(error.formatted)") }
}

@main
struct Runner {
    static func main() async {
        let command = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "all"
        let argument = CommandLine.arguments.count > 2
            ? CommandLine.arguments.dropFirst(2).joined(separator: " ")
            : ""

        do {
            let session = try await SQLServerSession.connect(profile: makeProfile(), password: password)
            let info = await session.serverInfo
            print("connected: \(info.serverName) · \(info.friendlyVersion) · db=\(info.currentDatabase)")

            switch command {
            case "query":
                let connection = try await session.openConnection(database: database)
                printResult(try await connection.query(argument), limit: 30)
                try await connection.close()

            case "tree":
                try await runTree(session: session)

            case "script":
                try await runScript(session: session, target: argument)

            case "activity":
                try await runActivity(session: session)

            case "export":
                try await runExport(session: session)

            case "intellisense":
                try await runIntelliSense(session: session, prefixOffsetScript: argument)

            case "edit":
                try await runDataEditor(session: session)

            case "admin":
                try await runAdmin(session: session)

            case "format":
                let formatter = SQLFormatter(style: SQLFormatter.Style())
                print(formatter.format(argument.isEmpty ? sampleScript : argument))

            default:
                try await runTree(session: session)
                try await runScript(session: session, target: "dbo.Customers")
                try await runActivity(session: session)
                try await runExport(session: session)
                try await runIntelliSense(session: session, prefixOffsetScript: "")
                try await runAdmin(session: session)
            }

            await session.close()
            print("\nOK")
            exit(0)
        } catch {
            print("FAILED: \(error)")
            exit(1)
        }
    }

    static let sampleScript = """
    select c.customerid,c.fullname,o.total from dbo.customers c inner join sales.orders o
    on o.customerid=c.customerid where c.isactive=1 and o.total>100 order by o.total desc
    """

    // MARK: - Object Explorer

    static func runTree(session: SQLServerSession) async throws {
        print("\n=== Object Explorer ===")
        let service = MetadataService(session: session)
        let root = await service.rootNode()
        var options = ObjectExplorerOptions()
        options.showSystemObjects = false

        func walk(_ node: ObjectExplorerNode, depth: Int, budget: inout Int) async {
            guard budget > 0 else { return }
            let indent = String(repeating: "  ", count: depth)
            let detail = node.detail.map { " \($0)" } ?? ""
            print("\(indent)\(node.label)\(detail)")
            budget -= 1
            guard node.isExpandable, depth < 4 else { return }
            do {
                let children = try await service.children(of: node, options: options)
                for child in children.prefix(depth >= 3 ? 4 : 12) {
                    // Only descend into the demo database to keep the output readable.
                    if depth == 1, child.kind == .database, child.name != "ShopDemo" { continue }
                    await walk(child, depth: depth + 1, budget: &budget)
                }
            } catch {
                print("\(indent)  !! \(error)")
            }
        }

        var budget = 120
        await walk(root, depth: 0, budget: &budget)

        let names = try await service.databaseNames(includeSystem: true)
        print("databases: \(names.joined(separator: ", "))")

        let columns = try await service.columns(database: "ShopDemo", schema: "dbo", table: "Customers")
        print("columns of dbo.Customers:")
        for column in columns {
            print("  \(column.name) \(column.typeName)"
                  + (column.isPrimaryKey ? " PK" : "")
                  + (column.isIdentity ? " IDENTITY" : "")
                  + (column.isNullable ? " NULL" : " NOT NULL")
                  + (column.defaultDefinition.isEmpty ? "" : " DEFAULT \(column.defaultDefinition)"))
        }

        let hits = try await service.search(text: "order", database: "ShopDemo", limit: 10)
        print("search 'order': " + hits.map(\.displayPath).joined(separator: ", "))
    }

    // MARK: - Scripting

    static func runScript(session: SQLServerSession, target: String) async throws {
        print("\n=== Scripting ===")
        let parts = (target.isEmpty ? "dbo.Customers" : target).split(separator: ".")
        let schema = parts.count > 1 ? String(parts[0]) : "dbo"
        let name = String(parts.last ?? "Customers")

        let generator = ScriptGenerator(session: session)
        var options = ScriptOptions()
        options.includeDescriptiveHeader = true

        let node = ObjectExplorerNode(id: "x", kind: .table, label: name, iconName: "tablecells",
                                      isExpandable: true, database: "ShopDemo",
                                      schema: schema, name: name)
        print("--- CREATE TABLE ---")
        print(try await generator.script(node: node, action: .create, options: options))
        print("--- SELECT ---")
        print(try await generator.selectTopRows(database: "ShopDemo", schema: schema,
                                                table: name, top: 1000))
        print("--- INSERT ---")
        print(try await generator.script(node: node, action: .insert, options: options))

        let procNode = ObjectExplorerNode(id: "p", kind: .storedProcedure,
                                          label: "usp_GetCustomerOrders", iconName: "function",
                                          isExpandable: true, database: "ShopDemo",
                                          schema: "sales", name: "usp_GetCustomerOrders")
        print("--- ALTER PROCEDURE ---")
        print(try await generator.script(node: procNode, action: .alter, options: options))
        print("--- EXECUTE ---")
        print(try await generator.script(node: procNode, action: .execute, options: options))
    }

    // MARK: - Admin

    static func runActivity(session: SQLServerSession) async throws {
        print("\n=== Activity Monitor ===")
        let monitor = ActivityMonitor(session: session)
        let sessions = try await monitor.sessions(includeSystem: false)
        print("user sessions: \(sessions.count)")
        for item in sessions.prefix(5) {
            print("  spid \(item.sessionID) \(item.loginName)@\(item.hostName) "
                  + "[\(item.databaseName)] \(item.status) cpu=\(item.cpuTimeMs)ms")
        }
        let waits = try await monitor.waits(top: 5)
        print("top waits: " + waits.map { "\($0.waitType)=\($0.waitTimeMs)ms" }.joined(separator: ", "))
        let expensive = try await monitor.expensiveQueries(top: 3)
        print("expensive queries: \(expensive.count)")
        let io = try await monitor.fileIO()
        print("file io rows: \(io.count)")
    }

    static func runAdmin(session: SQLServerSession) async throws {
        print("\n=== Database admin ===")
        let admin = DatabaseAdmin(session: session)
        let properties = try await admin.properties(database: "ShopDemo")
        print("db: \(properties.name) owner=\(properties.owner) collation=\(properties.collation)")
        print("  compat=\(properties.compatibilityLevel) recovery=\(properties.recoveryModel) "
              + "size=\(String(format: "%.1f", properties.sizeMB))MB")
        for file in properties.files {
            print("  file \(file.name) [\(file.type)] \(String(format: "%.0f", file.sizeMB))MB "
                  + "growth=\(file.growth)")
        }
        let table = try await admin.tableProperties(database: "ShopDemo", schema: "dbo",
                                                    table: "Customers")
        print("table dbo.Customers rows=\(table.rowCount) columns=\(table.columnCount) "
              + "indexes=\(table.indexCount) total=\(table.totalSpaceKB)KB")
        let fragmentation = try await admin.indexFragmentation(database: "ShopDemo")
        print("index fragmentation rows: \(fragmentation.count)")

        let request = BackupRequest(database: "ShopDemo", kind: .full,
                                    path: "/var/opt/mssql/data/ShopDemo.bak")
        print("--- backup script ---")
        print(try await admin.backupScript(request))
    }

    // MARK: - Export and import

    static func runExport(session: SQLServerSession) async throws {
        print("\n=== Export ===")
        let connection = try await session.openConnection(database: "ShopDemo")
        defer { Task { try? await connection.close() } }
        let result = try await connection.query(
            "SELECT CustomerId, FullName, Email, Country, Balance, CreatedAt, IsActive "
            + "FROM dbo.Customers ORDER BY CustomerId")
        guard let set = result.resultSets.first else { return }

        let exporter = ResultExporter()
        var options = ExportOptions()
        options.includeHeaders = true

        for format in [ExportFormat.csv, .json, .markdown, .sqlInsert] {
            var formatOptions = options
            formatOptions.tableName = "dbo.Customers"
            let text = try exporter.string(columns: set.columns, rows: set.rows,
                                           format: format, options: formatOptions)
            print("--- \(format.displayName) ---")
            print(text.split(separator: "\n").prefix(6).joined(separator: "\n"))
        }

        let directory = FileManager.default.temporaryDirectory
        let xlsx = directory.appendingPathComponent("customers.xlsx")
        try exporter.export(columns: set.columns, rows: set.rows, format: .xlsx,
                            to: xlsx, options: options)
        let size = (try? FileManager.default.attributesOfItem(atPath: xlsx.path)[.size]) as? Int ?? 0
        print("xlsx written: \(xlsx.path) (\(size) bytes)")

        // Round-trip a CSV back into a new table.
        let csv = directory.appendingPathComponent("customers.csv")
        try exporter.export(columns: set.columns, rows: set.rows, format: .csv,
                            to: csv, options: options)
        let importer = FlatFileImporter(session: session)
        let preview = try importer.preview(url: csv, sampleRows: 20)
        print("import preview: delimiter=\(preview.detectedDelimiter == "," ? "comma" : preview.detectedDelimiter) "
              + "header=\(preview.hasHeaderRow) columns=\(preview.columns.count) "
              + "encoding=\(preview.encodingName)")
        for column in preview.columns {
            print("  \(column.sourceName) -> \(column.targetName) \(column.sqlType)")
        }
        _ = try await connection.query("DROP TABLE IF EXISTS dbo.CustomersImported;")
        let count = try await importer.importFile(url: csv, database: "ShopDemo", schema: "dbo",
                                                  table: "CustomersImported", preview: preview,
                                                  createTable: true, truncateFirst: false,
                                                  batchSize: 100) { _, _ in }
        print("imported rows: \(count)")
        printResult(try await connection.query(
            "SELECT TOP 3 * FROM dbo.CustomersImported ORDER BY CustomerId"))
    }

    // MARK: - IntelliSense and editing

    static func runIntelliSense(session: SQLServerSession, prefixOffsetScript: String) async throws {
        print("\n=== IntelliSense ===")
        let provider = IntelliSenseProvider(session: session)
        let catalog = try await provider.refresh(database: "ShopDemo")
        print("catalog: \(catalog.tables.count) tables/views, \(catalog.routines.count) routines, "
              + "schemas: \(catalog.schemas.joined(separator: ", "))")

        let script = "SELECT c. FROM dbo.Customers AS c JOIN sales.Orders o ON o.CustomerId = c."
        let dotAfterAlias = script.utf16.count
        let items = await provider.completions(script: script, offset: dotAfterAlias,
                                               database: "ShopDemo")
        print("completions after 'c.': " + items.prefix(8).map(\.label).joined(separator: ", "))

        let fromScript = "SELECT * FROM "
        let afterFrom = await provider.completions(script: fromScript,
                                                   offset: fromScript.utf16.count,
                                                   database: "ShopDemo")
        print("completions after FROM: "
              + afterFrom.prefix(8).map { "\($0.label)(\($0.kind.rawValue))" }.joined(separator: ", "))

        let execScript = "EXEC sales."
        let afterExec = await provider.completions(script: execScript,
                                                   offset: execScript.utf16.count,
                                                   database: "ShopDemo")
        print("completions after 'EXEC sales.': " + afterExec.prefix(5).map(\.label).joined(separator: ", "))

        if let help = await provider.signatureHelp(script: "SELECT dbo.fn_FullLabel(",
                                                   offset: 24, database: "ShopDemo") {
            print("signature: \(help)")
        }

        print("--- formatter ---")
        print(SQLFormatter(style: SQLFormatter.Style()).format(sampleScript))
    }

    static func runDataEditor(session: SQLServerSession) async throws {
        print("\n=== Data editor ===")
        let editor = TableDataEditor(session: session, database: "ShopDemo",
                                     schema: "dbo", table: "Customers")
        let loaded = try await editor.load(top: 5, whereClause: nil, orderBy: "CustomerId")
        print("loaded \(loaded.rows.count) rows, keys: \(loaded.keyColumns.joined(separator: ", "))")

        guard let first = loaded.rows.first else { return }
        var original: [String: TDSValue] = [:]
        for column in loaded.columns { original[column.name] = first[column.index] }

        let change = TableDataEditor.RowChange(
            kind: .update, rowIndex: 0, originalValues: original,
            newValues: ["Country": .string("Iran (edited)")])
        print("--- generated script ---")
        print(try editor.script(for: [change]))
        _ = try await editor.apply([change])
        let after = try await editor.load(top: 1, whereClause: nil, orderBy: "CustomerId")
        print("after apply: " + (after.rows.first?.map { $0.displayString() }
            .joined(separator: " | ") ?? ""))
    }
}
