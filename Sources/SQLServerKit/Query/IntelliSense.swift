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

    public init(database: String, fetchedAt: Date, schemas: [String],
                tables: [IntelliSenseObject], routines: [IntelliSenseObject],
                relationships: [IntelliSenseRelationship] = []) {
        self.database = database
        self.fetchedAt = fetchedAt
        self.schemas = schemas
        self.tables = tables
        self.routines = routines
        self.relationships = relationships
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

    func object(named name: String, schema: String?) -> IntelliSenseObject? {
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

    func routine(named name: String, schema: String?) -> IntelliSenseObject? {
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

    @discardableResult
    public func refresh(database: String) async throws -> IntelliSenseCatalog {
        let tables = try await loadTables(database: database)
        let routines = try await loadRoutines(database: database)
        let relationships = try await loadRelationships(database: database)
        let schemas = Set(tables.map(\.schema)).union(routines.map(\.schema)).sorted()
        let catalog = IntelliSenseCatalog(database: database, fetchedAt: Date(),
                                          schemas: schemas, tables: tables, routines: routines,
                                          relationships: relationships)
        catalogs[database.lowercased()] = catalog
        return catalog
    }

    // MARK: Completion

    /// Insert `table AS alias` when completing a table reference, the way SQL Prompt does.
    public var generatesAliases = true

    public func setGeneratesAliases(_ value: Bool) {
        generatesAliases = value
    }

    public func completions(script: String, offset: Int, database: String) async -> [CompletionItem] {
        let catalog = catalogs[database.lowercased()]
        let tokens = lexer.tokenize(script)
        let context = IntelliSenseContext.analyse(tokens: tokens, offset: offset)

        // An ON clause with more than one table in scope is asking for the foreign key
        // that already describes the relationship.
        if context.isJoinCondition, let catalog, context.sources.count >= 2,
           let joined = context.sources.last {
            let suggestions = SQLAssist.joinConditions(
                script: script, offset: offset,
                joining: joined.table, alias: joined.alias, catalog: catalog)
            if !suggestions.isEmpty {
                let items = suggestions.map { suggestion in
                    CompletionItem(id: "join:\(suggestion.condition)",
                                   label: suggestion.condition,
                                   kind: .snippet,
                                   detail: suggestion.constraintName,
                                   documentation: "Foreign key \(suggestion.detail)",
                                   insertText: suggestion.condition,
                                   sortPriority: 0)
                }
                return items + columnCompletions(context: context, catalog: catalog)
            }
        }

        switch context.kind {
        case .memberOf(let qualifier):
            // "EXEC sales." must not offer tables, so honour the surrounding statement.
            if context.prefersRoutines, let catalog,
               catalog.schemas.contains(where: { $0.caseInsensitiveCompare(
                   IntelliSenseCatalog.unquote(qualifier)) == .orderedSame }) {
                return catalog.routines
                    .filter { $0.schema.caseInsensitiveCompare(
                        IntelliSenseCatalog.unquote(qualifier)) == .orderedSame }
                    .map { CompletionItem.make(label: $0.name,
                                               kind: $0.kind == "procedure" ? .procedure : .function,
                                               detail: $0.qualifiedName, priority: 60) }
            }
            return memberCompletions(qualifier: qualifier, context: context, catalog: catalog)

        case .tableReference:
            let aliases = generatesAliases
                ? SQLAssist.aliasesInScope(script: script, offset: offset)
                : []
            return tableCompletions(catalog: catalog, aliasesInScope: aliases)
                + schemaCompletions(catalog: catalog)

        case .procedureReference:
            return routineCompletions(catalog: catalog, kindFilter: "procedure")

        case .columnReference:
            return columnCompletions(context: context, catalog: catalog)
                + tableCompletions(catalog: catalog)
                + keywordCompletions()

        case .variable:
            return variableCompletions(context: context)

        case .general:
            return keywordCompletions()
                + tableCompletions(catalog: catalog)
                + routineCompletions(catalog: catalog, kindFilter: nil)
        }
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

    // MARK: Completion builders

    private func keywordCompletions() -> [CompletionItem] {
        var items: [CompletionItem] = []
        for keyword in TSQLKeywords.reserved {
            items.append(.make(label: keyword, kind: .keyword, detail: "keyword", priority: 400))
        }
        for type in TSQLKeywords.dataTypes {
            items.append(.make(label: type, kind: .dataType, detail: "data type", priority: 380))
        }
        for function in TSQLKeywords.functions where !function.hasPrefix("@") {
            items.append(.make(label: function, kind: .function, detail: "built-in function",
                               priority: 360))
        }
        return items
    }

    private func tableCompletions(catalog: IntelliSenseCatalog?,
                                  aliasesInScope: Set<String> = []) -> [CompletionItem] {
        guard let catalog else { return [] }
        return catalog.tables.map { object in
            var item = CompletionItem.make(
                label: object.name,
                kind: object.kind == "view" ? .view : .table,
                detail: object.qualifiedName,
                documentation: object.columns.prefix(8)
                    .map { "\($0.name) \($0.typeName)" }
                    .joined(separator: "\n")
                    + (object.columns.count > 8 ? "\n… \(object.columns.count - 8) more" : ""),
                priority: object.schema.lowercased() == "dbo" ? 100 : 140)
            if generatesAliases, !aliasesInScope.isEmpty || true {
                let alias = SQLAssist.suggestedAlias(for: object.name, existing: aliasesInScope)
                item.insertText += " AS \(alias)"
            }
            return item
        }
    }

    private func schemaCompletions(catalog: IntelliSenseCatalog?) -> [CompletionItem] {
        guard let catalog else { return [] }
        return catalog.schemas.map {
            CompletionItem.make(label: $0, kind: .schema, detail: "schema", priority: 200)
        }
    }

    private func routineCompletions(catalog: IntelliSenseCatalog?,
                                    kindFilter: String?) -> [CompletionItem] {
        guard let catalog else { return [] }
        return catalog.routines
            .filter { kindFilter == nil || $0.kind == kindFilter }
            .map { object in
                let signature = object.parameters
                    .map { "\($0.name) \($0.typeName)" }
                    .joined(separator: ", ")
                return CompletionItem.make(
                    label: object.name,
                    kind: object.kind == "procedure" ? .procedure : .function,
                    detail: object.qualifiedName,
                    documentation: signature,
                    priority: 150)
            }
    }

    private func columnCompletions(context: IntelliSenseContext,
                                   catalog: IntelliSenseCatalog?) -> [CompletionItem] {
        guard let catalog else { return [] }
        var items: [CompletionItem] = []
        var seen = Set<String>()

        for source in context.sources {
            guard let object = catalog.object(named: source.table, schema: source.schema) else { continue }
            for column in object.columns {
                let key = column.name.lowercased()
                // A name that appears in two sources still deserves one entry each,
                // qualified by the alias so the user can tell them apart.
                let detail = "\(source.alias ?? object.name) · \(column.typeName)"
                    + (column.isNullable ? ", null" : ", not null")
                items.append(.make(label: column.name,
                                   kind: .column,
                                   detail: detail,
                                   documentation: column.isPrimaryKey ? "Primary key" : "",
                                   priority: seen.insert(key).inserted ? 50 : 60))
            }
            if let alias = source.alias {
                items.append(.make(label: alias, kind: .alias,
                                   detail: object.qualifiedName, priority: 40))
            }
        }
        return items
    }

    private func memberCompletions(qualifier: String,
                                   context: IntelliSenseContext,
                                   catalog: IntelliSenseCatalog?) -> [CompletionItem] {
        guard let catalog else { return [] }
        let bare = IntelliSenseCatalog.unquote(qualifier)

        // An alias in the current statement wins over a schema of the same name.
        if let source = context.sources.first(where: {
            $0.alias?.caseInsensitiveCompare(bare) == .orderedSame
                || $0.table.caseInsensitiveCompare(bare) == .orderedSame
        }), let object = catalog.object(named: source.table, schema: source.schema) {
            return object.columns.map { column in
                CompletionItem.make(label: column.name, kind: .column,
                                    detail: "\(column.typeName)"
                                        + (column.isNullable ? ", null" : ", not null"),
                                    documentation: column.isPrimaryKey ? "Primary key" : "",
                                    priority: column.ordinal)
            }
        }

        if let object = catalog.object(named: bare, schema: nil) {
            return object.columns.map { column in
                CompletionItem.make(label: column.name, kind: .column,
                                    detail: column.typeName, priority: column.ordinal)
            }
        }

        if catalog.schemas.contains(where: { $0.caseInsensitiveCompare(bare) == .orderedSame }) {
            let tables = catalog.tables.filter {
                $0.schema.caseInsensitiveCompare(bare) == .orderedSame
            }
            let routines = catalog.routines.filter {
                $0.schema.caseInsensitiveCompare(bare) == .orderedSame
            }
            return tables.map {
                CompletionItem.make(label: $0.name, kind: $0.kind == "view" ? .view : .table,
                                    detail: $0.qualifiedName, priority: 60)
            } + routines.map {
                CompletionItem.make(label: $0.name,
                                    kind: $0.kind == "procedure" ? .procedure : .function,
                                    detail: $0.qualifiedName, priority: 80)
            }
        }

        return []
    }

    private func variableCompletions(context: IntelliSenseContext) -> [CompletionItem] {
        context.variables.map {
            CompletionItem(id: "variable:\($0)", label: $0, kind: .variable,
                           detail: "local variable", documentation: "",
                           insertText: $0, sortPriority: 20)
        }
    }

    // MARK: Catalog loading

    private func loadTables(database: String) async throws -> [IntelliSenseObject] {
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
        OUTER APPLY (
            SELECT TOP (1) ic.column_id
            FROM sys.indexes AS i
            JOIN sys.index_columns AS ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id
            WHERE i.object_id = o.object_id AND i.is_primary_key = 1 AND ic.column_id = c.column_id
        ) AS pk
        WHERE o.type IN ('U', 'V') AND o.is_ms_shipped = 0
        ORDER BY s.name, o.name, c.column_id
        """
        let result = try await session.metadataQuery(sql, database: database)
        return IntelliSenseProvider.groupObjects(result.resultSets.first?.dictionaries() ?? [],
                                                 isRoutine: false)
    }

    private func loadRoutines(database: String) async throws -> [IntelliSenseObject] {
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
        let result = try await session.metadataQuery(sql, database: database)
        return IntelliSenseProvider.groupObjects(result.resultSets.first?.dictionaries() ?? [],
                                                 isRoutine: true)
    }

    private func loadRelationships(database: String) async throws -> [IntelliSenseRelationship] {
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
        let result = try await session.metadataQuery(sql, database: database)
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
        var schema: String?
        var table: String
        var alias: String?
    }

    var kind: Kind = .general
    var sources: [Source] = []
    var variables: [String] = []
    /// True when the statement is an EXEC, so only routines make sense.
    var prefersRoutines = false
    /// True when the caret sits in a JOIN ... ON clause.
    var isJoinCondition = false

    static func analyse(tokens: [TSQLToken], offset: Int) -> IntelliSenseContext {
        var context = IntelliSenseContext()
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
        context.sources = parseSources(significant, in: statement)

        let current = significant[caretIndex]
        let isPartialWord = current.start + current.length == offset
            && (current.kind == .identifier || current.kind == .keyword
                || current.kind == .dataType || current.kind == .builtInFunction)
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
                if qualifier.kind == .identifier || qualifier.kind == .quotedIdentifier {
                    context.kind = .memberOf(qualifier.text)
                    return context
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
        var start = 0
        var end = tokens.count
        var cursor = index
        while cursor > 0 {
            let token = tokens[cursor]
            if token.kind == .punctuation && token.text == ";" { start = cursor + 1; break }
            if token.kind == .keyword && token.text.caseInsensitiveCompare("GO") == .orderedSame {
                start = cursor + 1
                break
            }
            cursor -= 1
        }
        cursor = index + 1
        while cursor < tokens.count {
            let token = tokens[cursor]
            if token.kind == .punctuation && token.text == ";" { end = cursor; break }
            cursor += 1
        }
        return start..<max(start, end)
    }

    /// Pull `table alias` and `table AS alias` pairs out of FROM/JOIN clauses.
    private static func parseSources(_ tokens: [TSQLToken], in range: Range<Int>) -> [Source] {
        var sources: [Source] = []
        var index = range.lowerBound

        func readName(_ start: inout Int) -> (schema: String?, name: String)? {
            guard start < range.upperBound else { return nil }
            var parts: [String] = []
            while start < range.upperBound {
                let token = tokens[start]
                guard token.kind == .identifier || token.kind == .quotedIdentifier
                        || token.kind == .tempTable else { break }
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
            return (schema.map(IntelliSenseCatalog.unquote), IntelliSenseCatalog.unquote(name))
        }

        while index < range.upperBound {
            let token = tokens[index]
            let upper = token.text.uppercased()
            guard token.kind == .keyword || token.kind == .identifier,
                  upper == "FROM" || upper == "JOIN" || upper == "UPDATE" || upper == "INTO" else {
                index += 1
                continue
            }
            index += 1
            guard let reference = readName(&index) else { continue }

            var alias: String?
            if index < range.upperBound {
                let next = tokens[index]
                if next.text.caseInsensitiveCompare("AS") == .orderedSame {
                    index += 1
                    if index < range.upperBound,
                       tokens[index].kind == .identifier || tokens[index].kind == .quotedIdentifier {
                        alias = IntelliSenseCatalog.unquote(tokens[index].text)
                        index += 1
                    }
                } else if next.kind == .identifier,
                          !IntelliSenseContext.clauseBoundaries.contains(next.text.uppercased()) {
                    alias = IntelliSenseCatalog.unquote(next.text)
                    index += 1
                }
            }
            sources.append(Source(schema: reference.schema, table: reference.name, alias: alias))
        }
        return sources
    }

    private static let clauseBoundaries: Set<String> = [
        "WHERE", "ON", "INNER", "LEFT", "RIGHT", "FULL", "CROSS", "OUTER", "JOIN", "GROUP",
        "ORDER", "HAVING", "UNION", "SET", "VALUES", "OPTION", "APPLY", "WITH", "SELECT"
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
