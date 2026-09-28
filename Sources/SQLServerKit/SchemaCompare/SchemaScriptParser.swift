import Foundation

/// Builds a `SchemaSnapshot` from T-SQL creation scripts — a scripts folder, a single script
/// file, or anything else made of CREATE / ALTER / GRANT / sp_addextendedproperty statements.
///
/// Objects may be spread over any number of files in any order: a table's indexes, triggers,
/// permissions and constraints are collected as pending operations and attached once every
/// script has been read.
public struct SchemaScriptParser {

    public var defaultCollation: String
    public private(set) var warnings: [String] = []

    var objects: [String: SchemaObject] = [:]
    var order: [String] = []
    /// Work that needs another object to exist, applied in `snapshot()`.
    var pending: [PendingOperation] = []
    var quotedIdentifier = true
    var ansiNulls = true
    var currentFile = ""
    /// `ALTER TABLE … ADD DEFAULT … FOR col` whose column was not known yet.
    var pendingDefault: (String, DefaultConstraintDefinition)?
    /// Partition schemes written with `ALL TO (fg)`: scheme, function, filegroup.
    var pendingAllTo: [(String, String, String)] = []
    /// `sp_settriggerorder` on DML triggers: schema, trigger, event, order.
    var pendingTriggerOrders: [(String, String, String, String)] = []

    struct PendingOperation {
        /// Lowercased `schema.name`, or a bare name for schema-less objects.
        var target: String
        /// Types the target may be; empty accepts any.
        var types: Set<SchemaObjectType>
        var apply: (inout SchemaObject) -> Void
        var description: String
    }

    public init(defaultCollation: String = "") {
        self.defaultCollation = defaultCollation
    }

    // MARK: - Input

    public mutating func parse(script: String, file: String = "") {
        currentFile = file
        quotedIdentifier = true
        ansiNulls = true
        for batch in BatchSplitter.split(script) where !batch.isEmpty {
            for statement in statements(in: batch.text) {
                parseStatement(statement)
            }
        }
    }

    /// Splits a batch into statements. Module definitions (procedures, views, functions,
    /// triggers) take the rest of the batch, as T-SQL requires.
    func statements(in batch: String) -> [String] {
        let tokens = TSQLLexer().significantTokens(batch)
        guard !tokens.isEmpty else { return [] }
        let utf16 = Array(batch.utf16)
        var starts: [Int] = []
        var depth = 0
        var index = 0
        var moduleStarted = false
        while index < tokens.count {
            let token = tokens[index]
            let word = token.text.uppercased()
            if token.text == "(" { depth += 1 }
            if token.text == ")" { depth = max(0, depth - 1) }
            if depth == 0, !moduleStarted {
                let previous = index > 0 ? tokens[index - 1].text.uppercased() : ";"
                let next = index + 1 < tokens.count ? tokens[index + 1].text.uppercased() : ""
                if index == 0 || isStatementStart(word, previous: previous, next: next) {
                    starts.append(index)
                    if isModuleStart(tokens, at: index) { moduleStarted = true }
                }
            }
            index += 1
        }
        var result: [String] = []
        for (offset, start) in starts.enumerated() {
            let from = tokens[start].start
            let to: Int = offset + 1 < starts.count ? tokens[starts[offset + 1]].start : utf16.count
            var text = String(decoding: utf16[from..<to], as: UTF16.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            while text.hasSuffix(";") { text.removeLast() }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty, text != ";" { result.append(text) }
        }
        return result
    }

    private static let dropKinds: Set<String> =
        ["TABLE", "VIEW", "PROCEDURE", "PROC", "FUNCTION", "TRIGGER", "SYNONYM", "SEQUENCE", "TYPE", "SCHEMA",
         "USER", "ROLE", "INDEX", "DEFAULT", "RULE", "ASSEMBLY", "SECURITY", "AGGREGATE", "XML", "PARTITION",
         "FULLTEXT", "MESSAGE", "CONTRACT", "QUEUE", "SERVICE", "APPLICATION", "STATISTICS"]

    private static let sessionOptions: Set<String> =
        ["QUOTED_IDENTIFIER", "ANSI_NULLS", "ANSI_PADDING", "ANSI_WARNINGS", "NOCOUNT", "XACT_ABORT",
         "NUMERIC_ROUNDABORT", "ARITHABORT", "CONCAT_NULL_YIELDS_NULL", "TRANSACTION", "NOEXEC",
         "IDENTITY_INSERT", "LANGUAGE", "DATEFORMAT", "ANSI_NULL_DFLT_ON", "DEADLOCK_PRIORITY", "LOCK_TIMEOUT"]

    private func isStatementStart(_ word: String, previous: String, next: String) -> Bool {
        if previous == ";" { return true }
        switch word {
        case "CREATE", "USE", "PRINT", "DECLARE":
            return true
        case "ALTER":
            return !["OR", "GRANT", "DENY", "REVOKE", ","].contains(previous)
        case "GRANT", "DENY", "REVOKE":
            return previous != "WITH" && previous != "FOR"
        case "EXEC", "EXECUTE":
            return !["GRANT", "DENY", "REVOKE", "WITH", ",", "AS"].contains(previous)
        case "DROP":
            return SchemaScriptParser.dropKinds.contains(next) && previous != "ON"
        case "SET":
            return SchemaScriptParser.sessionOptions.contains(next)
        case "IF":
            return !SchemaScriptParser.dropKinds.contains(previous)
        case "DISABLE", "ENABLE":
            // Only on its own; inside ALTER TABLE it is part of that statement.
            return false
        case "BEGIN", "COMMIT", "ROLLBACK":
            return next == "TRAN" || next == "TRANSACTION"
        default:
            return false
        }
    }

    private func isModuleStart(_ tokens: [TSQLToken], at index: Int) -> Bool {
        var cursor = index
        let first = tokens[cursor].text.uppercased()
        guard first == "CREATE" || first == "ALTER" else { return false }
        cursor += 1
        if first == "CREATE", cursor + 1 < tokens.count, tokens[cursor].text.uppercased() == "OR" {
            cursor += 2
        }
        guard cursor < tokens.count else { return false }
        switch tokens[cursor].text.uppercased() {
        case "PROCEDURE", "PROC", "VIEW", "FUNCTION", "TRIGGER", "RULE", "AGGREGATE":
            return true
        case "DEFAULT":
            return first == "CREATE"
        default:
            return false
        }
    }

    // MARK: - Dispatch

    mutating func parseStatement(_ text: String) {
        var cursor = DDLTokenCursor(text)
        switch cursor.word() {
        case "SET":
            parseSet(&cursor)
        case "CREATE":
            parseCreate(text, &cursor)
        case "ALTER":
            parseAlter(text, &cursor)
        case "GRANT", "DENY":
            parsePermission(&cursor)
        case "EXEC", "EXECUTE":
            parseExec(&cursor)
        case "DISABLE", "ENABLE":
            parseTriggerState(&cursor)
        case "USE", "PRINT", "DECLARE", "BEGIN", "COMMIT", "ROLLBACK", "IF", "DROP", "REVOKE":
            return
        default:
            warn("Skipped a statement that is not a schema definition: \(Self.preview(text))")
        }
    }

    private mutating func parseSet(_ cursor: inout DDLTokenCursor) {
        cursor.advance()
        let option = cursor.word()
        let value = cursor.word(1) == "ON"
        if option == "QUOTED_IDENTIFIER" { quotedIdentifier = value }
        if option == "ANSI_NULLS" { ansiNulls = value }
    }

    private mutating func parseCreate(_ text: String, _ cursor: inout DDLTokenCursor) {
        cursor.advance()
        if cursor.matches(["OR", "ALTER"]) { cursor.advance(2) }
        switch cursor.word() {
        case "TABLE":
            cursor.advance()
            parseCreateTable(&cursor)
        case "PROCEDURE", "PROC", "VIEW", "FUNCTION", "RULE", "AGGREGATE":
            parseModule(text)
        case "DEFAULT":
            parseModule(text)
        case "TRIGGER":
            parseTrigger(text)
        case "XML" where cursor.word(1) == "SCHEMA":
            cursor.advance(3)
            guard let (schema, name) = cursor.objectName() else { return }
            add(SchemaObject(type: .xmlSchemaCollection, schema: schema, name: name, body: text))
        case "UNIQUE", "CLUSTERED", "NONCLUSTERED", "INDEX", "COLUMNSTORE", "PRIMARY", "XML", "SPATIAL":
            parseCreateIndex(&cursor)
        case "STATISTICS":
            cursor.advance()
            parseCreateStatistics(&cursor)
        case "FULLTEXT":
            cursor.advance()
            parseCreateFullText(text, &cursor)
        case "SCHEMA":
            cursor.advance()
            parseCreateSchema(&cursor)
        case "USER":
            cursor.advance()
            parseCreateUser(&cursor)
        case "ROLE":
            cursor.advance()
            parseCreateRole(&cursor)
        case "APPLICATION":
            cursor.advance(2)
            parseCreateApplicationRole(&cursor)
        case "TYPE":
            cursor.advance()
            parseCreateType(text, &cursor)
        case "SEQUENCE":
            cursor.advance()
            parseCreateSequence(&cursor)
        case "SYNONYM":
            cursor.advance()
            parseCreateSynonym(&cursor)
        case "PARTITION":
            parseCreatePartition(text, &cursor)
        case "ASSEMBLY":
            cursor.advance()
            guard let name = cursor.identifier() else { return }
            add(SchemaObject(type: .assembly, schema: "", name: name, body: text))
        case "SECURITY":
            cursor.advance(2)
            guard let (schema, name) = cursor.objectName() else { return }
            add(SchemaObject(type: .securityPolicy, schema: schema, name: name, body: text))
        case "MESSAGE":
            cursor.advance(2)
            guard let name = cursor.identifier() else { return }
            add(SchemaObject(type: .messageType, schema: "", name: name, body: text))
        case "CONTRACT":
            cursor.advance()
            guard let name = cursor.identifier() else { return }
            add(SchemaObject(type: .contract, schema: "", name: name, body: text))
        case "QUEUE":
            cursor.advance()
            guard let (schema, name) = cursor.objectName() else { return }
            add(SchemaObject(type: .queue, schema: schema, name: name, body: text))
        case "SERVICE":
            cursor.advance()
            guard let name = cursor.identifier() else { return }
            add(SchemaObject(type: .service, schema: "", name: name, body: text))
        default:
            warn("Skipped an unsupported CREATE statement: \(Self.preview(text))")
        }
    }

    private mutating func parseAlter(_ text: String, _ cursor: inout DDLTokenCursor) {
        cursor.advance()
        switch cursor.word() {
        case "TABLE":
            cursor.advance()
            parseAlterTable(&cursor)
        case "ROLE":
            cursor.advance()
            guard let role = cursor.identifier() else { return }
            if cursor.accept(["ADD", "MEMBER"]), let member = cursor.identifier() {
                addRoleMembership(role: role, member: member)
            }
        case "AUTHORIZATION":
            cursor.advance()
            parseAuthorization(&cursor)
        case "INDEX":
            cursor.advance()
            guard let index = cursor.identifier(), cursor.accept("ON"),
                  let (schema, table) = cursor.objectName() else { return }
            if cursor.accept("DISABLE") {
                attach(schema: schema, name: table, types: [.table, .view], "disable index \(index)") { object in
                    if let position = object.indexes.firstIndex(where: {
                        $0.name.caseInsensitiveCompare(index) == .orderedSame
                    }) {
                        object.indexes[position].isDisabled = true
                    }
                }
            }
        case "FULLTEXT":
            cursor.advance()
            if cursor.accept("STOPLIST"), let name = cursor.identifier() {
                let fragment = text
                attachNamed(name, types: [.fullTextStoplist], "stopword for \(name)") { object in
                    object.body += ";\n" + fragment
                    if !object.body.hasSuffix(";") { object.body += ";" }
                }
            }
        case "PROCEDURE", "PROC", "VIEW", "FUNCTION", "TRIGGER":
            // An ALTER script defines the object just as well as a CREATE one.
            parseModule(text)
        default:
            return
        }
    }

    // MARK: - Modules

    private mutating func parseModule(_ text: String) {
        guard let header = ModuleText.header(of: text) else {
            warn("Could not read the name of a module: \(Self.preview(text))")
            return
        }
        let parts = header.nameParts
        let name = parts.last ?? ""
        let schema = parts.count >= 2 ? parts[parts.count - 2] : "dbo"
        let type: SchemaObjectType
        var subtype = ""
        let cursor = DDLTokenCursor(text)
        switch header.kind {
        case "VIEW": type = .view
        case "PROCEDURE":
            type = .storedProcedure
            subtype = containsExternalName(cursor) ? "PC" : "P"
        case "FUNCTION":
            type = .function
            subtype = functionKind(cursor)
        case "AGGREGATE":
            type = .function
            subtype = "AF"
        case "RULE": type = .rule
        default: type = .defaultObject
        }
        let body = ModuleText.rewrite(text, verb: "CREATE", quotedName: SQLIdentifier.quote(schema: schema, name: name))
        var object = SchemaObject(type: type, schema: schema, name: name, body: body, subtype: subtype)
        object.usesQuotedIdentifier = quotedIdentifier
        object.usesAnsiNulls = ansiNulls
        object.isSchemaBound = isSchemaBound(cursor)
        add(object)
    }

    private func containsExternalName(_ cursor: DDLTokenCursor) -> Bool {
        for index in cursor.tokens.indices where index + 1 < cursor.tokens.count {
            if cursor.tokens[index].text.uppercased() == "EXTERNAL",
               cursor.tokens[index + 1].text.uppercased() == "NAME" { return true }
        }
        return false
    }

    private func functionKind(_ cursor: DDLTokenCursor) -> String {
        let external = containsExternalName(cursor)
        var depth = 0
        for (index, token) in cursor.tokens.enumerated() {
            if token.text == "(" { depth += 1 }
            if token.text == ")" { depth -= 1 }
            guard depth == 0, token.text.uppercased() == "RETURNS", index + 1 < cursor.tokens.count else { continue }
            let next = cursor.tokens[index + 1]
            if next.text.uppercased() == "TABLE" { return external ? "FT" : "IF" }
            if next.kind == .variable { return "TF" }
            return external ? "FS" : "FN"
        }
        return "FN"
    }

    private func isSchemaBound(_ cursor: DDLTokenCursor) -> Bool {
        var depth = 0
        var seenName = false
        for token in cursor.tokens {
            if token.text == "(" { depth += 1 }
            if token.text == ")" { depth -= 1 }
            let upper = token.text.uppercased()
            if upper == "SCHEMABINDING" { return true }
            if depth == 0, seenName, upper == "AS" || upper == "BEGIN" { return false }
            if ["VIEW", "FUNCTION", "PROCEDURE", "PROC", "TRIGGER"].contains(upper) { seenName = true }
        }
        return false
    }

    private mutating func parseTrigger(_ text: String) {
        guard let header = ModuleText.header(of: text) else { return }
        let name = header.nameParts.last ?? ""
        if header.isDatabaseTrigger {
            var object = SchemaObject(type: .ddlTrigger, schema: "", name: name,
                                      body: ModuleText.rewrite(text, verb: "CREATE", quotedName: SQLIdentifier.quote(name)))
            object.usesQuotedIdentifier = quotedIdentifier
            object.usesAnsiNulls = ansiNulls
            add(object)
            return
        }
        let targetParts = header.targetParts
        guard let targetName = targetParts.last else { return }
        let targetSchema = targetParts.count >= 2 ? targetParts[targetParts.count - 2]
            : (header.nameParts.count >= 2 ? header.nameParts[header.nameParts.count - 2] : "dbo")
        let trigger = TriggerDefinition(name: name, definition: text, isDisabled: false,
                                        usesQuotedIdentifier: quotedIdentifier, usesAnsiNulls: ansiNulls)
        attach(schema: targetSchema, name: targetName, types: [.table, .view], "trigger \(name)") { object in
            object.triggers.removeAll { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            object.triggers.append(trigger)
        }
    }

    private mutating func parseTriggerState(_ cursor: inout DDLTokenCursor) {
        let disable = cursor.word() == "DISABLE"
        cursor.advance()
        guard cursor.accept("TRIGGER") else { return }
        let parts = cursor.multipartName()
        guard let name = parts.last, cursor.accept("ON") else { return }
        if cursor.accept("DATABASE") {
            attachNamed(name, types: [.ddlTrigger], "trigger state \(name)") { object in
                object.subtype = disable ? "disabled" : ""
            }
            return
        }
        guard let (schema, table) = cursor.objectName() else { return }
        attach(schema: schema, name: table, types: [.table, .view], "trigger state \(name)") { object in
            if let index = object.triggers.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                object.triggers[index].isDisabled = disable
            }
        }
    }

    // MARK: - Bookkeeping

    mutating func add(_ object: SchemaObject) {
        let key = object.key.matchKey
        if objects[key] == nil {
            order.append(key)
        } else {
            warn("\(object.type.title) \(object.qualifiedName) is defined more than once; the last definition wins.")
        }
        objects[key] = object
    }

    /// Queue work against a schema-scoped object that may not have been read yet.
    mutating func attach(schema: String, name: String, types: Set<SchemaObjectType>, _ description: String,
                         apply: @escaping (inout SchemaObject) -> Void) {
        pending.append(PendingOperation(target: "\(schema.lowercased()).\(name.lowercased())", types: types,
                                        apply: apply, description: description))
    }

    /// Queue work against an object without a schema (principals, schemas, DDL triggers, …).
    mutating func attachNamed(_ name: String, types: Set<SchemaObjectType>, _ description: String,
                             apply: @escaping (inout SchemaObject) -> Void) {
        pending.append(PendingOperation(target: name.lowercased(), types: types, apply: apply,
                                        description: description))
    }

    mutating func warn(_ message: String) {
        let location = currentFile.isEmpty ? "" : "\(currentFile): "
        warnings.append(location + message)
    }

    static func preview(_ text: String) -> String {
        let line = text.split(separator: "\n").first.map(String.init) ?? text
        return String(line.prefix(100))
    }

    // MARK: - Output

    public func snapshot(origin: String, databaseName: String = "", compatibilityLevel: Int = 0) -> SchemaSnapshot {
        var result = objects
        var unresolved: [String] = []
        for operation in pending {
            let candidates = result.keys.filter { key in
                guard let object = result[key] else { return false }
                if !operation.types.isEmpty, !operation.types.contains(object.type) { return false }
                let identity = object.type.isSchemaScoped
                    ? "\(object.schema.lowercased()).\(object.name.lowercased())" : object.name.lowercased()
                return identity == operation.target
            }
            guard let key = candidates.sorted().first, var object = result[key] else {
                unresolved.append(operation.description)
                continue
            }
            operation.apply(&object)
            result[key] = object
        }
        for (scheme, function, filegroup) in pendingAllTo {
            let functionKey = SchemaObjectKey(type: .partitionFunction, schema: "", name: function).matchKey
            let schemeKey = SchemaObjectKey(type: .partitionScheme, schema: "", name: scheme).matchKey
            guard let functionObject = result[functionKey], var schemeObject = result[schemeKey] else { continue }
            let boundaries = Self.boundaryCount(functionObject.body)
            let list = Array(repeating: filegroup, count: boundaries + 1).joined(separator: ", ")
            if let range = schemeObject.body.range(of: "TO (", options: .backwards) {
                schemeObject.body = String(schemeObject.body[..<range.lowerBound]) + "TO (" + list + ")"
                result[schemeKey] = schemeObject
            }
        }
        for (schema, trigger, event, triggerOrder) in pendingTriggerOrders {
            for key in result.keys.sorted() {
                guard var object = result[key], object.schema.lowercased() == schema,
                      let index = object.triggers.firstIndex(where: { $0.name.lowercased() == trigger }) else { continue }
                if triggerOrder == "None" {
                    object.triggers[index].order.removeValue(forKey: event)
                } else {
                    object.triggers[index].order[event] = triggerOrder
                }
                result[key] = object
                break
            }
        }
        var output: [SchemaObject] = order.compactMap { result[$0] }
        output = resolveReferences(output)
        output.sort { $0.key < $1.key }
        var notes = warnings
        for description in Set(unresolved).sorted() {
            notes.append("Nothing to attach \(description) to: the object it belongs to is not in the scripts.")
        }
        return SchemaSnapshot(origin: origin, databaseName: databaseName, serverVersion: "",
                              compatibilityLevel: compatibilityLevel, defaultCollation: defaultCollation,
                              createdAt: Date(), objects: output, warnings: notes)
    }

    /// Dependencies found by name, standing in for sys.sql_expression_dependencies.
    private func resolveReferences(_ input: [SchemaObject]) -> [SchemaObject] {
        var byNamespace: [String: SchemaObjectKey] = [:]
        var existing: Set<String> = []
        for object in input {
            existing.insert(object.key.matchKey)
            if object.type.isSchemaScoped { byNamespace[object.key.namespaceKey] = object.key }
        }
        return input.map { original in
            var object = original
            var refs: Set<SchemaObjectKey> = []
            if object.type.isSchemaScoped { refs.insert(SchemaObjectKey(type: .schema, schema: "", name: object.schema)) }
            var texts: [String] = []
            if object.type.isModule || object.type == .storedProcedure || object.type == .function
                || object.type == .securityPolicy || object.type == .queue || object.type == .tableType
                || object.type == .sequence {
                texts.append(object.body)
            }
            if let table = object.table {
                for column in table.columns {
                    if column.isUserDefinedType {
                        texts.append(column.dataType)
                    }
                    if column.dataType.lowercased().hasPrefix("xml(") { texts.append(column.dataType) }
                    if let expression = column.computedExpression { texts.append(expression) }
                    if let constraint = column.defaultConstraint { texts.append(constraint.definition) }
                    if let rule = column.boundRule { texts.append(rule) }
                    if let bound = column.boundDefault { texts.append(bound) }
                }
                for check in table.checkConstraints { texts.append(check.definition) }
                if let temporal = table.temporal, let history = temporal.historyTable {
                    refs.insert(SchemaObjectKey(type: .table, schema: temporal.historySchema ?? object.schema, name: history))
                }
                if let fullText = table.fullTextIndex {
                    refs.insert(SchemaObjectKey(type: .fullTextCatalog, schema: "", name: fullText.catalog))
                }
                if !table.dataSpace.isEmpty {
                    refs.insert(SchemaObjectKey(type: .partitionScheme, schema: "", name: table.dataSpace))
                }
            }
            for text in texts {
                for name in ModuleText.referencedNames(in: text, defaultSchema: object.schema.isEmpty ? "dbo" : object.schema) {
                    if let key = byNamespace[name], key != object.key { refs.insert(key) }
                }
            }
            if let owner = object.owner {
                refs.insert(SchemaObjectKey(type: .user, schema: "", name: owner))
                refs.insert(SchemaObjectKey(type: .role, schema: "", name: owner))
            }
            for role in object.roleMemberships { refs.insert(SchemaObjectKey(type: .role, schema: "", name: role)) }
            if object.type == .partitionScheme, let function = Self.partitionFunctionName(object.body) {
                refs.insert(SchemaObjectKey(type: .partitionFunction, schema: "", name: function))
            }
            object.references = refs.filter { existing.contains($0.matchKey) && $0 != object.key }.sorted()
            object.permissions.sort()
            object.extendedProperties.sort()
            object.indexes.sort { $0.name.lowercased() < $1.name.lowercased() }
            object.triggers.sort { $0.name.lowercased() < $1.name.lowercased() }
            object.statistics.sort { $0.name.lowercased() < $1.name.lowercased() }
            return object
        }
    }

    static func boundaryCount(_ functionBody: String) -> Int {
        guard let range = functionBody.range(of: "FOR VALUES (", options: .caseInsensitive) else { return 0 }
        var cursor = DDLTokenCursor("(" + functionBody[range.upperBound...])
        return cursor.parenthesizedList().count
    }

    static func partitionFunctionName(_ body: String) -> String? {
        var cursor = DDLTokenCursor(body)
        while !cursor.isAtEnd {
            if cursor.accept(["AS", "PARTITION"]) { return cursor.identifier() }
            cursor.advance()
        }
        return nil
    }
}
