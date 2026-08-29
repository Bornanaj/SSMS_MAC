import Foundation
import TDSKit

// MARK: - Models

/// One object the Generate Scripts wizard can script.
public struct ScriptableObject: Sendable, Hashable, Identifiable {
    public var id: String { "\(kind.rawValue):\(schema).\(name)" }

    public var kind: ObjectNodeKind
    public var schema: String
    public var name: String
    public var objectID: Int
    public var createDate: String
    public var isSystemObject: Bool

    public init(kind: ObjectNodeKind,
                schema: String,
                name: String,
                objectID: Int = 0,
                createDate: String = "",
                isSystemObject: Bool = false) {
        self.kind = kind
        self.schema = schema
        self.name = name
        self.objectID = objectID
        self.createDate = createDate
        self.isSystemObject = isSystemObject
    }

    public var qualifiedName: String { "\(schema).\(name)" }

    /// The heading the wizard groups objects under.
    public var groupTitle: String {
        switch kind {
        case .schema: return "Schemas"
        case .userDefinedDataType: return "User-Defined Data Types"
        case .userDefinedTableType: return "User-Defined Table Types"
        case .table: return "Tables"
        case .view: return "Views"
        case .scalarFunction: return "Scalar-valued Functions"
        case .tableValuedFunction: return "Table-valued Functions"
        case .aggregateFunction: return "Aggregate Functions"
        case .storedProcedure: return "Stored Procedures"
        case .trigger: return "Database Triggers"
        case .synonym: return "Synonyms"
        case .sequence: return "Sequences"
        default: return "Other"
        }
    }

    /// The heading in the singular, for the banner above each object.
    public var singularTitle: String {
        switch kind {
        case .schema: return "Schema"
        case .userDefinedDataType: return "User-Defined Data Type"
        case .userDefinedTableType: return "User-Defined Table Type"
        case .table: return "Table"
        case .view: return "View"
        case .scalarFunction: return "Scalar-valued Function"
        case .tableValuedFunction: return "Table-valued Function"
        case .aggregateFunction: return "Aggregate Function"
        case .storedProcedure: return "Stored Procedure"
        case .trigger: return "Database Trigger"
        case .synonym: return "Synonym"
        case .sequence: return "Sequence"
        default: return "Object"
        }
    }

    /// The node the scripter needs. `ScriptGenerator` works from tree nodes, so a
    /// discovered object is turned back into one.
    func explorerNode(database: String) -> ObjectExplorerNode {
        ObjectExplorerNode(
            id: "script/\(database)/\(id)",
            kind: kind,
            label: qualifiedName,
            iconName: "doc.text",
            isExpandable: false,
            database: database,
            schema: schema,
            name: name,
            objectID: objectID == 0 ? nil : objectID,
            isSystemObject: isSystemObject
        )
    }
}

/// The wizard's Set Scripting Options page.
public struct ScriptProjectOptions: Sendable, Hashable {
    /// Per-object scripting behaviour, shared with "Script as CREATE To".
    public var scriptOptions: ScriptOptions
    /// Emit CREATE DATABASE ahead of everything else.
    public var includeDatabaseCreate: Bool
    /// Emit `USE [db]` so the script can be run against any connection.
    public var includeUseStatement: Bool
    /// Prefix every object with a DROP, which is SSMS's "Script DROP and CREATE".
    public var dropAndCreate: Bool
    /// Follow each table's DDL with INSERT statements for its rows.
    public var includeData: Bool
    /// A hard cap on rows scripted per table; the wizard warns rather than hang on a
    /// hundred-million-row fact table.
    public var maxDataRowsPerTable: Int
    /// Put a `GO` and a comment banner between objects.
    public var includeObjectBanners: Bool

    public init(scriptOptions: ScriptOptions = ScriptOptions(),
                includeDatabaseCreate: Bool = false,
                includeUseStatement: Bool = true,
                dropAndCreate: Bool = false,
                includeData: Bool = false,
                maxDataRowsPerTable: Int = 10_000,
                includeObjectBanners: Bool = true) {
        self.scriptOptions = scriptOptions
        self.includeDatabaseCreate = includeDatabaseCreate
        self.includeUseStatement = includeUseStatement
        self.dropAndCreate = dropAndCreate
        self.includeData = includeData
        self.maxDataRowsPerTable = maxDataRowsPerTable
        self.includeObjectBanners = includeObjectBanners
    }
}

/// Progress for the wizard's status line.
public struct ScriptProjectProgress: Sendable, Hashable {
    public var completed: Int
    public var total: Int
    public var currentObject: String

    public init(completed: Int, total: Int, currentObject: String) {
        self.completed = completed
        self.total = total
        self.currentObject = currentObject
    }

    public var fraction: Double {
        total > 0 ? Double(completed) / Double(total) : 0
    }
}

/// The outcome: the script plus whatever could not be scripted, so a partial failure
/// never silently drops an object.
public struct ScriptProjectResult: Sendable {
    public var sql: String
    public var scriptedCount: Int
    /// Object name paired with the reason it was skipped.
    public var failures: [(object: String, reason: String)]

    public init(sql: String, scriptedCount: Int, failures: [(object: String, reason: String)]) {
        self.sql = sql
        self.scriptedCount = scriptedCount
        self.failures = failures
    }
}

// MARK: - Generate Scripts

/// The Generate Scripts wizard: discover a database's objects, order them so the script
/// runs top to bottom, and concatenate the per-object output of `ScriptGenerator`.
public struct ScriptProject: Sendable {

    private let session: SQLServerSession
    private let runner: AdminRunner

    public init(session: SQLServerSession) {
        self.session = session
        self.runner = AdminRunner(session: session)
    }

    // MARK: Discovery

    /// Every user object in the database, in one round trip.
    public func discover(database: String,
                         includeSystemObjects: Bool = false) async throws -> [ScriptableObject] {
        let systemFilter = includeSystemObjects ? "" : "AND o.is_ms_shipped = 0"
        let sql = """
        SELECT
            s.name                                                   AS SchemaName,
            o.name                                                   AS ObjectName,
            RTRIM(o.type)                                            AS ObjectType,
            CAST(o.object_id AS int)                                 AS ObjectId,
            ISNULL(CONVERT(nvarchar(23), o.create_date, 121), N'')    AS CreateDate,
            CAST(o.is_ms_shipped AS int)                             AS IsMSShipped
        FROM sys.objects AS o
        JOIN sys.schemas AS s ON s.schema_id = o.schema_id
        WHERE o.type IN ('U', 'V', 'P', 'FN', 'IF', 'TF', 'FS', 'FT', 'AF', 'SN', 'SO', 'TR')
          AND o.parent_object_id = 0
          \(systemFilter)

        UNION ALL

        SELECT s.name, t.name, N'TT', CAST(t.type_table_object_id AS int), N'', 0
        FROM sys.table_types AS t
        JOIN sys.schemas AS s ON s.schema_id = t.schema_id

        UNION ALL

        SELECT s.name, t.name, N'DT', CAST(t.user_type_id AS int), N'', 0
        FROM sys.types AS t
        JOIN sys.schemas AS s ON s.schema_id = t.schema_id
        WHERE t.is_user_defined = 1 AND t.is_table_type = 0

        UNION ALL

        SELECT s.name, s.name, N'SC', CAST(s.schema_id AS int), N'', 0
        FROM sys.schemas AS s
        WHERE s.name NOT IN ('dbo', 'guest', 'sys', 'INFORMATION_SCHEMA')
          AND s.name NOT LIKE 'db[_]%'

        ORDER BY SchemaName, ObjectName;
        """
        let rows = try await runner.read(sql, database: database)
        return rows.compactMap { row in
            let type = row.string("ObjectType")
            guard let kind = ScriptProject.kind(forObjectType: type) else { return nil }
            return ScriptableObject(
                kind: kind,
                schema: row.string("SchemaName"),
                name: row.string("ObjectName"),
                objectID: row.int("ObjectId"),
                createDate: row.string("CreateDate"),
                isSystemObject: row.bool("IsMSShipped")
            )
        }
    }

    static func kind(forObjectType type: String) -> ObjectNodeKind? {
        switch type.trimmingCharacters(in: .whitespaces).uppercased() {
        case "U": return .table
        case "V": return .view
        case "P", "PC": return .storedProcedure
        case "FN", "FS": return .scalarFunction
        case "IF", "TF", "FT": return .tableValuedFunction
        case "AF": return .aggregateFunction
        case "SN": return .synonym
        case "SO": return .sequence
        case "TR": return .trigger
        case "TT": return .userDefinedTableType
        case "DT": return .userDefinedDataType
        case "SC": return .schema
        default: return nil
        }
    }

    /// `referencing -> referenced` pairs between the objects in a database, used to order
    /// views that select from other views and functions that call other functions.
    public func dependencyEdges(database: String) async throws -> [(from: String, to: String)] {
        let sql = """
        SELECT DISTINCT
            rs.name + N'.' + ro.name                                 AS Referencing,
            ds.name + N'.' + dobj.name                               AS Referenced
        FROM sys.sql_expression_dependencies AS d
        JOIN sys.objects AS ro ON ro.object_id = d.referencing_id
        JOIN sys.schemas AS rs ON rs.schema_id = ro.schema_id
        JOIN sys.objects AS dobj ON dobj.object_id = d.referenced_id
        JOIN sys.schemas AS ds ON ds.schema_id = dobj.schema_id
        WHERE d.referenced_id IS NOT NULL
          AND d.referencing_id <> d.referenced_id
          AND ro.is_ms_shipped = 0
          AND dobj.is_ms_shipped = 0;
        """
        return try await runner.read(sql, database: database).map {
            (from: $0.string("Referencing"), to: $0.string("Referenced"))
        }
    }

    // MARK: Ordering

    /// Where a kind sits in the script. Schemas and types come first because everything
    /// else can reference them; triggers come last because they need their tables.
    static func rank(for kind: ObjectNodeKind) -> Int {
        switch kind {
        case .schema: return 0
        case .userDefinedDataType: return 1
        case .userDefinedTableType: return 2
        case .sequence: return 3
        case .table: return 4
        case .scalarFunction: return 5
        case .tableValuedFunction: return 6
        case .aggregateFunction: return 7
        case .view: return 8
        case .storedProcedure: return 9
        case .synonym: return 10
        case .trigger: return 11
        default: return 12
        }
    }

    /// Objects in an order the resulting script can be run in.
    ///
    /// Kinds are ranked first, then a stable topological sort runs inside each rank so a
    /// view that selects from another view is created second. A dependency cycle — two
    /// procedures calling each other, which SQL Server allows — falls back to alphabetical
    /// order for the objects in the cycle rather than dropping any of them.
    public static func ordered(_ objects: [ScriptableObject],
                               edges: [(from: String, to: String)] = []) -> [ScriptableObject] {
        var out: [ScriptableObject] = []
        let tiers = Set(objects.map { rank(for: $0.kind) }).sorted()
        for tier in tiers {
            let group = objects
                .filter { ScriptProject.rank(for: $0.kind) == tier }
                .sorted { ($0.schema, $0.name) < ($1.schema, $1.name) }
            let names = Set(group.map(\.qualifiedName))

            // Only edges that stay inside this tier can reorder it; cross-tier edges are
            // already satisfied by the tier order itself.
            var dependencies: [String: Set<String>] = [:]
            for edge in edges where names.contains(edge.from) && names.contains(edge.to)
                && edge.from != edge.to {
                dependencies[edge.from, default: []].insert(edge.to)
            }
            guard !dependencies.isEmpty else {
                out += group
                continue
            }

            var emitted = Set<String>()
            var remaining = group
            // Kahn's algorithm, but scanning in alphabetical order so the output is stable.
            while !remaining.isEmpty {
                let ready = remaining.filter { object in
                    (dependencies[object.qualifiedName] ?? []).isSubset(of: emitted)
                }
                if ready.isEmpty {
                    // Everything left is in a cycle; emit it in the order it came in.
                    out += remaining
                    break
                }
                out += ready
                for object in ready { emitted.insert(object.qualifiedName) }
                let readyNames = Set(ready.map(\.qualifiedName))
                remaining.removeAll { readyNames.contains($0.qualifiedName) }
            }
        }
        return out
    }

    // MARK: Generation

    /// Scripts `objects` into one batch-separated script.
    ///
    /// `onProgress` is called on the caller's task, once per object, so the wizard can
    /// show which object it is on without polling.
    public func generate(database: String,
                         objects: [ScriptableObject],
                         options: ScriptProjectOptions = ScriptProjectOptions(),
                         onProgress: (@Sendable (ScriptProjectProgress) -> Void)? = nil)
        async throws -> ScriptProjectResult {

        let generator = ScriptGenerator(session: session)
        let edges = (try? await dependencyEdges(database: database)) ?? []
        let ordered = ScriptProject.ordered(objects, edges: edges)

        var out = ""
        var failures: [(object: String, reason: String)] = []
        var scripted = 0

        if options.includeDatabaseCreate {
            do {
                out += try await generator.createDatabase(name: database,
                                                          options: options.scriptOptions)
                out += "\n"
            } catch {
                failures.append((object: database, reason: String(describing: error)))
            }
        }
        if options.includeUseStatement {
            out += "USE \(SQLIdentifier.quote(database));\nGO\n\n"
        }

        for (index, object) in ordered.enumerated() {
            onProgress?(ScriptProjectProgress(completed: index,
                                              total: ordered.count,
                                              currentObject: object.qualifiedName))
            if Task.isCancelled { throw SQLServerError.cancelled }

            do {
                let body = try await script(object: object, database: database,
                                           generator: generator, options: options)
                if options.includeObjectBanners {
                    out += "/* ---- \(object.singularTitle): \(object.qualifiedName) ---- */\n"
                }
                out += body
                if !out.hasSuffix("\n") { out += "\n" }
                out += "\n"
                scripted += 1
            } catch {
                failures.append((object: object.qualifiedName, reason: String(describing: error)))
            }
        }

        if options.includeData {
            for object in ordered where object.kind == .table {
                onProgress?(ScriptProjectProgress(completed: ordered.count,
                                                  total: ordered.count,
                                                  currentObject: "\(object.qualifiedName) data"))
                if Task.isCancelled { throw SQLServerError.cancelled }
                do {
                    let inserts = try await dataScript(for: object, database: database,
                                                       maxRows: options.maxDataRowsPerTable)
                    guard !inserts.isEmpty else { continue }
                    out += "/* ---- Data: \(object.qualifiedName) ---- */\n"
                    out += inserts
                    out += "\n"
                } catch {
                    failures.append((object: "\(object.qualifiedName) (data)",
                                     reason: String(describing: error)))
                }
            }
        }

        onProgress?(ScriptProjectProgress(completed: ordered.count,
                                          total: ordered.count,
                                          currentObject: ""))
        return ScriptProjectResult(sql: out, scriptedCount: scripted, failures: failures)
    }

    private func script(object: ScriptableObject,
                        database: String,
                        generator: ScriptGenerator,
                        options: ScriptProjectOptions) async throws -> String {
        let node = object.explorerNode(database: database)
        let action: ScriptAction = options.dropAndCreate ? .dropAndCreate : .create
        return try await generator.script(node: node, action: action,
                                          options: options.scriptOptions)
    }

    private func dataScript(for object: ScriptableObject,
                            database: String,
                            maxRows: Int) async throws -> String {
        let limit = max(1, maxRows)
        let target = SQLIdentifier.quote(schema: object.schema, name: object.name)
        let result = try await session.metadataQuery("SELECT TOP (\(limit)) * FROM \(target);",
                                                     database: database)
        if let failure = result.errors.first { throw failure }
        guard let set = result.resultSets.first, !set.rows.isEmpty else { return "" }

        var exportOptions = ExportOptions()
        exportOptions.tableName = "\(object.schema).\(object.name)"
        exportOptions.lineEnding = "\n"
        exportOptions.batchSize = 500
        let body = try ResultExporter().string(columns: set.columns, rows: set.rows,
                                               format: .sqlInsert, options: exportOptions)
        // An identity column cannot be written to without the gate open, so a data script
        // for such a table is bracketed by SET IDENTITY_INSERT.
        guard set.columns.contains(where: { $0.identity }) else { return body }
        return "SET IDENTITY_INSERT \(target) ON;\nGO\n" + body
            + "SET IDENTITY_INSERT \(target) OFF;\nGO\n"
    }
}
