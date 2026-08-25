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

    private let session: SQLServerSession
    private let database: String
    private let schema: String
    private let table: String

    private var columns: [TDSColumn] = []
    private var keyColumns: [String] = []
    private var identityColumns: Set<String> = []
    private var computedColumns: Set<String> = []
    private var timestampColumns: Set<String> = []

    public init(session: SQLServerSession, database: String, schema: String, table: String) {
        self.session = session
        self.database = database
        self.schema = schema
        self.table = table
    }

    private var qualifiedTable: String {
        SQLIdentifier.quote(schema: schema, name: table)
    }

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

        let readOnlyReason: String? = keyColumns.isEmpty
            ? "The table has no primary key or unique index, so rows cannot be identified for update."
            : nil

        return LoadResult(columns: resultSet.columns,
                          rows: resultSet.rows,
                          keyColumns: keyColumns,
                          isReadOnly: readOnlyReason != nil,
                          readOnlyReason: readOnlyReason)
    }

    /// Primary key first; a unique index is the fallback SSMS also accepts.
    private func loadColumnMetadata() async throws {
        let sql = """
        SELECT c.name, c.is_identity, c.is_computed,
               CONVERT(int, CASE WHEN t.name IN (N'timestamp', N'rowversion') THEN 1 ELSE 0 END)
                   AS is_timestamp
        FROM sys.columns AS c
        JOIN sys.types AS t ON t.user_type_id = c.user_type_id
        WHERE c.object_id = OBJECT_ID(\(SQLIdentifier.literal("\(schema).\(table)")))
        ORDER BY c.column_id;

        SELECT TOP (1) i.index_id, i.is_primary_key,
               STUFF((SELECT N',' + c2.name
                      FROM sys.index_columns AS ic2
                      JOIN sys.columns AS c2 ON c2.object_id = ic2.object_id
                           AND c2.column_id = ic2.column_id
                      WHERE ic2.object_id = i.object_id AND ic2.index_id = i.index_id
                        AND ic2.is_included_column = 0
                      ORDER BY ic2.key_ordinal
                      FOR XML PATH(N''), TYPE).value(N'.', N'nvarchar(max)'), 1, 1, N'') AS key_columns
        FROM sys.indexes AS i
        WHERE i.object_id = OBJECT_ID(\(SQLIdentifier.literal("\(schema).\(table)")))
          AND (i.is_primary_key = 1 OR i.is_unique = 1)
        ORDER BY i.is_primary_key DESC, i.index_id;
        """
        let result = try await session.metadataQuery(sql, database: database)

        identityColumns = []
        computedColumns = []
        timestampColumns = []
        if let rows = result.resultSets.first?.dictionaries() {
            for row in rows {
                let name = row.string("name")
                if row.bool("is_identity") { identityColumns.insert(name.lowercased()) }
                if row.bool("is_computed") { computedColumns.insert(name.lowercased()) }
                if row.bool("is_timestamp") { timestampColumns.insert(name.lowercased()) }
            }
        }

        keyColumns = []
        if result.resultSets.count > 1,
           let row = result.resultSets[1].dictionaries().first {
            keyColumns = row.string("key_columns")
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
    }

    // MARK: - Writing

    public func script(for changes: [RowChange]) throws -> String {
        guard !changes.isEmpty else { return "" }
        guard !keyColumns.isEmpty || changes.allSatisfy({ $0.kind == .insert }) else {
            throw SQLServerError.unsupportedOperation(
                "The table has no primary key or unique index, so rows cannot be identified for update.")
        }

        var statements: [String] = []
        statements.append("SET XACT_ABORT ON;")
        statements.append("BEGIN TRANSACTION;")

        let needsIdentityInsert = changes.contains { change in
            change.kind == .insert && change.newValues.keys.contains {
                identityColumns.contains($0.lowercased())
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

    @discardableResult
    public func apply(_ changes: [RowChange]) async throws -> Int {
        let sql = try script(for: changes)
        guard !sql.isEmpty else { return 0 }
        let connection = try await session.openConnection(database: database)
        defer { Task { try? await connection.close() } }
        _ = try await connection.query(sql)
        return changes.count
    }

    // MARK: - Statement builders

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
        IF @@ROWCOUNT <> 1
            RAISERROR (N'The update affected a different number of rows than expected. \
        The row may have been changed by another session.', 16, 1);
        """
    }

    private func insertStatement(_ change: RowChange) -> String {
        let entries = change.newValues
            .filter { name, _ in
                !computedColumns.contains(name.lowercased())
                    && !timestampColumns.contains(name.lowercased())
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
        IF @@ROWCOUNT <> 1
            RAISERROR (N'The delete affected a different number of rows than expected. \
        The row may have been changed by another session.', 16, 1);
        """
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
            return value.sqlLiteral
        }
    }
}
