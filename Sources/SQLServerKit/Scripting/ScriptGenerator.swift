import Foundation
import TDSKit

/// Produces the T-SQL behind "Script <object> as …".
///
/// This runs its own catalog queries rather than going through `MetadataService`,
/// because scripting needs far more detail per object than the tree does.
public struct ScriptGenerator: Sendable {

    /// Visible inside the module so the per-kind scripters in `ScriptGeneratorExtras` can
    /// run their own catalog queries.
    let session: SQLServerSession

    public init(session: SQLServerSession) {
        self.session = session
    }

    // MARK: - Entry point

    public func script(node: ObjectExplorerNode,
                       action: ScriptAction,
                       options: ScriptOptions) async throws -> String {
        let database = node.database ?? ""
        let schema = node.schema ?? "dbo"
        let name = node.name ?? node.label

        switch node.kind {
        case .database:
            switch action {
            case .create: return try await createDatabase(name: name.isEmpty ? database : name,
                                                          options: options)
            case .drop: return dropDatabaseScript(name.isEmpty ? database : name)
            default: throw SQLServerError.unsupportedOperation(
                "\(action.menuTitle) is not available for a database.")
            }

        case .table, .externalTable:
            return try await tableScript(database: database, schema: schema, table: name,
                                         action: action, options: options)

        case .view:
            switch action {
            case .select, .insert, .update, .delete:
                return try await tableScript(database: database, schema: schema, table: name,
                                             action: action, options: options)
            default:
                return try await moduleScript(database: database, schema: schema, name: name,
                                              kind: node.kind, action: action, options: options)
            }

        case .storedProcedure, .scalarFunction, .tableValuedFunction, .aggregateFunction, .trigger:
            return try await moduleScript(database: database, schema: schema, name: name,
                                          kind: node.kind, action: action, options: options)

        case .index:
            // The tree records an index's table under `parentTable`; `table` was never
            // written by `MetadataService`, so reading it silently produced no script.
            let table = node.info["parentTable"] ?? node.info["table"] ?? ""
            return try await indexScript(database: database, schema: schema, table: table,
                                         index: name, action: action, options: options)

        default:
            // Synonyms, sequences, user-defined types, schemas, principals and the
            // partitioning objects are rebuilt from their catalog rows instead.
            return try await extraScript(node: node, action: action, options: options)
        }
    }

    // MARK: - Tables

    public func createTable(database: String, schema: String, table: String,
                            options: ScriptOptions) async throws -> String {
        try await tableScript(database: database, schema: schema, table: table,
                              action: .create, options: options)
    }

    public func selectTopRows(database: String, schema: String, table: String,
                              top: Int) async throws -> String {
        var options = ScriptOptions()
        options.selectTopRows = top
        options.includeDescriptiveHeader = false
        options.includeSetOptionsHeader = false
        return try await tableScript(database: database, schema: schema, table: table,
                                     action: .select, options: options)
    }

    private func tableScript(database: String, schema: String, table: String,
                             action: ScriptAction, options: ScriptOptions) async throws -> String {
        let columns = try await loadColumns(database: database, schema: schema, object: table)
        guard !columns.isEmpty else {
            throw SQLServerError.objectNotFound("\(schema).\(table)")
        }

        switch action {
        case .select:
            return selectStatement(database: database, schema: schema, table: table,
                                   columns: columns, options: options)
        case .insert:
            return insertTemplate(schema: schema, table: table, columns: columns, options: options)
        case .update:
            return updateTemplate(schema: schema, table: table, columns: columns, options: options)
        case .delete:
            return deleteTemplate(schema: schema, table: table, options: options)
        case .drop:
            return try await header(kind: "Table", schema: schema, name: table, options: options)
                + dropTableScript(schema: schema, table: table)
        case .dropAndCreate:
            let drop = dropTableScript(schema: schema, table: table)
            var createOptions = options
            createOptions.includeDescriptiveHeader = false
            let create = try await createTableScript(database: database, schema: schema,
                                                     table: table, columns: columns,
                                                     options: createOptions)
            return try await header(kind: "Table", schema: schema, name: table, options: options)
                + drop + create
        case .create:
            let body = try await createTableScript(database: database, schema: schema, table: table,
                                                   columns: columns, options: options)
            var prefix = try await header(kind: "Table", schema: schema, name: table, options: options)
            if options.includeDropIfExists {
                prefix += dropTableScript(schema: schema, table: table)
            }
            return prefix + body
        case .alter, .execute:
            throw SQLServerError.unsupportedOperation("\(action.menuTitle) is not available for a table.")
        }
    }

    private func createTableScript(database: String, schema: String, table: String,
                                   columns: [ScriptColumn], options: ScriptOptions) async throws -> String {
        let defaultCollation = try await databaseCollation(database)
        let keys = try await loadKeyConstraints(database: database, schema: schema, table: table)
        let indexes = options.scriptIndexes
            ? try await loadIndexes(database: database, schema: schema, table: table)
            : []
        let foreignKeys = options.scriptForeignKeys
            ? try await loadForeignKeys(database: database, schema: schema, table: table)
            : []
        let checks = options.scriptCheckConstraints
            ? try await loadCheckConstraints(database: database, schema: schema, table: table)
            : []
        let defaults = options.scriptDefaults
            ? try await loadDefaultConstraints(database: database, schema: schema, table: table)
            : []
        let properties = options.scriptExtendedProperties
            ? try await loadExtendedProperties(database: database, schema: schema, table: table)
            : []

        let target = qualified(schema: schema, name: table, options: options)
        var out = ""

        if options.includeSetOptionsHeader {
            out += "SET ANSI_NULLS ON\nGO\nSET QUOTED_IDENTIFIER ON\nGO\n"
        }
        if options.includeIfNotExists {
            out += "IF NOT EXISTS (SELECT * FROM sys.objects "
                + "WHERE object_id = OBJECT_ID(N'\(escaped(target))') AND type IN (N'U'))\n"
        }

        out += "CREATE TABLE \(target)(\n"

        var lines: [String] = columns.map { column in
            "\t" + columnDefinition(column, defaultCollation: defaultCollation, options: options)
        }

        // Primary key and unique constraints go inline, like SSMS emits them.
        for key in keys where options.scriptPrimaryKey || !key.isPrimaryKey {
            lines.append("\t" + Self.keyConstraintDefinition(key))
        }
        out += lines.joined(separator: ",\n")
        out += "\n) ON \(SQLIdentifier.quote(tableFilegroup(indexes: indexes, keys: keys)))\n"
        if columns.contains(where: { $0.isLob }) {
            out += "TEXTIMAGE_ON \(SQLIdentifier.quote("PRIMARY"))\n"
        }
        out += "GO\n"

        // A clustered columnstore index is created on the finished table here as well:
        // CREATE TABLE has no form that builds one inline.
        for index in indexes where !index.isConstraint {
            out += "\n" + Self.createIndexStatement(index, schema: schema, table: table,
                                                    options: options)
        }

        for def in defaults {
            out += "\nALTER TABLE \(target) ADD CONSTRAINT \(SQLIdentifier.quote(def.name)) "
                + "DEFAULT \(def.definition) FOR \(SQLIdentifier.quote(def.column))\nGO\n"
        }

        for key in foreignKeys {
            out += "\n" + foreignKeyStatement(key, target: target, options: options)
        }

        for check in checks {
            out += "\nALTER TABLE \(target) WITH \(check.isNotTrusted ? "NOCHECK" : "CHECK") "
                + "ADD CONSTRAINT \(SQLIdentifier.quote(check.name)) CHECK \(check.definition)\nGO\n"
            out += "ALTER TABLE \(target) \(check.isDisabled ? "NOCHECK" : "CHECK") "
                + "CONSTRAINT \(SQLIdentifier.quote(check.name))\nGO\n"
        }

        if options.scriptTriggers {
            for trigger in try await loadTriggerDefinitions(database: database, schema: schema,
                                                            table: table) {
                out += "\n" + Self.setOptionsHeader(for: trigger, options: options)
                    + trigger.definition + "\nGO\n"
            }
        }

        for property in properties {
            out += "\n" + extendedPropertyStatement(property, schema: schema, table: table)
        }

        return out
    }

    private func columnDefinition(_ column: ScriptColumn,
                                  defaultCollation: String,
                                  options: ScriptOptions) -> String {
        if column.isComputed {
            var text = "\(SQLIdentifier.quote(column.name)) AS \(column.computedDefinition)"
            if column.isPersisted {
                text += " PERSISTED"
                if !column.isNullable { text += " NOT NULL" }
            }
            return text
        }

        var text = "\(SQLIdentifier.quote(column.name)) \(column.typeName)"

        if column.isFileStream { text += " FILESTREAM" }
        if options.scriptCollation, !column.collation.isEmpty,
           column.collation != defaultCollation {
            text += " COLLATE \(column.collation)"
        }
        if column.isSparse { text += " SPARSE" }
        if options.scriptIdentity, column.isIdentity {
            text += " IDENTITY(\(column.identitySeed),\(column.identityIncrement))"
        }
        if column.isRowGuidCol { text += " ROWGUIDCOL" }
        text += column.isNullable ? " NULL" : " NOT NULL"
        return text
    }

    /// The inline `CONSTRAINT … PRIMARY KEY/UNIQUE` clause of a CREATE TABLE statement.
    public static func keyConstraintDefinition(_ key: ScriptKeyConstraint) -> String {
        var text = "CONSTRAINT \(SQLIdentifier.quote(key.name)) "
        text += key.isPrimaryKey ? "PRIMARY KEY " : "UNIQUE "
        text += key.isClustered ? "CLUSTERED " : "NONCLUSTERED "
        text += "\n\t(\n\t\t" + key.columns.map(\.keyClause).joined(separator: ",\n\t\t") + "\n\t)"
        text += "WITH (PAD_INDEX = \(onOff(key.padIndex)), STATISTICS_NORECOMPUTE = OFF, "
            + "IGNORE_DUP_KEY = \(onOff(key.ignoreDupKey)), ALLOW_ROW_LOCKS = \(onOff(key.allowRowLocks)), "
            + "ALLOW_PAGE_LOCKS = \(onOff(key.allowPageLocks))"
        if key.fillFactor > 0 { text += ", FILLFACTOR = \(key.fillFactor)" }
        text += ") ON \(SQLIdentifier.quote(key.filegroup))"
        return text
    }

    /// `CREATE … INDEX` for one index, in the form its type needs: rowstore, columnstore,
    /// XML and spatial indexes all have different syntax, and an index this cannot script
    /// (a selective XML index, a hash index) becomes a comment rather than invalid SQL.
    public static func createIndexStatement(_ index: ScriptIndex, schema: String, table: String,
                                            options: ScriptOptions) -> String {
        let target = qualifiedName(schema: schema, name: table, options: options)
        let name = SQLIdentifier.quote(index.name)
        var text = ""
        if options.includeIfNotExists {
            text += "IF NOT EXISTS (SELECT * FROM sys.indexes WHERE object_id = "
                + "OBJECT_ID(\(SQLIdentifier.literal(target))) AND name = "
                + "\(SQLIdentifier.literal(index.name)))\n"
        }

        let keyList = "(\n\t" + index.keyColumns.map(\.keyClause).joined(separator: ",\n\t") + "\n)"
        // XML and spatial indexes name one column and take no sort direction.
        let bareList = "(\n\t" + index.keyColumns.map { SQLIdentifier.quote($0.name) }
            .joined(separator: ",\n\t") + "\n)"
        var filter = ""
        if let definition = index.filterDefinition, !definition.isEmpty {
            filter = "\nWHERE \(definition)"
        }
        // The options every rowstore-like index type accepts; STATISTICS_NORECOMPUTE is not
        // among them for XML indexes, so it is added by the callers that take it.
        var lockOptions = "SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, "
            + "ALLOW_ROW_LOCKS = \(onOff(index.allowRowLocks)), "
            + "ALLOW_PAGE_LOCKS = \(onOff(index.allowPageLocks))"
        if index.fillFactor > 0 { lockOptions += ", FILLFACTOR = \(index.fillFactor)" }
        let filegroup = " ON \(SQLIdentifier.quote(index.filegroup))\nGO\n"

        switch index.type {
        case 1, 2:
            text += "CREATE "
            if index.isUnique { text += "UNIQUE " }
            text += index.type == 1 ? "CLUSTERED " : "NONCLUSTERED "
            text += "INDEX \(name) ON \(target)\n" + keyList
            if !index.includedColumns.isEmpty {
                text += "\nINCLUDE(\(index.includedColumns.map(SQLIdentifier.quote).joined(separator: ", ")))"
            }
            text += filter
            text += "\nWITH (PAD_INDEX = \(onOff(index.padIndex)), STATISTICS_NORECOMPUTE = OFF, "
                + lockOptions
            let compression = index.dataCompression.uppercased()
            if compression == "ROW" || compression == "PAGE" {
                text += ", DATA_COMPRESSION = \(compression)"
            }
            text += ")" + filegroup

        case 5, 6:
            // Columnstore: no key list, no fill factor and no lock options. A clustered
            // columnstore index covers every column, so it takes no column list at all;
            // a nonclustered one names its columns, which sys.index_columns reports as
            // included columns.
            let archive = index.dataCompression.uppercased() == "COLUMNSTORE_ARCHIVE"
            let columnstoreOptions = "WITH (DROP_EXISTING = OFF, "
                + "COMPRESSION_DELAY = \(max(0, index.compressionDelay)), "
                + "DATA_COMPRESSION = \(archive ? "COLUMNSTORE_ARCHIVE" : "COLUMNSTORE"))"
            if index.type == 5 {
                text += "CREATE CLUSTERED COLUMNSTORE INDEX \(name) ON \(target)\n"
                    + columnstoreOptions + filegroup
            } else {
                let columns = index.includedColumns.isEmpty
                    ? index.keyColumns.map(\.name)
                    : index.includedColumns
                text += "CREATE NONCLUSTERED COLUMNSTORE INDEX \(name) ON \(target)\n"
                    + "(\n\t" + columns.map(SQLIdentifier.quote).joined(separator: ",\n\t") + "\n)"
                    + filter + "\n" + columnstoreOptions + filegroup
            }

        case 3:
            guard let xml = index.xml, xml.indexType == 0 || xml.indexType == 1 else {
                return text + "-- Selective XML index \(name) on \(target) is not scripted.\n"
            }
            if xml.indexType == 0 {
                text += "CREATE PRIMARY XML INDEX \(name) ON \(target)\n" + bareList
            } else {
                text += "CREATE XML INDEX \(name) ON \(target)\n" + bareList
                    + "\nUSING XML INDEX \(SQLIdentifier.quote(xml.primaryIndex)) "
                    + "FOR \(xml.secondaryType.uppercased())"
            }
            // An XML index lives with the clustered index, so it takes no ON clause.
            text += "\nWITH (PAD_INDEX = \(onOff(index.padIndex)), " + lockOptions + ")\nGO\n"

        case 4:
            guard let spatial = index.spatial else {
                return text + "-- Spatial index \(name) on \(target) is not scripted.\n"
            }
            text += "CREATE SPATIAL INDEX \(name) ON \(target)\n" + bareList
            text += "\nUSING \(spatial.tessellationScheme.uppercased())"
            var spatialOptions: [String] = []
            if spatial.boundingBox.count == 4 {
                // Whole numbers are written plainly; anything else in Swift's shortest
                // round-trip form, which T-SQL reads as a float literal.
                let box = spatial.boundingBox.map { value -> String in
                    value == value.rounded() && abs(value) < 1e15
                        ? String(format: "%.0f", value)
                        : String(value)
                }
                spatialOptions.append("BOUNDING_BOX = (\(box.joined(separator: ", ")))")
            }
            if !spatial.gridLevels.isEmpty {
                let levels = spatial.gridLevels.enumerated()
                    .map { "LEVEL_\($0.offset + 1) = \($0.element.uppercased())" }
                spatialOptions.append("GRIDS = (\(levels.joined(separator: ", ")))")
            }
            if spatial.cellsPerObject > 0 {
                spatialOptions.append("CELLS_PER_OBJECT = \(spatial.cellsPerObject)")
            }
            spatialOptions.append("PAD_INDEX = \(onOff(index.padIndex))")
            spatialOptions.append("STATISTICS_NORECOMPUTE = OFF")
            spatialOptions.append(lockOptions)
            text += "\nWITH (" + spatialOptions.joined(separator: ", ") + ")" + filegroup

        default:
            return text + "-- Index \(name) on \(target) (sys.indexes.type \(index.type)) "
                + "is not scripted.\n"
        }
        return text
    }

    private func foreignKeyStatement(_ key: ScriptForeignKey, target: String,
                                     options: ScriptOptions) -> String {
        let referenced = qualified(schema: key.referencedSchema, name: key.referencedTable,
                                   options: options)
        var text = "ALTER TABLE \(target) WITH \(key.isNotTrusted ? "NOCHECK" : "CHECK") "
            + "ADD CONSTRAINT \(SQLIdentifier.quote(key.name)) FOREIGN KEY("
            + key.columns.map(SQLIdentifier.quote).joined(separator: ", ") + ")\n"
        text += "REFERENCES \(referenced) ("
            + key.referencedColumns.map(SQLIdentifier.quote).joined(separator: ", ") + ")\n"
        if key.deleteAction != "NO_ACTION" {
            text += "ON DELETE \(key.deleteAction.replacingOccurrences(of: "_", with: " "))\n"
        }
        if key.updateAction != "NO_ACTION" {
            text += "ON UPDATE \(key.updateAction.replacingOccurrences(of: "_", with: " "))\n"
        }
        text += "GO\n"
        text += "ALTER TABLE \(target) \(key.isDisabled ? "NOCHECK" : "CHECK") "
            + "CONSTRAINT \(SQLIdentifier.quote(key.name))\nGO\n"
        return text
    }

    private func extendedPropertyStatement(_ property: ScriptExtendedProperty,
                                           schema: String, table: String) -> String {
        var text = "EXEC sys.sp_addextendedproperty @name = N'\(escapedLiteral(property.name))', "
            + "@value = N'\(escapedLiteral(property.value))', "
            + "@level0type = N'SCHEMA', @level0name = N'\(escapedLiteral(schema))', "
            + "@level1type = N'TABLE', @level1name = N'\(escapedLiteral(table))'"
        if let column = property.column {
            text += ", @level2type = N'COLUMN', @level2name = N'\(escapedLiteral(column))'"
        }
        return text + "\nGO\n"
    }

    private func tableFilegroup(indexes: [ScriptIndex], keys: [ScriptKeyConstraint]) -> String {
        keys.first(where: { $0.isClustered })?.filegroup
            ?? indexes.first(where: { $0.isClustered })?.filegroup
            ?? "PRIMARY"
    }

    private func dropTableScript(schema: String, table: String) -> String {
        let target = SQLIdentifier.quote(schema: schema, name: table)
        return "DROP TABLE IF EXISTS \(target)\nGO\n"
    }

    private func dropDatabaseScript(_ name: String) -> String {
        "ALTER DATABASE \(SQLIdentifier.quote(name)) SET SINGLE_USER WITH ROLLBACK IMMEDIATE\nGO\n"
            + "DROP DATABASE IF EXISTS \(SQLIdentifier.quote(name))\nGO\n"
    }

    // MARK: - DML templates

    private func selectStatement(database: String, schema: String, table: String,
                                 columns: [ScriptColumn], options: ScriptOptions) -> String {
        // SSMS puts the first column on the SELECT line and prefixes the rest with ",".
        let quoted = columns.map { SQLIdentifier.quote($0.name) }
        let list = quoted.enumerated()
            .map { $0.offset == 0 ? $0.element : "      ," + $0.element }
            .joined(separator: "\n")
        let target = database.isEmpty
            ? qualified(schema: schema, name: table, options: options)
            : SQLIdentifier.quote(database: database, schema: schema, name: table)
        var out = ""
        if options.includeDescriptiveHeader {
            out += "/****** Script for SelectTopNRows command from SSMS for Mac  ******/\n"
        }
        out += "SELECT "
        out += options.selectTopRows > 0 ? "TOP (\(options.selectTopRows)) " : ""
        out += list + "\n  FROM \(target)\n"
        return out
    }

    private func insertTemplate(schema: String, table: String,
                                columns: [ScriptColumn], options: ScriptOptions) -> String {
        let insertable = columns.filter { !$0.isIdentity && !$0.isComputed && !$0.isTimestamp }
        let target = qualified(schema: schema, name: table, options: options)
        let names = insertable.map { "\t\t" + SQLIdentifier.quote($0.name) }.joined(separator: ",\n")
        let values = insertable.map { "\t\t<\($0.name), \($0.typeName),>" }.joined(separator: ",\n")
        return "INSERT INTO \(target)\n\t(\n\(names)\n\t)\nVALUES\n\t(\n\(values)\n\t)\nGO\n"
    }

    private func updateTemplate(schema: String, table: String,
                                columns: [ScriptColumn], options: ScriptOptions) -> String {
        let updatable = columns.filter { !$0.isIdentity && !$0.isComputed && !$0.isTimestamp }
        let target = qualified(schema: schema, name: table, options: options)
        let assignments = updatable
            .map { "\t\(SQLIdentifier.quote($0.name)) = <\($0.name), \($0.typeName),>" }
            .joined(separator: ",\n")
        return "UPDATE \(target)\nSET\n\(assignments)\nWHERE <Search Conditions,,>\nGO\n"
    }

    private func deleteTemplate(schema: String, table: String, options: ScriptOptions) -> String {
        "DELETE FROM \(qualified(schema: schema, name: table, options: options))\n"
            + "WHERE <Search Conditions,,>\nGO\n"
    }

    // MARK: - Modules

    private func moduleScript(database: String, schema: String, name: String,
                              kind: ObjectNodeKind, action: ScriptAction,
                              options: ScriptOptions) async throws -> String {
        let label = moduleLabel(kind)
        let target = qualified(schema: schema, name: name, options: options)

        if action == .execute {
            return try await executeTemplate(database: database, schema: schema,
                                             procedure: name, options: options)
        }

        if action == .drop {
            return try await header(kind: label, schema: schema, name: name, options: options)
                + "DROP \(dropKeyword(kind)) IF EXISTS \(target)\nGO\n"
        }

        guard let module = try await moduleDefinition(database: database, schema: schema,
                                                      name: name) else {
            throw SQLServerError.objectNotFound("\(schema).\(name)")
        }
        let definition = module.definition

        var out = try await header(kind: label, schema: schema, name: name, options: options)
        out += Self.setOptionsHeader(for: module, options: options)

        switch action {
        case .alter:
            out += ScriptGenerator.rewriteLeadingCreate(definition, to: "ALTER")
        case .dropAndCreate:
            out += "DROP \(dropKeyword(kind)) IF EXISTS \(target)\nGO\n"
            out += definition
        case .create:
            if options.includeDropIfExists {
                out += "DROP \(dropKeyword(kind)) IF EXISTS \(target)\nGO\n"
            }
            if options.includeIfNotExists {
                out += "IF NOT EXISTS (SELECT * FROM sys.objects "
                    + "WHERE object_id = OBJECT_ID(N'\(escaped(target))'))\n"
                    + "\tEXEC dbo.sp_executesql @statement = N'"
                    + definition.replacingOccurrences(of: "'", with: "''") + "'\n"
                return out + "GO\n"
            }
            out += definition
        default:
            throw SQLServerError.unsupportedOperation("\(action.menuTitle) is not available here.")
        }

        if !out.hasSuffix("\n") { out += "\n" }
        return out + "GO\n"
    }

    /// Turn `CREATE PROCEDURE` / `CREATE OR ALTER PROCEDURE` into `ALTER PROCEDURE`,
    /// skipping any leading whitespace and comments the author left in place.
    public static func rewriteLeadingCreate(_ definition: String, to keyword: String) -> String {
        let lexer = TSQLLexer()
        for token in lexer.tokenize(definition) {
            switch token.kind {
            case .whitespace, .lineComment, .blockComment:
                continue
            case .keyword, .identifier:
                guard token.text.caseInsensitiveCompare("CREATE") == .orderedSame else {
                    return definition
                }
                let ns = definition as NSString
                var replaceRange = NSRange(location: token.start, length: token.length)
                // Collapse "CREATE OR ALTER" down to the single keyword.
                let rest = lexer.significantTokens(ns.substring(from: token.start + token.length))
                if rest.count >= 2,
                   rest[0].text.caseInsensitiveCompare("OR") == .orderedSame,
                   rest[1].text.caseInsensitiveCompare("ALTER") == .orderedSame {
                    let end = token.start + token.length + rest[1].start + rest[1].length
                    replaceRange = NSRange(location: token.start, length: end - token.start)
                }
                return ns.replacingCharacters(in: replaceRange, with: keyword)
            default:
                return definition
            }
        }
        return definition
    }

    private func executeTemplate(database: String, schema: String, procedure: String,
                                 options: ScriptOptions) async throws -> String {
        let parameters = try await loadParameters(database: database, schema: schema, routine: procedure)
        let target = qualified(schema: schema, name: procedure, options: options)

        var out = try await header(kind: "StoredProcedure", schema: schema, name: procedure,
                                   options: options)
        out += "DECLARE\t@return_value int"
        for parameter in parameters {
            out += ",\n\t\t@\(parameter.bareName) \(parameter.typeName)"
        }
        out += "\n\n"
        for parameter in parameters where parameter.isOutput {
            out += "SELECT\t@\(parameter.bareName) = <@\(parameter.bareName), "
                + "\(parameter.typeName), >\n"
        }
        out += "\nEXEC\t@return_value = \(target)\n"
        let arguments = parameters.map { parameter -> String in
            let value = parameter.isOutput
                ? "@\(parameter.bareName) OUTPUT"
                : "<@\(parameter.bareName), \(parameter.typeName), >"
            return "\t\t\(parameter.name) = \(value)"
        }
        out += arguments.joined(separator: ",\n")
        out += "\n\nSELECT\t'Return Value' = @return_value\n"
        for parameter in parameters where parameter.isOutput {
            out += "SELECT\t@\(parameter.bareName) AS N'@\(parameter.bareName)'\n"
        }
        return out + "\nGO\n"
    }

    private func indexScript(database: String, schema: String, table: String, index: String,
                             action: ScriptAction, options: ScriptOptions) async throws -> String {
        let indexes = try await loadIndexes(database: database, schema: schema, table: table)
        guard let match = indexes.first(where: { $0.name == index }) else {
            throw SQLServerError.objectNotFound(index)
        }
        let target = qualified(schema: schema, name: table, options: options)
        switch action {
        case .drop:
            return "DROP INDEX \(SQLIdentifier.quote(index)) ON \(target)\nGO\n"
        default:
            return Self.createIndexStatement(match, schema: schema, table: table, options: options)
        }
    }

    // MARK: - Databases

    public func createDatabase(name: String, options: ScriptOptions) async throws -> String {
        let sql = """
        SELECT d.name, d.collation_name, d.compatibility_level, d.recovery_model_desc,
               d.is_read_committed_snapshot_on, d.snapshot_isolation_state_desc,
               d.page_verify_option_desc, d.is_auto_close_on, d.is_auto_shrink_on,
               d.is_auto_create_stats_on, d.is_auto_update_stats_on
        FROM sys.databases AS d
        WHERE d.name = \(SQLIdentifier.literal(name))
        """
        let result = try await session.metadataQuery(sql)
        guard let row = result.resultSets.first?.dictionaries().first else {
            throw SQLServerError.objectNotFound(name)
        }

        let quoted = SQLIdentifier.quote(name)
        var out = ""
        if options.includeDescriptiveHeader {
            out += "/****** Object:  Database \(quoted)    Script Date: \(timestamp()) ******/\n"
        }
        out += "CREATE DATABASE \(quoted)\n"
        out += " COLLATE \(row.string("collation_name"))\nGO\n"
        out += "ALTER DATABASE \(quoted) SET COMPATIBILITY_LEVEL = "
            + "\(row.int("compatibility_level"))\nGO\n"
        out += "ALTER DATABASE \(quoted) SET ANSI_NULL_DEFAULT OFF\nGO\n"
        out += "ALTER DATABASE \(quoted) SET ANSI_NULLS OFF\nGO\n"
        out += "ALTER DATABASE \(quoted) SET ANSI_PADDING OFF\nGO\n"
        out += "ALTER DATABASE \(quoted) SET ANSI_WARNINGS OFF\nGO\n"
        out += "ALTER DATABASE \(quoted) SET ARITHABORT OFF\nGO\n"
        out += "ALTER DATABASE \(quoted) SET AUTO_CLOSE "
            + "\(onOff(row.bool("is_auto_close_on")))\nGO\n"
        out += "ALTER DATABASE \(quoted) SET AUTO_SHRINK "
            + "\(onOff(row.bool("is_auto_shrink_on")))\nGO\n"
        out += "ALTER DATABASE \(quoted) SET AUTO_CREATE_STATISTICS "
            + "\(onOff(row.bool("is_auto_create_stats_on")))\nGO\n"
        out += "ALTER DATABASE \(quoted) SET AUTO_UPDATE_STATISTICS "
            + "\(onOff(row.bool("is_auto_update_stats_on")))\nGO\n"
        out += "ALTER DATABASE \(quoted) SET READ_COMMITTED_SNAPSHOT "
            + "\(onOff(row.bool("is_read_committed_snapshot_on")))\nGO\n"
        out += "ALTER DATABASE \(quoted) SET PAGE_VERIFY "
            + "\(row.string("page_verify_option_desc", default: "CHECKSUM"))\nGO\n"
        out += "ALTER DATABASE \(quoted) SET RECOVERY "
            + "\(row.string("recovery_model_desc", default: "FULL"))\nGO\n"
        out += "ALTER DATABASE \(quoted) SET MULTI_USER\nGO\n"
        return out
    }

    // MARK: - Catalog access

    /// `OBJECT_ID(N'[schema].[name]')`, with both parts bracket-quoted so a name holding a
    /// dot, a bracket or a quote still resolves.
    public static func objectIDExpression(schema: String, name: String) -> String {
        "OBJECT_ID(\(SQLIdentifier.literal(SQLIdentifier.quote(schema: schema, name: name))))"
    }

    private func loadColumns(database: String, schema: String,
                             object: String) async throws -> [ScriptColumn] {
        // CLR types (hierarchyid, geometry, geography, assembly types) have no sys.types
        // row for their system_type_id, so the base type is a LEFT JOIN that falls back to
        // the type's own name.
        let sql = """
        SELECT c.name, c.column_id, c.is_nullable, c.is_identity, c.is_computed,
               c.is_rowguidcol, c.is_filestream, c.is_sparse,
               ISNULL(c.collation_name, N'') AS collation_name,
               t.name AS type_name, ISNULL(ty.name, t.name) AS base_type_name,
               ISNULL(ts.name, N'') AS type_schema,
               c.max_length, c.precision, c.scale, c.user_type_id, t.is_user_defined,
               ISNULL(CONVERT(nvarchar(4000), cc.definition), N'') AS computed_definition,
               ISNULL(CONVERT(int, cc.is_persisted), 0) AS is_persisted,
               ISNULL(CONVERT(nvarchar(64), ic.seed_value), N'1') AS seed_value,
               ISNULL(CONVERT(nvarchar(64), ic.increment_value), N'1') AS increment_value
        FROM sys.columns AS c
        JOIN sys.types AS t ON t.user_type_id = c.user_type_id
        LEFT JOIN sys.types AS ty ON ty.user_type_id = t.system_type_id AND ty.is_user_defined = 0
        LEFT JOIN sys.schemas AS ts ON ts.schema_id = t.schema_id
        LEFT JOIN sys.computed_columns AS cc ON cc.object_id = c.object_id
             AND cc.column_id = c.column_id
        LEFT JOIN sys.identity_columns AS ic ON ic.object_id = c.object_id
             AND ic.column_id = c.column_id
        WHERE c.object_id = \(Self.objectIDExpression(schema: schema, name: object))
        ORDER BY c.column_id
        """
        let result = try await session.metadataQuery(sql, database: database)
        return (result.resultSets.first?.dictionaries() ?? []).map { row in
            ScriptColumn(
                name: row.string("name"),
                ordinal: row.int("column_id"),
                typeName: ScriptGenerator.formatType(
                    name: row.string("type_name"),
                    schema: row.string("type_schema"),
                    baseName: row.string("base_type_name"),
                    maxLength: row.int("max_length"),
                    precision: row.int("precision"),
                    scale: row.int("scale"),
                    isUserDefined: row.bool("is_user_defined")),
                baseTypeName: row.string("base_type_name"),
                isNullable: row.bool("is_nullable"),
                isIdentity: row.bool("is_identity"),
                isComputed: row.bool("is_computed"),
                isPersisted: row.bool("is_persisted"),
                isRowGuidCol: row.bool("is_rowguidcol"),
                isFileStream: row.bool("is_filestream"),
                isSparse: row.bool("is_sparse"),
                collation: row.string("collation_name"),
                computedDefinition: row.string("computed_definition"),
                identitySeed: row.string("seed_value", default: "1"),
                identityIncrement: row.string("increment_value", default: "1")
            )
        }
    }

    private func loadKeyConstraints(database: String, schema: String,
                                    table: String) async throws -> [ScriptKeyConstraint] {
        let objectID = Self.objectIDExpression(schema: schema, name: table)
        let sql = """
        SELECT kc.name, kc.type, i.index_id, i.is_padded, i.fill_factor, i.ignore_dup_key,
               i.allow_row_locks, i.allow_page_locks, i.type_desc,
               ISNULL(fg.name, N'PRIMARY') AS filegroup_name
        FROM sys.key_constraints AS kc
        JOIN sys.indexes AS i ON i.object_id = kc.parent_object_id AND i.index_id = kc.unique_index_id
        LEFT JOIN sys.filegroups AS fg ON fg.data_space_id = i.data_space_id
        WHERE kc.parent_object_id = \(objectID)
        ORDER BY kc.type DESC, kc.name;

        \(Self.indexColumnsQuery(objectID: objectID))
        """
        let result = try await session.metadataQuery(sql, database: database)
        let columns = Self.indexColumns(from: result.resultSets.count > 1 ? result.resultSets[1] : nil)
        return (result.resultSets.first?.dictionaries() ?? []).map { row in
            ScriptKeyConstraint(
                name: row.string("name"),
                isPrimaryKey: row.string("type").trimmingCharacters(in: .whitespaces) == "PK",
                isClustered: row.string("type_desc") == "CLUSTERED",
                columns: columns[row.int("index_id")]?.keys ?? [],
                padIndex: row.bool("is_padded"),
                fillFactor: row.int("fill_factor"),
                ignoreDupKey: row.bool("ignore_dup_key"),
                allowRowLocks: row.bool("allow_row_locks", default: true),
                allowPageLocks: row.bool("allow_page_locks", default: true),
                filegroup: row.string("filegroup_name", default: "PRIMARY")
            )
        }
    }

    private func loadIndexes(database: String, schema: String,
                             table: String) async throws -> [ScriptIndex] {
        let objectID = Self.objectIDExpression(schema: schema, name: table)
        let sql = """
        SELECT i.name, i.index_id, CAST(i.type AS int) AS index_type, i.is_unique, i.type_desc,
               i.is_padded, i.fill_factor, i.allow_row_locks, i.allow_page_locks,
               i.is_unique_constraint, i.is_primary_key,
               ISNULL(i.filter_definition, N'') AS filter_definition,
               ISNULL(fg.name, N'PRIMARY') AS filegroup_name,
               ISNULL(p.data_compression_desc, N'NONE') AS data_compression,
               CAST(ISNULL(i.compression_delay, 0) AS int) AS compression_delay,
               ISNULL(CAST(xi.xml_index_type AS int), -1) AS xml_index_type,
               ISNULL(xi.secondary_type_desc, N'') AS xml_secondary_type,
               ISNULL(pxi.name, N'') AS xml_primary_index,
               ISNULL(si.tessellation_scheme, N'') AS tessellation_scheme,
               sit.bounding_box_xmin, sit.bounding_box_ymin,
               sit.bounding_box_xmax, sit.bounding_box_ymax,
               ISNULL(sit.level_1_grid_desc, N'') AS level_1_grid,
               ISNULL(sit.level_2_grid_desc, N'') AS level_2_grid,
               ISNULL(sit.level_3_grid_desc, N'') AS level_3_grid,
               ISNULL(sit.level_4_grid_desc, N'') AS level_4_grid,
               CAST(ISNULL(sit.cells_per_object, 0) AS int) AS cells_per_object
        FROM sys.indexes AS i
        LEFT JOIN sys.filegroups AS fg ON fg.data_space_id = i.data_space_id
        LEFT JOIN sys.partitions AS p ON p.object_id = i.object_id AND p.index_id = i.index_id
             AND p.partition_number = 1
        LEFT JOIN sys.xml_indexes AS xi ON xi.object_id = i.object_id AND xi.index_id = i.index_id
        LEFT JOIN sys.indexes AS pxi ON pxi.object_id = xi.object_id
             AND pxi.index_id = xi.using_xml_index_id
        LEFT JOIN sys.spatial_indexes AS si ON si.object_id = i.object_id AND si.index_id = i.index_id
        LEFT JOIN sys.spatial_index_tessellations AS sit ON sit.object_id = i.object_id
             AND sit.index_id = i.index_id
        WHERE i.object_id = \(objectID)
          AND i.index_id > 0 AND i.name IS NOT NULL
        ORDER BY i.index_id;

        \(Self.indexColumnsQuery(objectID: objectID))
        """
        let result = try await session.metadataQuery(sql, database: database)
        let columns = Self.indexColumns(from: result.resultSets.count > 1 ? result.resultSets[1] : nil)
        return (result.resultSets.first?.dictionaries() ?? []).map { row in
            let type = row.int("index_type")
            let members = columns[row.int("index_id")] ?? IndexColumns()

            var xml: ScriptIndex.XMLOptions?
            if type == 3 {
                xml = ScriptIndex.XMLOptions(indexType: row.int("xml_index_type", default: -1),
                                             secondaryType: row.string("xml_secondary_type"),
                                             primaryIndex: row.string("xml_primary_index"))
            }
            var spatial: ScriptIndex.SpatialOptions?
            if type == 4, !row.string("tessellation_scheme").isEmpty {
                let scheme = row.string("tessellation_scheme")
                let boundingBox = ["bounding_box_xmin", "bounding_box_ymin",
                                   "bounding_box_xmax", "bounding_box_ymax"]
                    .compactMap { row.isNull($0) ? nil : row.double($0) }
                let levels = ["level_1_grid", "level_2_grid", "level_3_grid", "level_4_grid"]
                    .map { row.string($0) }
                spatial = ScriptIndex.SpatialOptions(
                    tessellationScheme: scheme,
                    boundingBox: boundingBox.count == 4 ? boundingBox : [],
                    gridLevels: levels.allSatisfy { !$0.isEmpty } ? levels : [],
                    cellsPerObject: row.int("cells_per_object"))
            }

            return ScriptIndex(
                name: row.string("name"),
                type: type,
                isUnique: row.bool("is_unique"),
                isConstraint: row.bool("is_primary_key") || row.bool("is_unique_constraint"),
                keyColumns: members.keys,
                includedColumns: members.included,
                filterDefinition: row.string("filter_definition"),
                padIndex: row.bool("is_padded"),
                fillFactor: row.int("fill_factor"),
                allowRowLocks: row.bool("allow_row_locks", default: true),
                allowPageLocks: row.bool("allow_page_locks", default: true),
                filegroup: row.string("filegroup_name", default: "PRIMARY"),
                dataCompression: row.string("data_compression", default: "NONE"),
                compressionDelay: row.int("compression_delay"),
                xml: xml,
                spatial: spatial
            )
        }
    }

    private func loadForeignKeys(database: String, schema: String,
                                 table: String) async throws -> [ScriptForeignKey] {
        let objectID = Self.objectIDExpression(schema: schema, name: table)
        let sql = """
        SELECT fk.object_id AS constraint_id, fk.name, fk.is_not_trusted, fk.is_disabled,
               fk.delete_referential_action_desc, fk.update_referential_action_desc,
               rs.name AS referenced_schema, rt.name AS referenced_table
        FROM sys.foreign_keys AS fk
        JOIN sys.objects AS rt ON rt.object_id = fk.referenced_object_id
        JOIN sys.schemas AS rs ON rs.schema_id = rt.schema_id
        WHERE fk.parent_object_id = \(objectID)
        ORDER BY fk.name;

        SELECT fkc.constraint_object_id AS constraint_id, fkc.constraint_column_id,
               pc.name AS parent_column, rc.name AS referenced_column
        FROM sys.foreign_key_columns AS fkc
        JOIN sys.columns AS pc ON pc.object_id = fkc.parent_object_id
             AND pc.column_id = fkc.parent_column_id
        JOIN sys.columns AS rc ON rc.object_id = fkc.referenced_object_id
             AND rc.column_id = fkc.referenced_column_id
        WHERE fkc.parent_object_id = \(objectID)
        ORDER BY fkc.constraint_object_id, fkc.constraint_column_id;
        """
        let result = try await session.metadataQuery(sql, database: database)

        // One row per key column, grouped by constraint and kept in constraint_column_id order.
        var parentColumns: [Int: [String]] = [:]
        var referencedColumns: [Int: [String]] = [:]
        if result.resultSets.count > 1 {
            let rows = result.resultSets[1].dictionaries()
                .sorted { ($0.int("constraint_id"), $0.int("constraint_column_id"))
                          < ($1.int("constraint_id"), $1.int("constraint_column_id")) }
            for row in rows {
                parentColumns[row.int("constraint_id"), default: []].append(row.string("parent_column"))
                referencedColumns[row.int("constraint_id"), default: []]
                    .append(row.string("referenced_column"))
            }
        }

        return (result.resultSets.first?.dictionaries() ?? []).map { row in
            let id = row.int("constraint_id")
            return ScriptForeignKey(
                name: row.string("name"),
                columns: parentColumns[id] ?? [],
                referencedSchema: row.string("referenced_schema"),
                referencedTable: row.string("referenced_table"),
                referencedColumns: referencedColumns[id] ?? [],
                deleteAction: row.string("delete_referential_action_desc", default: "NO_ACTION"),
                updateAction: row.string("update_referential_action_desc", default: "NO_ACTION"),
                isNotTrusted: row.bool("is_not_trusted"),
                isDisabled: row.bool("is_disabled")
            )
        }
    }

    private func loadCheckConstraints(database: String, schema: String,
                                      table: String) async throws -> [ScriptCheckConstraint] {
        let sql = """
        SELECT cc.name, CONVERT(nvarchar(max), cc.definition) AS definition,
               cc.is_not_trusted, cc.is_disabled
        FROM sys.check_constraints AS cc
        WHERE cc.parent_object_id = \(Self.objectIDExpression(schema: schema, name: table))
        ORDER BY cc.name
        """
        let result = try await session.metadataQuery(sql, database: database)
        return (result.resultSets.first?.dictionaries() ?? []).map { row in
            ScriptCheckConstraint(name: row.string("name"),
                                  definition: row.string("definition"),
                                  isNotTrusted: row.bool("is_not_trusted"),
                                  isDisabled: row.bool("is_disabled"))
        }
    }

    private func loadDefaultConstraints(database: String, schema: String,
                                        table: String) async throws -> [ScriptDefaultConstraint] {
        let sql = """
        SELECT dc.name, CONVERT(nvarchar(max), dc.definition) AS definition, c.name AS column_name
        FROM sys.default_constraints AS dc
        JOIN sys.columns AS c ON c.object_id = dc.parent_object_id
             AND c.column_id = dc.parent_column_id
        WHERE dc.parent_object_id = \(Self.objectIDExpression(schema: schema, name: table))
        ORDER BY dc.name
        """
        let result = try await session.metadataQuery(sql, database: database)
        return (result.resultSets.first?.dictionaries() ?? []).map { row in
            ScriptDefaultConstraint(name: row.string("name"),
                                    column: row.string("column_name"),
                                    definition: row.string("definition"))
        }
    }

    private func loadExtendedProperties(database: String, schema: String,
                                        table: String) async throws -> [ScriptExtendedProperty] {
        let sql = """
        SELECT ep.name, CONVERT(nvarchar(max), ep.value) AS value,
               ISNULL(c.name, N'') AS column_name
        FROM sys.extended_properties AS ep
        LEFT JOIN sys.columns AS c ON c.object_id = ep.major_id AND c.column_id = ep.minor_id
        WHERE ep.class = 1
          AND ep.major_id = \(Self.objectIDExpression(schema: schema, name: table))
        ORDER BY ep.minor_id, ep.name
        """
        let result = try await session.metadataQuery(sql, database: database)
        return (result.resultSets.first?.dictionaries() ?? []).map { row in
            let column = row.string("column_name")
            return ScriptExtendedProperty(name: row.string("name"),
                                          value: row.string("value"),
                                          column: column.isEmpty ? nil : column)
        }
    }

    private func loadTriggerDefinitions(database: String, schema: String,
                                        table: String) async throws -> [ScriptModuleDefinition] {
        let sql = """
        SELECT CONVERT(nvarchar(max), m.definition) AS definition,
               m.uses_ansi_nulls, m.uses_quoted_identifier
        FROM sys.triggers AS tr
        JOIN sys.sql_modules AS m ON m.object_id = tr.object_id
        WHERE tr.parent_id = \(Self.objectIDExpression(schema: schema, name: table))
          AND tr.is_ms_shipped = 0
        ORDER BY tr.name
        """
        let result = try await session.metadataQuery(sql, database: database)
        return (result.resultSets.first?.dictionaries() ?? [])
            .map(ScriptModuleDefinition.init(row:))
            .filter { !$0.definition.isEmpty }
    }

    private func moduleDefinition(database: String, schema: String,
                                  name: String) async throws -> ScriptModuleDefinition? {
        let sql = """
        SELECT CONVERT(nvarchar(max), m.definition) AS definition,
               m.uses_ansi_nulls, m.uses_quoted_identifier
        FROM sys.sql_modules AS m
        WHERE m.object_id = \(Self.objectIDExpression(schema: schema, name: name))
        """
        let result = try await session.metadataQuery(sql, database: database)
        guard let row = result.resultSets.first?.dictionaries().first else { return nil }
        let module = ScriptModuleDefinition(row: row)
        return module.definition.isEmpty ? nil : module
    }

    private func loadParameters(database: String, schema: String,
                                routine: String) async throws -> [ScriptParameter] {
        let sql = """
        SELECT p.name, p.is_output, p.max_length, p.precision, p.scale,
               t.name AS type_name, ISNULL(ty.name, t.name) AS base_type_name,
               ISNULL(ts.name, N'') AS type_schema, t.is_user_defined
        FROM sys.parameters AS p
        JOIN sys.types AS t ON t.user_type_id = p.user_type_id
        LEFT JOIN sys.types AS ty ON ty.user_type_id = t.system_type_id AND ty.is_user_defined = 0
        LEFT JOIN sys.schemas AS ts ON ts.schema_id = t.schema_id
        WHERE p.object_id = \(Self.objectIDExpression(schema: schema, name: routine))
          AND p.parameter_id > 0
        ORDER BY p.parameter_id
        """
        let result = try await session.metadataQuery(sql, database: database)
        return (result.resultSets.first?.dictionaries() ?? []).map { row in
            ScriptParameter(
                name: row.string("name"),
                typeName: ScriptGenerator.formatType(
                    name: row.string("type_name"),
                    schema: row.string("type_schema"),
                    baseName: row.string("base_type_name"),
                    maxLength: row.int("max_length"),
                    precision: row.int("precision"),
                    scale: row.int("scale"),
                    isUserDefined: row.bool("is_user_defined")),
                isOutput: row.bool("is_output")
            )
        }
    }

    private func databaseCollation(_ database: String) async throws -> String {
        let sql = "SELECT CONVERT(nvarchar(128), DATABASEPROPERTYEX("
            + "\(SQLIdentifier.literal(database)), 'Collation')) AS collation_name"
        let result = try await session.metadataQuery(sql)
        return result.resultSets.first?.dictionaries().first?.string("collation_name") ?? ""
    }

    // MARK: - Formatting helpers

    /// Render a catalog row's type metadata the way it appears in a CREATE statement.
    public static func formatType(name: String, baseName: String, maxLength: Int,
                                  precision: Int, scale: Int, isUserDefined: Bool) -> String {
        formatType(name: name, schema: "", baseName: baseName, maxLength: maxLength,
                   precision: precision, scale: scale, isUserDefined: isUserDefined)
    }

    /// As above, with the schema a user-defined type lives in: an alias or CLR type is
    /// written `[schema].[type]`, because a bare `[type]` only resolves in the caller's
    /// default schema. System types never carry a schema.
    public static func formatType(name: String, schema: String, baseName: String, maxLength: Int,
                                  precision: Int, scale: Int, isUserDefined: Bool) -> String {
        if isUserDefined {
            return schema.isEmpty
                ? SQLIdentifier.quote(name)
                : SQLIdentifier.quote(schema: schema, name: name)
        }
        let lowered = name.lowercased()
        switch lowered {
        case "nvarchar", "nchar":
            return maxLength == -1 ? "\(lowered)(max)" : "\(lowered)(\(maxLength / 2))"
        case "varchar", "char", "varbinary", "binary":
            return maxLength == -1 ? "\(lowered)(max)" : "\(lowered)(\(maxLength))"
        case "decimal", "numeric":
            return "\(lowered)(\(precision),\(scale))"
        case "datetime2", "datetimeoffset", "time":
            return "\(lowered)(\(scale))"
        case "float":
            return precision == 53 ? "float" : "float(\(precision))"
        case "sysname":
            return "sysname"
        default:
            return lowered
        }
    }

    private func header(kind: String, schema: String, name: String,
                        options: ScriptOptions) async throws -> String {
        guard options.includeDescriptiveHeader else { return "" }
        let target = SQLIdentifier.quote(schema: schema, name: name)
        return "/****** Object:  \(kind) \(target)    Script Date: \(timestamp()) ******/\n"
    }

    private func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: Date())
    }

    private func qualified(schema: String, name: String, options: ScriptOptions) -> String {
        Self.qualifiedName(schema: schema, name: name, options: options)
    }

    private static func qualifiedName(schema: String, name: String,
                                      options: ScriptOptions) -> String {
        options.schemaQualify
            ? SQLIdentifier.quote(schema: schema, name: name)
            : SQLIdentifier.quote(name)
    }

    /// `SET ANSI_NULLS` / `SET QUOTED_IDENTIFIER` batches matching the settings a module
    /// was compiled under. A module created with either option OFF (a view that uses
    /// "double quoted" literals, say) cannot be re-created under ON, so for those the header
    /// is emitted even when the option to include it is off.
    public static func setOptionsHeader(ansiNulls: Bool, quotedIdentifier: Bool,
                                        options: ScriptOptions) -> String {
        guard options.includeSetOptionsHeader || !ansiNulls || !quotedIdentifier else { return "" }
        return "SET ANSI_NULLS \(ansiNulls ? "ON" : "OFF")\nGO\n"
            + "SET QUOTED_IDENTIFIER \(quotedIdentifier ? "ON" : "OFF")\nGO\n"
    }

    private static func setOptionsHeader(for module: ScriptModuleDefinition,
                                         options: ScriptOptions) -> String {
        setOptionsHeader(ansiNulls: module.usesAnsiNulls,
                         quotedIdentifier: module.usesQuotedIdentifier, options: options)
    }

    private func moduleLabel(_ kind: ObjectNodeKind) -> String {
        switch kind {
        case .view: return "View"
        case .storedProcedure: return "StoredProcedure"
        case .scalarFunction: return "UserDefinedFunction"
        case .tableValuedFunction: return "UserDefinedFunction"
        case .aggregateFunction: return "AggregateFunction"
        case .trigger: return "Trigger"
        default: return "Object"
        }
    }

    private func dropKeyword(_ kind: ObjectNodeKind) -> String {
        switch kind {
        case .view: return "VIEW"
        case .storedProcedure: return "PROCEDURE"
        case .scalarFunction, .tableValuedFunction, .aggregateFunction: return "FUNCTION"
        case .trigger: return "TRIGGER"
        default: return "OBJECT"
        }
    }

    private func onOff(_ value: Bool) -> String { Self.onOff(value) }

    private static func onOff(_ value: Bool) -> String { value ? "ON" : "OFF" }

    private func escaped(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }

    private func escapedLiteral(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }

    // MARK: - Index column rows

    /// One row per index column for every index of a table, as a second result set.
    /// Column lists used to be aggregated into one comma separated string, which a column
    /// named `Last, First` broke; rows cannot be mis-split.
    private static func indexColumnsQuery(objectID: String) -> String {
        """
        SELECT ic.index_id, c.name AS column_name, ic.key_ordinal, ic.index_column_id,
               CAST(ic.is_descending_key AS int) AS is_descending_key,
               CAST(ic.is_included_column AS int) AS is_included_column
        FROM sys.index_columns AS ic
        JOIN sys.columns AS c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
        WHERE ic.object_id = \(objectID)
        ORDER BY ic.index_id, ic.is_included_column, ic.key_ordinal, ic.index_column_id;
        """
    }

    private struct IndexColumns {
        var keys: [ScriptIndexColumn] = []
        var included: [String] = []
    }

    /// Groups the rows of `indexColumnsQuery` by index_id. XML, spatial and columnstore
    /// indexes report `key_ordinal` 0 for their columns, so ordering falls back to
    /// `index_column_id` for them.
    private static func indexColumns(from resultSet: TDSResultSet?) -> [Int: IndexColumns] {
        guard let resultSet else { return [:] }
        var rows = resultSet.dictionaries()
        rows.sort { lhs, rhs in
            let left = (lhs.int("index_id"), lhs.int("is_included_column"),
                        lhs.int("key_ordinal"), lhs.int("index_column_id"))
            let right = (rhs.int("index_id"), rhs.int("is_included_column"),
                         rhs.int("key_ordinal"), rhs.int("index_column_id"))
            return left < right
        }
        var grouped: [Int: IndexColumns] = [:]
        for row in rows {
            let name = row.string("column_name")
            guard !name.isEmpty else { continue }
            if row.bool("is_included_column") {
                grouped[row.int("index_id"), default: IndexColumns()].included.append(name)
            } else {
                grouped[row.int("index_id"), default: IndexColumns()].keys.append(
                    ScriptIndexColumn(name: name, isDescending: row.bool("is_descending_key")))
            }
        }
        return grouped
    }
}

// MARK: - Index and key models

/// One member of an index or key column list.
public struct ScriptIndexColumn: Sendable, Hashable {
    public var name: String
    public var isDescending: Bool

    public init(name: String, isDescending: Bool = false) {
        self.name = name
        self.isDescending = isDescending
    }

    /// `[name] ASC` / `[name] DESC`, quoted so a comma in the name cannot split the list.
    public var keyClause: String {
        SQLIdentifier.quote(name) + (isDescending ? " DESC" : " ASC")
    }
}

/// A primary key or unique constraint, scripted inline in CREATE TABLE.
public struct ScriptKeyConstraint: Sendable {
    public var name: String
    public var isPrimaryKey: Bool
    public var isClustered: Bool
    public var columns: [ScriptIndexColumn]
    public var padIndex: Bool
    public var fillFactor: Int
    public var ignoreDupKey: Bool
    public var allowRowLocks: Bool
    public var allowPageLocks: Bool
    public var filegroup: String

    public init(name: String, isPrimaryKey: Bool, isClustered: Bool,
                columns: [ScriptIndexColumn], padIndex: Bool = false, fillFactor: Int = 0,
                ignoreDupKey: Bool = false, allowRowLocks: Bool = true,
                allowPageLocks: Bool = true, filegroup: String = "PRIMARY") {
        self.name = name
        self.isPrimaryKey = isPrimaryKey
        self.isClustered = isClustered
        self.columns = columns
        self.padIndex = padIndex
        self.fillFactor = fillFactor
        self.ignoreDupKey = ignoreDupKey
        self.allowRowLocks = allowRowLocks
        self.allowPageLocks = allowPageLocks
        self.filegroup = filegroup
    }
}

/// An index as `sys.indexes` describes it. `type` is `sys.indexes.type`: 1 clustered,
/// 2 nonclustered, 3 XML, 4 spatial, 5 clustered columnstore, 6 nonclustered columnstore,
/// 7 nonclustered hash.
public struct ScriptIndex: Sendable {

    public struct XMLOptions: Sendable {
        /// `sys.xml_indexes.xml_index_type`: 0 primary, 1 secondary, 2 selective,
        /// 3 secondary selective.
        public var indexType: Int
        /// PATH, VALUE or PROPERTY for a secondary index.
        public var secondaryType: String
        /// The primary XML index a secondary one is built on.
        public var primaryIndex: String

        public init(indexType: Int, secondaryType: String = "", primaryIndex: String = "") {
            self.indexType = indexType
            self.secondaryType = secondaryType
            self.primaryIndex = primaryIndex
        }
    }

    public struct SpatialOptions: Sendable {
        /// GEOMETRY_GRID, GEOGRAPHY_GRID, GEOMETRY_AUTO_GRID or GEOGRAPHY_AUTO_GRID.
        public var tessellationScheme: String
        /// xmin, ymin, xmax, ymax; empty for geography, which has no bounding box.
        public var boundingBox: [Double]
        /// LOW / MEDIUM / HIGH for levels 1 to 4; empty for the AUTO_GRID schemes.
        public var gridLevels: [String]
        public var cellsPerObject: Int

        public init(tessellationScheme: String, boundingBox: [Double] = [],
                    gridLevels: [String] = [], cellsPerObject: Int = 0) {
            self.tessellationScheme = tessellationScheme
            self.boundingBox = boundingBox
            self.gridLevels = gridLevels
            self.cellsPerObject = cellsPerObject
        }
    }

    public var name: String
    public var type: Int
    public var isUnique: Bool
    public var isConstraint: Bool
    public var keyColumns: [ScriptIndexColumn]
    public var includedColumns: [String]
    public var filterDefinition: String?
    public var padIndex: Bool
    public var fillFactor: Int
    public var allowRowLocks: Bool
    public var allowPageLocks: Bool
    public var filegroup: String
    /// `sys.partitions.data_compression_desc` of the first partition: NONE, ROW, PAGE,
    /// COLUMNSTORE or COLUMNSTORE_ARCHIVE.
    public var dataCompression: String
    public var compressionDelay: Int
    public var xml: XMLOptions?
    public var spatial: SpatialOptions?

    public init(name: String, type: Int, isUnique: Bool = false, isConstraint: Bool = false,
                keyColumns: [ScriptIndexColumn] = [], includedColumns: [String] = [],
                filterDefinition: String? = nil, padIndex: Bool = false, fillFactor: Int = 0,
                allowRowLocks: Bool = true, allowPageLocks: Bool = true,
                filegroup: String = "PRIMARY", dataCompression: String = "NONE",
                compressionDelay: Int = 0, xml: XMLOptions? = nil,
                spatial: SpatialOptions? = nil) {
        self.name = name
        self.type = type
        self.isUnique = isUnique
        self.isConstraint = isConstraint
        self.keyColumns = keyColumns
        self.includedColumns = includedColumns
        self.filterDefinition = filterDefinition
        self.padIndex = padIndex
        self.fillFactor = fillFactor
        self.allowRowLocks = allowRowLocks
        self.allowPageLocks = allowPageLocks
        self.filegroup = filegroup
        self.dataCompression = dataCompression
        self.compressionDelay = compressionDelay
        self.xml = xml
        self.spatial = spatial
    }

    /// Clustered rowstore or clustered columnstore: either one decides the table's filegroup.
    public var isClustered: Bool { type == 1 || type == 5 }
}

// MARK: - Catalog row models

/// A module's text together with the two SET options it was compiled under.
struct ScriptModuleDefinition {
    var definition: String
    var usesAnsiNulls: Bool
    var usesQuotedIdentifier: Bool

    init(row: [String: TDSValue]) {
        definition = row.string("definition")
        usesAnsiNulls = row.bool("uses_ansi_nulls", default: true)
        usesQuotedIdentifier = row.bool("uses_quoted_identifier", default: true)
    }
}

private struct ScriptColumn {
    var name: String
    var ordinal: Int
    var typeName: String
    var baseTypeName: String
    var isNullable: Bool
    var isIdentity: Bool
    var isComputed: Bool
    var isPersisted: Bool
    var isRowGuidCol: Bool
    var isFileStream: Bool
    var isSparse: Bool
    var collation: String
    var computedDefinition: String
    var identitySeed: String
    var identityIncrement: String

    var isTimestamp: Bool {
        baseTypeName.lowercased() == "timestamp" || baseTypeName.lowercased() == "rowversion"
    }

    /// LOB columns force a TEXTIMAGE_ON clause in the CREATE statement.
    var isLob: Bool {
        let lowered = typeName.lowercased()
        return lowered.contains("(max)") || lowered == "text" || lowered == "ntext"
            || lowered == "image" || lowered == "xml"
    }
}

private struct ScriptForeignKey {
    var name: String
    var columns: [String]
    var referencedSchema: String
    var referencedTable: String
    var referencedColumns: [String]
    var deleteAction: String
    var updateAction: String
    var isNotTrusted: Bool
    var isDisabled: Bool
}

private struct ScriptCheckConstraint {
    var name: String
    var definition: String
    var isNotTrusted: Bool
    var isDisabled: Bool
}

private struct ScriptDefaultConstraint {
    var name: String
    var column: String
    var definition: String
}

private struct ScriptExtendedProperty {
    var name: String
    var value: String
    var column: String?
}

private struct ScriptParameter {
    var name: String
    var typeName: String
    var isOutput: Bool

    /// `@Id` -> `Id`, so declarations can be rebuilt without doubling the sigil.
    var bareName: String {
        name.hasPrefix("@") ? String(name.dropFirst()) : name
    }
}
