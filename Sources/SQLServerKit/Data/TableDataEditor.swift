import Foundation
import TDSKit

/// Backs "Edit Top 200 Rows": loads a window of rows and writes changes back with
/// statements that can only ever affect the single row the user edited.
public final class TableDataEditor {

    public struct RowChange: Sendable {
        public enum Kind: Sendable { case update, insert, delete }

        public var kind: Kind
        public var rowIndex: Int
        public var originalValues: [String: TDSValue]
        public var newValues: [String: TDSValue]

        public init(kind: Kind, rowIndex: Int,
                    originalValues: [String: TDSValue],
                    newValues: [String: TDSValue]) {
            self.kind = kind
            self.rowIndex = rowIndex
            self.originalValues = originalValues
            self.newValues = newValues
        }
    }

    public struct LoadResult: Sendable {
        public var columns: [TDSColumn]
        public var rows: [[TDSValue]]
        public var keyColumns: [String]
        public var isReadOnly: Bool
        public var readOnlyReason: String?

        public init(columns: [TDSColumn], rows: [[TDSValue]], keyColumns: [String],
                    isReadOnly: Bool, readOnlyReason: String?) {
            self.columns = columns
            self.rows = rows
            self.keyColumns = keyColumns
            self.isReadOnly = isReadOnly
            self.readOnlyReason = readOnlyReason
        }
    }

    /// The pure half of the editor: turns row changes into the batch that applies them,
    /// from the column facts `load` read. It holds no connection, so the batch text can
    /// be checked without a server.
    public struct StatementBuilder: Sendable {
        public var qualifiedTable: String
        /// The columns that identify a row (the primary key, else the first unique index),
        /// in key order. Empty when the table has neither.
        public var keyColumns: [String]
        /// Lower-cased names, because column names are case-insensitive on the server but
        /// not in a Swift dictionary.
        public var identityColumns: Set<String>
        public var computedColumns: Set<String>
        public var timestampColumns: Set<String>

        public init(schema: String, table: String, keyColumns: [String],
                    identityColumns: Set<String> = [], computedColumns: Set<String> = [],
                    timestampColumns: Set<String> = []) {
            qualifiedTable = SQLIdentifier.quote(schema: schema, name: table)
            self.keyColumns = keyColumns
            self.identityColumns = Set(identityColumns.map { $0.lowercased() })
            self.computedColumns = Set(computedColumns.map { $0.lowercased() })
            self.timestampColumns = Set(timestampColumns.map { $0.lowercased() })
        }

        public func script(for changes: [RowChange]) throws -> String {
            guard !changes.isEmpty else { return "" }
            guard !keyColumns.isEmpty || changes.allSatisfy({ $0.kind == .insert }) else {
                throw SQLServerError.unsupportedOperation(
                    "The table has no primary key or unique index, so rows cannot be identified for update.")
            }

            var statements: [String] = []
            statements.append("SET XACT_ABORT ON;")
            statements.append("BEGIN TRANSACTION;")

            // IDENTITY_INSERT is only needed when the user typed a value into an identity
            // column; a NULL there means "let the server number the row".
            let needsIdentityInsert = changes.contains { change in
                change.kind == .insert && change.newValues.contains { name, value in
                    identityColumns.contains(name.lowercased()) && !value.isNull
                }
            }
            if needsIdentityInsert {
                statements.append("SET IDENTITY_INSERT \(qualifiedTable) ON;")
            }

            for change in changes {
                switch change.kind {
                case .update:
                    if let statement = updateStatement(change) { statements.append(statement) }
                case .insert:
                    statements.append(insertStatement(change))
                case .delete:
                    statements.append(deleteStatement(change))
                }
            }

            if needsIdentityInsert {
                statements.append("SET IDENTITY_INSERT \(qualifiedTable) OFF;")
            }
            statements.append("COMMIT TRANSACTION;")
            return statements.joined(separator: "\n\n") + "\n"
        }

        // MARK: Statement builders

        private func updateStatement(_ change: RowChange) -> String? {
            let assignments = change.newValues
                .filter { name, value in
                    guard !isReadOnlyColumn(name) else { return false }
                    return change.originalValues[name] != value
                }
                .sorted { $0.key < $1.key }
                .map { "    \(SQLIdentifier.quote($0.key)) = \(literal($0.value))" }

            guard !assignments.isEmpty else { return nil }

            return """
            UPDATE \(qualifiedTable) SET
            \(assignments.joined(separator: ",\n"))
            WHERE \(whereClause(for: change.originalValues));
            \(rowCountGuard("update"))
            """
        }

        private func insertStatement(_ change: RowChange) -> String {
            let entries = change.newValues
                .filter { name, value in
                    let lowered = name.lowercased()
                    if computedColumns.contains(lowered) || timestampColumns.contains(lowered) {
                        return false
                    }
                    // The grid sends every column of a new row, the identity column as
                    // NULL unless the user typed a value. Leaving it out lets the server
                    // assign the next value; keeping it would be INSERT … VALUES (NULL, …)
                    // under IDENTITY_INSERT, which fails with Msg 339.
                    if identityColumns.contains(lowered), value.isNull { return false }
                    return true
                }
                .sorted { $0.key < $1.key }

            guard !entries.isEmpty else { return "INSERT INTO \(qualifiedTable) DEFAULT VALUES;" }

            let names = entries.map { SQLIdentifier.quote($0.key) }.joined(separator: ", ")
            let values = entries.map { literal($0.value) }.joined(separator: ", ")
            return "INSERT INTO \(qualifiedTable) (\(names))\nVALUES (\(values));"
        }

        private func deleteStatement(_ change: RowChange) -> String {
            """
            DELETE FROM \(qualifiedTable)
            WHERE \(whereClause(for: change.originalValues));
            \(rowCountGuard("delete"))
            """
        }

        /// THROW ends the batch, and with XACT_ABORT on the transaction is rolled back, so
        /// a row another session changed stops the whole edit. RAISERROR with severity 16
        /// does neither: the statements after it, COMMIT included, would still run and
        /// the other rows would be committed while the client reports a failure.
        private func rowCountGuard(_ verb: String) -> String {
            "IF @@ROWCOUNT <> 1 THROW 50000, N'The \(verb) affected a different number of rows "
                + "than expected. The row may have been changed by another session.', 1;"
        }

        /// Key on the original values so a concurrent change makes the statement a no-op
        /// rather than clobbering someone else's edit.
        private func whereClause(for values: [String: TDSValue]) -> String {
            let keys = keyColumns.isEmpty
                ? values.keys.sorted().filter { !isReadOnlyColumn($0) }
                : keyColumns

            let predicates = keys.compactMap { name -> String? in
                guard let value = values[name] ?? values[matchingKey(name, in: values) ?? ""] else {
                    return nil
                }
                let quoted = SQLIdentifier.quote(name)
                return value.isNull ? "\(quoted) IS NULL" : "\(quoted) = \(literal(value))"
            }
            return predicates.isEmpty ? "1 = 0" : predicates.joined(separator: " AND ")
        }

        /// Column names are case-insensitive on the server but not in a Swift dictionary.
        private func matchingKey(_ name: String, in values: [String: TDSValue]) -> String? {
            values.keys.first { $0.caseInsensitiveCompare(name) == .orderedSame }
        }

        private func isReadOnlyColumn(_ name: String) -> Bool {
            let lowered = name.lowercased()
            return identityColumns.contains(lowered)
                || computedColumns.contains(lowered)
                || timestampColumns.contains(lowered)
        }

        private func literal(_ value: TDSValue) -> String {
            switch value {
            case .binary(let bytes):
                // sqlLiteral already renders 0x-prefixed hex, but an empty blob needs 0x.
                return bytes.isEmpty ? "0x" : value.sqlLiteral
            default:
                // Dates go through sqlLiteral too, which renders the language-neutral form.
                return value.sqlLiteral
            }
        }
    }

    private let session: SQLServerSession
    private let database: String
    private let schema: String
    private let table: String

    private var columns: [TDSColumn] = []
    private var builder: StatementBuilder

    public init(session: SQLServerSession, database: String, schema: String, table: String) {
        self.session = session
        self.database = database
        self.schema = schema
        self.table = table
        self.builder = StatementBuilder(schema: schema, table: table, keyColumns: [])
    }

    private var qualifiedTable: String { builder.qualifiedTable }

    // MARK: - Loading

    public func load(top: Int, whereClause: String?, orderBy: String?) async throws -> LoadResult {
        try await loadColumnMetadata()

        var sql = "SELECT TOP (\(max(1, top))) * FROM \(qualifiedTable)"
        if let whereClause, !whereClause.trimmingCharacters(in: .whitespaces).isEmpty {
            sql += " WHERE \(whereClause)"
        }
        if let orderBy, !orderBy.trimmingCharacters(in: .whitespaces).isEmpty {
            sql += " ORDER BY \(orderBy)"
        }

        let result = try await session.metadataQuery(sql, database: database)
        guard let resultSet = result.resultSets.first else {
            throw SQLServerError.objectNotFound("\(schema).\(table)")
        }
        columns = resultSet.columns

        let readOnlyReason: String? = builder.keyColumns.isEmpty
            ? "The table has no primary key or unique index, so rows cannot be identified for update."
            : nil

        return LoadResult(columns: resultSet.columns,
                          rows: resultSet.rows,
                          keyColumns: builder.keyColumns,
                          isReadOnly: readOnlyReason != nil,
                          readOnlyReason: readOnlyReason)
    }

    /// Primary key first; a unique index is the fallback SSMS also accepts. The key
    /// columns come back one row each, so a comma in a column name cannot split the list.
    private func loadColumnMetadata() async throws {
        let objectID = ScriptGenerator.objectIDExpression(schema: schema, name: table)
        let sql = """
        SELECT c.name, c.is_identity, c.is_computed,
               CONVERT(int, CASE WHEN t.name IN (N'timestamp', N'rowversion') THEN 1 ELSE 0 END)
                   AS is_timestamp
        FROM sys.columns AS c
        JOIN sys.types AS t ON t.user_type_id = c.user_type_id
        WHERE c.object_id = \(objectID)
        ORDER BY c.column_id;

        DECLARE @key_index_id int;
        SELECT TOP (1) @key_index_id = i.index_id
        FROM sys.indexes AS i
        WHERE i.object_id = \(objectID)
          AND (i.is_primary_key = 1 OR i.is_unique = 1)
        ORDER BY i.is_primary_key DESC, i.index_id;

        SELECT c2.name AS key_column
        FROM sys.index_columns AS ic2
        JOIN sys.columns AS c2 ON c2.object_id = ic2.object_id AND c2.column_id = ic2.column_id
        WHERE ic2.object_id = \(objectID) AND ic2.index_id = @key_index_id
          AND ic2.is_included_column = 0
        ORDER BY ic2.key_ordinal;
        """
        let result = try await session.metadataQuery(sql, database: database)

        var identityColumns: Set<String> = []
        var computedColumns: Set<String> = []
        var timestampColumns: Set<String> = []
        if let rows = result.resultSets.first?.dictionaries() {
            for row in rows {
                let name = row.string("name")
                if row.bool("is_identity") { identityColumns.insert(name) }
                if row.bool("is_computed") { computedColumns.insert(name) }
                if row.bool("is_timestamp") { timestampColumns.insert(name) }
            }
        }

        var keyColumns: [String] = []
        if result.resultSets.count > 1 {
            keyColumns = result.resultSets[1].dictionaries()
                .map { $0.string("key_column") }
                .filter { !$0.isEmpty }
        }

        builder = StatementBuilder(schema: schema, table: table, keyColumns: keyColumns,
                                   identityColumns: identityColumns,
                                   computedColumns: computedColumns,
                                   timestampColumns: timestampColumns)
    }

    // MARK: - Writing

    public func script(for changes: [RowChange]) throws -> String {
        try builder.script(for: changes)
    }

    @discardableResult
    public func apply(_ changes: [RowChange]) async throws -> Int {
        let sql = try script(for: changes)
        guard !sql.isEmpty else { return 0 }
        let connection = try await session.openConnection(database: database)
        defer { Task { try? await connection.close() } }
        _ = try await connection.query(sql)
        return changes.count
    }
}
