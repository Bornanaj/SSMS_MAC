import Foundation
import TDSKit

/// A schema-qualified object, for saying which one still needs reading.
public struct ObjectReference: Sendable, Hashable {
    public var schema: String
    public var name: String

    public init(schema: String, name: String) {
        self.schema = schema
        self.name = name
    }
}

/// Works out what to offer at a caret position, from a catalog it is handed.
///
/// Deliberately pure and synchronous. Completion runs on every keystroke, and when
/// this logic lived on the actor that also owns the connection, one slow read put the
/// whole editor behind it — and nothing here could be tested without a server. The
/// actor keeps the catalog and the I/O; this decides what the list says.
public struct CompletionEngine: Sendable {
    public let catalog: IntelliSenseCatalog?
    /// Insert `table AS alias` when completing a table reference, the way SQL Prompt does.
    public let generatesAliases: Bool
    private let lexer = TSQLLexer()

    public init(catalog: IntelliSenseCatalog?, generatesAliases: Bool = true) {
        self.catalog = catalog
        self.generatesAliases = generatesAliases
    }

    /// The whole answer for one caret position, with no I/O anywhere in it.
    public func result(script: String, offset: Int) -> CompletionResult {
        let tokens = lexer.tokenize(script)
        let context = IntelliSenseContext.analyse(tokens: tokens, offset: offset)
        if context.isSuppressed {
            // Reported as a member context so the editor shows nothing rather than
            // falling back to the keyword list.
            return CompletionResult(items: [], isMemberContext: true, hasCatalog: catalog != nil)
        }

        let isMemberContext: Bool
        if case .memberOf(_) = context.kind {
            isMemberContext = true
        } else {
            isMemberContext = false
        }
        func answer(_ items: [CompletionItem]) -> CompletionResult {
            CompletionResult(items: items, isMemberContext: isMemberContext,
                             hasCatalog: catalog != nil,
                             pendingColumns: unreadTables(in: context.sources))
        }

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
                return answer(items + columnCompletions(context: context, catalog: catalog))
            }
        }

        switch context.kind {
        case .memberOf(let qualifier):
            // "EXEC sales." must not offer tables, so honour the surrounding statement.
            if context.prefersRoutines, let catalog,
               catalog.schemas.contains(where: { $0.caseInsensitiveCompare(
                   IntelliSenseCatalog.unquote(qualifier)) == .orderedSame }) {
                return answer(catalog.routines
                    .filter { $0.schema.caseInsensitiveCompare(
                        IntelliSenseCatalog.unquote(qualifier)) == .orderedSame }
                    .map { CompletionItem.make(label: $0.name,
                                               kind: $0.kind == "procedure" ? .procedure : .function,
                                               detail: $0.qualifiedName, priority: 60) })
            }
            // Columns the catalog has not read yet are not fetched here: this method
            // is called on every keystroke, and a query in the middle of it would make
            // the whole editor wait. The caller is told what to read instead.
            let members = memberCompletions(qualifier: qualifier, context: context,
                                            catalog: catalog)
            var memberAnswer = answer(members.items)
            if members.items.isEmpty {
                // Nothing to offer after a dot is the one case where silence is
                // indistinguishable from a broken editor, so it says why.
                memberAnswer.message = emptyMemberReason(qualifier: qualifier,
                                                         context: context,
                                                         pending: members.pendingColumns)
            }
            return memberAnswer

        case .tableReference:
            let aliases = generatesAliases
                ? SQLAssist.aliasesInScope(script: script, offset: offset)
                : []
            // Only a table reference takes an alias; the same table offered inside a
            // SELECT list or a WHERE clause must insert its bare name.
            return answer(localTableCompletions(context: context)
                + tableCompletions(catalog: catalog, aliasesInScope: aliases,
                                   withAliases: generatesAliases)
                + schemaCompletions(catalog: catalog))

        case .procedureReference:
            return answer(routineCompletions(catalog: catalog, kindFilter: "procedure"))

        case .columnReference:
            return answer(columnCompletions(context: context, catalog: catalog)
                + tableCompletions(catalog: catalog)
                + keywordCompletions())

        case .variable:
            return answer(variableCompletions(context: context))

        case .general:
            return answer(keywordCompletions()
                + tableCompletions(catalog: catalog)
                + routineCompletions(catalog: catalog, kindFilter: nil))
        }
    }

    /// The sentence shown in place of a member list that came back empty.
    private func emptyMemberReason(qualifier: String, context: IntelliSenseContext,
                                   pending: ObjectReference?) -> String {
        guard let catalog else {
            return "IntelliSense has not read this database yet"
        }
        if let pending {
            return "Reading the columns of \(pending.schema).\(pending.name)…"
        }
        let bare = IntelliSenseCatalog.unquote(qualifier)
        if let foreign = context.sources.first(where: { $0.isCalled(bare) && isInAnotherDatabase($0) }),
           let database = foreign.database {
            return "IntelliSense has read \(catalog.database) only, not \(database)"
        }
        if let local = context.sources.first(where: { $0.isCalled(bare) && $0.local != nil })?.local {
            return "\(local.description) has no named columns"
        }
        if !catalog.isComplete {
            return "IntelliSense is still reading \(catalog.database)…"
        }
        return "No table, view or alias called \(bare) is in scope"
    }

    // MARK: - Builders

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
                                  aliasesInScope: Set<String> = [],
                                  withAliases: Bool = false) -> [CompletionItem] {
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
            if withAliases {
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
        var items: [CompletionItem] = []
        var seen = Set<String>()

        for source in context.sources {
            let columns = columns(of: source)
            guard !columns.isEmpty else { continue }
            let origin = source.local?.description
                ?? catalog?.object(named: source.table, schema: source.schema)?.qualifiedName
                ?? source.table
            for column in columns {
                let key = column.name.lowercased()
                // A name that appears in two sources still deserves one entry each,
                // qualified by the alias so the user can tell them apart.
                let qualifier = source.alias ?? source.table
                let detail = "\(qualifier) · \(describe(column, origin: origin))"
                var item = CompletionItem.make(label: column.name,
                                               kind: .column,
                                               detail: detail,
                                               documentation: column.isPrimaryKey
                                                   ? "Primary key" : "",
                                               priority: seen.insert(key).inserted ? 50 : 60)
                // The same column name in two sources is two entries, so the id has to
                // carry the source: the popup keys its rows by it.
                item.id = "column:\(qualifier.lowercased()).\(column.name.lowercased())"
                items.append(item)
            }
            if let alias = source.alias, alias.caseInsensitiveCompare(source.table) != .orderedSame {
                items.append(.make(label: alias, kind: .alias, detail: origin, priority: 40))
            }
        }
        return items
    }

    /// CTEs, temp tables and table variables the script has defined by the caret.
    private func localTableCompletions(context: IntelliSenseContext) -> [CompletionItem] {
        context.localDefinitions.map { definition in
            CompletionItem(id: "local:\(definition.name.lowercased())",
                           label: definition.name, kind: .table,
                           detail: definition.description, documentation: "",
                           insertText: definition.name, sortPriority: 90)
        }
    }

    /// The type and nullability of a catalog column, or where a column with no
    /// type information came from.
    private func describe(_ column: IntelliSenseColumn, origin: String) -> String {
        guard !column.typeName.isEmpty else { return origin }
        return column.typeName + (column.isNullable ? ", null" : ", not null")
    }

    /// The columns a source has: the catalog's for a table, its own definition's for
    /// a CTE, a derived table, a temp table or a table variable.
    private func columns(of source: IntelliSenseContext.Source, depth: Int = 0) -> [IntelliSenseColumn] {
        if let local = source.local { return columns(of: local, depth: depth) }
        guard let catalog, !isInAnotherDatabase(source),
              let object = catalog.object(named: source.table, schema: source.schema)
        else { return [] }
        return object.columns
    }

    /// A three-part name for a database the catalog does not cover. Answering it
    /// from a same-named table in this database would be a wrong answer, not a guess.
    private func isInAnotherDatabase(_ source: IntelliSenseContext.Source) -> Bool {
        guard let database = source.database, let catalog else { return false }
        return database.caseInsensitiveCompare(catalog.database) != .orderedSame
    }

    private func columns(of definition: LocalDefinition, depth: Int) -> [IntelliSenseColumn] {
        // A CTE built on a CTE built on a CTE ends somewhere; a cycle does not.
        guard depth < 8 else { return [] }
        var result: [IntelliSenseColumn] = []
        for column in definition.columns {
            switch column {
            case .named(let name):
                result.append(IntelliSenseColumn(name: name, typeName: "", isNullable: true,
                                                 isPrimaryKey: false, ordinal: result.count + 1))
            case .star(let qualifier):
                for source in definition.sources
                where qualifier.map(source.isCalled) ?? true {
                    for column in columns(of: source, depth: depth + 1) {
                        var copy = column
                        copy.ordinal = result.count + 1
                        result.append(copy)
                    }
                }
            }
        }
        return result
    }

    /// Every table the sources in scope read, directly or through a CTE, whose
    /// columns have not arrived yet: the window fetches them and asks again.
    private func unreadTables(in sources: [IntelliSenseContext.Source]) -> [ObjectReference] {
        var seen = Set<ObjectReference>()
        return sources.flatMap { unreadTables(of: $0) }.filter { seen.insert($0).inserted }
    }

    /// Catalog tables a definition reads through a star whose columns have not been
    /// read yet, so the caller can fetch them.
    private func unreadTables(of source: IntelliSenseContext.Source, depth: Int = 0) -> [ObjectReference] {
        guard depth < 8 else { return [] }
        if let local = source.local {
            return local.columns.flatMap { column -> [ObjectReference] in
                guard case .star(let qualifier) = column else { return [] }
                return local.sources
                    .filter { qualifier.map($0.isCalled) ?? true }
                    .flatMap { unreadTables(of: $0, depth: depth + 1) }
            }
        }
        guard let catalog, !isInAnotherDatabase(source),
              let object = catalog.object(named: source.table, schema: source.schema),
              object.columns.isEmpty else { return [] }
        return [ObjectReference(schema: object.schema, name: object.name)]
    }

    /// Members of a qualifier, plus the object whose columns have to be read before
    /// this can be answered properly.
    private func memberCompletions(qualifier: String,
                                   context: IntelliSenseContext,
                                   catalog: IntelliSenseCatalog?)
        -> (items: [CompletionItem], pendingColumns: ObjectReference?) {
        let bare = IntelliSenseCatalog.unquote(qualifier)

        // An alias or table in the current statement wins over a schema of the same
        // name. Several sources can be called the same thing (UPDATE o … FROM … o);
        // the first that has columns answers.
        var pending: ObjectReference?
        for source in context.sources where source.isCalled(bare) {
            let columns = columns(of: source)
            if columns.isEmpty {
                pending = pending ?? unreadTables(of: source).first
                continue
            }
            let origin = source.local?.description
                ?? catalog?.object(named: source.table, schema: source.schema)?.qualifiedName
                ?? source.table
            return (columns.map { column in
                CompletionItem.make(label: column.name, kind: .column,
                                    detail: describe(column, origin: origin),
                                    documentation: column.isPrimaryKey ? "Primary key" : "",
                                    priority: column.ordinal)
            }, nil)
        }
        if let pending { return ([], pending) }
        guard let catalog else { return ([], nil) }

        if let object = catalog.object(named: bare, schema: nil) {
            let pending = object.columns.isEmpty
                ? ObjectReference(schema: object.schema, name: object.name)
                : nil
            return (object.columns.map { column in
                CompletionItem.make(label: column.name, kind: .column,
                                    detail: column.typeName, priority: column.ordinal)
            }, pending)
        }

        if catalog.schemas.contains(where: { $0.caseInsensitiveCompare(bare) == .orderedSame }) {
            let tables = catalog.tables.filter {
                $0.schema.caseInsensitiveCompare(bare) == .orderedSame
            }
            let routines = catalog.routines.filter {
                $0.schema.caseInsensitiveCompare(bare) == .orderedSame
            }
            return (tables.map {
                CompletionItem.make(label: $0.name, kind: $0.kind == "view" ? .view : .table,
                                    detail: $0.qualifiedName, priority: 60)
            } + routines.map {
                CompletionItem.make(label: $0.name,
                                    kind: $0.kind == "procedure" ? .procedure : .function,
                                    detail: $0.qualifiedName, priority: 80)
            }, nil)
        }

        return ([], nil)
    }

    private func variableCompletions(context: IntelliSenseContext) -> [CompletionItem] {
        context.variables.map {
            CompletionItem(id: "variable:\($0)", label: $0, kind: .variable,
                           detail: "local variable", documentation: "",
                           insertText: $0, sortPriority: 20)
        }
    }

}
