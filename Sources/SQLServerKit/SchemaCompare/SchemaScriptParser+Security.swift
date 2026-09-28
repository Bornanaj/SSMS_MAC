import Foundation

/// Principals, schemas, types, sequences, synonyms, partitioning, permissions, extended
/// properties and the system procedures scripts use to set them.
extension SchemaScriptParser {

    // MARK: - Schemas and principals

    mutating func parseCreateSchema(_ cursor: inout DDLTokenCursor) {
        guard let name = cursor.identifier() else { return }
        var object = SchemaObject(type: .schema, schema: "", name: name)
        object.owner = cursor.accept("AUTHORIZATION") ? (cursor.identifier() ?? "dbo") : "dbo"
        add(object)
    }

    mutating func parseCreateUser(_ cursor: inout DDLTokenCursor) {
        guard let name = cursor.identifier() else { return }
        var type = "S"
        var authentication = "INSTANCE"
        var login = name
        var defaultSchema: String?
        var certificate = ""
        var asymmetricKey = ""
        while !cursor.isAtEnd {
            if cursor.accept(["FOR", "LOGIN"]) || cursor.accept(["FROM", "LOGIN"]) {
                login = cursor.identifier() ?? name
            } else if cursor.accept(["WITHOUT", "LOGIN"]) {
                authentication = "NONE"
            } else if cursor.accept(["FROM", "EXTERNAL", "PROVIDER"]) {
                type = "E"
                authentication = "EXTERNAL"
            } else if cursor.accept(["FOR", "CERTIFICATE"]) || cursor.accept(["FROM", "CERTIFICATE"]) {
                type = "C"
                certificate = cursor.identifier() ?? ""
            } else if cursor.accept(["FOR", "ASYMMETRIC", "KEY"]) || cursor.accept(["FROM", "ASYMMETRIC", "KEY"]) {
                type = "K"
                asymmetricKey = cursor.identifier() ?? ""
            } else if cursor.accept("PASSWORD") {
                authentication = "DATABASE"
                cursor.accept("=")
                cursor.advance()
            } else if cursor.accept("DEFAULT_SCHEMA") {
                cursor.accept("=")
                defaultSchema = cursor.identifier()
            } else {
                cursor.advance()
            }
        }
        if login.contains("\\") && authentication == "INSTANCE" { type = "U" }
        // The catalog reports dbo when no default schema was given.
        let schema = defaultSchema ?? (type == "C" || type == "K" ? "" : "dbo")
        let body = LiveSchemaReader.userBody(name: name, type: type, authentication: authentication, login: login,
                                             defaultSchema: schema, certificate: certificate,
                                             asymmetricKey: asymmetricKey)
        add(SchemaObject(type: .user, schema: "", name: name, body: body))
    }

    mutating func parseCreateRole(_ cursor: inout DDLTokenCursor) {
        guard let name = cursor.identifier() else { return }
        var object = SchemaObject(type: .role, schema: "", name: name)
        object.owner = cursor.accept("AUTHORIZATION") ? (cursor.identifier() ?? "dbo") : "dbo"
        add(object)
    }

    mutating func parseCreateApplicationRole(_ cursor: inout DDLTokenCursor) {
        guard let name = cursor.identifier() else { return }
        var schema = "dbo"
        while !cursor.isAtEnd {
            if cursor.accept("DEFAULT_SCHEMA") {
                cursor.accept("=")
                schema = cursor.identifier() ?? "dbo"
            } else {
                cursor.advance()
            }
        }
        let body = "CREATE APPLICATION ROLE \(SQLIdentifier.quote(name)) WITH PASSWORD = N'<password>', "
            + "DEFAULT_SCHEMA = \(SQLIdentifier.quote(schema))"
        add(SchemaObject(type: .applicationRole, schema: "", name: name, body: body))
    }

    mutating func addRoleMembership(role: String, member: String) {
        attachNamed(member, types: [.user, .role, .applicationRole], "membership of \(member) in \(role)") { object in
            if !object.roleMemberships.contains(where: { $0.caseInsensitiveCompare(role) == .orderedSame }) {
                object.roleMemberships.append(role)
            }
        }
    }

    // MARK: - Types, sequences, synonyms

    mutating func parseCreateType(_ text: String, _ cursor: inout DDLTokenCursor) {
        guard let (schema, name) = cursor.objectName() else { return }
        let quoted = SQLIdentifier.quote(schema: schema, name: name)
        if cursor.accept("FROM") {
            let (base, _) = parseDataType(&cursor)
            var nullable = true
            if cursor.accept(["NOT", "NULL"]) { nullable = false }
            add(SchemaObject(type: .userDefinedType, schema: schema, name: name,
                             body: "CREATE TYPE \(quoted) FROM \(base)" + (nullable ? " NULL" : " NOT NULL")))
            return
        }
        if cursor.accept(["EXTERNAL", "NAME"]) {
            let parts = cursor.multipartName()
            let external = parts.map(SQLIdentifier.quote).joined(separator: ".")
            var object = SchemaObject(type: .userDefinedType, schema: schema, name: name,
                                      body: "CREATE TYPE \(quoted) EXTERNAL NAME \(external)")
            object.subtype = "CLR"
            add(object)
            return
        }
        guard cursor.accept(["AS", "TABLE"]), cursor.word() == "(" else {
            add(SchemaObject(type: .userDefinedType, schema: schema, name: name, body: text))
            return
        }
        var table = TableDefinition()
        var shell = SchemaObject(type: .tableType, schema: schema, name: name)
        var checks: [CheckConstraintDefinition] = []
        var indexes: [TableTypeIndex] = []
        for range in cursor.parenthesizedList() {
            var element = cursor.sub(range)
            let before = (table.primaryKey, table.uniqueConstraints.count, shell.indexes.count)
            parseTableElement(&element, table: &table, object: &shell, checks: &checks, trusted: true)
            if before.0 == nil, let key = table.primaryKey {
                indexes.append(TableTypeIndex(kind: .primaryKey, isClustered: key.isClustered, columns: key.columns,
                                              ignoreDupKey: key.options.ignoreDupKey))
            }
            if table.uniqueConstraints.count > before.1, let key = table.uniqueConstraints.last {
                indexes.append(TableTypeIndex(kind: .unique, isClustered: key.isClustered, columns: key.columns,
                                              ignoreDupKey: key.options.ignoreDupKey))
            }
            if shell.indexes.count > before.2, let index = shell.indexes.last {
                indexes.append(TableTypeIndex(kind: .index, name: index.name, isUnique: index.isUnique,
                                              isClustered: index.kind == .clustered, columns: index.columns))
            }
        }
        var memoryOptimized = false
        if cursor.accept("WITH"), cursor.word() == "(" {
            memoryOptimized = cursor.optionList()["MEMORY_OPTIMIZED"].map(Self.firstWord) == "ON"
        }
        let body = SchemaScriptWriter().tableTypeBody(quotedName: quoted, columns: table.columns, indexes: indexes,
                                                      checks: checks.map(\.definition),
                                                      memoryOptimized: memoryOptimized)
        add(SchemaObject(type: .tableType, schema: schema, name: name, body: body))
    }

    mutating func parseCreateSequence(_ cursor: inout DDLTokenCursor) {
        guard let (schema, name) = cursor.objectName() else { return }
        var type = "bigint"
        var start: String?
        var increment = "1"
        var minimum: String?
        var maximum: String?
        var cycle = false
        var cache = "CACHE"
        while !cursor.isAtEnd {
            if cursor.accept("AS") {
                type = parseDataType(&cursor).0
            } else if cursor.accept(["START", "WITH"]) {
                start = Self.signedNumber(&cursor)
            } else if cursor.accept(["INCREMENT", "BY"]) {
                increment = Self.signedNumber(&cursor)
            } else if cursor.accept(["NO", "MINVALUE"]) {
                minimum = nil
            } else if cursor.accept("MINVALUE") {
                minimum = Self.signedNumber(&cursor)
            } else if cursor.accept(["NO", "MAXVALUE"]) {
                maximum = nil
            } else if cursor.accept("MAXVALUE") {
                maximum = Self.signedNumber(&cursor)
            } else if cursor.accept(["NO", "CYCLE"]) {
                cycle = false
            } else if cursor.accept("CYCLE") {
                cycle = true
            } else if cursor.accept(["NO", "CACHE"]) {
                cache = "NO CACHE"
            } else if cursor.accept("CACHE") {
                if let token = cursor.current, token.kind == .number {
                    cache = "CACHE \(token.text)"
                    cursor.advance()
                }
            } else {
                cursor.advance()
            }
        }
        let range = Self.sequenceRange(type)
        let lowest = minimum ?? range.0
        let highest = maximum ?? range.1
        let first = start ?? (increment.hasPrefix("-") ? highest : lowest)
        let quoted = SQLIdentifier.quote(schema: schema, name: name)
        var body = "CREATE SEQUENCE \(quoted)\n    AS \(type)\n"
        body += "    START WITH \(first)\n    INCREMENT BY \(increment)\n"
        body += "    MINVALUE \(lowest)\n    MAXVALUE \(highest)\n"
        body += cycle ? "    CYCLE\n" : "    NO CYCLE\n"
        body += "    \(cache)"
        add(SchemaObject(type: .sequence, schema: schema, name: name, body: body))
    }

    static func signedNumber(_ cursor: inout DDLTokenCursor) -> String {
        var text = ""
        if cursor.word() == "-" || cursor.word() == "+" {
            if cursor.word() == "-" { text = "-" }
            cursor.advance()
        }
        text += cursor.current?.text ?? "0"
        cursor.advance()
        return text
    }

    static func sequenceRange(_ type: String) -> (String, String) {
        switch SchemaTypes.baseName(of: type) {
        case "tinyint": return ("0", "255")
        case "smallint": return ("-32768", "32767")
        case "int": return ("-2147483648", "2147483647")
        case "decimal", "numeric":
            let precision = SchemaTypes.precisionScale(of: type)?.0 ?? 18
            let nines = String(repeating: "9", count: max(1, precision))
            return ("-" + nines, nines)
        default: return ("-9223372036854775808", "9223372036854775807")
        }
    }

    mutating func parseCreateSynonym(_ cursor: inout DDLTokenCursor) {
        guard let (schema, name) = cursor.objectName(), cursor.accept("FOR") else { return }
        let parts = cursor.multipartName()
        let target = parts.map(SQLIdentifier.quote).joined(separator: ".")
        add(SchemaObject(type: .synonym, schema: schema, name: name,
                         body: "CREATE SYNONYM \(SQLIdentifier.quote(schema: schema, name: name)) FOR \(target)"))
    }

    mutating func parseCreatePartition(_ text: String, _ cursor: inout DDLTokenCursor) {
        cursor.advance()
        if cursor.accept("FUNCTION") {
            guard let name = cursor.identifier(), cursor.word() == "(" else { return }
            let typeRange = cursor.parenthesizedList().first ?? 0..<0
            var typeCursor = cursor.sub(typeRange)
            let type = parseDataType(&typeCursor).0
            cursor.accept(["AS", "RANGE"])
            let right = cursor.accept("RIGHT")
            if !right { cursor.accept("LEFT") }
            var values: [String] = []
            if cursor.accept(["FOR", "VALUES"]), cursor.word() == "(" {
                values = cursor.parenthesizedList().map { range in
                    cursor.text(from: range.lowerBound, to: range.upperBound - 1).trimmingCharacters(in: .whitespaces)
                }
            }
            let body = "CREATE PARTITION FUNCTION \(SQLIdentifier.quote(name)) (\(type))\n"
                + "    AS RANGE \(right ? "RIGHT" : "LEFT")\n"
                + "    FOR VALUES (" + values.joined(separator: ", ") + ")"
            add(SchemaObject(type: .partitionFunction, schema: "", name: name, body: body))
            return
        }
        guard cursor.accept("SCHEME"), let name = cursor.identifier(), cursor.accept(["AS", "PARTITION"]),
              let function = cursor.identifier() else { return }
        let all = cursor.accept("ALL")
        cursor.accept("TO")
        let filegroups = cursor.nameList().map(SQLIdentifier.quote)
        var object = SchemaObject(type: .partitionScheme, schema: "", name: name)
        object.body = "CREATE PARTITION SCHEME \(SQLIdentifier.quote(name))\n    AS PARTITION \(SQLIdentifier.quote(function))\n"
            + "    TO (" + filegroups.joined(separator: ", ") + ")"
        add(object)
        if all, let filegroup = filegroups.first {
            // ALL TO names one filegroup for every partition; expand it once the function's
            // boundary count is known.
            let functionKey = function.lowercased()
            pendingAllTo.append((name.lowercased(), functionKey, filegroup))
        }
    }

    // MARK: - Permissions

    mutating func parsePermission(_ cursor: inout DDLTokenCursor) {
        let state = cursor.word() == "DENY" ? "DENY" : "GRANT"
        cursor.advance()
        // Permission list up to ON or TO.
        var permissions: [(String, [String])] = []
        var words: [String] = []
        var columns: [String] = []
        while !cursor.isAtEnd, cursor.word() != "ON", cursor.word() != "TO" {
            if cursor.word() == "," {
                if !words.isEmpty { permissions.append((words.joined(separator: " "), columns)) }
                words = []
                columns = []
                cursor.advance()
            } else if cursor.word() == "(" {
                columns = cursor.nameList()
            } else {
                words.append(cursor.current?.text.uppercased() ?? "")
                cursor.advance()
            }
        }
        if !words.isEmpty { permissions.append((words.joined(separator: " "), columns)) }

        var securableClass = ""
        var securableParts: [String] = []
        var securableColumns: [String] = []
        if cursor.accept("ON") {
            // Class names can be several words: XML SCHEMA COLLECTION::x.
            var lookahead = 0
            while let token = cursor.peek(lookahead), token.text != "::", lookahead < 4 { lookahead += 1 }
            if cursor.peek(lookahead)?.text == "::" {
                var classWords: [String] = []
                for _ in 0..<lookahead {
                    classWords.append(cursor.current?.text.uppercased() ?? "")
                    cursor.advance()
                }
                securableClass = classWords.joined(separator: " ")
                cursor.advance()
            }
            securableParts = cursor.multipartName()
            if cursor.word() == "(" { securableColumns = cursor.nameList() }
        }
        guard cursor.accept("TO") else { return }
        var grantees: [String] = []
        while let grantee = cursor.identifier() {
            grantees.append(grantee)
            if !cursor.accept(",") { break }
        }
        let withGrant = cursor.accept(["WITH", "GRANT", "OPTION"])
        let finalState = state == "GRANT" && withGrant ? "GRANT_WITH_GRANT_OPTION" : state

        var definitions: [PermissionDefinition] = []
        for (permission, permissionColumns) in permissions {
            let targets = !permissionColumns.isEmpty ? permissionColumns : securableColumns
            for grantee in grantees {
                if targets.isEmpty {
                    definitions.append(PermissionDefinition(state: finalState, permission: permission, grantee: grantee))
                } else {
                    for column in targets {
                        definitions.append(PermissionDefinition(state: finalState, permission: permission,
                                                                grantee: grantee, column: column))
                    }
                }
            }
        }
        guard !definitions.isEmpty else { return }
        let collected = definitions
        func append(_ object: inout SchemaObject) {
            for permission in collected where !object.permissions.contains(permission) {
                object.permissions.append(permission)
            }
        }

        if securableParts.isEmpty {
            // Database-level permissions belong to the grantee.
            for grantee in grantees {
                let mine = collected.filter { $0.grantee.caseInsensitiveCompare(grantee) == .orderedSame }
                attachNamed(grantee, types: [.user, .role, .applicationRole], "permissions of \(grantee)") { object in
                    for permission in mine where !object.permissions.contains(permission) {
                        object.permissions.append(permission)
                    }
                }
            }
            return
        }
        let name = securableParts.last ?? ""
        let schema = securableParts.count >= 2 ? securableParts[securableParts.count - 2] : "dbo"
        switch securableClass {
        case "SCHEMA":
            attachNamed(name, types: [.schema], "permissions on schema \(name)") { append(&$0) }
        case "TYPE":
            attach(schema: schema, name: name, types: [.userDefinedType, .tableType], "permissions on type \(name)") {
                append(&$0)
            }
        case "XML SCHEMA COLLECTION":
            attach(schema: schema, name: name, types: [.xmlSchemaCollection], "permissions on \(name)") { append(&$0) }
        case "ASSEMBLY":
            attachNamed(name, types: [.assembly], "permissions on assembly \(name)") { append(&$0) }
        case "FULLTEXT CATALOG":
            attachNamed(name, types: [.fullTextCatalog], "permissions on \(name)") { append(&$0) }
        case "FULLTEXT STOPLIST":
            attachNamed(name, types: [.fullTextStoplist], "permissions on \(name)") { append(&$0) }
        case "MESSAGE TYPE":
            attachNamed(name, types: [.messageType], "permissions on \(name)") { append(&$0) }
        case "CONTRACT":
            attachNamed(name, types: [.contract], "permissions on \(name)") { append(&$0) }
        case "SERVICE":
            attachNamed(name, types: [.service], "permissions on \(name)") { append(&$0) }
        case "", "OBJECT":
            attach(schema: schema, name: name, types: [.table, .view, .storedProcedure, .function, .synonym,
                                                         .sequence, .queue, .rule, .defaultObject],
                   "permissions on \(schema).\(name)") { append(&$0) }
        default:
            return
        }
    }

    // MARK: - Ownership

    mutating func parseAuthorization(_ cursor: inout DDLTokenCursor) {
        guard cursor.accept("ON") else { return }
        var securableClass = "OBJECT"
        if cursor.peek(1)?.text == "::" {
            securableClass = cursor.word()
            cursor.advance(2)
        }
        let parts = cursor.multipartName()
        guard cursor.accept("TO"), let name = parts.last else { return }
        let owner: String? = cursor.matches(["SCHEMA", "OWNER"]) ? nil : cursor.identifier()
        let schema = parts.count >= 2 ? parts[parts.count - 2] : "dbo"
        switch securableClass {
        case "SCHEMA", "ROLE":
            attachNamed(name, types: securableClass == "SCHEMA" ? [.schema] : [.role], "owner of \(name)") { object in
                object.owner = owner ?? "dbo"
            }
        case "TYPE":
            attach(schema: schema, name: name, types: [.userDefinedType, .tableType], "owner of \(name)") { $0.owner = owner }
        default:
            attach(schema: schema, name: name, types: [], "owner of \(schema).\(name)") { $0.owner = owner }
        }
    }

    // MARK: - System procedures

    mutating func parseExec(_ cursor: inout DDLTokenCursor) {
        cursor.advance()
        if cursor.word() == "(" {
            // EXEC(N'...') carries a script of its own.
            if let literal = cursor.peek(1), literal.kind == .string {
                parseNested(literal.text.sqlStringValue)
            }
            return
        }
        let parts = cursor.multipartName()
        guard let procedure = parts.last?.lowercased() else { return }
        let arguments = Self.procedureArguments(cursor)
        switch procedure {
        case "sp_executesql":
            if let script = arguments.positional.first ?? arguments.named["@statement"] {
                parseNested(script)
            }
        case "sp_addextendedproperty", "sp_updateextendedproperty":
            parseExtendedProperty(arguments)
        case "sp_addrolemember":
            let role = arguments.named["@rolename"] ?? arguments.positional.first ?? ""
            let member = arguments.named["@membername"] ?? (arguments.positional.count > 1 ? arguments.positional[1] : "")
            if !role.isEmpty, !member.isEmpty { addRoleMembership(role: role, member: member) }
        case "sp_bindrule", "sp_bindefault":
            let bound = arguments.named["@rulename"] ?? arguments.named["@defname"] ?? arguments.positional.first ?? ""
            let column = arguments.named["@objname"] ?? (arguments.positional.count > 1 ? arguments.positional[1] : "")
            bind(procedure == "sp_bindrule", object: bound, column: column)
        case "sp_settriggerorder":
            let trigger = arguments.named["@triggername"] ?? arguments.positional.first ?? ""
            let order = arguments.named["@order"] ?? (arguments.positional.count > 1 ? arguments.positional[1] : "None")
            let event = arguments.named["@stmttype"] ?? (arguments.positional.count > 2 ? arguments.positional[2] : "")
            let namespace = arguments.named["@namespace"] ?? (arguments.positional.count > 3 ? arguments.positional[3] : "")
            setTriggerOrder(trigger, order: order, event: event, isDatabase: !namespace.isEmpty)
        default:
            return
        }
    }

    private mutating func parseNested(_ script: String) {
        let saved = (quotedIdentifier, ansiNulls)
        for batch in BatchSplitter.split(script) where !batch.isEmpty {
            for statement in statements(in: batch.text) { parseStatement(statement) }
        }
        (quotedIdentifier, ansiNulls) = saved
    }

    struct ProcedureArguments {
        var positional: [String] = []
        var named: [String: String] = [:]
    }

    /// Arguments of an EXEC as unquoted string values; NULL becomes empty.
    static func procedureArguments(_ cursor: DDLTokenCursor) -> ProcedureArguments {
        var result = ProcedureArguments()
        for range in splitTopLevel(cursor, from: cursor.position) {
            var sub = cursor.sub(range)
            var name: String?
            if let token = sub.current, token.kind == .variable, sub.word(1) == "=" {
                name = token.text.lowercased()
                sub.advance(2)
            }
            var value = ""
            if let token = sub.current {
                switch token.kind {
                case .string: value = token.text.sqlStringValue
                case .keyword where token.text.uppercased() == "NULL": value = ""
                default: value = sub.isAtEnd ? "" : sub.text(from: 0, to: sub.tokens.count - 1)
                }
            }
            if let name { result.named[name] = value } else { result.positional.append(value) }
        }
        return result
    }

    private mutating func parseExtendedProperty(_ arguments: ProcedureArguments) {
        let keys = ["@name", "@value", "@level0type", "@level0name", "@level1type", "@level1name",
                    "@level2type", "@level2name"]
        var values: [String] = []
        for (offset, key) in keys.enumerated() {
            if let named = arguments.named[key] {
                values.append(named)
            } else if offset < arguments.positional.count {
                values.append(arguments.positional[offset])
            } else {
                values.append("")
            }
        }
        let name = values[0]
        let value = values[1]
        let level0 = values[2].uppercased()
        let level0Name = values[3]
        let level1 = values[4].uppercased()
        let level1Name = values[5]
        let level2 = values[6].uppercased()
        let level2Name = values[7]
        var property = ExtendedPropertyDefinition(name: name, value: value)
        if !level2.isEmpty {
            property.childType = level2
            property.childName = level2Name
        }
        let definition = property
        func apply(_ object: inout SchemaObject) {
            object.extendedProperties.removeAll { $0.slotKey == definition.slotKey }
            object.extendedProperties.append(definition)
        }
        switch level0 {
        case "SCHEMA":
            guard !level1.isEmpty else {
                attachNamed(level0Name, types: [.schema], "extended property \(name)") { apply(&$0) }
                return
            }
            let types: Set<SchemaObjectType>
            switch level1 {
            case "TABLE": types = [.table]
            case "VIEW": types = [.view]
            case "PROCEDURE": types = [.storedProcedure]
            case "FUNCTION", "AGGREGATE": types = [.function]
            case "SYNONYM": types = [.synonym]
            case "SEQUENCE": types = [.sequence]
            case "TYPE", "TABLE_TYPE": types = [.userDefinedType, .tableType]
            case "XML SCHEMA COLLECTION": types = [.xmlSchemaCollection]
            case "RULE": types = [.rule]
            case "DEFAULT": types = [.defaultObject]
            case "QUEUE": types = [.queue]
            default: types = []
            }
            attach(schema: level0Name, name: level1Name, types: types, "extended property \(name)") { apply(&$0) }
        case "USER":
            attachNamed(level0Name, types: [.user, .role, .applicationRole], "extended property \(name)") { apply(&$0) }
        case "TRIGGER":
            attachNamed(level0Name, types: [.ddlTrigger], "extended property \(name)") { apply(&$0) }
        case "ASSEMBLY":
            attachNamed(level0Name, types: [.assembly], "extended property \(name)") { apply(&$0) }
        case "PARTITION FUNCTION":
            attachNamed(level0Name, types: [.partitionFunction], "extended property \(name)") { apply(&$0) }
        case "PARTITION SCHEME":
            attachNamed(level0Name, types: [.partitionScheme], "extended property \(name)") { apply(&$0) }
        case "MESSAGE TYPE":
            attachNamed(level0Name, types: [.messageType], "extended property \(name)") { apply(&$0) }
        case "CONTRACT":
            attachNamed(level0Name, types: [.contract], "extended property \(name)") { apply(&$0) }
        case "SERVICE":
            attachNamed(level0Name, types: [.service], "extended property \(name)") { apply(&$0) }
        default:
            return
        }
    }

    private mutating func bind(_ isRule: Bool, object bound: String, column path: String) {
        let parts = DDLTokenCursorName.parts(path)
        guard parts.count >= 2 else { return }
        let columnName = parts[parts.count - 1]
        let tableName = parts[parts.count - 2]
        let schema = parts.count >= 3 ? parts[parts.count - 3] : "dbo"
        let boundParts = DDLTokenCursorName.parts(bound)
        guard let boundName = boundParts.last else { return }
        let boundSchema = boundParts.count >= 2 ? boundParts[boundParts.count - 2] : "dbo"
        let quoted = SQLIdentifier.quote(schema: boundSchema, name: boundName)
        attach(schema: schema, name: tableName, types: [.table], "binding of \(columnName)") { object in
            guard let index = object.table?.columns.firstIndex(where: {
                $0.name.caseInsensitiveCompare(columnName) == .orderedSame
            }) else { return }
            if isRule { object.table?.columns[index].boundRule = quoted } else { object.table?.columns[index].boundDefault = quoted }
        }
    }

    private mutating func setTriggerOrder(_ trigger: String, order: String, event: String, isDatabase: Bool) {
        let parts = DDLTokenCursorName.parts(trigger)
        guard let name = parts.last else { return }
        let normalized = order.capitalized
        let eventName = event.uppercased()
        if isDatabase {
            attachNamed(name, types: [.ddlTrigger], "order of trigger \(name)") { object in
                if normalized == "None" { object.triggerOrder.removeValue(forKey: eventName) }
                else { object.triggerOrder[eventName] = normalized }
            }
            return
        }
        // The trigger's table is not named; find it by the trigger among all tables and views.
        let schema = parts.count >= 2 ? parts[parts.count - 2] : "dbo"
        pendingTriggerOrders.append((schema.lowercased(), name.lowercased(), eventName, normalized))
    }
}

/// Splits `[a].[b].c` into unquoted parts.
enum DDLTokenCursorName {
    static func parts(_ text: String) -> [String] {
        var cursor = DDLTokenCursor(text)
        return cursor.multipartName()
    }
}
