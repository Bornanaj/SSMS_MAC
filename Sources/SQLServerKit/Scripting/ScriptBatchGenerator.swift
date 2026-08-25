import Foundation
import TDSKit

// MARK: - Object list entry

/// One selectable row in the Generate Scripts wizard.
public struct ScriptableObject: Sendable, Hashable, Identifiable {
    public var id: String
    public var schema: String
    public var name: String
    public var kind: ObjectNodeKind
    public var isSelected: Bool

    public init(schema: String, name: String, kind: ObjectNodeKind, isSelected: Bool = false) {
        self.id = "\(schema).\(name):\(kind.rawValue)"
        self.schema = schema
        self.name = name
        self.kind = kind
        self.isSelected = isSelected
    }

    /// `schema.name` without brackets, for progress text and list rows.
    public var qualifiedName: String {
        schema.isEmpty ? name : "\(schema).\(name)"
    }

    public var kindTitle: String { ScriptableObject.title(for: kind) }

    public static func title(for kind: ObjectNodeKind) -> String {
        switch kind {
        case .schema: return "Schema"
        case .table: return "Table"
        case .externalTable: return "External table"
        case .view: return "View"
        case .storedProcedure: return "Stored procedure"
        case .scalarFunction: return "Scalar-valued function"
        case .tableValuedFunction: return "Table-valued function"
        case .aggregateFunction: return "Aggregate function"
        case .synonym: return "Synonym"
        case .sequence: return "Sequence"
        default: return "Object"
        }
    }

    public static func pluralTitle(for kind: ObjectNodeKind) -> String {
        switch kind {
        case .schema: return "Schemas"
        case .table: return "Tables"
        case .externalTable: return "External tables"
        case .view: return "Views"
        case .storedProcedure: return "Stored procedures"
        case .scalarFunction: return "Scalar-valued functions"
        case .tableValuedFunction: return "Table-valued functions"
        case .aggregateFunction: return "Aggregate functions"
        case .synonym: return "Synonyms"
        case .sequence: return "Sequences"
        default: return "Objects"
        }
    }

    /// SF Symbol used by the picker list.
    public static func iconName(for kind: ObjectNodeKind) -> String {
        switch kind {
        case .schema: return "folder"
        case .table, .externalTable: return "tablecells"
        case .view: return "rectangle.on.rectangle"
        case .storedProcedure: return "gearshape"
        case .scalarFunction, .tableValuedFunction, .aggregateFunction: return "function"
        case .sequence: return "number"
        case .synonym: return "arrow.triangle.branch"
        default: return "doc"
        }
    }
}

// MARK: - Batch generator

/// Scripts a whole set of objects in one pass, in an order that can be executed
/// top to bottom: schemas, tables, then the keys/indexes/triggers that hang off the
/// tables, then views in dependency order, then functions and stored procedures.
///
/// Per-object DDL is produced by `ScriptGenerator`; this type only decides the order
/// and stitches the batches together.
public struct ScriptBatchGenerator: Sendable {

    private let session: SQLServerSession

    public init(session: SQLServerSession) {
        self.session = session
    }

    // MARK: - Discovery

    public func objects(in database: String) async throws -> [ScriptableObject] {
        var result: [ScriptableObject] = []
        result.append(contentsOf: try await loadSchemas(database: database))
        result.append(contentsOf: try await loadObjects(database: database))
        return result
    }

    // MARK: - Scripting

    /// - Parameter progress: called with a 0...1 fraction and the object being scripted.
    public func script(database: String, objects: [ScriptableObject],
                       options: ScriptOptions,
                       progress: @escaping @Sendable (Double, String) -> Void)
        async throws -> String {

        let selected: [ScriptableObject] = objects.filter(\.isSelected)
        guard !selected.isEmpty else {
            return "/* No objects were selected. */\n"
        }

        let schemas: [ScriptableObject] = byName(selected.filter { $0.kind == .schema })
        let tables: [ScriptableObject] = byName(selected.filter {
            $0.kind == .table || $0.kind == .externalTable
        })
        let views: [ScriptableObject] = selected.filter { $0.kind == .view }
        let functions: [ScriptableObject] = selected.filter {
            $0.kind == .scalarFunction || $0.kind == .tableValuedFunction
                || $0.kind == .aggregateFunction
        }
        let procedures: [ScriptableObject] = byName(selected.filter { $0.kind == .storedProcedure })

        // Views and inline functions are bound at CREATE time, so they have to follow
        // whatever they reference. Procedures use deferred name resolution and can go last.
        let needsGraph: Bool = !views.isEmpty || !functions.isEmpty
        let graph: [String: Set<String>] = needsGraph
            ? try await moduleDependencies(database: database)
            : [:]
        let orderedViews: [ScriptableObject] = ordered(views, dependencies: graph)
        let orderedFunctions: [ScriptableObject] = ordered(functions, dependencies: graph)

        let total: Int = selected.count
        var done: Int = 0
        progress(0, selected.first?.qualifiedName ?? "")

        let generator = ScriptGenerator(session: session)
        let owners: [String: String] = schemas.isEmpty
            ? [:]
            : try await schemaOwners(database: database)

        var out: String = ""
        if options.includeDescriptiveHeader {
            out += generationBanner(database: database, count: total)
        }

        let info: ServerInfo = await session.serverInfo
        if !info.isAzureSQLDatabase {
            out += "USE \(SQLIdentifier.quote(database))\nGO\n\n"
        }

        // MARK: schemas

        if !schemas.isEmpty {
            out += banner("Schemas", options: options)
            for object in schemas {
                out += schemaScript(object, owner: owners[object.name] ?? "dbo", options: options)
                done += 1
                progress(Double(done) / Double(total), object.qualifiedName)
            }
            out += "\n"
        }

        // MARK: tables, split into the CREATE TABLE batch and everything after it

        var tails: [(object: ScriptableObject, text: String)] = []
        if !tables.isEmpty {
            out += banner("Tables", options: options)
            for object in tables {
                do {
                    let node: ObjectExplorerNode = explorerNode(for: object, database: database)
                    let text: String = try await generator.script(node: node, action: .create,
                                                                  options: options)
                    let parts: (core: String, tail: String) = splitTableScript(text)
                    out += parts.core + "\n"
                    if !parts.tail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        tails.append((object, parts.tail))
                    }
                } catch {
                    out += failureComment(object, error: error)
                }
                done += 1
                progress(Double(done) / Double(total), object.qualifiedName)
            }
        }

        if !tails.isEmpty {
            out += banner("Keys, indexes, constraints and triggers", options: options)
            for entry in tails {
                if options.includeDescriptiveHeader {
                    let target: String = SQLIdentifier.quote(schema: entry.object.schema,
                                                             name: entry.object.name)
                    out += "/****** \(target) ******/\n"
                }
                out += entry.text + "\n"
            }
        }

        // MARK: views, then functions, then procedures

        out += await moduleSection("Views", objects: orderedViews, database: database,
                                   options: options, generator: generator,
                                   completed: done, total: total, progress: progress)
        done += orderedViews.count

        out += await moduleSection("Functions", objects: orderedFunctions, database: database,
                                   options: options, generator: generator,
                                   completed: done, total: total, progress: progress)
        done += orderedFunctions.count

        out += await moduleSection("Stored procedures", objects: procedures, database: database,
                                   options: options, generator: generator,
                                   completed: done, total: total, progress: progress)
        done += procedures.count

        progress(1, "")
        return out
    }

    /// - Parameter completed: how many objects were already scripted before this section,
    ///   so the shared progress fraction keeps climbing across sections.
    private func moduleSection(_ title: String, objects: [ScriptableObject], database: String,
                               options: ScriptOptions, generator: ScriptGenerator,
                               completed: Int, total: Int,
                               progress: @escaping @Sendable (Double, String) -> Void)
        async -> String {

        guard !objects.isEmpty else { return "" }
        var out: String = banner(title, options: options)
        for (offset, object) in objects.enumerated() {
            do {
                let node: ObjectExplorerNode = explorerNode(for: object, database: database)
                let text: String = try await generator.script(node: node, action: .create,
                                                              options: options)
                out += text
                if !text.hasSuffix("\n") { out += "\n" }
                out += "\n"
            } catch {
                out += failureComment(object, error: error)
            }
            let fraction: Double = Double(completed + offset + 1) / Double(max(total, 1))
            progress(fraction, object.qualifiedName)
        }
        return out
    }

    // MARK: - Ordering

    private func byName(_ items: [ScriptableObject]) -> [ScriptableObject] {
        items.sorted { lhs, rhs in
            lhs.qualifiedName.localizedCaseInsensitiveCompare(rhs.qualifiedName) == .orderedAscending
        }
    }

    /// Depth-first topological sort. Objects outside `items` are ignored, and a cycle
    /// leaves the objects involved in plain name order rather than looping forever.
    private func ordered(_ items: [ScriptableObject],
                         dependencies: [String: Set<String>]) -> [ScriptableObject] {
        let sorted: [ScriptableObject] = byName(items)
        var index: [String: ScriptableObject] = [:]
        for item in sorted { index[item.qualifiedName.lowercased()] = item }

        var result: [ScriptableObject] = []
        var visited: Set<String> = []

        func visit(_ key: String) {
            guard let object = index[key], !visited.contains(key) else { return }
            visited.insert(key)
            let referenced: [String] = dependencies[key].map { Array($0).sorted() } ?? []
            for other in referenced where !visited.contains(other) {
                visit(other)
            }
            result.append(object)
        }

        for item in sorted { visit(item.qualifiedName.lowercased()) }
        return result
    }

    // MARK: - Emitters

    private func schemaScript(_ object: ScriptableObject, owner: String,
                              options: ScriptOptions) -> String {
        let target: String = SQLIdentifier.quote(object.name)
        var out: String = ""
        if options.includeDescriptiveHeader {
            out += "/****** Object:  Schema \(target)    Script Date: \(timestamp()) ******/\n"
        }
        if options.includeDropIfExists {
            out += "DROP SCHEMA IF EXISTS \(target)\nGO\n"
        }
        let create: String = "CREATE SCHEMA \(target) AUTHORIZATION \(SQLIdentifier.quote(owner))"
        if options.includeIfNotExists {
            // CREATE SCHEMA has to be the first statement in its batch, so the
            // existence guard can only be expressed through dynamic SQL.
            let inner: String = create.replacingOccurrences(of: "'", with: "''")
            out += "IF NOT EXISTS (SELECT * FROM sys.schemas WHERE name = "
                + "\(SQLIdentifier.literal(object.name)))\n"
                + "\tEXEC sys.sp_executesql N'\(inner)'\nGO\n"
        } else {
            out += create + "\nGO\n"
        }
        return out
    }

    private func failureComment(_ object: ScriptableObject, error: Error) -> String {
        let target: String = SQLIdentifier.quote(schema: object.schema, name: object.name)
        let reason: String = String(describing: error)
            .replacingOccurrences(of: "*/", with: "* /")
        return "/* Could not script \(object.kindTitle.lowercased()) \(target): \(reason) */\n\n"
    }

    private func banner(_ title: String, options: ScriptOptions) -> String {
        guard options.includeDescriptiveHeader else { return "" }
        return "/****** \(title) ******/\n"
    }

    private func generationBanner(database: String, count: Int) -> String {
        var text: String = "/*\n"
        text += "    Generated script for \(SQLIdentifier.quote(database))\n"
        text += "    Objects: \(count)\n"
        text += "    Script date: \(timestamp())\n"
        text += "*/\n"
        return text
    }

    private func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: Date())
    }

    private func explorerNode(for object: ScriptableObject, database: String) -> ObjectExplorerNode {
        ObjectExplorerNode(id: "scriptbatch/\(database)/\(object.id)",
                           kind: object.kind,
                           label: object.name,
                           iconName: ScriptableObject.iconName(for: object.kind),
                           isExpandable: false,
                           database: database,
                           schema: object.schema,
                           name: object.name)
    }

    /// `ScriptGenerator` emits `CREATE TABLE … GO` first and then every ALTER/CREATE INDEX
    /// that belongs to the table. Splitting there lets all tables be created before any
    /// foreign key points at them.
    private func splitTableScript(_ text: String) -> (core: String, tail: String) {
        let lines: [Substring] = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard let createIndex = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("CREATE TABLE")
        }) else {
            return (text, "")
        }
        var terminator: Int? = nil
        var cursor: Int = createIndex
        while cursor < lines.count {
            if lines[cursor].trimmingCharacters(in: .whitespaces).uppercased() == "GO" {
                terminator = cursor
                break
            }
            cursor += 1
        }
        guard let end = terminator else { return (text, "") }

        let core: String = lines[0...end].joined(separator: "\n") + "\n"
        var tail: String = lines[(end + 1)...].joined(separator: "\n")
        while tail.hasPrefix("\n") { tail.removeFirst() }
        if !tail.isEmpty, !tail.hasSuffix("\n") { tail += "\n" }
        return (core, tail)
    }

    // MARK: - Catalog access

    private func loadSchemas(database: String) async throws -> [ScriptableObject] {
        // schema_id 1..4 are dbo/guest/INFORMATION_SCHEMA/sys; 16384+ are the
        // fixed database role schemas. Neither is ever scripted.
        let sql: String = """
        SELECT s.name AS schema_name
        FROM sys.schemas AS s
        WHERE s.schema_id > 4 AND s.schema_id < 16384
        ORDER BY s.name
        """
        let result: TDSQueryResult = try await session.metadataQuery(sql, database: database)
        let rows: [[String: TDSValue]] = result.resultSets.first?.dictionaries() ?? []
        return rows.compactMap { row in
            let name: String = row.string("schema_name")
            guard !name.isEmpty else { return nil }
            return ScriptableObject(schema: "", name: name, kind: .schema)
        }
    }

    private func loadObjects(database: String) async throws -> [ScriptableObject] {
        let sql: String = """
        SELECT s.name AS schema_name, o.name AS object_name, RTRIM(o.type) AS object_type
        FROM sys.objects AS o
        JOIN sys.schemas AS s ON s.schema_id = o.schema_id
        WHERE o.is_ms_shipped = 0
          AND o.parent_object_id = 0
          AND o.type IN ('U', 'V', 'P', 'FN', 'IF', 'TF')
          AND s.name NOT IN (N'sys', N'INFORMATION_SCHEMA')
        ORDER BY o.type, s.name, o.name
        """
        let result: TDSQueryResult = try await session.metadataQuery(sql, database: database)
        let rows: [[String: TDSValue]] = result.resultSets.first?.dictionaries() ?? []
        return rows.compactMap { row in
            let name: String = row.string("object_name")
            guard !name.isEmpty else { return nil }
            guard let kind = ScriptBatchGenerator.kind(forObjectType: row.string("object_type"))
            else { return nil }
            return ScriptableObject(schema: row.string("schema_name"), name: name, kind: kind)
        }
    }

    private func schemaOwners(database: String) async throws -> [String: String] {
        let sql: String = """
        SELECT s.name AS schema_name, ISNULL(p.name, N'dbo') AS owner_name
        FROM sys.schemas AS s
        LEFT JOIN sys.database_principals AS p ON p.principal_id = s.principal_id
        WHERE s.schema_id > 4 AND s.schema_id < 16384
        """
        let result: TDSQueryResult = try await session.metadataQuery(sql, database: database)
        let rows: [[String: TDSValue]] = result.resultSets.first?.dictionaries() ?? []
        var owners: [String: String] = [:]
        for row in rows {
            owners[row.string("schema_name")] = row.string("owner_name", default: "dbo")
        }
        return owners
    }

    /// referencing `schema.name` (lowercased) -> everything it references in this database.
    private func moduleDependencies(database: String) async throws -> [String: Set<String>] {
        let sql: String = """
        SELECT DISTINCT
            SCHEMA_NAME(o.schema_id) AS referencing_schema, o.name AS referencing_name,
            SCHEMA_NAME(r.schema_id) AS referenced_schema, r.name AS referenced_name
        FROM sys.sql_expression_dependencies AS sed
        JOIN sys.objects AS o ON o.object_id = sed.referencing_id
        JOIN sys.objects AS r ON r.object_id = sed.referenced_id
        WHERE sed.referencing_class = 1
          AND sed.referenced_id IS NOT NULL
          AND sed.referenced_id <> sed.referencing_id
          AND sed.referenced_database_name IS NULL
          AND o.type IN ('V', 'P', 'FN', 'IF', 'TF')
          AND r.type IN ('V', 'P', 'FN', 'IF', 'TF')
        """
        let result: TDSQueryResult = try await session.metadataQuery(sql, database: database)
        let rows: [[String: TDSValue]] = result.resultSets.first?.dictionaries() ?? []
        var graph: [String: Set<String>] = [:]
        for row in rows {
            let from: String = "\(row.string("referencing_schema")).\(row.string("referencing_name"))"
            let to: String = "\(row.string("referenced_schema")).\(row.string("referenced_name"))"
            graph[from.lowercased(), default: []].insert(to.lowercased())
        }
        return graph
    }

    private static func kind(forObjectType type: String) -> ObjectNodeKind? {
        switch type.trimmingCharacters(in: .whitespaces).uppercased() {
        case "U": return .table
        case "V": return .view
        case "P": return .storedProcedure
        case "FN": return .scalarFunction
        case "IF", "TF": return .tableValuedFunction
        case "AF": return .aggregateFunction
        default: return nil
        }
    }
}
