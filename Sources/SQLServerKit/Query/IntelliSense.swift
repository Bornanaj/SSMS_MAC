import Foundation
import TDSKit

// MARK: - Catalog model

public struct IntelliSenseColumn: Sendable, Hashable {
    public var name: String
    public var typeName: String
    public var isNullable: Bool
    public var isPrimaryKey: Bool
    public var ordinal: Int

    public init(name: String, typeName: String, isNullable: Bool,
                isPrimaryKey: Bool, ordinal: Int) {
        self.name = name
        self.typeName = typeName
        self.isNullable = isNullable
        self.isPrimaryKey = isPrimaryKey
        self.ordinal = ordinal
    }
}

public struct IntelliSenseParameter: Sendable, Hashable {
    public var name: String
    public var typeName: String
    public var isOutput: Bool
    public var hasDefault: Bool

    public init(name: String, typeName: String, isOutput: Bool, hasDefault: Bool) {
        self.name = name
        self.typeName = typeName
        self.isOutput = isOutput
        self.hasDefault = hasDefault
    }
}

public struct IntelliSenseObject: Sendable, Hashable {
    public var schema: String
    public var name: String
    /// "table", "view", "procedure" or "function".
    public var kind: String
    public var columns: [IntelliSenseColumn]
    public var parameters: [IntelliSenseParameter]

    public init(schema: String, name: String, kind: String,
                columns: [IntelliSenseColumn] = [], parameters: [IntelliSenseParameter] = []) {
        self.schema = schema
        self.name = name
        self.kind = kind
        self.columns = columns
        self.parameters = parameters
    }

    public var qualifiedName: String { "\(schema).\(name)" }
}

/// A foreign key, so a JOIN can be completed with its own ON condition.
public struct IntelliSenseRelationship: Sendable, Hashable {
    public var name: String
    public var parentSchema: String
    public var parentTable: String
    public var parentColumns: [String]
    public var referencedSchema: String
    public var referencedTable: String
    public var referencedColumns: [String]

    public init(name: String, parentSchema: String, parentTable: String,
                parentColumns: [String], referencedSchema: String,
                referencedTable: String, referencedColumns: [String]) {
        self.name = name
        self.parentSchema = parentSchema
        self.parentTable = parentTable
        self.parentColumns = parentColumns
        self.referencedSchema = referencedSchema
        self.referencedTable = referencedTable
        self.referencedColumns = referencedColumns
    }
}

public struct IntelliSenseCatalog: Sendable {
    public var database: String
    public var fetchedAt: Date
    public var schemas: [String]
    public var tables: [IntelliSenseObject]
    public var routines: [IntelliSenseObject]
    public var relationships: [IntelliSenseRelationship]
    /// False while only the object names have been read. Completion works from that
    /// outline immediately; columns and parameters arrive with the full read, and are
    /// fetched per object on demand until they do.
    public var isComplete: Bool

    public init(database: String, fetchedAt: Date, schemas: [String],
                tables: [IntelliSenseObject], routines: [IntelliSenseObject],
                relationships: [IntelliSenseRelationship] = [],
                isComplete: Bool = true) {
        self.database = database
        self.fetchedAt = fetchedAt
        self.schemas = schemas
        self.tables = tables
        self.routines = routines
        self.relationships = relationships
        self.isComplete = isComplete
    }

    /// Foreign keys linking the two tables, in either direction.
    public func relationships(between left: String, and right: String) -> [IntelliSenseRelationship] {
        let a = IntelliSenseCatalog.unquote(left).lowercased()
        let b = IntelliSenseCatalog.unquote(right).lowercased()
        return relationships.filter { relationship in
            let parent = relationship.parentTable.lowercased()
            let referenced = relationship.referencedTable.lowercased()
            return (parent == a && referenced == b) || (parent == b && referenced == a)
        }
    }

    /// Resolve a table reference that may be bare, schema-qualified or bracketed.
    public func columns(forTable name: String, schema: String?) -> [IntelliSenseColumn] {
        object(named: name, schema: schema)?.columns ?? []
    }

    public func object(named name: String, schema: String?) -> IntelliSenseObject? {
        let bare = IntelliSenseCatalog.unquote(name)
        if let schema {
            let bareSchema = IntelliSenseCatalog.unquote(schema)
            return tables.first {
                $0.name.caseInsensitiveCompare(bare) == .orderedSame
                    && $0.schema.caseInsensitiveCompare(bareSchema) == .orderedSame
            }
        }
        return tables.first { $0.name.caseInsensitiveCompare(bare) == .orderedSame }
    }

    public func routine(named name: String, schema: String?) -> IntelliSenseObject? {
        let bare = IntelliSenseCatalog.unquote(name)
        if let schema {
            let bareSchema = IntelliSenseCatalog.unquote(schema)
            return routines.first {
                $0.name.caseInsensitiveCompare(bare) == .orderedSame
                    && $0.schema.caseInsensitiveCompare(bareSchema) == .orderedSame
            }
        }
        return routines.first { $0.name.caseInsensitiveCompare(bare) == .orderedSame }
    }

    static func unquote(_ value: String) -> String {
        var text = value
        if text.hasPrefix("["), text.hasSuffix("]"), text.count >= 2 {
            text = String(text.dropFirst().dropLast()).replacingOccurrences(of: "]]", with: "]")
        } else if text.hasPrefix("\""), text.hasSuffix("\""), text.count >= 2 {
            text = String(text.dropFirst().dropLast())
        }
        return text
    }
}

// MARK: - Completion items

public struct CompletionItem: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Hashable {
        case keyword, table, view, column, procedure, function, schema, database
        case variable, snippet, dataType, alias, parameter
        /// Not a completion: a line explaining why there is nothing to complete.
        case info
    }

    public var id: String
    public var label: String
    public var kind: Kind
    public var detail: String
    public var documentation: String
    public var insertText: String
    public var sortPriority: Int

    public init(id: String, label: String, kind: Kind, detail: String,
                documentation: String, insertText: String, sortPriority: Int) {
        self.id = id
        self.label = label
        self.kind = kind
        self.detail = detail
        self.documentation = documentation
        self.insertText = insertText
        self.sortPriority = sortPriority
    }

    static func make(label: String, kind: Kind, detail: String = "",
                     documentation: String = "", priority: Int) -> CompletionItem {
        CompletionItem(id: "\(kind.rawValue):\(label)",
                       label: label,
                       kind: kind,
                       detail: detail,
                       documentation: documentation,
                       insertText: SQLIdentifier.isRegular(label) ? label : SQLIdentifier.quote(label),
                       sortPriority: priority)
    }
}

/// What the editor needs to know about a completion request, beyond the items: after a
/// qualifier ("c." or "sales.") a keyword list is the wrong answer, and an empty list
/// while the catalog is still loading is not the same as "nothing matches here".
public struct CompletionResult: Sendable {
    public var items: [CompletionItem]
    public var isMemberContext: Bool
    public var hasCatalog: Bool
    /// Tables in scope whose columns the catalog has not read yet. The caller reads
    /// them and asks again; nothing is fetched while the list is being computed.
    public var pendingColumns: [ObjectReference]
    /// Why there is nothing to offer, when there is nothing to offer. An empty popup
    /// and a popup that never opened look identical, and both read as "IntelliSense is
    /// broken"; this is what the editor shows instead.
    public var message: String?

    public init(items: [CompletionItem], isMemberContext: Bool, hasCatalog: Bool,
                pendingColumns: [ObjectReference] = [], message: String? = nil) {
        self.items = items
        self.isMemberContext = isMemberContext
        self.hasCatalog = hasCatalog
        self.pendingColumns = pendingColumns
        self.message = message
    }
}

// MARK: - Provider

/// Supplies context-aware completions. The catalog is refreshed in the background and
/// cached per database, because completion has to answer while the user is still typing.
public actor IntelliSenseProvider {

    private let session: SQLServerSession
    private var catalogs: [String: IntelliSenseCatalog] = [:]
    private let lexer = TSQLLexer()

    public init(session: SQLServerSession) {
        self.session = session
    }

    public func catalog(for database: String) -> IntelliSenseCatalog? {
        catalogs[database.lowercased()]
    }

    /// Reads in flight, so two windows asking for the same database cause one read.
    private var refreshes: [String: Task<IntelliSenseCatalog, Error>] = [:]
    /// How long a complete catalog is trusted before a new window reads it again.
    /// Refresh IntelliSense Cache ignores this.
    private let catalogLifetime: TimeInterval = 15 * 60

    /// `onOutline` is called with the object count as soon as the names are in, which
    /// is what the editor can start completing against. A complete catalog read
    /// recently is returned as it is unless `force` is set; a read already under way
    /// for the same database is joined rather than repeated.
    @discardableResult
    public func refresh(database: String, force: Bool = false,
                        onOutline: (@Sendable (Int) -> Void)? = nil) async throws -> IntelliSenseCatalog {
        let key = database.lowercased()
        if !force, let cached = catalogs[key], cached.isComplete,
           Date().timeIntervalSince(cached.fetchedAt) < catalogLifetime {
            return cached
        }
        if let inFlight = refreshes[key] {
            return try await inFlight.value
        }
        let task = Task<IntelliSenseCatalog, Error> {
            defer { refreshes[key] = nil }
            return try await load(database: database, onOutline: onOutline)
        }
        refreshes[key] = task
        return try await task.value
    }

    private func load(database: String,
                      onOutline: (@Sendable (Int) -> Void)?) async throws -> IntelliSenseCatalog {
        // The catalog is a big read, and the session's metadata connection is shared
        // with the Object Explorer and every properties sheet. On a production
        // database that read takes long enough to stall all of them, so it gets a
        // connection of its own and gives it back when it is done.
        let connection = try await session.openConnection(database: database)
        defer { Task { try? await connection.close() } }

        // Names first. Reading every column of every object takes seconds on a real
        // database, and until it lands the editor would offer nothing but keywords —
        // which is what "IntelliSense does not work" looks like from the outside. The
        // names arrive in one cheap query and are published straight away, so tables
        // and procedures can be completed while the columns are still being read.
        let outline = try await loadObjectNames(on: connection)
        catalogs[database.lowercased()] = IntelliSenseCatalog(
            database: database,
            fetchedAt: Date(),
            schemas: Set(outline.map(\.schema)).sorted(),
            tables: outline.filter { $0.kind == "table" || $0.kind == "view" },
            routines: outline.filter { $0.kind == "procedure" || $0.kind == "function" },
            relationships: [],
            isComplete: false)
        onOutline?(outline.count)

        let tables = try await loadTables(on: connection)
        let routines = try await loadRoutines(on: connection)
        let relationships = try await loadRelationships(on: connection)
        let schemas = Set(tables.map(\.schema)).union(routines.map(\.schema)).sorted()
        let catalog = IntelliSenseCatalog(database: database, fetchedAt: Date(),
                                          schemas: schemas, tables: tables, routines: routines,
                                          relationships: relationships,
                                          isComplete: true)
        catalogs[database.lowercased()] = catalog
        return catalog
    }

    /// Schema, name and kind for everything completable, in one pass. No columns, no
    /// parameters: this is the query that has to come back quickly.
    private func loadObjectNames(on connection: TDSConnection) async throws -> [IntelliSenseObject] {
        let sql = """
        SELECT s.name AS schema_name, o.name AS object_name,
               CASE o.type WHEN 'V' THEN N'view'
                           WHEN 'P' THEN N'procedure'
                           WHEN 'U' THEN N'table'
                           ELSE N'function' END AS object_kind
        FROM sys.objects AS o
        JOIN sys.schemas AS s ON s.schema_id = o.schema_id
        WHERE o.type IN ('U', 'V', 'P', 'FN', 'IF', 'TF', 'AF') AND o.is_ms_shipped = 0
        ORDER BY s.name, o.name
        """
        let result = try await connection.query(sql)
        if let failure = result.errors.first { throw failure }
        return (result.resultSets.first?.dictionaries() ?? []).map { row in
            IntelliSenseObject(schema: row.string("schema_name"),
                               name: row.string("object_name"),
                               kind: row.string("object_kind"))
        }
    }

    /// Columns for one table, fetched when something needs them before the full read
    /// has landed — typing "alias." should not have to wait for the whole database.
    private func fetchColumns(schema: String, name table: String,
                              database: String) async -> [IntelliSenseColumn] {
        let sql = """
        SELECT c.name AS column_name, c.column_id, c.is_nullable,
               t.name AS type_name, c.max_length, c.precision, c.scale, t.is_user_defined,
               CONVERT(int, CASE WHEN pk.column_id IS NULL THEN 0 ELSE 1 END) AS is_primary_key
        FROM sys.columns AS c
        JOIN sys.objects AS o ON o.object_id = c.object_id
        JOIN sys.schemas AS s ON s.schema_id = o.schema_id
        JOIN sys.types AS t ON t.user_type_id = c.user_type_id
        LEFT JOIN (
            SELECT ic.object_id, ic.column_id
            FROM sys.indexes AS i
            JOIN sys.index_columns AS ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id
            WHERE i.is_primary_key = 1
        ) AS pk ON pk.object_id = c.object_id AND pk.column_id = c.column_id
        WHERE s.name = \(SQLIdentifier.literal(schema)) AND o.name = \(SQLIdentifier.literal(table))
        ORDER BY c.column_id
        """
        guard let result = try? await session.metadataQuery(sql, database: database),
              result.errors.isEmpty else { return [] }
        return (result.resultSets.first?.dictionaries() ?? []).map { row in
            IntelliSenseColumn(
                name: row.string("column_name"),
                typeName: ScriptGenerator.formatType(name: row.string("type_name"),
                                                     baseName: row.string("type_name"),
                                                     maxLength: row.int("max_length"),
                                                     precision: row.int("precision"),
                                                     scale: row.int("scale"),
                                                     isUserDefined: row.bool("is_user_defined")),
                isNullable: row.bool("is_nullable"),
                isPrimaryKey: row.int("is_primary_key") == 1,
                ordinal: row.int("column_id"))
        }
    }

    // MARK: Completion

    /// Insert `table AS alias` when completing a table reference, the way SQL Prompt does.
    public var generatesAliases = true

    public func setGeneratesAliases(_ value: Bool) {
        generatesAliases = value
    }

    public func completions(script: String, offset: Int, database: String) async -> [CompletionItem] {
        await completionResult(script: script, offset: offset, database: database).items
    }

    /// True when the caret sits inside a string literal or a comment, where no
    /// completion is worth offering.
    public static func caretIsInsideLiteralOrComment(tokens: [TSQLToken], offset: Int) -> Bool {
        tokens.contains { token in
            let end = token.start + token.length
            switch token.kind {
            case .lineComment, .blockComment:
                return token.start < offset && offset <= end
            case .string:
                // Right after the closing quote is outside; at the end of an unterminated
                // literal the user is still inside it.
                let terminated = token.length >= 2 && token.text.hasSuffix("'")
                return token.start < offset && (offset < end || (offset == end && !terminated))
            default:
                return false
            }
        }
    }

    /// Pure: the catalog is read from memory and nothing waits on the server, because
    /// this runs on every keystroke. When a member list needs columns the catalog has
    /// not read yet, the result says which object to read and the caller decides.
    public func completionResult(script: String, offset: Int,
                                 database: String) async -> CompletionResult {
        CompletionEngine(catalog: catalogs[database.lowercased()],
                         generatesAliases: generatesAliases)
            .result(script: script, offset: offset)
    }

    /// Reads one object's columns into the cached catalog. Returns false when there was
    /// nothing to add, so a caller cannot loop asking for the same thing.
    @discardableResult
    public func loadColumns(_ object: ObjectReference, database: String) async -> Bool {
        let key = database.lowercased()
        guard var catalog = catalogs[key],
              let index = catalog.tables.firstIndex(where: {
                  $0.name.caseInsensitiveCompare(object.name) == .orderedSame
                      && $0.schema.caseInsensitiveCompare(object.schema) == .orderedSame
              }), catalog.tables[index].columns.isEmpty else { return false }

        let columns = await fetchColumns(schema: object.schema, name: object.name,
                                         database: database)
        guard !columns.isEmpty else { return false }
        // The catalog may have been replaced by a full refresh while this was in
        // flight; re-read it rather than writing a stale copy back.
        guard var current = catalogs[key],
              let slot = current.tables.firstIndex(where: {
                  $0.name.caseInsensitiveCompare(object.name) == .orderedSame
                      && $0.schema.caseInsensitiveCompare(object.schema) == .orderedSame
              }), current.tables[slot].columns.isEmpty else { return false }
        current.tables[slot].columns = columns
        catalogs[key] = current
        return true
    }


    public func signatureHelp(script: String, offset: Int, database: String) async -> String? {
        guard let catalog = catalogs[database.lowercased()] else { return nil }
        let tokens = lexer.tokenize(script)
        guard let call = IntelliSenseContext.enclosingCall(tokens: tokens, offset: offset) else {
            return nil
        }
        guard let routine = catalog.routine(named: call.name, schema: call.schema) else { return nil }
        let parameters = routine.parameters.map { parameter in
            "\(parameter.name) \(parameter.typeName)\(parameter.isOutput ? " OUTPUT" : "")"
        }
        return "\(routine.qualifiedName)(\(parameters.joined(separator: ", ")))"
    }

    // MARK: Catalog loading

    private func loadTables(on connection: TDSConnection) async throws -> [IntelliSenseObject] {
        let sql = """
        SELECT s.name AS schema_name, o.name AS object_name,
               CASE WHEN o.type = 'V' THEN N'view' ELSE N'table' END AS object_kind,
               c.name AS column_name, c.column_id, c.is_nullable,
               t.name AS type_name, c.max_length, c.precision, c.scale, t.is_user_defined,
               CONVERT(int, CASE WHEN pk.column_id IS NULL THEN 0 ELSE 1 END) AS is_primary_key
        FROM sys.objects AS o
        JOIN sys.schemas AS s ON s.schema_id = o.schema_id
        JOIN sys.columns AS c ON c.object_id = o.object_id
        JOIN sys.types AS t ON t.user_type_id = c.user_type_id
        -- One pass over the primary key columns, rather than a lookup per column:
        -- the correlated form costs an index seek for every column in the database.
        LEFT JOIN (
            SELECT ic.object_id, ic.column_id
            FROM sys.indexes AS i
            JOIN sys.index_columns AS ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id
            WHERE i.is_primary_key = 1
        ) AS pk ON pk.object_id = c.object_id AND pk.column_id = c.column_id
        WHERE o.type IN ('U', 'V') AND o.is_ms_shipped = 0
        ORDER BY s.name, o.name, c.column_id
        """
        let result = try await connection.query(sql)
        if let failure = result.errors.first { throw failure }
        return IntelliSenseProvider.groupObjects(result.resultSets.first?.dictionaries() ?? [],
                                                 isRoutine: false)
    }

    private func loadRoutines(on connection: TDSConnection) async throws -> [IntelliSenseObject] {
        let sql = """
        SELECT s.name AS schema_name, o.name AS object_name,
               CASE WHEN o.type = 'P' THEN N'procedure' ELSE N'function' END AS object_kind,
               ISNULL(p.name, N'') AS parameter_name, ISNULL(p.parameter_id, 0) AS parameter_id,
               ISNULL(t.name, N'') AS type_name, ISNULL(p.max_length, 0) AS max_length,
               ISNULL(p.precision, 0) AS precision, ISNULL(p.scale, 0) AS scale,
               ISNULL(CONVERT(int, t.is_user_defined), 0) AS is_user_defined,
               ISNULL(CONVERT(int, p.is_output), 0) AS is_output,
               ISNULL(CONVERT(int, p.has_default_value), 0) AS has_default_value
        FROM sys.objects AS o
        JOIN sys.schemas AS s ON s.schema_id = o.schema_id
        LEFT JOIN sys.parameters AS p ON p.object_id = o.object_id AND p.parameter_id > 0
        LEFT JOIN sys.types AS t ON t.user_type_id = p.user_type_id
        WHERE o.type IN ('P', 'FN', 'IF', 'TF', 'AF') AND o.is_ms_shipped = 0
        ORDER BY s.name, o.name, p.parameter_id
        """
        let result = try await connection.query(sql)
        if let failure = result.errors.first { throw failure }
        return IntelliSenseProvider.groupObjects(result.resultSets.first?.dictionaries() ?? [],
                                                 isRoutine: true)
    }

    private func loadRelationships(on connection: TDSConnection) async throws -> [IntelliSenseRelationship] {
        let sql = """
        SELECT fk.name,
               ps.name AS parent_schema, pt.name AS parent_table,
               rs.name AS referenced_schema, rt.name AS referenced_table,
               STUFF((SELECT N',' + pc.name
                      FROM sys.foreign_key_columns AS fkc2
                      JOIN sys.columns AS pc ON pc.object_id = fkc2.parent_object_id
                           AND pc.column_id = fkc2.parent_column_id
                      WHERE fkc2.constraint_object_id = fk.object_id
                      ORDER BY fkc2.constraint_column_id
                      FOR XML PATH(N''), TYPE).value(N'.', N'nvarchar(max)'), 1, 1, N'')
                  AS parent_columns,
               STUFF((SELECT N',' + rc.name
                      FROM sys.foreign_key_columns AS fkc3
                      JOIN sys.columns AS rc ON rc.object_id = fkc3.referenced_object_id
                           AND rc.column_id = fkc3.referenced_column_id
                      WHERE fkc3.constraint_object_id = fk.object_id
                      ORDER BY fkc3.constraint_column_id
                      FOR XML PATH(N''), TYPE).value(N'.', N'nvarchar(max)'), 1, 1, N'')
                  AS referenced_columns
        FROM sys.foreign_keys AS fk
        JOIN sys.objects AS pt ON pt.object_id = fk.parent_object_id
        JOIN sys.schemas AS ps ON ps.schema_id = pt.schema_id
        JOIN sys.objects AS rt ON rt.object_id = fk.referenced_object_id
        JOIN sys.schemas AS rs ON rs.schema_id = rt.schema_id
        """
        let result = try await connection.query(sql)
        if let failure = result.errors.first { throw failure }
        func split(_ value: String) -> [String] {
            value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        return (result.resultSets.first?.dictionaries() ?? []).map { row in
            IntelliSenseRelationship(
                name: row.string("name"),
                parentSchema: row.string("parent_schema"),
                parentTable: row.string("parent_table"),
                parentColumns: split(row.string("parent_columns")),
                referencedSchema: row.string("referenced_schema"),
                referencedTable: row.string("referenced_table"),
                referencedColumns: split(row.string("referenced_columns")))
        }
    }

    private static func groupObjects(_ rows: [[String: TDSValue]],
                                     isRoutine: Bool) -> [IntelliSenseObject] {
        var objects: [String: IntelliSenseObject] = [:]
        var order: [String] = []

        for row in rows {
            let schema = row.string("schema_name")
            let name = row.string("object_name")
            let key = "\(schema.lowercased()).\(name.lowercased())"
            if objects[key] == nil {
                objects[key] = IntelliSenseObject(schema: schema, name: name,
                                                  kind: row.string("object_kind"))
                order.append(key)
            }

            let typeName = ScriptGenerator.formatType(
                name: row.string("type_name"),
                baseName: row.string("type_name"),
                maxLength: row.int("max_length"),
                precision: row.int("precision"),
                scale: row.int("scale"),
                isUserDefined: row.bool("is_user_defined"))

            if isRoutine {
                let parameterName = row.string("parameter_name")
                guard !parameterName.isEmpty else { continue }
                objects[key]?.parameters.append(IntelliSenseParameter(
                    name: parameterName,
                    typeName: typeName,
                    isOutput: row.bool("is_output"),
                    hasDefault: row.bool("has_default_value")))
            } else {
                objects[key]?.columns.append(IntelliSenseColumn(
                    name: row.string("column_name"),
                    typeName: typeName,
                    isNullable: row.bool("is_nullable"),
                    isPrimaryKey: row.bool("is_primary_key"),
                    ordinal: row.int("column_id")))
            }
        }

        return order.compactMap { objects[$0] }
    }
}

// MARK: - Caret context

/// What the caret is sitting in, worked out from the token stream.
struct IntelliSenseContext {
    enum Kind {
        case general
        case tableReference
        case procedureReference
        case columnReference
        case memberOf(String)
        case variable
    }

    struct Source {
        /// The database of a three-part name, which the catalog may not cover.
        var database: String?
        var schema: String?
        var table: String
        var alias: String?
        /// The parenthesised groups the reference sits in, outermost first, as the
        /// indices of their opening tokens. A source is visible from inside its own
        /// group and anything nested in it, so what a subquery reads stays inside it
        /// while the outer query stays visible to a correlated one.
        var path: [Int] = []
        /// Set when the script defines the source itself: a CTE, a derived table, a
        /// temp table or a table variable.
        var local: LocalDefinition?

        /// Whether `name` is this source's alias or, failing that, its table.
        func isCalled(_ name: String) -> Bool {
            if let alias, alias.caseInsensitiveCompare(name) == .orderedSame { return true }
            return table.caseInsensitiveCompare(name) == .orderedSame
        }
    }

    var kind: Kind = .general
    var sources: [Source] = []
    var variables: [String] = []
    /// CTEs, temp tables and table variables the script has defined by the caret, so
    /// a FROM can offer them alongside the catalog's tables.
    var localDefinitions: [LocalDefinition] = []
    /// True when the statement is an EXEC, so only routines make sense.
    var prefersRoutines = false
    /// True when the caret sits in a JOIN ... ON clause.
    var isJoinCondition = false
    /// True when the caret is inside a string literal or a comment, where nothing is
    /// worth offering and a popup would only get in the way of the text.
    var isSuppressed = false

    static func analyse(tokens: [TSQLToken], offset: Int) -> IntelliSenseContext {
        var context = IntelliSenseContext()
        if IntelliSenseProvider.caretIsInsideLiteralOrComment(tokens: tokens, offset: offset) {
            context.isSuppressed = true
            return context
        }
        let significant = tokens.filter {
            $0.kind != .whitespace && $0.kind != .lineComment && $0.kind != .blockComment
        }
        context.variables = Array(Set(tokens
            .filter { $0.kind == .variable && $0.start < offset && !$0.text.hasPrefix("@@") }
            .map(\.text))).sorted()

        // Index of the last significant token that ends at or before the caret.
        guard let caretIndex = significant.lastIndex(where: { $0.start + $0.length <= offset })
        else {
            context.kind = .general
            return context
        }

        let statement = statementRange(significant, containing: caretIndex)
        let definitions = LocalSources.batchDefinitions(significant, before: statement)
            + LocalSources.cteDefinitions(significant, in: statement)
        context.localDefinitions = definitions
        let caretPath = groupPath(significant, at: caretIndex, in: statement)
        context.sources = parseSources(significant, in: statement, definitions: definitions)
            .filter { caretPath.starts(with: $0.path) }

        let current = significant[caretIndex]
        let isPartialWord = current.start + current.length == offset
            && (current.kind == .identifier || current.kind == .keyword
                || current.kind == .dataType || current.kind == .builtInFunction
                || current.kind == .tempTable)
        // When the caret sits at the end of a word, the meaningful keyword is the one before it.
        let anchorIndex = isPartialWord ? caretIndex - 1 : caretIndex
        guard anchorIndex >= 0 else {
            context.kind = .general
            return context
        }
        let anchor = significant[anchorIndex]

        if anchor.kind == .variable && anchor.start + anchor.length == offset {
            context.kind = .variable
            return context
        }

        if anchor.kind == .punctuation && anchor.text == "." {
            // Look back past "schema." for an EXEC that governs this reference.
            var scan = anchorIndex - 2
            while scan >= statement.lowerBound {
                let token = significant[scan]
                let word = token.text.uppercased()
                if word == "EXEC" || word == "EXECUTE" { context.prefersRoutines = true; break }
                if token.kind == .punctuation && token.text == "." { scan -= 1; continue }
                break
            }
            let qualifierIndex = anchorIndex - 1
            if qualifierIndex >= 0 {
                let qualifier = significant[qualifierIndex]
                switch qualifier.kind {
                case .identifier, .quotedIdentifier, .tempTable, .variable:
                    context.kind = .memberOf(qualifier.text)
                    return context
                default:
                    break
                }
            }
        }

        let upper = anchor.text.uppercased()
        if upper == "ON" || (upper == "AND" && anchorIsInsideOnClause(significant, anchorIndex)) {
            context.isJoinCondition = true
        }
        switch upper {
        case "FROM", "JOIN", "INTO", "UPDATE", "TABLE", "APPLY":
            context.kind = .tableReference
        case "EXEC", "EXECUTE":
            context.kind = .procedureReference
        case "SELECT", "WHERE", "ON", "AND", "OR", "BY", "HAVING", "SET", "GROUP", "ORDER",
             "WHEN", "THEN", "ELSE", "=", "<", ">", "<=", ">=", "<>", ",", "(":
            context.kind = context.sources.isEmpty ? .general : .columnReference
        default:
            context.kind = .general
        }
        return context
    }

    /// Walk back from an AND to see whether it continues an ON clause rather than a WHERE.
    private static func anchorIsInsideOnClause(_ tokens: [TSQLToken], _ index: Int) -> Bool {
        var cursor = index - 1
        while cursor >= 0 {
            let upper = tokens[cursor].text.uppercased()
            if upper == "ON" { return true }
            if ["WHERE", "SELECT", "FROM", "GROUP", "ORDER", "HAVING"].contains(upper) {
                return false
            }
            cursor -= 1
        }
        return false
    }

    /// Bound the search to the statement around the caret so aliases from an earlier
    /// query in the same script do not leak in.
    private static func statementRange(_ tokens: [TSQLToken],
                                       containing index: Int) -> Range<Int> {
        TSQLStatements.range(of: tokens, containing: index)
    }

    /// The groups the token at `index` sits in, outermost first. An opening
    /// parenthesis at `index` counts: the caret after it is inside.
    private static func groupPath(_ tokens: [TSQLToken], at index: Int,
                                  in range: Range<Int>) -> [Int] {
        var path: [Int] = []
        guard range.lowerBound <= index else { return path }
        for cursor in range.lowerBound...index where tokens[cursor].kind == .punctuation {
            if tokens[cursor].text == "(" { path.append(cursor) }
            else if tokens[cursor].text == ")" { _ = path.popLast() }
        }
        return path
    }

    /// Pull the table references out of FROM, JOIN, APPLY, UPDATE, DELETE and INSERT
    /// INTO clauses, with their aliases, noting which ones the script defines itself.
    static func parseSources(_ tokens: [TSQLToken], in range: Range<Int>,
                             definitions: [LocalDefinition]) -> [Source] {
        var sources: [Source] = []
        var index = range.lowerBound
        var path: [Int] = []

        func readName(_ start: inout Int) -> (database: String?, schema: String?, name: String)? {
            guard start < range.upperBound else { return nil }
            var parts: [String] = []
            while start < range.upperBound {
                let token = tokens[start]
                guard token.kind == .identifier || token.kind == .quotedIdentifier
                        || token.kind == .tempTable || token.kind == .variable else { break }
                parts.append(token.text)
                start += 1
                if start < range.upperBound, tokens[start].kind == .punctuation,
                   tokens[start].text == "." {
                    start += 1
                    continue
                }
                break
            }
            guard let name = parts.last else { return nil }
            let schema = parts.count >= 2 ? parts[parts.count - 2] : nil
            let database = parts.count >= 3 ? parts[parts.count - 3] : nil
            return (database.map(IntelliSenseCatalog.unquote), schema.map(IntelliSenseCatalog.unquote),
                    IntelliSenseCatalog.unquote(name))
        }

        func readAlias(_ start: inout Int) -> String? {
            guard start < range.upperBound else { return nil }
            let next = tokens[start]
            if next.text.caseInsensitiveCompare("AS") == .orderedSame {
                start += 1
                guard start < range.upperBound,
                      tokens[start].kind == .identifier || tokens[start].kind == .quotedIdentifier
                else { return nil }
                let alias = IntelliSenseCatalog.unquote(tokens[start].text)
                start += 1
                return alias
            }
            if next.kind == .identifier || next.kind == .quotedIdentifier,
               !clauseBoundaries.contains(next.text.uppercased()) {
                start += 1
                return IntelliSenseCatalog.unquote(next.text)
            }
            return nil
        }

        func definition(named name: String) -> LocalDefinition? {
            definitions.last { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        }

        while index < range.upperBound {
            let token = tokens[index]
            if token.kind == .punctuation {
                if token.text == "(" { path.append(index) } else if token.text == ")" { _ = path.popLast() }
                index += 1
                continue
            }
            let upper = token.text.uppercased()
            guard token.kind == .keyword || token.kind == .identifier,
                  sourceKeywords.contains(upper) else {
                index += 1
                continue
            }
            if upper == "INTO" {
                // INSERT INTO and MERGE INTO name a source; SELECT … INTO names a result.
                let previous = index > range.lowerBound ? tokens[index - 1].text.uppercased() : ""
                guard previous == "INSERT" || previous == "MERGE" else { index += 1; continue }
            }
            index += 1
            let referencePath = path

            // A derived table: FROM (SELECT …) [AS] alias [(columns)]. Its own sources
            // are parsed by the loop as it walks into the group, with their deeper path.
            if let body = LocalSources.group(openingAt: index, in: tokens, limit: range.upperBound) {
                var cursor = body.upperBound
                if let alias = readAlias(&cursor) {
                    var columnList: Range<Int>?
                    if let list = LocalSources.group(openingAt: cursor, in: tokens,
                                                     limit: range.upperBound) {
                        columnList = list
                    }
                    let local = LocalSources.derivedDefinition(
                        named: alias, body: body, columnList: columnList, in: tokens,
                        definitions: definitions)
                    sources.append(Source(schema: nil, table: alias, alias: alias,
                                          path: referencePath, local: local))
                }
                continue
            }

            guard let reference = readName(&index) else { continue }
            // A table-valued function: its arguments come before the alias.
            if let arguments = LocalSources.group(openingAt: index, in: tokens,
                                                  limit: range.upperBound) {
                index = arguments.upperBound
            }
            let alias = readAlias(&index)
            var source = Source(database: reference.database, schema: reference.schema,
                                table: reference.name, alias: alias, path: referencePath)
            if reference.schema == nil { source.local = definition(named: reference.name) }
            sources.append(source)
        }

        // UPDATE o … FROM sales.Orders o: the first "o" is that alias, not a table.
        let aliases = Set(sources.compactMap { $0.alias?.lowercased() })
        return sources.filter { source in
            !(source.alias == nil && source.local == nil
                && aliases.contains(source.table.lowercased()))
        }
    }

    private static let sourceKeywords: Set<String> = [
        "FROM", "JOIN", "UPDATE", "DELETE", "APPLY", "INTO"
    ]

    private static let clauseBoundaries: Set<String> = [
        "WHERE", "ON", "INNER", "LEFT", "RIGHT", "FULL", "CROSS", "OUTER", "JOIN", "GROUP",
        "ORDER", "HAVING", "UNION", "SET", "VALUES", "OPTION", "APPLY", "WITH", "SELECT",
        "EXCEPT", "INTERSECT", "FOR", "PIVOT", "UNPIVOT", "TABLESAMPLE", "OUTPUT", "WHEN",
        "USING", "INSERT", "UPDATE", "DELETE", "MERGE", "DECLARE", "IF", "WHILE", "BEGIN",
        "END", "RETURN", "PRINT", "EXEC", "EXECUTE", "CREATE", "ALTER", "DROP", "GO"
    ]

    /// The routine call whose argument list contains the caret, if any.
    static func enclosingCall(tokens: [TSQLToken], offset: Int) -> (schema: String?, name: String)? {
        let significant = tokens.filter {
            $0.kind != .whitespace && $0.kind != .lineComment && $0.kind != .blockComment
        }
        var depth = 0
        var index = significant.count - 1
        while index >= 0 {
            let token = significant[index]
            guard token.start < offset else { index -= 1; continue }
            if token.kind == .punctuation && token.text == ")" { depth += 1 }
            if token.kind == .punctuation && token.text == "(" {
                if depth == 0 {
                    guard index > 0 else { return nil }
                    let nameToken = significant[index - 1]
                    guard nameToken.kind == .identifier || nameToken.kind == .quotedIdentifier
                            || nameToken.kind == .builtInFunction else { return nil }
                    var schema: String?
                    if index >= 3, significant[index - 2].text == "." {
                        schema = IntelliSenseCatalog.unquote(significant[index - 3].text)
                    }
                    return (schema, IntelliSenseCatalog.unquote(nameToken.text))
                }
                depth -= 1
            }
            index -= 1
        }
        return nil
    }
}
