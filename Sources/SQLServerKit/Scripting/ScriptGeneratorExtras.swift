import Foundation
import TDSKit

/// Scripting for the object kinds that have no module definition in `sys.sql_modules`.
///
/// A view or a procedure carries its own text, so scripting it is a lookup. A synonym, a
/// sequence, a user-defined type or a partition function has to be rebuilt from its
/// catalog row, which is what this file does.
extension ScriptGenerator {

    /// Dispatcher for the kinds `script(node:action:options:)` cannot route to a module or
    /// a table.
    func extraScript(node: ObjectExplorerNode,
                     action: ScriptAction,
                     options: ScriptOptions) async throws -> String {
        let database = node.database ?? ""
        let schema = node.schema ?? "dbo"
        let name = node.name ?? node.label

        switch node.kind {
        case .synonym:
            return try await synonymScript(database: database, schema: schema, name: name,
                                           action: action, options: options)
        case .sequence:
            return try await sequenceScript(database: database, schema: schema, name: name,
                                            action: action, options: options)
        case .userDefinedDataType:
            return try await dataTypeScript(database: database, schema: schema, name: name,
                                            action: action, options: options)
        case .userDefinedTableType:
            return try await tableTypeScript(database: database, schema: schema, name: name,
                                             action: action, options: options)
        case .schema:
            return try await schemaScript(database: database, name: name, action: action)
        case .databaseUser:
            return try await databaseUserScript(database: database, name: name, action: action)
        case .databaseRole, .applicationRole:
            return try await databaseRoleScript(database: database, name: name,
                                                kind: node.kind, action: action)
        case .login:
            return try await loginScript(name: name, action: action)
        case .partitionFunction:
            return try await partitionFunctionScript(database: database, name: name, action: action)
        case .partitionScheme:
            return try await partitionSchemeScript(database: database, name: name, action: action)
        case .xmlSchemaCollection:
            return try await xmlSchemaCollectionScript(database: database, schema: schema,
                                                       name: name, action: action)
        case .assembly:
            throw SQLServerError.unsupportedOperation(
                "An assembly's bytes cannot be scripted as text. Use Tasks → Back Up on the "
                + "database, or redeploy the assembly from its build output.")
        default:
            throw SQLServerError.unsupportedOperation(
                "Scripting is not supported for this object type.")
        }
    }

    // MARK: - Synonyms

    private func synonymScript(database: String, schema: String, name: String,
                               action: ScriptAction, options: ScriptOptions) async throws -> String {
        let target = SQLIdentifier.quote(schema: schema, name: name)
        if action == .drop {
            return "DROP SYNONYM IF EXISTS \(target);\nGO\n"
        }
        let sql = """
        SELECT s.base_object_name AS BaseObjectName
        FROM sys.synonyms AS s
        JOIN sys.schemas AS sc ON sc.schema_id = s.schema_id
        WHERE sc.name = \(SQLIdentifier.literal(schema)) AND s.name = \(SQLIdentifier.literal(name));
        """
        guard let row = try await rows(sql, database: database).first else {
            throw SQLServerError.objectNotFound("\(schema).\(name)")
        }
        var out = descriptiveHeader(kind: "Synonym", target: target, options: options)
        if action == .dropAndCreate || options.includeDropIfExists {
            out += "DROP SYNONYM IF EXISTS \(target);\nGO\n"
        }
        // base_object_name is already stored bracket-quoted by SQL Server.
        out += "CREATE SYNONYM \(target) FOR \(row.string("BaseObjectName"));\nGO\n"
        return out
    }

    // MARK: - Sequences

    private func sequenceScript(database: String, schema: String, name: String,
                                action: ScriptAction, options: ScriptOptions) async throws -> String {
        let target = SQLIdentifier.quote(schema: schema, name: name)
        if action == .drop {
            return "DROP SEQUENCE IF EXISTS \(target);\nGO\n"
        }
        let sql = """
        SELECT
            t.name                                        AS TypeName,
            CONVERT(nvarchar(64), s.start_value)          AS StartValue,
            CONVERT(nvarchar(64), s.increment)            AS IncrementValue,
            CONVERT(nvarchar(64), s.minimum_value)        AS MinimumValue,
            CONVERT(nvarchar(64), s.maximum_value)        AS MaximumValue,
            CAST(s.is_cycling AS int)                     AS IsCycling,
            CAST(s.is_cached AS int)                      AS IsCached,
            CAST(ISNULL(s.cache_size, 0) AS int)          AS CacheSize
        FROM sys.sequences AS s
        JOIN sys.schemas AS sc ON sc.schema_id = s.schema_id
        JOIN sys.types AS t ON t.user_type_id = s.user_type_id
        WHERE sc.name = \(SQLIdentifier.literal(schema)) AND s.name = \(SQLIdentifier.literal(name));
        """
        guard let row = try await rows(sql, database: database).first else {
            throw SQLServerError.objectNotFound("\(schema).\(name)")
        }

        var out = descriptiveHeader(kind: "Sequence", target: target, options: options)
        if action == .dropAndCreate || options.includeDropIfExists {
            out += "DROP SEQUENCE IF EXISTS \(target);\nGO\n"
        }
        out += "CREATE SEQUENCE \(target)\n"
        out += "    AS \(SQLIdentifier.quote(row.string("TypeName")))\n"
        out += "    START WITH \(row.string("StartValue", default: "1"))\n"
        out += "    INCREMENT BY \(row.string("IncrementValue", default: "1"))\n"
        out += "    MINVALUE \(row.string("MinimumValue", default: "1"))\n"
        out += "    MAXVALUE \(row.string("MaximumValue", default: "1"))\n"
        out += row.bool("IsCycling") ? "    CYCLE\n" : "    NO CYCLE\n"
        if row.bool("IsCached") {
            let size = row.int("CacheSize")
            out += size > 0 ? "    CACHE \(size);\n" : "    CACHE;\n"
        } else {
            out += "    NO CACHE;\n"
        }
        return out + "GO\n"
    }

    // MARK: - User-defined types

    private func dataTypeScript(database: String, schema: String, name: String,
                                action: ScriptAction, options: ScriptOptions) async throws -> String {
        let target = SQLIdentifier.quote(schema: schema, name: name)
        if action == .drop {
            return "DROP TYPE IF EXISTS \(target);\nGO\n"
        }
        let sql = """
        SELECT
            base.name                                     AS BaseTypeName,
            CAST(t.max_length AS int)                     AS MaxLength,
            CAST(t.precision AS int)                      AS TypePrecision,
            CAST(t.scale AS int)                          AS TypeScale,
            CAST(t.is_nullable AS int)                    AS IsNullable,
            ISNULL(t.collation_name, N'')                 AS CollationName
        FROM sys.types AS t
        JOIN sys.schemas AS sc ON sc.schema_id = t.schema_id
        JOIN sys.types AS base ON base.user_type_id = t.system_type_id
        WHERE sc.name = \(SQLIdentifier.literal(schema)) AND t.name = \(SQLIdentifier.literal(name))
          AND t.is_user_defined = 1 AND t.is_table_type = 0;
        """
        guard let row = try await rows(sql, database: database).first else {
            throw SQLServerError.objectNotFound("\(schema).\(name)")
        }
        let typeName = ScriptGenerator.formatType(name: row.string("BaseTypeName"),
                                                  baseName: row.string("BaseTypeName"),
                                                  maxLength: row.int("MaxLength"),
                                                  precision: row.int("TypePrecision"),
                                                  scale: row.int("TypeScale"),
                                                  isUserDefined: false)
        var out = descriptiveHeader(kind: "UserDefinedDataType", target: target, options: options)
        if action == .dropAndCreate || options.includeDropIfExists {
            out += "DROP TYPE IF EXISTS \(target);\nGO\n"
        }
        out += "CREATE TYPE \(target) FROM \(typeName)"
        out += row.bool("IsNullable") ? " NULL;\n" : " NOT NULL;\n"
        return out + "GO\n"
    }

    private func tableTypeScript(database: String, schema: String, name: String,
                                 action: ScriptAction, options: ScriptOptions) async throws -> String {
        let target = SQLIdentifier.quote(schema: schema, name: name)
        if action == .drop {
            return "DROP TYPE IF EXISTS \(target);\nGO\n"
        }

        let columnSQL = """
        SELECT
            c.name                                        AS ColumnName,
            t.name                                        AS TypeName,
            base.name                                     AS BaseTypeName,
            CAST(t.is_user_defined AS int)                AS IsUserDefined,
            CAST(c.max_length AS int)                     AS MaxLength,
            CAST(c.precision AS int)                      AS TypePrecision,
            CAST(c.scale AS int)                          AS TypeScale,
            CAST(c.is_nullable AS int)                    AS IsNullable,
            CAST(c.is_identity AS int)                    AS IsIdentity,
            ISNULL(c.collation_name, N'')                 AS CollationName,
            ISNULL(CONVERT(nvarchar(max), dc.definition), N'') AS DefaultDefinition
        FROM sys.table_types AS tt
        JOIN sys.schemas AS sc ON sc.schema_id = tt.schema_id
        JOIN sys.columns AS c ON c.object_id = tt.type_table_object_id
        JOIN sys.types AS t ON t.user_type_id = c.user_type_id
        JOIN sys.types AS base ON base.user_type_id = t.system_type_id
        LEFT JOIN sys.default_constraints AS dc ON dc.parent_object_id = c.object_id
             AND dc.parent_column_id = c.column_id
        WHERE sc.name = \(SQLIdentifier.literal(schema)) AND tt.name = \(SQLIdentifier.literal(name))
        ORDER BY c.column_id;
        """
        let columnRows = try await rows(columnSQL, database: database)
        guard !columnRows.isEmpty else {
            throw SQLServerError.objectNotFound("\(schema).\(name)")
        }

        let keySQL = """
        SELECT
            CAST(i.is_primary_key AS int)                 AS IsPrimaryKey,
            CAST(i.is_unique AS int)                      AS IsUnique,
            CAST(i.type AS int)                           AS IndexType,
            STUFF((SELECT N', ' + QUOTENAME(c2.name)
                     + CASE WHEN ic2.is_descending_key = 1 THEN N' DESC' ELSE N' ASC' END
                   FROM sys.index_columns AS ic2
                   JOIN sys.columns AS c2 ON c2.object_id = ic2.object_id
                        AND c2.column_id = ic2.column_id
                   WHERE ic2.object_id = i.object_id AND ic2.index_id = i.index_id
                     AND ic2.is_included_column = 0
                   ORDER BY ic2.key_ordinal
                   FOR XML PATH(N''), TYPE).value(N'.', N'nvarchar(max)'), 1, 2, N'') AS KeyColumns
        FROM sys.table_types AS tt
        JOIN sys.schemas AS sc ON sc.schema_id = tt.schema_id
        JOIN sys.indexes AS i ON i.object_id = tt.type_table_object_id
        WHERE sc.name = \(SQLIdentifier.literal(schema)) AND tt.name = \(SQLIdentifier.literal(name))
          AND i.index_id > 0
        ORDER BY i.index_id;
        """
        let keyRows = (try? await rows(keySQL, database: database)) ?? []

        var out = descriptiveHeader(kind: "UserDefinedTableType", target: target, options: options)
        if action == .dropAndCreate || options.includeDropIfExists {
            out += "DROP TYPE IF EXISTS \(target);\nGO\n"
        }
        out += "CREATE TYPE \(target) AS TABLE(\n"

        var lines: [String] = columnRows.map { row in
            let typeName = ScriptGenerator.formatType(name: row.string("TypeName"),
                                                      baseName: row.string("BaseTypeName"),
                                                      maxLength: row.int("MaxLength"),
                                                      precision: row.int("TypePrecision"),
                                                      scale: row.int("TypeScale"),
                                                      isUserDefined: row.bool("IsUserDefined"))
            var text = "\t\(SQLIdentifier.quote(row.string("ColumnName"))) \(typeName)"
            let collation = row.string("CollationName")
            if options.scriptCollation, !collation.isEmpty {
                text += " COLLATE \(collation)"
            }
            if row.bool("IsIdentity") { text += " IDENTITY(1,1)" }
            let defaultDefinition = row.string("DefaultDefinition")
            if options.scriptDefaults, !defaultDefinition.isEmpty {
                text += " DEFAULT \(defaultDefinition)"
            }
            text += row.bool("IsNullable") ? " NULL" : " NOT NULL"
            return text
        }

        for row in keyRows {
            let columns = row.string("KeyColumns")
            guard !columns.isEmpty else { continue }
            let clustered = row.int("IndexType") == 1 ? "CLUSTERED" : "NONCLUSTERED"
            if row.bool("IsPrimaryKey") {
                lines.append("\tPRIMARY KEY \(clustered) (\(columns))")
            } else if row.bool("IsUnique") {
                lines.append("\tUNIQUE \(clustered) (\(columns))")
            }
        }

        out += lines.joined(separator: ",\n")
        out += "\n);\nGO\n"
        return out
    }

    // MARK: - Principals and schemas

    private func schemaScript(database: String, name: String,
                              action: ScriptAction) async throws -> String {
        let target = SQLIdentifier.quote(name)
        if action == .drop {
            return "DROP SCHEMA IF EXISTS \(target);\nGO\n"
        }
        let sql = """
        SELECT ISNULL(dp.name, N'') AS OwnerName
        FROM sys.schemas AS s
        LEFT JOIN sys.database_principals AS dp ON dp.principal_id = s.principal_id
        WHERE s.name = \(SQLIdentifier.literal(name));
        """
        let owner = try await rows(sql, database: database).first?.string("OwnerName") ?? ""
        var out = "CREATE SCHEMA \(target)"
        if !owner.isEmpty { out += " AUTHORIZATION \(SQLIdentifier.quote(owner))" }
        return out + ";\nGO\n"
    }

    private func databaseUserScript(database: String, name: String,
                                    action: ScriptAction) async throws -> String {
        let target = SQLIdentifier.quote(name)
        if action == .drop {
            return "DROP USER IF EXISTS \(target);\nGO\n"
        }
        let sql = """
        SELECT
            ISNULL(dp.type_desc, N'')                     AS TypeDesc,
            ISNULL(dp.default_schema_name, N'')           AS DefaultSchema,
            ISNULL(dp.authentication_type_desc, N'')      AS AuthenticationType,
            ISNULL(SUSER_SNAME(dp.sid), N'')              AS LoginName
        FROM sys.database_principals AS dp
        WHERE dp.name = \(SQLIdentifier.literal(name));
        """
        guard let row = try await rows(sql, database: database).first else {
            throw SQLServerError.objectNotFound(name)
        }
        let login = row.string("LoginName")
        let authentication = row.string("AuthenticationType").uppercased()

        var clauses: [String] = []
        switch authentication {
        case "NONE":
            // A user without a login: WITHOUT LOGIN, which is how contained-schema owners
            // and impersonation-only users are created.
            clauses.append("WITHOUT LOGIN")
        case "DATABASE":
            clauses.append("PASSWORD = N'<insert a password here>'")
        default:
            if !login.isEmpty { clauses.append("LOGIN = \(SQLIdentifier.quote(login))") }
        }
        let schema = row.string("DefaultSchema")
        if !schema.isEmpty { clauses.append("DEFAULT_SCHEMA = \(SQLIdentifier.quote(schema))") }

        var out = "CREATE USER \(target)"
        if !clauses.isEmpty { out += " WITH " + clauses.joined(separator: ", ") }
        return out + ";\nGO\n"
    }

    private func databaseRoleScript(database: String, name: String, kind: ObjectNodeKind,
                                    action: ScriptAction) async throws -> String {
        let target = SQLIdentifier.quote(name)
        let keyword = kind == .applicationRole ? "APPLICATION ROLE" : "ROLE"
        if action == .drop {
            return "DROP \(keyword) IF EXISTS \(target);\nGO\n"
        }
        if kind == .applicationRole {
            return "CREATE APPLICATION ROLE \(target) "
                + "WITH PASSWORD = N'<insert a password here>';\nGO\n"
        }
        let sql = """
        SELECT ISNULL(owner.name, N'') AS OwnerName
        FROM sys.database_principals AS r
        LEFT JOIN sys.database_principals AS owner ON owner.principal_id = r.owning_principal_id
        WHERE r.name = \(SQLIdentifier.literal(name));
        """
        let owner = try await rows(sql, database: database).first?.string("OwnerName") ?? ""
        var out = "CREATE ROLE \(target)"
        if !owner.isEmpty { out += " AUTHORIZATION \(SQLIdentifier.quote(owner))" }
        out += ";\nGO\n"

        // Members are what makes a role useful, so they are scripted with it.
        let memberSQL = """
        SELECT m.name AS MemberName
        FROM sys.database_role_members AS rm
        JOIN sys.database_principals AS r ON r.principal_id = rm.role_principal_id
        JOIN sys.database_principals AS m ON m.principal_id = rm.member_principal_id
        WHERE r.name = \(SQLIdentifier.literal(name))
        ORDER BY m.name;
        """
        for member in (try? await rows(memberSQL, database: database)) ?? [] {
            let memberName = member.string("MemberName")
            guard !memberName.isEmpty else { continue }
            out += "ALTER ROLE \(target) ADD MEMBER \(SQLIdentifier.quote(memberName));\nGO\n"
        }
        return out
    }

    private func loginScript(name: String, action: ScriptAction) async throws -> String {
        let target = SQLIdentifier.quote(name)
        if action == .drop {
            return "DROP LOGIN \(target);\nGO\n"
        }
        let sql = """
        SELECT
            ISNULL(sp.type_desc, N'')                     AS TypeDesc,
            ISNULL(sp.default_database_name, N'')         AS DefaultDatabase,
            ISNULL(sp.default_language_name, N'')         AS DefaultLanguage,
            CAST(sp.is_disabled AS int)                   AS IsDisabled
        FROM sys.server_principals AS sp
        WHERE sp.name = \(SQLIdentifier.literal(name));
        """
        guard let row = try await rows(sql, database: "master").first else {
            throw SQLServerError.objectNotFound(name)
        }
        let type = row.string("TypeDesc").uppercased()

        var out: String
        if type.hasPrefix("WINDOWS") {
            out = "CREATE LOGIN \(target) FROM WINDOWS"
        } else {
            // The password hash is deliberately not scripted: reading it needs CONTROL
            // SERVER, and copying a hash between instances is rarely what is wanted.
            out = "CREATE LOGIN \(target) WITH PASSWORD = N'<insert a password here>'"
        }
        var clauses: [String] = []
        let defaultDatabase = row.string("DefaultDatabase")
        if !defaultDatabase.isEmpty {
            clauses.append("DEFAULT_DATABASE = \(SQLIdentifier.quote(defaultDatabase))")
        }
        let language = row.string("DefaultLanguage")
        if !language.isEmpty {
            clauses.append("DEFAULT_LANGUAGE = \(SQLIdentifier.quote(language))")
        }
        if !clauses.isEmpty {
            out += type.hasPrefix("WINDOWS") ? " WITH " : ", "
            out += clauses.joined(separator: ", ")
        }
        out += ";\nGO\n"
        if row.bool("IsDisabled") {
            out += "ALTER LOGIN \(target) DISABLE;\nGO\n"
        }
        return out
    }

    // MARK: - Partitioning and XML schemas

    private func partitionFunctionScript(database: String, name: String,
                                         action: ScriptAction) async throws -> String {
        let target = SQLIdentifier.quote(name)
        if action == .drop {
            return "DROP PARTITION FUNCTION \(target);\nGO\n"
        }
        let sql = """
        SELECT
            CAST(pf.boundary_value_on_right AS int)       AS RangeRight,
            t.name                                        AS TypeName,
            CAST(pp.max_length AS int)                    AS MaxLength,
            CAST(pp.precision AS int)                     AS TypePrecision,
            CAST(pp.scale AS int)                         AS TypeScale,
            STUFF((SELECT N', ' + CONVERT(nvarchar(max), rv.value, 121)
                   FROM sys.partition_range_values AS rv
                   WHERE rv.function_id = pf.function_id
                   ORDER BY rv.boundary_id
                   FOR XML PATH(N''), TYPE).value(N'.', N'nvarchar(max)'), 1, 2, N'')
                                                          AS BoundaryValues
        FROM sys.partition_functions AS pf
        JOIN sys.partition_parameters AS pp ON pp.function_id = pf.function_id
        JOIN sys.types AS t ON t.user_type_id = pp.user_type_id
        WHERE pf.name = \(SQLIdentifier.literal(name));
        """
        guard let row = try await rows(sql, database: database).first else {
            throw SQLServerError.objectNotFound(name)
        }
        let typeName = ScriptGenerator.formatType(name: row.string("TypeName"),
                                                  baseName: row.string("TypeName"),
                                                  maxLength: row.int("MaxLength"),
                                                  precision: row.int("TypePrecision"),
                                                  scale: row.int("TypeScale"),
                                                  isUserDefined: false)
        // Boundary values are already rendered as literals by CONVERT; text and date types
        // need quoting, which the type test below applies.
        let needsQuotes = ["char", "varchar", "nchar", "nvarchar", "date", "datetime",
                           "datetime2", "smalldatetime", "datetimeoffset", "time",
                           "uniqueidentifier"]
            .contains { typeName.lowercased().hasPrefix($0) }
        let values = row.string("BoundaryValues")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { needsQuotes ? SQLIdentifier.literal($0) : $0 }
            .joined(separator: ", ")

        return "CREATE PARTITION FUNCTION \(target) (\(typeName))\n"
            + "    AS RANGE \(row.bool("RangeRight") ? "RIGHT" : "LEFT")\n"
            + "    FOR VALUES (\(values));\nGO\n"
    }

    private func partitionSchemeScript(database: String, name: String,
                                       action: ScriptAction) async throws -> String {
        let target = SQLIdentifier.quote(name)
        if action == .drop {
            return "DROP PARTITION SCHEME \(target);\nGO\n"
        }
        let sql = """
        SELECT
            pf.name                                       AS FunctionName,
            STUFF((SELECT N', ' + QUOTENAME(fg.name)
                   FROM sys.destination_data_spaces AS dds
                   JOIN sys.filegroups AS fg ON fg.data_space_id = dds.data_space_id
                   WHERE dds.partition_scheme_id = ps.data_space_id
                   ORDER BY dds.destination_id
                   FOR XML PATH(N''), TYPE).value(N'.', N'nvarchar(max)'), 1, 2, N'')
                                                          AS Filegroups
        FROM sys.partition_schemes AS ps
        JOIN sys.partition_functions AS pf ON pf.function_id = ps.function_id
        WHERE ps.name = \(SQLIdentifier.literal(name));
        """
        guard let row = try await rows(sql, database: database).first else {
            throw SQLServerError.objectNotFound(name)
        }
        let filegroups = row.string("Filegroups")
        return "CREATE PARTITION SCHEME \(target)\n"
            + "    AS PARTITION \(SQLIdentifier.quote(row.string("FunctionName")))\n"
            + "    TO (\(filegroups.isEmpty ? "[PRIMARY]" : filegroups));\nGO\n"
    }

    private func xmlSchemaCollectionScript(database: String, schema: String, name: String,
                                           action: ScriptAction) async throws -> String {
        let target = SQLIdentifier.quote(schema: schema, name: name)
        if action == .drop {
            return "DROP XML SCHEMA COLLECTION \(target);\nGO\n"
        }
        let sql = """
        SELECT CONVERT(nvarchar(max),
                   XML_SCHEMA_NAMESPACE(\(SQLIdentifier.literal(schema)),
                                        \(SQLIdentifier.literal(name)))) AS SchemaText;
        """
        guard let text = try await rows(sql, database: database).first?.string("SchemaText"),
              !text.isEmpty else {
            throw SQLServerError.objectNotFound("\(schema).\(name)")
        }
        return "CREATE XML SCHEMA COLLECTION \(target) AS N'"
            + text.replacingOccurrences(of: "'", with: "''") + "';\nGO\n"
    }

    // MARK: - Shared helpers

    private func rows(_ sql: String, database: String?) async throws -> [[String: TDSValue]] {
        let result = try await session.metadataQuery(sql, database: database)
        if let failure = result.errors.first { throw failure }
        return result.resultSets.first?.dictionaries() ?? []
    }

    private func descriptiveHeader(kind: String, target: String,
                                   options: ScriptOptions) -> String {
        guard options.includeDescriptiveHeader else { return "" }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return "/****** Object:  \(kind) \(target)    "
            + "Script Date: \(formatter.string(from: Date())) ******/\n"
    }
}
