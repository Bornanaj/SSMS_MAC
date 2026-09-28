import Foundation

/// CREATE TABLE, ALTER TABLE, indexes, statistics and full-text indexes.
extension SchemaScriptParser {

    static let systemTypes: Set<String> =
        ["bigint", "binary", "bit", "char", "date", "datetime", "datetime2", "datetimeoffset", "decimal",
         "float", "geography", "geometry", "hierarchyid", "image", "int", "money", "nchar", "ntext", "numeric",
         "nvarchar", "real", "smalldatetime", "smallint", "smallmoney", "sql_variant", "sysname", "text",
         "time", "timestamp", "rowversion", "tinyint", "uniqueidentifier", "varbinary", "varchar", "xml"]

    /// Words that end a DEFAULT expression inside a column definition.
    private static let columnAttributeWords: Set<String> =
        ["CONSTRAINT", "NOT", "NULL", "PRIMARY", "UNIQUE", "CHECK", "REFERENCES", "FOREIGN", "IDENTITY",
         "ROWGUIDCOL", "COLLATE", "SPARSE", "MASKED", "GENERATED", "HIDDEN", "FILESTREAM", "INDEX", "WITH"]

    // MARK: - CREATE TABLE

    mutating func parseCreateTable(_ cursor: inout DDLTokenCursor) {
        guard let (schema, name) = cursor.objectName() else { return }
        var object = SchemaObject(type: .table, schema: schema, name: name)
        var table = TableDefinition()
        table.dataSpace = ""
        guard cursor.word() == "(" else {
            warn("CREATE TABLE \(schema).\(name) has no column list.")
            return
        }
        let elements = cursor.parenthesizedList()
        var pendingChecks: [CheckConstraintDefinition] = []
        for range in elements {
            var element = cursor.sub(range)
            parseTableElement(&element, table: &table, object: &object, checks: &pendingChecks, trusted: true)
        }
        table.checkConstraints.append(contentsOf: pendingChecks)

        // Table options after the column list.
        while !cursor.isAtEnd {
            if cursor.accept("ON") {
                if let space = cursor.identifier() {
                    table.dataSpace = space
                    if cursor.word() == "(" {
                        table.partitionColumn = cursor.nameList().first
                    }
                }
            } else if cursor.accept("TEXTIMAGE_ON") {
                table.textImageDataSpace = cursor.identifier()
            } else if cursor.accept("FILESTREAM_ON") {
                _ = cursor.identifier()
            } else if cursor.accept("WITH"), cursor.word() == "(" {
                let options = cursor.optionList()
                if let compression = options["DATA_COMPRESSION"] {
                    table.dataCompression = Self.firstWord(compression)
                }
                if options["MEMORY_OPTIMIZED"].map(Self.firstWord) == "ON" {
                    table.isMemoryOptimized = true
                    table.durability = options["DURABILITY"].map(Self.firstWord) ?? "SCHEMA_AND_DATA"
                }
                if let versioning = options["SYSTEM_VERSIONING"], Self.firstWord(versioning) == "ON" {
                    let history = Self.historyTable(versioning)
                    if table.temporal == nil {
                        table.temporal = TemporalDefinition(periodStartColumn: "", periodEndColumn: "")
                    }
                    table.temporal?.historySchema = history?.0 ?? schema
                    table.temporal?.historyTable = history?.1 ?? "MSSQL_TemporalHistoryFor_\(name)"
                }
                if let escalation = options["LOCK_ESCALATION"] { table.lockEscalation = Self.firstWord(escalation) }
            } else {
                cursor.advance()
            }
        }
        if table.dataSpace.isEmpty && !table.isMemoryOptimized { table.dataSpace = "PRIMARY" }
        // Keys created without an ON clause live with the table.
        if var key = table.primaryKey, key.dataSpace.isEmpty {
            key.dataSpace = table.isMemoryOptimized ? "" : table.dataSpace
            key.partitionColumn = key.partitionColumn ?? (key.isClustered ? table.partitionColumn : nil)
            table.primaryKey = key
        }
        for index in table.uniqueConstraints.indices where table.uniqueConstraints[index].dataSpace.isEmpty {
            table.uniqueConstraints[index].dataSpace = table.isMemoryOptimized ? "" : table.dataSpace
        }
        if table.textImageDataSpace == nil, !table.isMemoryOptimized,
           table.columns.contains(where: { SchemaTypes.isLargeObject($0.dataType) && !$0.isComputed }) {
            table.textImageDataSpace = table.dataSpace
        }
        if table.isMemoryOptimized {
            for index in object.indexes.indices { object.indexes[index].dataSpace = "" }
        }
        object.table = table
        add(object)
    }

    /// One comma-separated element of a CREATE TABLE / ALTER TABLE ADD list.
    mutating func parseTableElement(_ cursor: inout DDLTokenCursor, table: inout TableDefinition,
                                    object: inout SchemaObject, checks: inout [CheckConstraintDefinition],
                                    trusted: Bool) {
        var constraintName: String?
        if cursor.accept("CONSTRAINT") { constraintName = cursor.identifier() }
        switch cursor.word() {
        case "PRIMARY", "UNIQUE":
            if let key = parseKeyConstraint(&cursor, name: constraintName, columns: nil) {
                if key.isPrimaryKey { table.primaryKey = key } else { table.uniqueConstraints.append(key) }
            }
        case "CHECK":
            checks.append(parseCheck(&cursor, name: constraintName, trusted: trusted))
        case "FOREIGN":
            cursor.advance(2)
            let columns = cursor.nameList()
            if let key = parseReferences(&cursor, name: constraintName, columns: columns, trusted: trusted) {
                table.foreignKeys.append(key)
            }
        case "DEFAULT":
            cursor.advance()
            let range = cursor.skipUntil(["FOR", "WITH"])
            let expression = range.isEmpty ? "" : cursor.text(from: range.lowerBound, to: range.upperBound - 1)
            let constraint = DefaultConstraintDefinition(name: constraintName ?? "", definition: expression,
                                                         isSystemNamed: constraintName == nil)
            if cursor.accept("FOR"), let column = cursor.identifier() {
                if let index = table.columns.firstIndex(where: { $0.name.caseInsensitiveCompare(column) == .orderedSame }) {
                    table.columns[index].defaultConstraint = constraint
                } else {
                    pendingDefault = (column, constraint)
                }
            }
        case "PERIOD":
            cursor.advance(3)
            let columns = cursor.nameList()
            if columns.count == 2 {
                let history = table.temporal
                table.temporal = TemporalDefinition(periodStartColumn: columns[0], periodEndColumn: columns[1],
                                                    historySchema: history?.historySchema,
                                                    historyTable: history?.historyTable)
            }
        case "INDEX":
            cursor.advance()
            guard let name = cursor.identifier() else { return }
            let unique = cursor.accept("UNIQUE")
            var kind: IndexKind = .nonclustered
            if cursor.accept("CLUSTERED") { kind = .clustered }
            if cursor.accept("NONCLUSTERED") { kind = .nonclustered }
            if cursor.accept("COLUMNSTORE") { kind = kind == .clustered ? .clusteredColumnstore : .nonclusteredColumnstore }
            let columns = cursor.word() == "(" ? cursor.indexColumns() : []
            var index = IndexDefinition(name: name, kind: kind, isUnique: unique, columns: columns)
            if kind == .nonclusteredColumnstore {
                index.includedColumns = columns.map(\.name)
                index.columns = []
            }
            object.indexes.append(index)
        default:
            if let column = parseColumn(&cursor, table: &table, object: &object, checks: &checks, trusted: trusted) {
                table.columns.append(column)
            }
        }
    }

    // MARK: - Columns

    private mutating func parseColumn(_ cursor: inout DDLTokenCursor, table: inout TableDefinition,
                                      object: inout SchemaObject, checks: inout [CheckConstraintDefinition],
                                      trusted: Bool) -> ColumnDefinition? {
        guard let name = cursor.identifier() else { return nil }
        if cursor.accept("AS") {
            let range = cursor.skipUntil(["PERSISTED", "CONSTRAINT", "NOT", "NULL", "PRIMARY", "UNIQUE", "CHECK"])
            var column = ColumnDefinition(name: name, dataType: "")
            column.computedExpression = range.isEmpty ? "" : cursor.text(from: range.lowerBound, to: range.upperBound - 1)
            column.isNullable = true
            if cursor.accept("PERSISTED") {
                column.isPersisted = true
                if cursor.accept(["NOT", "NULL"]) { column.isNullable = false }
            }
            parseColumnConstraints(&cursor, column: &column, table: &table, checks: &checks, trusted: trusted)
            return column
        }

        let (dataType, isUserDefined) = parseDataType(&cursor)
        var column = ColumnDefinition(name: name, dataType: dataType, isUserDefinedType: isUserDefined,
                                      isNullable: true)
        if dataType.lowercased() == "timestamp" { column.isNullable = false }
        var explicitNull = false
        var pendingName: String?
        while !cursor.isAtEnd {
            if cursor.accept("COLLATE") {
                column.collation = cursor.identifier()
            } else if cursor.accept(["NOT", "NULL"]) {
                column.isNullable = false
                explicitNull = true
            } else if cursor.accept("NULL") {
                column.isNullable = true
                explicitNull = true
            } else if cursor.accept("IDENTITY") {
                var identity = IdentitySpec()
                if cursor.word() == "(" {
                    let arguments = cursor.parenthesizedList().map { range -> String in
                        cursor.text(from: range.lowerBound, to: range.upperBound - 1)
                    }
                    if arguments.count == 2 {
                        identity.seed = arguments[0].trimmingCharacters(in: .whitespaces)
                        identity.increment = arguments[1].trimmingCharacters(in: .whitespaces)
                    }
                }
                if cursor.accept(["NOT", "FOR", "REPLICATION"]) { identity.notForReplication = true }
                column.identity = identity
                if !explicitNull { column.isNullable = false }
            } else if cursor.accept(["NOT", "FOR", "REPLICATION"]) {
                column.identity?.notForReplication = true
            } else if cursor.accept("ROWGUIDCOL") {
                column.isRowGuidCol = true
            } else if cursor.accept("SPARSE") {
                column.isSparse = true
            } else if cursor.accept("FILESTREAM") {
                column.isFileStream = true
            } else if cursor.accept(["COLUMN_SET", "FOR", "ALL_SPARSE_COLUMNS"]) {
                column.isColumnSet = true
            } else if cursor.accept(["MASKED", "WITH"]) {
                let options = cursor.optionList()
                column.maskingFunction = options["FUNCTION"]?.sqlStringValue
            } else if cursor.accept(["GENERATED", "ALWAYS", "AS"]) {
                var words: [String] = []
                while let word = cursor.current?.text.uppercased(), ["ROW", "START", "END", "TRANSACTION_ID",
                                                                     "SEQUENCE_NUMBER"].contains(word) {
                    words.append(word)
                    cursor.advance()
                }
                column.generatedAlways = words.joined(separator: " ")
                if !explicitNull { column.isNullable = false }
            } else if cursor.accept("HIDDEN") {
                column.isHidden = true
            } else if cursor.accept("CONSTRAINT") {
                pendingName = cursor.identifier()
            } else if cursor.accept("DEFAULT") {
                let range = cursor.skipUntil(Self.columnAttributeWords)
                let expression = range.isEmpty ? "" : cursor.text(from: range.lowerBound, to: range.upperBound - 1)
                column.defaultConstraint = DefaultConstraintDefinition(name: pendingName ?? "", definition: expression,
                                                                       isSystemNamed: pendingName == nil)
                pendingName = nil
                if cursor.accept(["WITH", "VALUES"]) { continue }
            } else if ["PRIMARY", "UNIQUE", "CHECK", "REFERENCES", "FOREIGN"].contains(cursor.word()) {
                parseInlineConstraint(&cursor, name: pendingName, columnName: name, table: &table, checks: &checks,
                                      trusted: trusted)
                pendingName = nil
            } else if cursor.accept("INDEX") {
                guard let indexName = cursor.identifier() else { continue }
                let clustered = cursor.accept("CLUSTERED")
                _ = cursor.accept("NONCLUSTERED")
                object.indexes.append(IndexDefinition(name: indexName, kind: clustered ? .clustered : .nonclustered,
                                                      columns: [IndexColumn(name: name)]))
            } else {
                cursor.advance()
            }
        }
        return column
    }

    private mutating func parseColumnConstraints(_ cursor: inout DDLTokenCursor, column: inout ColumnDefinition,
                                                 table: inout TableDefinition,
                                                 checks: inout [CheckConstraintDefinition], trusted: Bool) {
        var pendingName: String?
        while !cursor.isAtEnd {
            if cursor.accept("CONSTRAINT") {
                pendingName = cursor.identifier()
            } else if ["PRIMARY", "UNIQUE", "CHECK", "REFERENCES", "FOREIGN"].contains(cursor.word()) {
                parseInlineConstraint(&cursor, name: pendingName, columnName: column.name, table: &table,
                                      checks: &checks, trusted: trusted)
                pendingName = nil
            } else {
                cursor.advance()
            }
        }
    }

    private mutating func parseInlineConstraint(_ cursor: inout DDLTokenCursor, name: String?, columnName: String,
                                                table: inout TableDefinition,
                                                checks: inout [CheckConstraintDefinition], trusted: Bool) {
        switch cursor.word() {
        case "PRIMARY", "UNIQUE":
            if let key = parseKeyConstraint(&cursor, name: name, columns: [IndexColumn(name: columnName)]) {
                if key.isPrimaryKey { table.primaryKey = key } else { table.uniqueConstraints.append(key) }
            }
        case "CHECK":
            checks.append(parseCheck(&cursor, name: name, trusted: trusted))
        default:
            if cursor.accept("FOREIGN") { cursor.accept("KEY") }
            if let key = parseReferences(&cursor, name: name, columns: [columnName], trusted: trusted) {
                table.foreignKeys.append(key)
            }
        }
    }

    /// `PRIMARY KEY [CLUSTERED|NONCLUSTERED] [(cols)] [WITH (...)] [ON ds]`
    private func parseKeyConstraint(_ cursor: inout DDLTokenCursor, name: String?,
                                    columns inline: [IndexColumn]?) -> KeyConstraintDefinition? {
        let isPrimary = cursor.accept(["PRIMARY", "KEY"])
        if !isPrimary { cursor.accept("UNIQUE") }
        var clustered = isPrimary
        if cursor.accept("CLUSTERED") { clustered = true }
        if cursor.accept("NONCLUSTERED") { clustered = false }
        _ = cursor.accept("HASH")
        var columns = inline ?? []
        if cursor.word() == "(" { columns = cursor.indexColumns() }
        var key = KeyConstraintDefinition(name: name ?? "", isSystemNamed: name == nil, isPrimaryKey: isPrimary,
                                          isClustered: clustered, columns: columns, dataSpace: "")
        while !cursor.isAtEnd {
            if cursor.accept("WITH") {
                if cursor.word() == "(" {
                    key.options = Self.indexOptions(cursor.optionList(), base: key.options)
                } else if cursor.accept("FILLFACTOR") {
                    cursor.accept("=")
                    key.options.fillFactor = Int(cursor.current?.text ?? "") ?? 0
                    cursor.advance()
                }
            } else if cursor.accept("ON") {
                key.dataSpace = cursor.identifier() ?? ""
                if cursor.word() == "(" { key.partitionColumn = cursor.nameList().first }
            } else if ["CONSTRAINT", "PRIMARY", "UNIQUE", "CHECK", "REFERENCES", "FOREIGN", "DEFAULT", "NOT",
                       "NULL"].contains(cursor.word()) {
                break
            } else {
                cursor.advance()
            }
        }
        return key
    }

    private func parseCheck(_ cursor: inout DDLTokenCursor, name: String?, trusted: Bool) -> CheckConstraintDefinition {
        cursor.accept("CHECK")
        let notForReplication = cursor.accept(["NOT", "FOR", "REPLICATION"])
        var definition = ""
        if cursor.word() == "(", let close = cursor.matchingParenthesis() {
            definition = cursor.text(from: cursor.position, to: close)
            cursor.position = close + 1
        }
        return CheckConstraintDefinition(name: name ?? "", isSystemNamed: name == nil, definition: definition,
                                         isNotForReplication: notForReplication, isNotTrusted: !trusted,
                                         isDisabled: false)
    }

    private func parseReferences(_ cursor: inout DDLTokenCursor, name: String?, columns: [String],
                                 trusted: Bool) -> ForeignKeyDefinition? {
        guard cursor.accept("REFERENCES"), let (schema, table) = cursor.objectName() else { return nil }
        var referenced: [String] = []
        if cursor.word() == "(" { referenced = cursor.nameList() }
        var key = ForeignKeyDefinition(name: name ?? "", isSystemNamed: name == nil, columns: columns,
                                       referencedSchema: schema, referencedTable: table,
                                       referencedColumns: referenced, isNotTrusted: !trusted)
        while !cursor.isAtEnd {
            if cursor.accept(["ON", "DELETE"]) {
                key.deleteAction = Self.referentialAction(&cursor)
            } else if cursor.accept(["ON", "UPDATE"]) {
                key.updateAction = Self.referentialAction(&cursor)
            } else if cursor.accept(["NOT", "FOR", "REPLICATION"]) {
                key.isNotForReplication = true
            } else {
                break
            }
        }
        return key
    }

    private static func referentialAction(_ cursor: inout DDLTokenCursor) -> String {
        if cursor.accept("CASCADE") { return "CASCADE" }
        if cursor.accept(["SET", "NULL"]) { return "SET NULL" }
        if cursor.accept(["SET", "DEFAULT"]) { return "SET DEFAULT" }
        cursor.accept(["NO", "ACTION"])
        return "NO ACTION"
    }

    /// `nvarchar (50)`, `[dbo].[Phone]`, `decimal(18, 2)`, `xml(CONTENT dbo.Notes)`.
    func parseDataType(_ cursor: inout DDLTokenCursor) -> (String, Bool) {
        let parts = cursor.multipartName()
        guard let last = parts.last else { return ("", false) }
        var arguments: [String] = []
        if cursor.word() == "(" {
            arguments = cursor.parenthesizedList().map { range in
                cursor.sub(range).tokens.map { $0.text }.joined(separator: " ")
            }
        }
        let lowered = last.lowercased()
        if parts.count == 1, Self.systemTypes.contains(lowered) {
            return (Self.canonicalSystemType(lowered, arguments: arguments), false)
        }
        let schema = parts.count >= 2 ? parts[parts.count - 2] : "dbo"
        return (SQLIdentifier.quote(schema: schema, name: last), true)
    }

    /// The spelling the catalog reader produces for a system type, including SQL Server's
    /// implicit defaults (`varchar` is `varchar(1)`, `datetime2` is `datetime2(7)`).
    static func canonicalSystemType(_ name: String, arguments: [String]) -> String {
        let first = arguments.first?.trimmingCharacters(in: .whitespaces).lowercased()
        switch name {
        case "char", "varchar", "nchar", "nvarchar", "binary", "varbinary":
            return "\(name)(\(first ?? "1"))"
        case "decimal", "numeric":
            let precision = first ?? "18"
            let scale = arguments.count > 1 ? arguments[1].trimmingCharacters(in: .whitespaces) : "0"
            return "\(name)(\(precision),\(scale))"
        case "datetime2", "datetimeoffset", "time":
            return "\(name)(\(first ?? "7"))"
        case "float":
            guard let first, let bits = Int(first) else { return "float" }
            return bits <= 24 ? "real" : "float"
        case "rowversion":
            return "timestamp"
        case "xml":
            guard !arguments.isEmpty else { return "xml" }
            let words = arguments[0].split(separator: " ").map(String.init)
            var mode = "CONTENT"
            var nameWords = words
            if let firstWord = words.first?.uppercased(), firstWord == "CONTENT" || firstWord == "DOCUMENT" {
                mode = firstWord
                nameWords = Array(words.dropFirst())
            }
            let collection = nameWords.joined().split(separator: ".").map { ModuleText.unquote(String($0)) }
            let collectionName = collection.count >= 2
                ? SQLIdentifier.quote(schema: collection[collection.count - 2], name: collection.last!)
                : SQLIdentifier.quote(schema: "dbo", name: collection.last ?? "")
            return "xml(\(mode) \(collectionName))"
        default:
            return name
        }
    }

    static func indexOptions(_ options: [String: String], base: IndexOptions) -> IndexOptions {
        var value = base
        func flag(_ key: String) -> Bool? {
            guard let raw = options[key] else { return nil }
            return firstWord(raw) == "ON"
        }
        if let raw = options["FILLFACTOR"] { value.fillFactor = Int(firstWord(raw)) ?? 0 }
        if let padded = flag("PAD_INDEX") { value.padIndex = padded }
        if let ignore = flag("IGNORE_DUP_KEY") { value.ignoreDupKey = ignore }
        if let noRecompute = flag("STATISTICS_NORECOMPUTE") { value.statisticsNoRecompute = noRecompute }
        if let rowLocks = flag("ALLOW_ROW_LOCKS") { value.allowRowLocks = rowLocks }
        if let pageLocks = flag("ALLOW_PAGE_LOCKS") { value.allowPageLocks = pageLocks }
        if let sequential = flag("OPTIMIZE_FOR_SEQUENTIAL_KEY") { value.optimizeForSequentialKey = sequential }
        if let compression = options["DATA_COMPRESSION"] { value.dataCompression = firstWord(compression) }
        return value
    }

    static func firstWord(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let word = trimmed.split(whereSeparator: { $0 == " " || $0 == "(" || $0 == "\n" }).first.map(String.init) ?? trimmed
        return ModuleText.unquote(word).uppercased()
    }

    static func historyTable(_ versioning: String) -> (String, String)? {
        var cursor = DDLTokenCursor(versioning)
        while !cursor.isAtEnd {
            if cursor.accept("HISTORY_TABLE") {
                cursor.accept("=")
                guard let (schema, name) = cursor.objectName() else { return nil }
                return (schema, name)
            }
            cursor.advance()
        }
        return nil
    }

    // MARK: - ALTER TABLE

    mutating func parseAlterTable(_ cursor: inout DDLTokenCursor) {
        guard let (schema, name) = cursor.objectName() else { return }
        var trusted = true
        if cursor.accept(["WITH", "NOCHECK"]) { trusted = false }
        if cursor.accept(["WITH", "CHECK"]) { trusted = true }
        let tableTypes: Set<SchemaObjectType> = [.table]
        if cursor.accept("ADD") {
            let start = cursor.position
            let elements = Self.splitTopLevel(cursor, from: start)
            var fragments: [DDLTokenCursor] = []
            for range in elements { fragments.append(cursor.sub(range)) }
            let isTrusted = trusted
            attach(schema: schema, name: name, types: tableTypes, "constraints added to \(schema).\(name)") { object in
                var parser = SchemaScriptParser()
                var table = object.table ?? TableDefinition()
                var checks: [CheckConstraintDefinition] = []
                for fragment in fragments {
                    var element = fragment
                    parser.parseTableElement(&element, table: &table, object: &object, checks: &checks,
                                             trusted: isTrusted)
                    if let (column, constraint) = parser.pendingDefault,
                       let index = table.columns.firstIndex(where: { $0.name.caseInsensitiveCompare(column) == .orderedSame }) {
                        table.columns[index].defaultConstraint = constraint
                        parser.pendingDefault = nil
                    }
                }
                table.checkConstraints.append(contentsOf: checks)
                if var key = table.primaryKey, key.dataSpace.isEmpty {
                    key.dataSpace = table.dataSpace
                    table.primaryKey = key
                }
                for index in table.uniqueConstraints.indices where table.uniqueConstraints[index].dataSpace.isEmpty {
                    table.uniqueConstraints[index].dataSpace = table.dataSpace
                }
                object.table = table
            }
            return
        }
        if cursor.accept("NOCHECK") || cursor.matches(["CHECK", "CONSTRAINT"]) {
            let disable = cursor.tokens[cursor.position - 1].text.uppercased() == "NOCHECK"
            if !disable { cursor.advance() }
            guard cursor.accept("CONSTRAINT"), let constraint = cursor.identifier() else { return }
            attach(schema: schema, name: name, types: tableTypes, "constraint state of \(constraint)") { object in
                guard var table = object.table else { return }
                for index in table.checkConstraints.indices
                    where table.checkConstraints[index].name.caseInsensitiveCompare(constraint) == .orderedSame {
                    table.checkConstraints[index].isDisabled = disable
                }
                for index in table.foreignKeys.indices
                    where table.foreignKeys[index].name.caseInsensitiveCompare(constraint) == .orderedSame {
                    table.foreignKeys[index].isDisabled = disable
                }
                object.table = table
            }
            return
        }
        if cursor.accept("SET"), cursor.word() == "(" {
            let options = cursor.optionList()
            attach(schema: schema, name: name, types: tableTypes, "options of \(schema).\(name)") { object in
                if let escalation = options["LOCK_ESCALATION"] {
                    object.table?.lockEscalation = Self.firstWord(escalation)
                }
                if let versioning = options["SYSTEM_VERSIONING"], Self.firstWord(versioning) == "ON",
                   let history = Self.historyTable(versioning) {
                    object.table?.temporal?.historySchema = history.0
                    object.table?.temporal?.historyTable = history.1
                }
            }
            return
        }
        if cursor.accept(["ENABLE", "CHANGE_TRACKING"]) {
            var trackColumns = false
            if cursor.accept("WITH"), cursor.word() == "(" {
                trackColumns = cursor.optionList()["TRACK_COLUMNS_UPDATED"].map(Self.firstWord) == "ON"
            }
            let track = trackColumns
            attach(schema: schema, name: name, types: tableTypes, "change tracking of \(schema).\(name)") { object in
                object.table?.changeTracking = true
                object.table?.changeTrackingColumnsUpdated = track
            }
            return
        }
        if cursor.accept("DISABLE") || cursor.matches(["ENABLE", "TRIGGER"]) {
            let disable = cursor.tokens[cursor.position - 1].text.uppercased() == "DISABLE"
            if !disable { cursor.advance() }
            guard cursor.accept("TRIGGER"), let trigger = cursor.identifier() else { return }
            attach(schema: schema, name: name, types: [.table, .view], "trigger state \(trigger)") { object in
                if let index = object.triggers.firstIndex(where: { $0.name.caseInsensitiveCompare(trigger) == .orderedSame }) {
                    object.triggers[index].isDisabled = disable
                }
            }
        }
    }

    /// Token ranges between top-level commas from `start` to the end of the statement.
    static func splitTopLevel(_ cursor: DDLTokenCursor, from start: Int) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var depth = 0
        var itemStart = start
        var index = start
        while index < cursor.tokens.count {
            let text = cursor.tokens[index].text
            if text == "(" { depth += 1 }
            if text == ")" { depth -= 1 }
            if text == ",", depth == 0 {
                if itemStart < index { ranges.append(itemStart..<index) }
                itemStart = index + 1
            }
            index += 1
        }
        if itemStart < cursor.tokens.count { ranges.append(itemStart..<cursor.tokens.count) }
        return ranges
    }

    // MARK: - Indexes

    mutating func parseCreateIndex(_ cursor: inout DDLTokenCursor) {
        var unique = false
        var kind: IndexKind = .nonclustered
        var isPrimaryXml = false
        var isXml = false
        var isSpatial = false
        var columnstore = false
        while !cursor.isAtEnd, cursor.word() != "INDEX" {
            switch cursor.word() {
            case "UNIQUE": unique = true
            case "CLUSTERED": kind = .clustered
            case "NONCLUSTERED": kind = .nonclustered
            case "COLUMNSTORE": columnstore = true
            case "PRIMARY": isPrimaryXml = true
            case "XML": isXml = true
            case "SPATIAL": isSpatial = true
            default: break
            }
            cursor.advance()
        }
        guard cursor.accept("INDEX"), let name = cursor.identifier(), cursor.accept("ON"),
              let (schema, table) = cursor.objectName() else { return }
        if columnstore { kind = kind == .clustered ? .clusteredColumnstore : .nonclusteredColumnstore }
        if isXml { kind = isPrimaryXml ? .primaryXml : .secondaryXml }
        if isSpatial { kind = .spatial }

        var index = IndexDefinition(name: name, kind: kind, isUnique: unique, columns: [], dataSpace: "")
        if cursor.word() == "(" {
            let columns = cursor.indexColumns()
            if kind == .nonclusteredColumnstore {
                index.includedColumns = columns.map(\.name)
            } else if kind != .clusteredColumnstore {
                index.columns = columns
            }
        }
        var explicitSpace = false
        while !cursor.isAtEnd {
            if cursor.accept("INCLUDE") {
                index.includedColumns = cursor.nameList()
            } else if cursor.accept("WHERE") {
                let range = cursor.skipUntil(["WITH", "ON"])
                index.filter = range.isEmpty ? nil : cursor.text(from: range.lowerBound, to: range.upperBound - 1)
            } else if cursor.accept(["USING", "XML", "INDEX"]) {
                index.primaryXmlIndex = cursor.identifier()
                if cursor.accept("FOR") { index.secondaryXmlType = cursor.current?.text.uppercased(); cursor.advance() }
            } else if cursor.accept("USING") {
                index.spatialTessellation = cursor.current?.text.uppercased()
                cursor.advance()
            } else if cursor.accept("WITH"), cursor.word() == "(" {
                let start = cursor.position
                let options = cursor.optionList()
                index.options = Self.indexOptions(options, base: index.options)
                if kind == .spatial {
                    let inner = cursor.text(from: start + 1, to: cursor.position - 2)
                    let kept = Self.splitTopLevel(DDLTokenCursor(inner), from: 0).map { range -> String in
                        let sub = DDLTokenCursor(inner)
                        return sub.text(from: range.lowerBound, to: range.upperBound - 1)
                    }.filter { item in
                        let upper = item.uppercased()
                        return upper.hasPrefix("BOUNDING_BOX") || upper.hasPrefix("GRIDS")
                            || upper.hasPrefix("CELLS_PER_OBJECT")
                    }
                    index.spatialBoundingBox = kept.joined(separator: ", ")
                }
                if kind == .clusteredColumnstore || kind == .nonclusteredColumnstore {
                    index.options.dataCompression = options["DATA_COMPRESSION"].map(Self.firstWord) ?? "COLUMNSTORE"
                }
            } else if cursor.accept("ON") {
                index.dataSpace = cursor.identifier() ?? ""
                explicitSpace = true
                if cursor.word() == "(" { index.partitionColumn = cursor.nameList().first }
            } else {
                cursor.advance()
            }
        }
        if (kind == .clusteredColumnstore || kind == .nonclusteredColumnstore), index.options.dataCompression == "NONE" {
            index.options.dataCompression = "COLUMNSTORE"
        }
        let noStorage = kind == .spatial || kind == .primaryXml || kind == .secondaryXml
        let definition = index
        attach(schema: schema, name: table, types: [.table, .view], "index \(name)") { object in
            var value = definition
            if !explicitSpace && !noStorage {
                value.dataSpace = object.table?.dataSpace ?? "PRIMARY"
                if object.table?.isMemoryOptimized ?? false { value.dataSpace = "" }
                if value.kind.isClustered || object.table?.partitionColumn != nil {
                    value.partitionColumn = value.partitionColumn ?? object.table?.partitionColumn
                }
            }
            object.indexes.removeAll { $0.name.caseInsensitiveCompare(value.name) == .orderedSame }
            object.indexes.append(value)
        }
    }

    mutating func parseCreateStatistics(_ cursor: inout DDLTokenCursor) {
        guard let name = cursor.identifier(), cursor.accept("ON"), let (schema, table) = cursor.objectName() else { return }
        var statistic = StatisticsDefinition(name: name, columns: cursor.word() == "(" ? cursor.nameList() : [])
        while !cursor.isAtEnd {
            if cursor.accept("WHERE") {
                let range = cursor.skipUntil(["WITH"])
                statistic.filter = range.isEmpty ? nil : cursor.text(from: range.lowerBound, to: range.upperBound - 1)
            } else if cursor.accept("NORECOMPUTE") {
                statistic.noRecompute = true
            } else {
                cursor.advance()
            }
        }
        let definition = statistic
        attach(schema: schema, name: table, types: [.table, .view], "statistics \(name)") { object in
            object.statistics.removeAll { $0.name.caseInsensitiveCompare(definition.name) == .orderedSame }
            object.statistics.append(definition)
        }
    }

    mutating func parseCreateFullText(_ text: String, _ cursor: inout DDLTokenCursor) {
        if cursor.accept("CATALOG") {
            guard let name = cursor.identifier() else { return }
            add(SchemaObject(type: .fullTextCatalog, schema: "", name: name, body: text))
            return
        }
        if cursor.accept("STOPLIST") {
            guard let name = cursor.identifier() else { return }
            var body = text
            if !body.hasSuffix(";") { body += ";" }
            add(SchemaObject(type: .fullTextStoplist, schema: "", name: name, body: body))
            return
        }
        guard cursor.accept(["INDEX", "ON"]), let (schema, table) = cursor.objectName() else { return }
        var columns: [FullTextIndexColumn] = []
        for range in cursor.parenthesizedList() {
            var sub = cursor.sub(range)
            guard let name = sub.identifier() else { continue }
            var column = FullTextIndexColumn(name: name)
            while !sub.isAtEnd {
                if sub.accept(["TYPE", "COLUMN"]) {
                    column.typeColumn = sub.identifier()
                } else if sub.accept("LANGUAGE") {
                    column.language = Int(sub.current?.text.sqlStringValue ?? "")
                    sub.advance()
                } else {
                    sub.advance()
                }
            }
            columns.append(column)
        }
        var definition = FullTextIndexDefinition(catalog: "", keyIndex: "", columns: columns)
        while !cursor.isAtEnd {
            if cursor.accept(["KEY", "INDEX"]) {
                definition.keyIndex = cursor.identifier() ?? ""
            } else if cursor.accept("ON") {
                if cursor.word() == "(" {
                    for range in cursor.parenthesizedList() {
                        var sub = cursor.sub(range)
                        if let name = sub.identifier() { definition.catalog = name }
                    }
                } else {
                    definition.catalog = cursor.identifier() ?? ""
                }
            } else if cursor.accept("WITH"), cursor.word() == "(" {
                let options = cursor.optionList()
                if let tracking = options["CHANGE_TRACKING"] { definition.changeTracking = Self.firstWord(tracking) }
                if let stoplist = options["STOPLIST"] { definition.stoplist = ModuleText.unquote(stoplist.trimmingCharacters(in: .whitespaces)) }
            } else {
                cursor.advance()
            }
        }
        if definition.stoplist == nil { definition.stoplist = "SYSTEM" }
        let index = definition
        attach(schema: schema, name: table, types: [.table], "full-text index on \(schema).\(table)") { object in
            object.table?.fullTextIndex = index
        }
    }
}
