import Foundation
import TDSKit

// MARK: - Model

/// One edge of the object dependency graph, already flattened for display.
public struct ObjectDependency: Sendable, Hashable, Identifiable {
    public var id: String
    public var schema: String
    public var name: String
    /// Display name of the object type: "Table", "View", "Stored procedure"…
    public var kind: String
    /// How the two objects are tied together: "Column reference", "Foreign key"…
    public var dependencyType: String
    public var isSchemaBound: Bool

    public init(schema: String, name: String, kind: String,
                dependencyType: String, isSchemaBound: Bool) {
        self.id = "\(dependencyType)|\(schema).\(name)"
        self.schema = schema
        self.name = name
        self.kind = kind
        self.dependencyType = dependencyType
        self.isSchemaBound = isSchemaBound
    }

    /// `schema.name` without brackets.
    public var qualifiedName: String {
        schema.isEmpty ? name : "\(schema).\(name)"
    }
}

// MARK: - Service

/// Reads `sys.sql_expression_dependencies` (module bodies) and `sys.foreign_keys`
/// (declarative table relationships), which together cover what SSMS shows in
/// "View Dependencies".
public struct DependencyService: Sendable {

    private let session: SQLServerSession

    public init(session: SQLServerSession) {
        self.session = session
    }

    // MARK: - Depends on

    /// Objects that `schema.name` references.
    public func dependsOn(database: String, schema: String, name: String)
        async throws -> [ObjectDependency] {

        let target: String = objectIDLiteral(schema: schema, name: name)
        let sql: String = """
        SELECT
            COALESCE(sed.referenced_schema_name, SCHEMA_NAME(r.schema_id), N'') AS ref_schema,
            COALESCE(sed.referenced_entity_name, r.name, N'') AS ref_name,
            COALESCE(r.type_desc, N'') AS type_desc,
            COALESCE(sed.referenced_database_name, N'') AS ref_database,
            MAX(CONVERT(int, sed.is_schema_bound_reference)) AS is_schema_bound,
            MAX(CASE WHEN sed.referenced_minor_id > 0 THEN 1 ELSE 0 END) AS has_column_reference
        FROM sys.sql_expression_dependencies AS sed
        LEFT JOIN sys.objects AS r ON r.object_id = sed.referenced_id
        WHERE sed.referencing_class = 1
          AND sed.referencing_id = OBJECT_ID(\(target))
        GROUP BY sed.referenced_schema_name, sed.referenced_entity_name,
                 sed.referenced_database_name, r.schema_id, r.name, r.type_desc
        ORDER BY 1, 2
        """
        let expressionRows: [[String: TDSValue]] = try await rows(sql, database: database)
        var result: [ObjectDependency] = expressionRows.compactMap { row in
            let referenced: String = row.string("ref_name")
            guard !referenced.isEmpty else { return nil }
            let external: String = row.string("ref_database")
            let typeDesc: String = row.string("type_desc")
            let kind: String = DependencyService.kindTitle(typeDesc, externalDatabase: external)
            let dependency: String = row.int("has_column_reference") == 1
                ? "Column reference"
                : "Object reference"
            return ObjectDependency(schema: row.string("ref_schema"),
                                    name: referenced,
                                    kind: kind,
                                    dependencyType: dependency,
                                    isSchemaBound: row.int("is_schema_bound") == 1)
        }

        let foreignKeySQL: String = """
        SELECT DISTINCT SCHEMA_NAME(rt.schema_id) AS ref_schema, rt.name AS ref_name
        FROM sys.foreign_keys AS fk
        JOIN sys.tables AS rt ON rt.object_id = fk.referenced_object_id
        WHERE fk.parent_object_id = OBJECT_ID(\(target))
        ORDER BY 1, 2
        """
        let foreignKeyRows: [[String: TDSValue]] = try await rows(foreignKeySQL, database: database)
        result.append(contentsOf: foreignKeyRows.compactMap { row in
            let referenced: String = row.string("ref_name")
            guard !referenced.isEmpty else { return nil }
            return ObjectDependency(schema: row.string("ref_schema"),
                                    name: referenced,
                                    kind: "Table",
                                    dependencyType: "Foreign key",
                                    isSchemaBound: false)
        })

        return deduplicated(result)
    }

    // MARK: - Dependents

    /// Objects that reference `schema.name`.
    public func dependents(database: String, schema: String, name: String)
        async throws -> [ObjectDependency] {

        let target: String = objectIDLiteral(schema: schema, name: name)
        // Unresolved references (created before the target existed) carry a NULL
        // referenced_id, so they are matched by name as well.
        let sql: String = """
        SELECT
            SCHEMA_NAME(o.schema_id) AS dep_schema, o.name AS dep_name, o.type_desc AS type_desc,
            MAX(CONVERT(int, sed.is_schema_bound_reference)) AS is_schema_bound,
            MAX(CASE WHEN sed.referenced_minor_id > 0 THEN 1 ELSE 0 END) AS has_column_reference
        FROM sys.sql_expression_dependencies AS sed
        JOIN sys.objects AS o ON o.object_id = sed.referencing_id
        WHERE sed.referencing_class = 1
          AND (sed.referenced_id = OBJECT_ID(\(target))
               OR (sed.referenced_id IS NULL
                   AND sed.referenced_database_name IS NULL
                   AND sed.referenced_entity_name = \(SQLIdentifier.literal(name))
                   AND (sed.referenced_schema_name IS NULL
                        OR sed.referenced_schema_name = \(SQLIdentifier.literal(schema)))))
        GROUP BY o.schema_id, o.name, o.type_desc
        ORDER BY 1, 2
        """
        let expressionRows: [[String: TDSValue]] = try await rows(sql, database: database)
        var result: [ObjectDependency] = expressionRows.compactMap { row in
            let referencing: String = row.string("dep_name")
            guard !referencing.isEmpty else { return nil }
            let kind: String = DependencyService.kindTitle(row.string("type_desc"),
                                                           externalDatabase: "")
            let dependency: String = row.int("has_column_reference") == 1
                ? "Column reference"
                : "Object reference"
            return ObjectDependency(schema: row.string("dep_schema"),
                                    name: referencing,
                                    kind: kind,
                                    dependencyType: dependency,
                                    isSchemaBound: row.int("is_schema_bound") == 1)
        }

        let foreignKeySQL: String = """
        SELECT DISTINCT SCHEMA_NAME(pt.schema_id) AS dep_schema, pt.name AS dep_name
        FROM sys.foreign_keys AS fk
        JOIN sys.tables AS pt ON pt.object_id = fk.parent_object_id
        WHERE fk.referenced_object_id = OBJECT_ID(\(target))
        ORDER BY 1, 2
        """
        let foreignKeyRows: [[String: TDSValue]] = try await rows(foreignKeySQL, database: database)
        result.append(contentsOf: foreignKeyRows.compactMap { row in
            let referencing: String = row.string("dep_name")
            guard !referencing.isEmpty else { return nil }
            return ObjectDependency(schema: row.string("dep_schema"),
                                    name: referencing,
                                    kind: "Table",
                                    dependencyType: "Foreign key",
                                    isSchemaBound: false)
        })

        return deduplicated(result)
    }

    // MARK: - Helpers

    private func rows(_ sql: String, database: String) async throws -> [[String: TDSValue]] {
        let result: TDSQueryResult = try await session.metadataQuery(sql, database: database)
        return result.resultSets.first?.dictionaries() ?? []
    }

    /// OBJECT_ID() accepts a bracketed name, which is the only form that survives
    /// schemas or objects containing a dot.
    private func objectIDLiteral(schema: String, name: String) -> String {
        let quoted: String = schema.isEmpty
            ? SQLIdentifier.quote(name)
            : SQLIdentifier.quote(schema: schema, name: name)
        return SQLIdentifier.literal(quoted)
    }

    private func deduplicated(_ items: [ObjectDependency]) -> [ObjectDependency] {
        var seen: Set<String> = []
        var result: [ObjectDependency] = []
        for item in items where !seen.contains(item.id) {
            seen.insert(item.id)
            result.append(item)
        }
        return result.sorted { lhs, rhs in
            if lhs.kind != rhs.kind { return lhs.kind < rhs.kind }
            return lhs.qualifiedName.localizedCaseInsensitiveCompare(rhs.qualifiedName)
                == .orderedAscending
        }
    }

    private static func kindTitle(_ typeDesc: String, externalDatabase: String) -> String {
        let trimmed: String = typeDesc.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            return externalDatabase.isEmpty ? "Unresolved" : "In \(externalDatabase)"
        }
        switch trimmed.uppercased() {
        case "USER_TABLE": return "Table"
        case "SYSTEM_TABLE": return "System table"
        case "INTERNAL_TABLE": return "Internal table"
        case "VIEW": return "View"
        case "SQL_STORED_PROCEDURE": return "Stored procedure"
        case "CLR_STORED_PROCEDURE": return "CLR stored procedure"
        case "EXTENDED_STORED_PROCEDURE": return "Extended stored procedure"
        case "SQL_SCALAR_FUNCTION": return "Scalar function"
        case "CLR_SCALAR_FUNCTION": return "CLR scalar function"
        case "SQL_INLINE_TABLE_VALUED_FUNCTION": return "Inline table-valued function"
        case "SQL_TABLE_VALUED_FUNCTION": return "Table-valued function"
        case "CLR_TABLE_VALUED_FUNCTION": return "CLR table-valued function"
        case "AGGREGATE_FUNCTION": return "Aggregate function"
        case "SQL_TRIGGER": return "Trigger"
        case "CLR_TRIGGER": return "CLR trigger"
        case "SYNONYM": return "Synonym"
        case "SEQUENCE_OBJECT": return "Sequence"
        case "TYPE_TABLE": return "User-defined table type"
        case "PLAN_GUIDE": return "Plan guide"
        case "SECURITY_POLICY": return "Security policy"
        default:
            return trimmed.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}
