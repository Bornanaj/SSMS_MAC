import Foundation
import TDSKit

// MARK: - Models

public struct ServerLogin: Sendable, Hashable, Identifiable {
    public var id: Int { principalID }
    public var principalID: Int
    public var name: String
    /// SQL_LOGIN, WINDOWS_LOGIN, WINDOWS_GROUP, EXTERNAL_LOGIN, CERTIFICATE_MAPPED_LOGIN
    public var type: String
    public var isDisabled: Bool
    public var defaultDatabase: String
    public var defaultLanguage: String
    public var createDate: String
    public var modifyDate: String
    public var isPolicyChecked: Bool
    public var isExpirationChecked: Bool
    public var serverRoles: [String]

    public var typeLabel: String {
        switch type {
        case "SQL_LOGIN": return "SQL login"
        case "WINDOWS_LOGIN": return "Windows login"
        case "WINDOWS_GROUP": return "Windows group"
        case "EXTERNAL_LOGIN", "EXTERNAL_GROUP": return "Microsoft Entra ID"
        case "CERTIFICATE_MAPPED_LOGIN": return "Certificate"
        case "ASYMMETRIC_KEY_MAPPED_LOGIN": return "Asymmetric key"
        default: return type.capitalized
        }
    }

    public var isSQLLogin: Bool { type == "SQL_LOGIN" }
}

public struct DatabasePrincipal: Sendable, Hashable, Identifiable {
    public var id: Int { principalID }
    public var principalID: Int
    public var name: String
    /// SQL_USER, WINDOWS_USER, DATABASE_ROLE, APPLICATION_ROLE …
    public var type: String
    public var defaultSchema: String
    public var loginName: String
    public var createDate: String
    public var isFixedRole: Bool
    public var roles: [String]

    public var isRole: Bool { type.hasSuffix("ROLE") }

    public var typeLabel: String {
        switch type {
        case "SQL_USER": return "SQL user"
        case "WINDOWS_USER": return "Windows user"
        case "WINDOWS_GROUP": return "Windows group"
        case "DATABASE_ROLE": return "Database role"
        case "APPLICATION_ROLE": return "Application role"
        case "EXTERNAL_USER", "EXTERNAL_GROUP": return "Microsoft Entra ID"
        case "CERTIFICATE_MAPPED_USER": return "Certificate"
        default: return type.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

public struct PermissionEntry: Sendable, Hashable, Identifiable {
    public var id: String
    public var grantee: String
    public var grantor: String
    /// SELECT, INSERT, EXECUTE, CONTROL …
    public var permission: String
    /// GRANT, DENY, GRANT_WITH_GRANT_OPTION, REVOKE
    public var state: String
    /// DATABASE, OBJECT_OR_COLUMN, SCHEMA …
    public var securableClass: String
    public var securableName: String
    public var columnName: String

    public var stateLabel: String {
        switch state {
        case "G": return "Grant"
        case "W": return "Grant with grant"
        case "D": return "Deny"
        case "R": return "Revoke"
        default: return state
        }
    }
}

/// What can be granted, grouped the way the SSMS permissions grid groups it.
public struct GrantablePermission: Sendable, Hashable, Identifiable {
    public var id: String { name }
    public var name: String
    public var appliesTo: String
}

// MARK: - Service

public struct SecurityService: Sendable {
    private let session: SQLServerSession

    public init(session: SQLServerSession) {
        self.session = session
    }

    // MARK: Logins

    public func logins() async throws -> [ServerLogin] {
        let info = await session.serverInfo
        // Azure SQL Database has no sys.server_principals worth reading outside master.
        let scope = info.isAzureSQLDatabase ? "master" : nil
        let sql = """
        SELECT p.principal_id, p.name, p.type_desc,
               CAST(ISNULL(l.is_disabled, 0) AS int) AS is_disabled,
               ISNULL(p.default_database_name, N'') AS default_database_name,
               ISNULL(p.default_language_name, N'') AS default_language_name,
               CONVERT(nvarchar(30), p.create_date, 120) AS create_date,
               CONVERT(nvarchar(30), p.modify_date, 120) AS modify_date,
               CAST(ISNULL(l.is_policy_checked, 0) AS int) AS is_policy_checked,
               CAST(ISNULL(l.is_expiration_checked, 0) AS int) AS is_expiration_checked,
               STUFF((SELECT N', ' + r.name
                      FROM sys.server_role_members AS m
                      JOIN sys.server_principals AS r ON r.principal_id = m.role_principal_id
                      WHERE m.member_principal_id = p.principal_id
                      ORDER BY r.name
                      FOR XML PATH(N''), TYPE).value(N'.', N'nvarchar(max)'), 1, 2, N'')
                 AS server_roles
        FROM sys.server_principals AS p
        LEFT JOIN sys.sql_logins AS l ON l.principal_id = p.principal_id
        WHERE p.type IN ('S', 'U', 'G', 'E', 'X', 'C', 'K')
          AND p.name NOT LIKE '##%'
        ORDER BY p.name
        """
        let result = try await session.metadataQuery(sql, database: scope)
        return (result.resultSets.first?.dictionaries() ?? []).map { row in
            ServerLogin(
                principalID: row.int("principal_id"),
                name: row.string("name"),
                type: row.string("type_desc"),
                isDisabled: row.int("is_disabled") == 1,
                defaultDatabase: row.string("default_database_name"),
                defaultLanguage: row.string("default_language_name"),
                createDate: row.string("create_date"),
                modifyDate: row.string("modify_date"),
                isPolicyChecked: row.int("is_policy_checked") == 1,
                isExpirationChecked: row.int("is_expiration_checked") == 1,
                serverRoles: splitList(row.string("server_roles")))
        }
    }

    public func serverRoles() async throws -> [String] {
        let sql = """
        SELECT name FROM sys.server_principals
        WHERE type = 'R' AND name NOT LIKE '##%'
        ORDER BY CASE WHEN is_fixed_role = 1 THEN 0 ELSE 1 END, name
        """
        let result = try await session.metadataQuery(sql)
        return (result.resultSets.first?.dictionaries() ?? []).map { $0.string("name") }
    }

    public struct LoginDefinition: Sendable {
        public enum Kind: String, Sendable, CaseIterable, Identifiable {
            case sqlLogin
            case windowsLogin
            case entraID
            public var id: String { rawValue }
            public var title: String {
                switch self {
                case .sqlLogin: return "SQL Server authentication"
                case .windowsLogin: return "Windows authentication"
                case .entraID: return "Microsoft Entra ID"
                }
            }
        }

        public var name: String
        public var kind: Kind
        public var password: String
        public var mustChangePassword: Bool
        public var enforcePolicy: Bool
        public var enforceExpiration: Bool
        public var defaultDatabase: String
        public var defaultLanguage: String
        public var isDisabled: Bool
        public var serverRoles: [String]

        public init(name: String = "", kind: Kind = .sqlLogin, password: String = "",
                    mustChangePassword: Bool = false, enforcePolicy: Bool = true,
                    enforceExpiration: Bool = false, defaultDatabase: String = "master",
                    defaultLanguage: String = "", isDisabled: Bool = false,
                    serverRoles: [String] = []) {
            self.name = name
            self.kind = kind
            self.password = password
            self.mustChangePassword = mustChangePassword
            self.enforcePolicy = enforcePolicy
            self.enforceExpiration = enforceExpiration
            self.defaultDatabase = defaultDatabase
            self.defaultLanguage = defaultLanguage
            self.isDisabled = isDisabled
            self.serverRoles = serverRoles
        }
    }

    public func createLoginScript(_ definition: LoginDefinition) throws -> String {
        guard !definition.name.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw SQLServerError.invalidProfile("A login name is required.")
        }
        let quoted = SQLIdentifier.quote(definition.name)
        var lines: [String] = []

        switch definition.kind {
        case .sqlLogin:
            guard !definition.password.isEmpty else {
                throw SQLServerError.invalidProfile("A SQL login needs a password.")
            }
            // The password is a literal, not an identifier: escape the quotes in it.
            var options = ["PASSWORD = \(SQLIdentifier.literal(definition.password))"]
            if definition.mustChangePassword { options[0] += " MUST_CHANGE" }
            options.append("CHECK_POLICY = \(definition.enforcePolicy ? "ON" : "OFF")")
            if definition.enforcePolicy {
                options.append("CHECK_EXPIRATION = \(definition.enforceExpiration ? "ON" : "OFF")")
            }
            if !definition.defaultDatabase.isEmpty {
                options.append("DEFAULT_DATABASE = \(SQLIdentifier.quote(definition.defaultDatabase))")
            }
            if !definition.defaultLanguage.isEmpty {
                options.append("DEFAULT_LANGUAGE = \(SQLIdentifier.quote(definition.defaultLanguage))")
            }
            lines.append("CREATE LOGIN \(quoted) WITH \(options.joined(separator: ", "));")

        case .windowsLogin:
            var options: [String] = []
            if !definition.defaultDatabase.isEmpty {
                options.append("DEFAULT_DATABASE = \(SQLIdentifier.quote(definition.defaultDatabase))")
            }
            let suffix = options.isEmpty ? "" : " WITH \(options.joined(separator: ", "))"
            lines.append("CREATE LOGIN \(quoted) FROM WINDOWS\(suffix);")

        case .entraID:
            lines.append("CREATE LOGIN \(quoted) FROM EXTERNAL PROVIDER;")
        }

        if definition.isDisabled {
            lines.append("ALTER LOGIN \(quoted) DISABLE;")
        }
        for role in definition.serverRoles {
            lines.append("ALTER SERVER ROLE \(SQLIdentifier.quote(role)) ADD MEMBER \(quoted);")
        }
        return lines.joined(separator: "\n")
    }

    public func createLogin(_ definition: LoginDefinition) async throws {
        let script = try createLoginScript(definition)
        try await run(script, database: "master")
    }

    public func dropLoginScript(_ name: String) -> String {
        "DROP LOGIN \(SQLIdentifier.quote(name));"
    }

    public func setLoginEnabled(_ name: String, enabled: Bool) async throws {
        let verb = enabled ? "ENABLE" : "DISABLE"
        try await run("ALTER LOGIN \(SQLIdentifier.quote(name)) \(verb);", database: "master")
    }

    public func changePasswordScript(login: String, newPassword: String,
                                     mustChange: Bool, unlock: Bool) -> String {
        SecurityService.changePasswordScriptStatic(login: login, newPassword: newPassword,
                                                   mustChange: mustChange, unlock: unlock)
    }

    /// Pure string building, so a dialog can produce the script before it has a session.
    public static func changePasswordScriptStatic(login: String, newPassword: String,
                                                  mustChange: Bool, unlock: Bool) -> String {
        var clause = "PASSWORD = \(SQLIdentifier.literal(newPassword))"
        if mustChange { clause += " MUST_CHANGE" }
        if unlock { clause += ", UNLOCK" }
        if mustChange { clause += ", CHECK_POLICY = ON, CHECK_EXPIRATION = ON" }
        return "ALTER LOGIN \(SQLIdentifier.quote(login)) WITH \(clause);"
    }

    public func setServerRoleMembership(login: String, roles: Set<String>,
                                        current: Set<String>) -> String {
        var lines: [String] = []
        let quotedLogin = SQLIdentifier.quote(login)
        for role in roles.subtracting(current).sorted() {
            lines.append("ALTER SERVER ROLE \(SQLIdentifier.quote(role)) ADD MEMBER \(quotedLogin);")
        }
        for role in current.subtracting(roles).sorted() {
            lines.append("ALTER SERVER ROLE \(SQLIdentifier.quote(role)) DROP MEMBER \(quotedLogin);")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Database principals

    public func users(database: String) async throws -> [DatabasePrincipal] {
        let sql = """
        SELECT p.principal_id, p.name, p.type_desc,
               ISNULL(s.name, N'') AS default_schema_name,
               ISNULL(sp.name, N'') AS login_name,
               CONVERT(nvarchar(30), p.create_date, 120) AS create_date,
               CAST(p.is_fixed_role AS int) AS is_fixed_role,
               STUFF((SELECT N', ' + r.name
                      FROM sys.database_role_members AS m
                      JOIN sys.database_principals AS r ON r.principal_id = m.role_principal_id
                      WHERE m.member_principal_id = p.principal_id
                      ORDER BY r.name
                      FOR XML PATH(N''), TYPE).value(N'.', N'nvarchar(max)'), 1, 2, N'')
                 AS roles
        FROM sys.database_principals AS p
        LEFT JOIN sys.schemas AS s ON s.schema_id = p.default_schema_id
        LEFT JOIN sys.server_principals AS sp ON sp.sid = p.sid
        WHERE p.type NOT IN ('R', 'A') AND p.name NOT LIKE '##%'
        ORDER BY p.name
        """
        return try await principals(sql: sql, database: database)
    }

    public func roles(database: String) async throws -> [DatabasePrincipal] {
        let sql = """
        SELECT p.principal_id, p.name, p.type_desc,
               N'' AS default_schema_name, N'' AS login_name,
               CONVERT(nvarchar(30), p.create_date, 120) AS create_date,
               CAST(p.is_fixed_role AS int) AS is_fixed_role,
               STUFF((SELECT N', ' + m2.name
                      FROM sys.database_role_members AS m
                      JOIN sys.database_principals AS m2 ON m2.principal_id = m.member_principal_id
                      WHERE m.role_principal_id = p.principal_id
                      ORDER BY m2.name
                      FOR XML PATH(N''), TYPE).value(N'.', N'nvarchar(max)'), 1, 2, N'')
                 AS roles
        FROM sys.database_principals AS p
        WHERE p.type IN ('R', 'A')
        ORDER BY CASE WHEN p.is_fixed_role = 1 THEN 0 ELSE 1 END, p.name
        """
        return try await principals(sql: sql, database: database)
    }

    private func principals(sql: String, database: String) async throws -> [DatabasePrincipal] {
        let result = try await session.metadataQuery(sql, database: database)
        return (result.resultSets.first?.dictionaries() ?? []).map { row in
            DatabasePrincipal(
                principalID: row.int("principal_id"),
                name: row.string("name"),
                type: row.string("type_desc"),
                defaultSchema: row.string("default_schema_name"),
                loginName: row.string("login_name"),
                createDate: row.string("create_date"),
                isFixedRole: row.int("is_fixed_role") == 1,
                roles: splitList(row.string("roles")))
        }
    }

    public func createUserScript(database: String, name: String, login: String,
                                 defaultSchema: String, roles: [String],
                                 withoutLogin: Bool) throws -> String {
        try SecurityService.createUserScriptStatic(database: database, name: name, login: login,
                                                   defaultSchema: defaultSchema, roles: roles,
                                                   withoutLogin: withoutLogin)
    }

    public static func createUserScriptStatic(database: String, name: String, login: String,
                                              defaultSchema: String, roles: [String],
                                              withoutLogin: Bool) throws -> String {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw SQLServerError.invalidProfile("A user name is required.")
        }
        let quoted = SQLIdentifier.quote(name)
        var clause: String
        if withoutLogin {
            clause = "CREATE USER \(quoted) WITHOUT LOGIN"
        } else if login.isEmpty {
            clause = "CREATE USER \(quoted)"
        } else {
            clause = "CREATE USER \(quoted) FOR LOGIN \(SQLIdentifier.quote(login))"
        }
        if !defaultSchema.isEmpty {
            clause += " WITH DEFAULT_SCHEMA = \(SQLIdentifier.quote(defaultSchema))"
        }
        var lines = ["USE \(SQLIdentifier.quote(database));", clause + ";"]
        for role in roles {
            lines.append("ALTER ROLE \(SQLIdentifier.quote(role)) ADD MEMBER \(quoted);")
        }
        return lines.joined(separator: "\n")
    }

    public func dropUserScript(database: String, name: String) -> String {
        "USE \(SQLIdentifier.quote(database));\nDROP USER \(SQLIdentifier.quote(name));"
    }

    public func createRoleScript(database: String, name: String, owner: String) -> String {
        var clause = "CREATE ROLE \(SQLIdentifier.quote(name))"
        if !owner.isEmpty { clause += " AUTHORIZATION \(SQLIdentifier.quote(owner))" }
        return "USE \(SQLIdentifier.quote(database));\n\(clause);"
    }

    public func setDatabaseRoleMembership(database: String, member: String,
                                          roles: Set<String>, current: Set<String>) -> String {
        var lines = ["USE \(SQLIdentifier.quote(database));"]
        let quotedMember = SQLIdentifier.quote(member)
        for role in roles.subtracting(current).sorted() {
            lines.append("ALTER ROLE \(SQLIdentifier.quote(role)) ADD MEMBER \(quotedMember);")
        }
        for role in current.subtracting(roles).sorted() {
            lines.append("ALTER ROLE \(SQLIdentifier.quote(role)) DROP MEMBER \(quotedMember);")
        }
        return lines.count > 1 ? lines.joined(separator: "\n") : ""
    }

    // MARK: Permissions

    public func permissions(database: String, principal: String) async throws -> [PermissionEntry] {
        let sql = """
        SELECT dp.name AS grantee, ISNULL(gp.name, N'') AS grantor,
               perm.permission_name, perm.state,
               perm.class_desc,
               ISNULL(CASE perm.class
                        WHEN 0 THEN DB_NAME()
                        WHEN 1 THEN SCHEMA_NAME(o.schema_id) + N'.' + o.name
                        WHEN 3 THEN s.name
                        ELSE CAST(perm.major_id AS nvarchar(20))
                      END, N'') AS securable,
               ISNULL(c.name, N'') AS column_name
        FROM sys.database_permissions AS perm
        JOIN sys.database_principals AS dp ON dp.principal_id = perm.grantee_principal_id
        LEFT JOIN sys.database_principals AS gp ON gp.principal_id = perm.grantor_principal_id
        LEFT JOIN sys.objects AS o ON o.object_id = perm.major_id AND perm.class = 1
        LEFT JOIN sys.schemas AS s ON s.schema_id = perm.major_id AND perm.class = 3
        LEFT JOIN sys.columns AS c ON c.object_id = perm.major_id
             AND c.column_id = perm.minor_id AND perm.minor_id > 0
        WHERE dp.name = @principal
        ORDER BY securable, perm.permission_name
        """
        let bound = sql.replacingOccurrences(of: "@principal",
                                             with: SQLIdentifier.literal(principal))
        let result = try await session.metadataQuery(bound, database: database)
        return (result.resultSets.first?.dictionaries() ?? []).enumerated().map { index, row in
            PermissionEntry(
                id: "\(index)",
                grantee: row.string("grantee"),
                grantor: row.string("grantor"),
                permission: row.string("permission_name"),
                state: row.string("state"),
                securableClass: row.string("class_desc"),
                securableName: row.string("securable"),
                columnName: row.string("column_name"))
        }
    }

    /// Permissions on one object, whoever holds them.
    public func permissions(database: String, schema: String,
                            object: String) async throws -> [PermissionEntry] {
        let sql = """
        SELECT dp.name AS grantee, ISNULL(gp.name, N'') AS grantor,
               perm.permission_name, perm.state, perm.class_desc,
               SCHEMA_NAME(o.schema_id) + N'.' + o.name AS securable,
               ISNULL(c.name, N'') AS column_name
        FROM sys.database_permissions AS perm
        JOIN sys.objects AS o ON o.object_id = perm.major_id AND perm.class = 1
        JOIN sys.database_principals AS dp ON dp.principal_id = perm.grantee_principal_id
        LEFT JOIN sys.database_principals AS gp ON gp.principal_id = perm.grantor_principal_id
        LEFT JOIN sys.columns AS c ON c.object_id = perm.major_id
             AND c.column_id = perm.minor_id AND perm.minor_id > 0
        WHERE o.name = @object AND SCHEMA_NAME(o.schema_id) = @schema
        ORDER BY dp.name, perm.permission_name
        """
        let bound = sql
            .replacingOccurrences(of: "@object", with: SQLIdentifier.literal(object))
            .replacingOccurrences(of: "@schema", with: SQLIdentifier.literal(schema))
        let result = try await session.metadataQuery(bound, database: database)
        return (result.resultSets.first?.dictionaries() ?? []).enumerated().map { index, row in
            PermissionEntry(
                id: "\(index)",
                grantee: row.string("grantee"),
                grantor: row.string("grantor"),
                permission: row.string("permission_name"),
                state: row.string("state"),
                securableClass: row.string("class_desc"),
                securableName: row.string("securable"),
                columnName: row.string("column_name"))
        }
    }

    public enum PermissionAction: String, Sendable, CaseIterable, Identifiable {
        case grant = "GRANT"
        case deny = "DENY"
        case revoke = "REVOKE"
        public var id: String { rawValue }
    }

    public func permissionScript(database: String, action: PermissionAction,
                                 permissions: [String], securable: String?,
                                 principal: String, withGrantOption: Bool) -> String {
        guard !permissions.isEmpty, !principal.isEmpty else { return "" }
        let list = permissions.joined(separator: ", ")
        let target = securable.map { " ON \($0)" } ?? ""
        let preposition = action == .revoke ? "FROM" : "TO"
        var statement = "\(action.rawValue) \(list)\(target) \(preposition) "
            + SQLIdentifier.quote(principal)
        if action == .grant && withGrantOption { statement += " WITH GRANT OPTION" }
        return "USE \(SQLIdentifier.quote(database));\n\(statement);"
    }

    /// The permission names SSMS offers for a securable class.
    public static func grantablePermissions(for securableClass: String) -> [GrantablePermission] {
        let object = ["SELECT", "INSERT", "UPDATE", "DELETE", "EXECUTE", "REFERENCES",
                      "VIEW DEFINITION", "ALTER", "CONTROL", "TAKE OWNERSHIP"]
        let schema = object + ["CREATE SEQUENCE"]
        let database = ["BACKUP DATABASE", "BACKUP LOG", "CONNECT", "CONNECT REPLICATION",
                        "CREATE FUNCTION", "CREATE PROCEDURE", "CREATE SCHEMA", "CREATE TABLE",
                        "CREATE VIEW", "DELETE", "EXECUTE", "INSERT", "SELECT", "UPDATE",
                        "REFERENCES", "SHOWPLAN", "VIEW DATABASE STATE", "VIEW DEFINITION",
                        "ALTER", "ALTER ANY SCHEMA", "ALTER ANY USER", "ALTER ANY ROLE",
                        "CONTROL", "TAKE OWNERSHIP"]
        let names: [String]
        switch securableClass.uppercased() {
        case "SCHEMA": names = schema
        case "DATABASE": names = database
        default: names = object
        }
        return names.map { GrantablePermission(name: $0, appliesTo: securableClass) }
    }

    /// What a principal can actually do, resolving role membership.
    public func effectivePermissions(database: String, principal: String) async throws -> [String] {
        let sql = """
        EXECUTE AS USER = @principal;
        SELECT DISTINCT permission_name, ISNULL(subentity_name, N'') AS subentity
        FROM fn_my_permissions(NULL, 'DATABASE')
        ORDER BY permission_name;
        REVERT;
        """
        let bound = sql.replacingOccurrences(of: "@principal",
                                             with: SQLIdentifier.literal(principal))
        let result = try await session.metadataQuery(bound, database: database)
        return (result.resultSets.first?.dictionaries() ?? []).map { $0.string("permission_name") }
    }

    // MARK: Helpers

    private func run(_ script: String, database: String?) async throws {
        let connection = try await session.openConnection(database: database)
        defer { Task { try? await connection.close() } }
        _ = try await connection.query(script)
    }

    /// Runs a script the caller has already reviewed, in the given database.
    public func execute(_ script: String, database: String?) async throws {
        try await run(script, database: database)
    }

    private func splitList(_ value: String) -> [String] {
        value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
