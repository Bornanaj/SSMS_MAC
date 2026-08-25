import Foundation
import TDSKit

/// Produces the T-SQL behind "Script <object> as …".
///
/// This runs its own catalog queries rather than going through `MetadataService`,
/// because scripting needs far more detail per object than the tree does.
public struct ScriptGenerator: Sendable {

    private let session: SQLServerSession

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
            let table = node.info["table"] ?? ""
            return try await indexScript(database: database, schema: schema, table: table,
                                         index: name, action: action, options: options)

        default:
            throw SQLServerError.unsupportedOperation(
                "Scripting is not supported for this object type.")
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
            lines.append("\t" + keyConstraintDefinition(key))
        }
        out += lines.joined(separator: ",\n")
        out += "\n) ON \(SQLIdentifier.quote(tableFilegroup(indexes: indexes, keys: keys)))\n"
        if columns.contains(where: { $0.isLob }) {
            out += "TEXTIMAGE_ON \(SQLIdentifier.quote("PRIMARY"))\n"
        }
        out += "GO\n"

        for index in indexes where !index.isConstraint {
            out += "\n" + createIndexStatement(index, schema: schema, table: table, options: options)
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
                out += "\n" + trigger + "\nGO\n"
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

    private func keyConstraintDefinition(_ key: ScriptKeyConstraint) -> String {
        var text = "CONSTRAINT \(SQLIdentifier.quote(key.name)) "
        text += key.isPrimaryKey ? "PRIMARY KEY " : "UNIQUE "
        text += key.isClustered ? "CLUSTERED " : "NONCLUSTERED "
        text += "\n\t(\n\t\t" + key.columns.joined(separator: ",\n\t\t") + "\n\t)"
        text += "WITH (PAD_INDEX = \(onOff(key.padIndex)), STATISTICS_NORECOMPUTE = OFF, "
            + "IGNORE_DUP_KEY = \(onOff(key.ignoreDupKey)), ALLOW_ROW_LOCKS = \(onOff(key.allowRowLocks)), "
            + "ALLOW_PAGE_LOCKS = \(onOff(key.allowPageLocks))"
        if key.fillFactor > 0 { text += ", FILLFACTOR = \(key.fillFactor)" }
        text += ") ON \(SQLIdentifier.quote(key.filegroup))"
        return text
    }

    private func createIndexStatement(_ index: ScriptIndex, schema: String, table: String,
                                      options: ScriptOptions) -> String {
        let target = qualified(schema: schema, name: table, options: options)
        var text = ""
        if options.includeIfNotExists {
            text += "IF NOT EXISTS (SELECT * FROM sys.indexes WHERE object_id = "
                + "OBJECT_ID(N'\(escaped(target))') AND name = N'\(escapedLiteral(index.name))')\n"
        }
        text += "CREATE "
        if index.isUnique { text += "UNIQUE " }
        text += index.isClustered ? "CLUSTERED " : "NONCLUSTERED "
        text += "INDEX \(SQLIdentifier.quote(index.name)) ON \(target)\n"
        text += "(\n\t" + index.keyColumns.joined(separator: ",\n\t") + "\n)"
        if !index.includedColumns.isEmpty {
            text += "\nINCLUDE(\(index.includedColumns.joined(separator: ", ")))"
        }
        if let filter = index.filterDefinition, !filter.isEmpty {
            text += "\nWHERE \(filter)"
        }
        text += "\nWITH (PAD_INDEX = \(onOff(index.padIndex)), STATISTICS_NORECOMPUTE = OFF, "
            + "SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, "
            + "ALLOW_ROW_LOCKS = \(onOff(index.allowRowLocks)), "
            + "ALLOW_PAGE_LOCKS = \(onOff(index.allowPageLocks))"
        if index.fillFactor > 0 { text += ", FILLFACTOR = \(index.fillFactor)" }
        text += ") ON \(SQLIdentifier.quote(index.filegroup))\nGO\n"
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

        guard let definition = try await moduleDefinition(database: database, schema: schema,
                                                          name: name) else {
            throw SQLServerError.objectNotFound("\(schema).\(name)")
        }

        var out = try await header(kind: label, schema: schema, name: name, options: options)
        if options.includeSetOptionsHeader {
            out += "SET ANSI_NULLS ON\nGO\nSET QUOTED_IDENTIFIER ON\nGO\n"
        }

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
            return createIndexStatement(match, schema: schema, table: table, options: options)
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

    private func loadColumns(database: String, schema: String,
                             object: String) async throws -> [ScriptColumn] {
        let sql = """
        SELECT c.name, c.column_id, c.is_nullable, c.is_identity, c.is_computed,
               c.is_rowguidcol, c.is_filestream, c.is_sparse,
               ISNULL(c.collation_name, N'') AS collation_name,
               t.name AS type_name, ty.name AS base_type_name,
               c.max_length, c.precision, c.scale, c.user_type_id, t.is_user_defined,
               ISNULL(CONVERT(nvarchar(4000), cc.definition), N'') AS computed_definition,
               ISNULL(CONVERT(int, cc.is_persisted), 0) AS is_persisted,
               ISNULL(CONVERT(nvarchar(64), ic.seed_value), N'1') AS seed_value,
               ISNULL(CONVERT(nvarchar(64), ic.increment_value), N'1') AS increment_value
        FROM sys.columns AS c
        JOIN sys.types AS t ON t.user_type_id = c.user_type_id
        JOIN sys.types AS ty ON ty.user_type_id = t.system_type_id
        LEFT JOIN sys.computed_columns AS cc ON cc.object_id = c.object_id
             AND cc.column_id = c.column_id
        LEFT JOIN sys.identity_columns AS ic ON ic.object_id = c.object_id
             AND ic.column_id = c.column_id
        WHERE c.object_id = OBJECT_ID(\(SQLIdentifier.literal("\(schema).\(object)")))
        ORDER BY c.column_id
        """
        let result = try await session.metadataQuery(sql, database: database)
        return (result.resultSets.first?.dictionaries() ?? []).map { row in
            ScriptColumn(
                name: row.string("name"),
                ordinal: row.int("column_id"),
                typeName: ScriptGenerator.formatType(
                    name: row.string("type_name"),
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
        let sql = """
        SELECT kc.name, kc.type, i.is_padded, i.fill_factor, i.ignore_dup_key,
               i.allow_row_locks, i.allow_page_locks, i.type_desc,
               ISNULL(fg.name, N'PRIMARY') AS filegroup_name,
               STUFF((SELECT N', ' + QUOTENAME(c2.name)
                        + CASE WHEN ic2.is_descending_key = 1 THEN N' DESC' ELSE N' ASC' END
                      FROM sys.index_columns AS ic2
                      JOIN sys.columns AS c2 ON c2.object_id = ic2.object_id
                           AND c2.column_id = ic2.column_id
                      WHERE ic2.object_id = i.object_id AND ic2.index_id = i.index_id
                        AND ic2.is_included_column = 0
                      ORDER BY ic2.key_ordinal
                      FOR XML PATH(N''), TYPE).value(N'.', N'nvarchar(max)'), 1, 2, N'') AS key_columns
        FROM sys.key_constraints AS kc
        JOIN sys.indexes AS i ON i.object_id = kc.parent_object_id AND i.index_id = kc.unique_index_id
        LEFT JOIN sys.filegroups AS fg ON fg.data_space_id = i.data_space_id
        WHERE kc.parent_object_id = OBJECT_ID(\(SQLIdentifier.literal("\(schema).\(table)")))
        ORDER BY kc.type DESC, kc.name
        """
        let result = try await session.metadataQuery(sql, database: database)
        return (result.resultSets.first?.dictionaries() ?? []).map { row in
            ScriptKeyConstraint(
                name: row.string("name"),
                isPrimaryKey: row.string("type").trimmingCharacters(in: .whitespaces) == "PK",
                isClustered: row.string("type_desc") == "CLUSTERED",
                columns: splitColumns(row.string("key_columns")),
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
        let sql = """
        SELECT i.name, i.is_unique, i.type_desc, i.is_padded, i.fill_factor,
               i.allow_row_locks, i.allow_page_locks, i.is_unique_constraint,
               i.is_primary_key, ISNULL(i.filter_definition, N'') AS filter_definition,
               ISNULL(fg.name, N'PRIMARY') AS filegroup_name,
               STUFF((SELECT N', ' + QUOTENAME(c2.name)
                        + CASE WHEN ic2.is_descending_key = 1 THEN N' DESC' ELSE N' ASC' END
                      FROM sys.index_columns AS ic2
                      JOIN sys.columns AS c2 ON c2.object_id = ic2.object_id
                           AND c2.column_id = ic2.column_id
                      WHERE ic2.object_id = i.object_id AND ic2.index_id = i.index_id
                        AND ic2.is_included_column = 0
                      ORDER BY ic2.key_ordinal
                      FOR XML PATH(N''), TYPE).value(N'.', N'nvarchar(max)'), 1, 2, N'') AS key_columns,
               ISNULL(STUFF((SELECT N', ' + QUOTENAME(c3.name)
                      FROM sys.index_columns AS ic3
                      JOIN sys.columns AS c3 ON c3.object_id = ic3.object_id
                           AND c3.column_id = ic3.column_id
                      WHERE ic3.object_id = i.object_id AND ic3.index_id = i.index_id
                        AND ic3.is_included_column = 1
                      ORDER BY ic3.index_column_id
                      FOR XML PATH(N''), TYPE).value(N'.', N'nvarchar(max)'), 1, 2, N''), N'')
                  AS included_columns
        FROM sys.indexes AS i
        LEFT JOIN sys.filegroups AS fg ON fg.data_space_id = i.data_space_id
        WHERE i.object_id = OBJECT_ID(\(SQLIdentifier.literal("\(schema).\(table)")))
          AND i.index_id > 0 AND i.name IS NOT NULL
        ORDER BY i.index_id
        """
        let result = try await session.metadataQuery(sql, database: database)
        return (result.resultSets.first?.dictionaries() ?? []).map { row in
            ScriptIndex(
                name: row.string("name"),
                isUnique: row.bool("is_unique"),
                isClustered: row.string("type_desc").hasPrefix("CLUSTERED"),
                isConstraint: row.bool("is_primary_key") || row.bool("is_unique_constraint"),
                keyColumns: splitColumns(row.string("key_columns")),
                includedColumns: splitColumns(row.string("included_columns")),
                filterDefinition: row.string("filter_definition"),
                padIndex: row.bool("is_padded"),
                fillFactor: row.int("fill_factor"),
                allowRowLocks: row.bool("allow_row_locks", default: true),
                allowPageLocks: row.bool("allow_page_locks", default: true),
                filegroup: row.string("filegroup_name", default: "PRIMARY")
            )
        }
    }

    private func loadForeignKeys(database: String, schema: String,
                                 table: String) async throws -> [ScriptForeignKey] {
        let sql = """
        SELECT fk.name, fk.is_not_trusted, fk.is_disabled,
               fk.delete_referential_action_desc, fk.update_referential_action_desc,
               rs.name AS referenced_schema, rt.name AS referenced_table,
               STUFF((SELECT N', ' + pc.name
                      FROM sys.foreign_key_columns AS fkc2
                      JOIN sys.columns AS pc ON pc.object_id = fkc2.parent_object_id
                           AND pc.column_id = fkc2.parent_column_id
                      WHERE fkc2.constraint_object_id = fk.object_id
                      ORDER BY fkc2.constraint_column_id
                      FOR XML PATH(N''), TYPE).value(N'.', N'nvarchar(max)'), 1, 2, N'') AS parent_columns,
               STUFF((SELECT N', ' + rc.name
                      FROM sys.foreign_key_columns AS fkc3
                      JOIN sys.columns AS rc ON rc.object_id = fkc3.referenced_object_id
                           AND rc.column_id = fkc3.referenced_column_id
                      WHERE fkc3.constraint_object_id = fk.object_id
                      ORDER BY fkc3.constraint_column_id
                      FOR XML PATH(N''), TYPE).value(N'.', N'nvarchar(max)'), 1, 2, N'') AS referenced_columns
        FROM sys.foreign_keys AS fk
        JOIN sys.objects AS rt ON rt.object_id = fk.referenced_object_id
        JOIN sys.schemas AS rs ON rs.schema_id = rt.schema_id
        WHERE fk.parent_object_id = OBJECT_ID(\(SQLIdentifier.literal("\(schema).\(table)")))
        ORDER BY fk.name
        """
        let result = try await session.metadataQuery(sql, database: database)
        return (result.resultSets.first?.dictionaries() ?? []).map { row in
            ScriptForeignKey(
                name: row.string("name"),
                columns: splitPlainColumns(row.string("parent_columns")),
                referencedSchema: row.string("referenced_schema"),
                referencedTable: row.string("referenced_table"),
                referencedColumns: splitPlainColumns(row.string("referenced_columns")),
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
        WHERE cc.parent_object_id = OBJECT_ID(\(SQLIdentifier.literal("\(schema).\(table)")))
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
        WHERE dc.parent_object_id = OBJECT_ID(\(SQLIdentifier.literal("\(schema).\(table)")))
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
          AND ep.major_id = OBJECT_ID(\(SQLIdentifier.literal("\(schema).\(table)")))
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
                                        table: String) async throws -> [String] {
        let sql = """
        SELECT CONVERT(nvarchar(max), m.definition) AS definition
        FROM sys.triggers AS tr
        JOIN sys.sql_modules AS m ON m.object_id = tr.object_id
        WHERE tr.parent_id = OBJECT_ID(\(SQLIdentifier.literal("\(schema).\(table)")))
          AND tr.is_ms_shipped = 0
        ORDER BY tr.name
        """
        let result = try await session.metadataQuery(sql, database: database)
        return (result.resultSets.first?.dictionaries() ?? [])
            .map { $0.string("definition") }
            .filter { !$0.isEmpty }
    }

    private func moduleDefinition(database: String, schema: String,
                                  name: String) async throws -> String? {
        let sql = """
        SELECT CONVERT(nvarchar(max), m.definition) AS definition
        FROM sys.sql_modules AS m
        WHERE m.object_id = OBJECT_ID(\(SQLIdentifier.literal("\(schema).\(name)")))
        """
        let result = try await session.metadataQuery(sql, database: database)
        guard let row = result.resultSets.first?.dictionaries().first else { return nil }
        let definition = row.string("definition")
        return definition.isEmpty ? nil : definition
    }

    private func loadParameters(database: String, schema: String,
                                routine: String) async throws -> [ScriptParameter] {
        let sql = """
        SELECT p.name, p.is_output, p.max_length, p.precision, p.scale,
               t.name AS type_name, ty.name AS base_type_name, t.is_user_defined
        FROM sys.parameters AS p
        JOIN sys.types AS t ON t.user_type_id = p.user_type_id
        JOIN sys.types AS ty ON ty.user_type_id = t.system_type_id
        WHERE p.object_id = OBJECT_ID(\(SQLIdentifier.literal("\(schema).\(routine)")))
          AND p.parameter_id > 0
        ORDER BY p.parameter_id
        """
        let result = try await session.metadataQuery(sql, database: database)
        return (result.resultSets.first?.dictionaries() ?? []).map { row in
            ScriptParameter(
                name: row.string("name"),
                typeName: ScriptGenerator.formatType(
                    name: row.string("type_name"),
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
        if isUserDefined { return SQLIdentifier.quote(name) }
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
        options.schemaQualify
            ? SQLIdentifier.quote(schema: schema, name: name)
            : SQLIdentifier.quote(name)
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

    private func onOff(_ value: Bool) -> String { value ? "ON" : "OFF" }

    private func escaped(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }

    private func escapedLiteral(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }

    private func splitColumns(_ value: String) -> [String] {
        value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func splitPlainColumns(_ value: String) -> [String] {
        splitColumns(value)
    }
}

// MARK: - Catalog row models

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

private struct ScriptKeyConstraint {
    var name: String
    var isPrimaryKey: Bool
    var isClustered: Bool
    var columns: [String]
    var padIndex: Bool
    var fillFactor: Int
    var ignoreDupKey: Bool
    var allowRowLocks: Bool
    var allowPageLocks: Bool
    var filegroup: String
}

private struct ScriptIndex {
    var name: String
    var isUnique: Bool
    var isClustered: Bool
    var isConstraint: Bool
    var keyColumns: [String]
    var includedColumns: [String]
    var filterDefinition: String?
    var padIndex: Bool
    var fillFactor: Int
    var allowRowLocks: Bool
    var allowPageLocks: Bool
    var filegroup: String
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
