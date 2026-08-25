import Foundation
import TDSKit

// MARK: - Model

/// One row of the table designer grid. `id` is stable for the lifetime of an editing
/// session so a rename can be told apart from a drop plus an add.
public struct DesignColumn: Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    /// Rendered the way the designer shows it, for example "nvarchar(50)".
    public var typeName: String
    public var isNullable: Bool
    public var isIdentity: Bool
    public var identitySeed: String
    public var identityIncrement: String
    public var defaultDefinition: String
    public var isPrimaryKey: Bool
    public var collation: String
    public var columnDescription: String
    public var isNew: Bool
    /// nil for a new column; otherwise the name the server still knows.
    public var originalName: String?

    /// Existing DEFAULT constraint name, so a default change can drop it by name
    /// instead of resolving the name at run time.
    var defaultConstraintName: String?
    /// Position inside the existing primary key; 0 when the column is not a member.
    /// Keeps key order stable when the key has to be dropped and re-created.
    var primaryKeyOrdinal: Int
    /// Computed columns can only be dropped and re-added, never altered.
    var isComputed: Bool

    public init(id: UUID = UUID(), name: String = "", typeName: String = "int",
                isNullable: Bool = true, isIdentity: Bool = false,
                identitySeed: String = "", identityIncrement: String = "",
                defaultDefinition: String = "", isPrimaryKey: Bool = false,
                collation: String = "", columnDescription: String = "",
                isNew: Bool = true, originalName: String? = nil) {
        self.id = id
        self.name = name
        self.typeName = typeName
        self.isNullable = isNullable
        self.isIdentity = isIdentity
        self.identitySeed = identitySeed
        self.identityIncrement = identityIncrement
        self.defaultDefinition = defaultDefinition
        self.isPrimaryKey = isPrimaryKey
        self.collation = collation
        self.columnDescription = columnDescription
        self.isNew = isNew
        self.originalName = originalName
        self.defaultConstraintName = nil
        self.primaryKeyOrdinal = 0
        self.isComputed = false
    }
}

public struct TableDesign: Sendable {
    public var schema: String
    public var name: String
    public var columns: [DesignColumn]

    /// Name of the existing primary key constraint, when the table has one.
    var primaryKeyName: String?
    /// Approximate row count taken from sys.partitions at load time. nil when the
    /// design was built by hand rather than read from a server.
    var rowCount: Int64?

    public init(schema: String, name: String, columns: [DesignColumn]) {
        self.schema = schema
        self.name = name
        self.columns = columns
        self.primaryKeyName = nil
        self.rowCount = nil
    }

    public var qualifiedName: String {
        SQLIdentifier.quote(schema: schema, name: name)
    }

    /// Approximate, from catalog metadata. Zero when unknown; good enough to decide
    /// whether a NOT NULL column can be added without a default.
    public var approximateRowCount: Int64 { rowCount ?? 0 }
}

// MARK: - Service

/// Reads a table into `TableDesign` and turns edits back into ALTER statements, the
/// way SSMS's "Design" window does. Anything that a real table rebuild would be
/// needed for is refused rather than silently scripted as something else.
public struct TableDesignService: Sendable {

    private let session: SQLServerSession

    public init(session: SQLServerSession) {
        self.session = session
    }

    // MARK: Loading

    public func load(database: String, schema: String, table: String)
        async throws -> TableDesign {
        let qualified: String = SQLIdentifier.quote(schema: schema, name: table)
        let objectLiteral: String = SQLIdentifier.literal(qualified)
        let sql: String = Self.designQuery(objectLiteral: objectLiteral)

        let result: TDSQueryResult = try await session.metadataQuery(sql, database: database)
        guard let columnSet = result.resultSets.first else {
            throw SQLServerError.objectNotFound("\(schema).\(table)")
        }
        let columnRows: [[String: TDSValue]] = columnSet.dictionaries()
        guard !columnRows.isEmpty else {
            throw SQLServerError.objectNotFound("\(schema).\(table)")
        }

        var columns: [DesignColumn] = []
        columns.reserveCapacity(columnRows.count)
        for row in columnRows {
            let name: String = row.string("ColumnName")
            let baseName: String = row.string("TypeName")
            let isUserDefined: Bool = row.bool("IsUserDefinedType")
            let rendered: String = Self.renderTypeName(base: baseName,
                                                       maxLength: row.int("MaxLength"),
                                                       precision: row.int("TypePrecision"),
                                                       scale: row.int("TypeScale"),
                                                       isUserDefined: isUserDefined)
            var column = DesignColumn(name: name,
                                      typeName: rendered,
                                      isNullable: row.bool("IsNullable"),
                                      isIdentity: row.bool("IsIdentity"),
                                      identitySeed: row.string("IdentitySeed"),
                                      identityIncrement: row.string("IdentityIncrement"),
                                      defaultDefinition: row.string("DefaultDefinition"),
                                      isPrimaryKey: row.bool("IsPrimaryKey"),
                                      collation: row.string("CollationName"),
                                      columnDescription: row.string("ColumnDescription"),
                                      isNew: false,
                                      originalName: name)
            let constraintName: String = row.string("DefaultConstraintName")
            column.defaultConstraintName = constraintName.isEmpty ? nil : constraintName
            column.primaryKeyOrdinal = row.int("KeyOrdinal")
            column.isComputed = row.bool("IsComputed")
            columns.append(column)
        }

        var design = TableDesign(schema: schema, name: table, columns: columns)
        if result.resultSets.count > 1, let keyRow = result.resultSets[1].dictionaries().first {
            let keyName: String = keyRow.string("PrimaryKeyName")
            design.primaryKeyName = keyName.isEmpty ? nil : keyName
        }
        if result.resultSets.count > 2, let statsRow = result.resultSets[2].dictionaries().first {
            design.rowCount = statsRow.int64("TableRows")
        }
        return design
    }

    /// Three result sets: columns, the primary key constraint name, an approximate row
    /// count. `sys.partitions` is used for the count so the designer never has to read
    /// the table's data just to open.
    private static func designQuery(objectLiteral: String) -> String {
        """
        SELECT
            c.column_id                                            AS ColumnId,
            c.name                                                 AS ColumnName,
            CONVERT(int, c.is_nullable)                            AS IsNullable,
            CONVERT(int, c.is_identity)                            AS IsIdentity,
            CONVERT(int, c.is_computed)                            AS IsComputed,
            ISNULL(c.collation_name, N'')                          AS CollationName,
            CONVERT(int, c.max_length)                             AS MaxLength,
            CONVERT(int, c.precision)                              AS TypePrecision,
            CONVERT(int, c.scale)                                  AS TypeScale,
            ISNULL(t.name, N'')                                    AS TypeName,
            CONVERT(int, ISNULL(t.is_user_defined, 0))             AS IsUserDefinedType,
            ISNULL(dc.definition, N'')                             AS DefaultDefinition,
            ISNULL(dc.name, N'')                                   AS DefaultConstraintName,
            ISNULL(CONVERT(nvarchar(64), ic.seed_value), N'')      AS IdentitySeed,
            ISNULL(CONVERT(nvarchar(64), ic.increment_value), N'') AS IdentityIncrement,
            CONVERT(int, CASE WHEN pk.column_id IS NULL THEN 0 ELSE 1 END) AS IsPrimaryKey,
            CONVERT(int, ISNULL(pk.key_ordinal, 0))                AS KeyOrdinal,
            ISNULL(CONVERT(nvarchar(4000), ep.value), N'')         AS ColumnDescription
        FROM sys.columns AS c
        JOIN sys.types AS t ON t.user_type_id = c.user_type_id
        LEFT JOIN sys.default_constraints AS dc ON dc.object_id = c.default_object_id
        LEFT JOIN sys.identity_columns AS ic
               ON ic.object_id = c.object_id AND ic.column_id = c.column_id
        LEFT JOIN (
            SELECT kic.object_id, kic.column_id, kic.key_ordinal
            FROM sys.index_columns AS kic
            JOIN sys.indexes AS ki
              ON ki.object_id = kic.object_id AND ki.index_id = kic.index_id
            WHERE ki.is_primary_key = 1
        ) AS pk ON pk.object_id = c.object_id AND pk.column_id = c.column_id
        LEFT JOIN sys.extended_properties AS ep
               ON ep.class = 1 AND ep.major_id = c.object_id AND ep.minor_id = c.column_id
              AND ep.name = N'MS_Description'
        WHERE c.object_id = OBJECT_ID(\(objectLiteral))
        ORDER BY c.column_id;

        SELECT TOP (1) kc.name AS PrimaryKeyName
        FROM sys.key_constraints AS kc
        WHERE kc.parent_object_id = OBJECT_ID(\(objectLiteral))
          AND kc.type = 'PK';

        SELECT CONVERT(bigint, ISNULL(SUM(p.rows), 0)) AS TableRows
        FROM sys.partitions AS p
        WHERE p.object_id = OBJECT_ID(\(objectLiteral))
          AND p.index_id IN (0, 1);
        """
    }

    // MARK: Scripting

    public func alterScript(database: String, original: TableDesign,
                            edited: TableDesign) throws -> String {
        let statements: [String] = try plan(original: original, edited: edited)
        guard !statements.isEmpty else { return "" }

        var lines: [String] = []
        lines.append("USE \(SQLIdentifier.quote(database));")
        lines.append("SET XACT_ABORT ON;")
        lines.append("BEGIN TRANSACTION;")
        lines.append(contentsOf: statements)
        lines.append("COMMIT TRANSACTION;")
        return lines.joined(separator: "\n\n") + "\n"
    }

    /// Runs the batch produced by `alterScript`. Returns the number of statements that
    /// were sent, excluding the transaction wrapper.
    @discardableResult
    public func apply(database: String, original: TableDesign,
                      edited: TableDesign) async throws -> Int {
        let statements: [String] = try plan(original: original, edited: edited)
        guard !statements.isEmpty else { return 0 }

        var lines: [String] = []
        lines.append("SET XACT_ABORT ON;")
        lines.append("BEGIN TRANSACTION;")
        lines.append(contentsOf: statements)
        lines.append("COMMIT TRANSACTION;")
        let sql: String = lines.joined(separator: "\n\n") + "\n"

        let connection: TDSConnection = try await session.openConnection(database: database)
        defer { Task { try? await connection.close() } }
        _ = try await connection.query(sql)
        return statements.count
    }

    /// Type names the designer offers. Lengths are placeholders the user edits.
    public static var dataTypes: [String] {
        ["bigint", "binary(50)", "bit", "char(10)", "date", "datetime", "datetime2(7)",
         "datetimeoffset(7)", "decimal(18, 0)", "float", "geography", "geometry",
         "hierarchyid", "int", "money", "nchar(10)", "numeric(18, 0)", "nvarchar(50)",
         "nvarchar(max)", "real", "smalldatetime", "smallint", "smallmoney",
         "sql_variant", "time(7)", "tinyint", "uniqueidentifier", "varbinary(50)",
         "varbinary(max)", "varchar(50)", "varchar(max)", "xml"]
    }

    /// COLLATE is only legal on character types, so the designer greys the field out
    /// for everything else.
    public static func supportsCollation(_ typeName: String) -> Bool {
        characterTypes.contains(baseType(of: typeName))
    }

    // MARK: - Planning

    private func plan(original: TableDesign, edited: TableDesign) throws -> [String] {
        guard original.schema.caseInsensitiveCompare(edited.schema) == .orderedSame,
              original.name.caseInsensitiveCompare(edited.name) == .orderedSame else {
            throw SQLServerError.unsupportedOperation(
                "Renaming or moving the table is not part of the designer. Use Rename on the "
                + "table itself instead.")
        }

        let table: String = original.qualifiedName
        let originalByID: [UUID: DesignColumn] = Dictionary(
            original.columns.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let editedIDs: Set<UUID> = Set(edited.columns.map(\.id))
        let removed: [DesignColumn] = original.columns.filter { !editedIDs.contains($0.id) }

        try validate(original: original, edited: edited, originalByID: originalByID)

        var head: [String] = []     // constraint drops that later statements depend on
        var body: [String] = []
        var tail: [String] = []     // constraint adds that depend on the column work

        // Primary key. The key is dropped up front whenever it has to change or one of
        // its member columns is altered or dropped, and re-created once the columns are
        // in their final shape.
        let originalKey: [DesignColumn] = Self.keyColumns(of: original.columns)
        let editedKey: [DesignColumn] = Self.keyColumns(of: edited.columns)
        var rebuildKey: Bool = originalKey.map(\.id) != editedKey.map(\.id)
        if !rebuildKey {
            rebuildKey = editedKey.contains { column in
                guard let existing = originalByID[column.id] else { return true }
                return Self.needsAlterColumn(existing: existing, edited: column)
            }
        }
        if rebuildKey, !originalKey.isEmpty {
            head.append(dropPrimaryKeyStatement(table: table, design: original))
        }
        if rebuildKey, !editedKey.isEmpty {
            let name: String = original.primaryKeyName ?? "PK_\(Self.sanitized(original.name))"
            let members: String = editedKey
                .map { "\(SQLIdentifier.quote($0.name)) ASC" }
                .joined(separator: ", ")
            let addClause: String = "ALTER TABLE \(table) ADD CONSTRAINT "
                + SQLIdentifier.quote(name)
            tail.append(addClause + "\n    PRIMARY KEY CLUSTERED (\(members));")
        }

        // 1. New columns.
        for column in edited.columns where originalByID[column.id] == nil {
            let definition: String = Self.columnDefinition(column, table: original.name)
            body.append("ALTER TABLE \(table) ADD \(definition);")
        }

        // 2. Renames, before anything else refers to the new name.
        for column in edited.columns {
            guard let existing = originalByID[column.id] else { continue }
            let previous: String = existing.originalName ?? existing.name
            guard column.name != previous else { continue }
            let objectName: String = "\(table).\(SQLIdentifier.quote(previous))"
            body.append("EXEC sys.sp_rename @objname = \(SQLIdentifier.literal(objectName)), "
                        + "@newname = \(SQLIdentifier.literal(column.name)), "
                        + "@objtype = N'COLUMN';")
        }

        // 3. Type, nullability and collation.
        for column in edited.columns {
            guard let existing = originalByID[column.id],
                  Self.needsAlterColumn(existing: existing, edited: column) else { continue }
            let quotedName: String = SQLIdentifier.quote(column.name)
            var definition: String = quotedName + " " + column.typeName.trimmed()
            if Self.supportsCollation(column.typeName), !column.collation.trimmed().isEmpty {
                definition += " COLLATE \(column.collation.trimmed())"
            }
            definition += column.isNullable ? " NULL" : " NOT NULL"
            body.append("ALTER TABLE \(table) ALTER COLUMN \(definition);")
        }

        // 4. Defaults: drop the old constraint, then add the new one.
        var dynamicDropIndex: Int = 0
        for column in edited.columns {
            guard let existing = originalByID[column.id] else { continue }
            let before: String = Self.normalizedDefault(existing.defaultDefinition)
            let after: String = Self.normalizedDefault(column.defaultDefinition)
            guard before != after else { continue }
            if !existing.defaultDefinition.trimmed().isEmpty {
                dynamicDropIndex += 1
                body.append(dropDefaultStatement(table: table, columnName: column.name,
                                                 constraintName: existing.defaultConstraintName,
                                                 index: dynamicDropIndex))
            }
            guard !column.defaultDefinition.trimmed().isEmpty else { continue }
            let constraint: String = Self.defaultConstraintName(table: original.name,
                                                                column: column.name)
            let addClause: String = "ALTER TABLE \(table) ADD CONSTRAINT "
                + SQLIdentifier.quote(constraint)
            let expression: String = Self.wrappedDefault(column.defaultDefinition)
            let forClause: String = "    DEFAULT \(expression) FOR "
                + SQLIdentifier.quote(column.name) + ";"
            body.append(addClause + "\n" + forClause)
        }

        // 5. Removals. A column cannot be dropped while it still owns a default.
        for column in removed {
            let columnName: String = column.originalName ?? column.name
            if !column.defaultDefinition.trimmed().isEmpty {
                dynamicDropIndex += 1
                body.append(dropDefaultStatement(table: table, columnName: columnName,
                                                 constraintName: column.defaultConstraintName,
                                                 index: dynamicDropIndex))
            }
            body.append("ALTER TABLE \(table) DROP COLUMN \(SQLIdentifier.quote(columnName));")
        }

        // 6. Descriptions.
        for column in edited.columns {
            let existing: DesignColumn? = originalByID[column.id]
            let before: String = existing?.columnDescription ?? ""
            let after: String = column.columnDescription
            guard before != after else { continue }
            body.append(descriptionStatement(schema: original.schema, table: original.name,
                                             column: column.name, text: after))
        }

        return head + body + tail
    }

    private func validate(original: TableDesign, edited: TableDesign,
                          originalByID: [UUID: DesignColumn]) throws {
        guard !edited.columns.isEmpty else {
            throw SQLServerError.unsupportedOperation("A table must keep at least one column.")
        }

        var seen: Set<String> = []
        for column in edited.columns {
            let name: String = column.name.trimmed()
            guard !name.isEmpty else {
                throw SQLServerError.unsupportedOperation("Every column needs a name.")
            }
            guard !column.typeName.trimmed().isEmpty else {
                throw SQLServerError.unsupportedOperation(
                    "Column \(name) has no data type.")
            }
            guard seen.insert(name.lowercased()).inserted else {
                throw SQLServerError.unsupportedOperation(
                    "Column \(name) appears more than once.")
            }
            if column.isPrimaryKey && column.isNullable {
                throw SQLServerError.unsupportedOperation(
                    "Primary key column \(name) cannot allow nulls.")
            }
            if column.isIdentity && column.isNullable {
                throw SQLServerError.unsupportedOperation(
                    "Identity column \(name) cannot allow nulls.")
            }
            if column.isIdentity && !column.defaultDefinition.trimmed().isEmpty {
                throw SQLServerError.unsupportedOperation(
                    "Column \(name) cannot be an identity column and have a default at the "
                    + "same time.")
            }

            if let existing = originalByID[column.id] {
                try validateExisting(existing, edited: column, name: name)
            } else {
                try validateNew(column, name: name, original: original, edited: edited)
            }
        }
    }

    private func validateExisting(_ existing: DesignColumn, edited: DesignColumn,
                                  name: String) throws {
        if existing.isIdentity != edited.isIdentity {
            throw SQLServerError.unsupportedOperation(
                "The identity property of column \(name) cannot be turned "
                + "\(edited.isIdentity ? "on" : "off") with ALTER TABLE. It needs a new table "
                + "and a data copy.")
        }
        if existing.isIdentity {
            let seedChanged: Bool = Self.normalizedNumber(existing.identitySeed)
                != Self.normalizedNumber(edited.identitySeed)
            let stepChanged: Bool = Self.normalizedNumber(existing.identityIncrement)
                != Self.normalizedNumber(edited.identityIncrement)
            if seedChanged || stepChanged {
                throw SQLServerError.unsupportedOperation(
                    "The seed and increment of identity column \(name) cannot be changed with "
                    + "ALTER TABLE. It needs a new table and a data copy.")
            }
            if Self.needsAlterColumn(existing: existing, edited: edited) {
                throw SQLServerError.unsupportedOperation(
                    "The data type or nullability of identity column \(name) cannot be changed "
                    + "with ALTER TABLE. It needs a new table and a data copy.")
            }
        }
        if existing.isComputed, Self.needsAlterColumn(existing: existing, edited: edited) {
            throw SQLServerError.unsupportedOperation(
                "Computed column \(name) cannot be altered. Drop it and add it back with the "
                + "new expression.")
        }
        if existing.isComputed, !edited.defaultDefinition.trimmed().isEmpty {
            throw SQLServerError.unsupportedOperation(
                "Computed column \(name) cannot have a default.")
        }
    }

    private func validateNew(_ column: DesignColumn, name: String,
                             original: TableDesign, edited: TableDesign) throws {
        let hasRows: Bool = original.approximateRowCount > 0
        let hasDefault: Bool = !column.defaultDefinition.trimmed().isEmpty
        if hasRows && !column.isNullable && !hasDefault && !column.isIdentity {
            throw SQLServerError.unsupportedOperation(
                "Column \(name) cannot be added as NOT NULL without a default because "
                + "\(original.qualifiedName) already contains rows. Give it a default or allow "
                + "nulls.")
        }
        // Adding an identity column to a populated table is legal - the server fills in
        // the values - so only the one-per-table rule needs checking here.
        if column.isIdentity {
            let otherIdentity: Bool = edited.columns.contains {
                $0.id != column.id && $0.isIdentity
            }
            if otherIdentity {
                throw SQLServerError.unsupportedOperation(
                    "A table can only have one identity column, so \(name) cannot be one.")
            }
        }
    }

    // MARK: - Statement builders

    private func dropPrimaryKeyStatement(table: String, design: TableDesign) -> String {
        if let name = design.primaryKeyName, !name.isEmpty {
            return "ALTER TABLE \(table) DROP CONSTRAINT \(SQLIdentifier.quote(name));"
        }
        // The design did not come from `load`, so resolve the name on the server.
        return """
        DECLARE @pk_name sysname;
        SELECT @pk_name = kc.name
        FROM sys.key_constraints AS kc
        WHERE kc.parent_object_id = OBJECT_ID(\(SQLIdentifier.literal(table)))
          AND kc.type = 'PK';
        IF @pk_name IS NOT NULL
            EXEC(N'ALTER TABLE \(Self.escapedForDynamicSQL(table)) DROP CONSTRAINT ' \
        + QUOTENAME(@pk_name));
        """
    }

    private func dropDefaultStatement(table: String, columnName: String,
                                      constraintName: String?, index: Int) -> String {
        if let constraintName, !constraintName.isEmpty {
            return "ALTER TABLE \(table) DROP CONSTRAINT \(SQLIdentifier.quote(constraintName));"
        }
        let variable: String = "@df_name\(index)"
        return """
        DECLARE \(variable) sysname;
        SELECT \(variable) = dc.name
        FROM sys.default_constraints AS dc
        JOIN sys.columns AS c ON c.object_id = dc.parent_object_id
                             AND c.column_id = dc.parent_column_id
        WHERE dc.parent_object_id = OBJECT_ID(\(SQLIdentifier.literal(table)))
          AND c.name = \(SQLIdentifier.literal(columnName));
        IF \(variable) IS NOT NULL
            EXEC(N'ALTER TABLE \(Self.escapedForDynamicSQL(table)) DROP CONSTRAINT ' \
        + QUOTENAME(\(variable)));
        """
    }

    /// MS_Description is added or updated depending on what is already there, and
    /// dropped when the user clears the text.
    private func descriptionStatement(schema: String, table: String,
                                      column: String, text: String) -> String {
        let qualified: String = SQLIdentifier.quote(schema: schema, name: table)
        let objectLiteral: String = SQLIdentifier.literal(qualified)
        let columnLiteral: String = SQLIdentifier.literal(column)
        let schemaLiteral: String = SQLIdentifier.literal(schema)
        let tableLiteral: String = SQLIdentifier.literal(table)
        let valueLiteral: String = SQLIdentifier.literal(text)

        var lines: [String] = []
        lines.append("IF EXISTS (")
        lines.append("    SELECT 1 FROM sys.extended_properties AS ep")
        lines.append("    WHERE ep.class = 1")
        lines.append("      AND ep.major_id = OBJECT_ID(\(objectLiteral))")
        lines.append("      AND ep.minor_id = COLUMNPROPERTY(OBJECT_ID(\(objectLiteral)), "
                     + "\(columnLiteral), 'ColumnId')")
        lines.append("      AND ep.name = N'MS_Description')")

        let levelArguments: [String] = [
            "        @level0type = N'SCHEMA', @level0name = \(schemaLiteral),",
            "        @level1type = N'TABLE',  @level1name = \(tableLiteral),",
            "        @level2type = N'COLUMN', @level2name = \(columnLiteral);"
        ]

        if text.trimmed().isEmpty {
            lines.append("    EXEC sys.sp_dropextendedproperty @name = N'MS_Description',")
            lines.append(contentsOf: levelArguments)
            return lines.joined(separator: "\n")
        }

        lines.append("    EXEC sys.sp_updateextendedproperty @name = N'MS_Description',")
        lines.append("        @value = \(valueLiteral),")
        lines.append(contentsOf: levelArguments)
        lines.append("ELSE")
        lines.append("    EXEC sys.sp_addextendedproperty @name = N'MS_Description',")
        lines.append("        @value = \(valueLiteral),")
        lines.append(contentsOf: levelArguments)
        return lines.joined(separator: "\n")
    }

    private static func columnDefinition(_ column: DesignColumn, table: String) -> String {
        var parts: [String] = [SQLIdentifier.quote(column.name), column.typeName.trimmed()]
        if supportsCollation(column.typeName), !column.collation.trimmed().isEmpty {
            parts.append("COLLATE \(column.collation.trimmed())")
        }
        if column.isIdentity {
            let seed: String = normalizedNumber(column.identitySeed, fallback: "1")
            let step: String = normalizedNumber(column.identityIncrement, fallback: "1")
            parts.append("IDENTITY(\(seed), \(step))")
        }
        parts.append(column.isNullable ? "NULL" : "NOT NULL")
        if !column.isIdentity, !column.defaultDefinition.trimmed().isEmpty {
            let constraint: String = defaultConstraintName(table: table, column: column.name)
            parts.append("CONSTRAINT \(SQLIdentifier.quote(constraint)) "
                         + "DEFAULT \(wrappedDefault(column.defaultDefinition))")
        }
        return parts.joined(separator: " ")
    }

    // MARK: - Helpers

    private static func keyColumns(of columns: [DesignColumn]) -> [DesignColumn] {
        let members: [(offset: Int, element: DesignColumn)] = columns.enumerated()
            .filter { $0.element.isPrimaryKey }
            .map { (offset: $0.offset, element: $0.element) }
        // Existing members keep their key order; newly ticked columns go on the end.
        let sorted = members.sorted { lhs, rhs in
            let left: Int = lhs.element.primaryKeyOrdinal == 0 ? Int.max : lhs.element.primaryKeyOrdinal
            let right: Int = rhs.element.primaryKeyOrdinal == 0 ? Int.max : rhs.element.primaryKeyOrdinal
            if left != right { return left < right }
            return lhs.offset < rhs.offset
        }
        return sorted.map(\.element)
    }

    private static func needsAlterColumn(existing: DesignColumn, edited: DesignColumn) -> Bool {
        if existing.isNullable != edited.isNullable { return true }
        if existing.typeName.trimmed().lowercased() != edited.typeName.trimmed().lowercased() {
            return true
        }
        return existing.collation.trimmed().lowercased() != edited.collation.trimmed().lowercased()
    }

    static func renderTypeName(base: String, maxLength: Int, precision: Int, scale: Int,
                               isUserDefined: Bool) -> String {
        guard !isUserDefined else { return base }
        switch base.lowercased() {
        case "char", "varchar", "binary", "varbinary":
            return maxLength < 0 ? "\(base)(max)" : "\(base)(\(maxLength))"
        case "nchar", "nvarchar":
            return maxLength < 0 ? "\(base)(max)" : "\(base)(\(maxLength / 2))"
        case "decimal", "numeric":
            return "\(base)(\(precision), \(scale))"
        case "datetime2", "time", "datetimeoffset":
            return "\(base)(\(scale))"
        case "float":
            return precision == 53 ? base : "\(base)(\(precision))"
        default:
            return base
        }
    }

    private static let characterTypes: Set<String> =
        ["char", "varchar", "nchar", "nvarchar", "text", "ntext"]

    private static func baseType(of typeName: String) -> String {
        let trimmed: String = typeName.trimmed()
        guard let paren = trimmed.firstIndex(of: "(") else { return trimmed.lowercased() }
        return String(trimmed[trimmed.startIndex..<paren]).trimmed().lowercased()
    }

    private static func defaultConstraintName(table: String, column: String) -> String {
        "DF_\(sanitized(table))_\(sanitized(column))"
    }

    /// Constraint names are generated, so keep them to characters that never need
    /// quoting even when the table or column name is exotic.
    private static func sanitized(_ name: String) -> String {
        let allowed: CharacterSet = CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: "_"))
        let characters: [Character] = name.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(scalar) : Character("_")
        }
        let result = String(characters)
        return result.isEmpty ? "col" : result
    }

    private static func escapedForDynamicSQL(_ text: String) -> String {
        text.replacingOccurrences(of: "'", with: "''")
    }

    /// The catalog stores defaults already parenthesised, "((0))". Strip the wrapping so
    /// a hand typed "0" is not treated as a change.
    static func normalizedDefault(_ text: String) -> String {
        var value: String = text.trimmed()
        while value.hasPrefix("("), value.hasSuffix(")"), value.count > 1 {
            let inner: String = String(value.dropFirst().dropLast()).trimmed()
            guard isBalanced(inner) else { break }
            value = inner
        }
        return value.lowercased()
    }

    static func wrappedDefault(_ text: String) -> String {
        let value: String = text.trimmed()
        if value.hasPrefix("("), value.hasSuffix(")"), isBalanced(String(value.dropFirst().dropLast())) {
            return value
        }
        return "(\(value))"
    }

    private static func isBalanced(_ text: String) -> Bool {
        var depth: Int = 0
        var inString: Bool = false
        for character in text {
            if character == "'" {
                inString.toggle()
                continue
            }
            guard !inString else { continue }
            if character == "(" { depth += 1 }
            if character == ")" {
                depth -= 1
                if depth < 0 { return false }
            }
        }
        return depth == 0 && !inString
    }

    private static func normalizedNumber(_ text: String, fallback: String = "") -> String {
        let value: String = text.trimmed()
        return value.isEmpty ? fallback : value
    }
}

private extension String {
    func trimmed() -> String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
