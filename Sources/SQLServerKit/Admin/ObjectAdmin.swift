import Foundation
import TDSKit

// MARK: - New database

/// The New Database dialog, reduced to the fields that change the generated DDL.
public struct NewDatabaseOptions: Sendable, Hashable {
    public var name: String
    /// Empty means "leave the creating login as the owner".
    public var owner: String
    /// Empty means "inherit the server collation".
    public var collation: String
    /// FULL, SIMPLE or BULK_LOGGED. Empty means "inherit from model".
    public var recoveryModel: String
    /// Zero means "inherit from model".
    public var compatibilityLevel: Int

    public var dataFileName: String
    public var dataFilePath: String
    public var dataFileSizeMB: Int
    /// Zero means "no autogrowth".
    public var dataFileGrowthMB: Int
    /// Zero means unlimited.
    public var dataFileMaxSizeMB: Int

    public var logFileName: String
    public var logFilePath: String
    public var logFileSizeMB: Int
    public var logFileGrowthMB: Int
    public var logFileMaxSizeMB: Int

    public init(name: String = "",
                owner: String = "",
                collation: String = "",
                recoveryModel: String = "",
                compatibilityLevel: Int = 0,
                dataFileName: String = "",
                dataFilePath: String = "",
                dataFileSizeMB: Int = 8,
                dataFileGrowthMB: Int = 64,
                dataFileMaxSizeMB: Int = 0,
                logFileName: String = "",
                logFilePath: String = "",
                logFileSizeMB: Int = 8,
                logFileGrowthMB: Int = 64,
                logFileMaxSizeMB: Int = 0) {
        self.name = name
        self.owner = owner
        self.collation = collation
        self.recoveryModel = recoveryModel
        self.compatibilityLevel = compatibilityLevel
        self.dataFileName = dataFileName
        self.dataFilePath = dataFilePath
        self.dataFileSizeMB = dataFileSizeMB
        self.dataFileGrowthMB = dataFileGrowthMB
        self.dataFileMaxSizeMB = dataFileMaxSizeMB
        self.logFileName = logFileName
        self.logFilePath = logFilePath
        self.logFileSizeMB = logFileSizeMB
        self.logFileGrowthMB = logFileGrowthMB
        self.logFileMaxSizeMB = logFileMaxSizeMB
    }

    /// SSMS names the files after the database: `Sales` and `Sales_log`.
    public var effectiveDataFileName: String {
        dataFileName.isEmpty ? name : dataFileName
    }

    public var effectiveLogFileName: String {
        logFileName.isEmpty ? name + "_log" : logFileName
    }
}

// MARK: - Detach and attach

public struct AttachFile: Sendable, Hashable, Identifiable {
    public var id: String { path }
    public var path: String

    public init(path: String) { self.path = path }
}

// MARK: - Dependencies

public enum DependencyDirection: String, Sendable, CaseIterable, Identifiable {
    /// Objects the selected object uses.
    case dependsOn
    /// Objects that use the selected object.
    case usedBy

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .dependsOn: return "Objects that this object depends on"
        case .usedBy: return "Objects that depend on this object"
        }
    }
}

/// One row of the View Dependencies dialog.
public struct ObjectDependency: Sendable, Hashable, Identifiable {
    public var id: String { "\(schema).\(name).\(dependencyType)" }

    public var schema: String
    public var name: String
    /// `sys.objects.type`, e.g. "U", "V", "P".
    public var dependencyType: String
    public var typeDescription: String
    /// A dependency SQL Server could not resolve — a reference to a dropped object.
    public var isUnresolved: Bool
    /// Set when the dependency is on a specific column.
    public var columnName: String

    public init(schema: String = "",
                name: String = "",
                dependencyType: String = "",
                typeDescription: String = "",
                isUnresolved: Bool = false,
                columnName: String = "") {
        self.schema = schema
        self.name = name
        self.dependencyType = dependencyType
        self.typeDescription = typeDescription
        self.isUnresolved = isUnresolved
        self.columnName = columnName
    }

    public var qualifiedName: String {
        schema.isEmpty ? name : "\(schema).\(name)"
    }

    /// The node kind the Object Explorer would give this dependency, so the dialog can
    /// show the same icon the tree does.
    public var nodeKind: ObjectNodeKind {
        switch dependencyType.trimmingCharacters(in: .whitespaces).uppercased() {
        case "U": return .table
        case "V": return .view
        case "P", "PC", "X": return .storedProcedure
        case "FN", "FS": return .scalarFunction
        case "IF", "TF", "FT": return .tableValuedFunction
        case "AF": return .aggregateFunction
        case "TR", "TA": return .trigger
        case "SN": return .synonym
        case "SO": return .sequence
        default: return .unknown
        }
    }
}

// MARK: - Permissions

public enum PermissionAction: String, Sendable, CaseIterable, Identifiable {
    case grant = "GRANT"
    case deny = "DENY"
    case revoke = "REVOKE"

    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
}

/// What a permission applies to. Each case knows how to write its own `ON` clause.
public enum PermissionTarget: Sendable, Hashable {
    case server
    case database
    case schema(String)
    case object(schema: String, name: String)

    /// The `ON <class>::<name>` fragment, or an empty string for a server or database
    /// permission where SQL Server takes the current scope.
    public var onClause: String {
        switch self {
        case .server, .database:
            return ""
        case .schema(let name):
            return " ON SCHEMA::\(SQLIdentifier.quote(name))"
        case .object(let schema, let name):
            return " ON OBJECT::\(SQLIdentifier.quote(schema: schema, name: name))"
        }
    }

    public var describedScope: String {
        switch self {
        case .server: return "the server"
        case .database: return "the database"
        case .schema(let name): return "schema \(name)"
        case .object(let schema, let name): return "\(schema).\(name)"
        }
    }
}

/// One row of the Permissions page.
public struct PermissionEntry: Sendable, Hashable, Identifiable {
    public var id: String { "\(principal)/\(permission)/\(columnName)" }

    public var principal: String
    /// `sys.database_principals.type_desc`, humanised.
    public var principalType: String
    public var permission: String
    /// GRANT, DENY or GRANT_WITH_GRANT_OPTION.
    public var state: String
    public var columnName: String
    public var grantor: String

    public init(principal: String = "",
                principalType: String = "",
                permission: String = "",
                state: String = "",
                columnName: String = "",
                grantor: String = "") {
        self.principal = principal
        self.principalType = principalType
        self.permission = permission
        self.state = state
        self.columnName = columnName
        self.grantor = grantor
    }

    public var isDenied: Bool { state == "DENY" }
    public var allowsGranting: Bool { state == "GRANT_WITH_GRANT_OPTION" }
}

// MARK: - Object administration

/// The object-level operations behind SSMS's context menus: rename, delete, create a
/// database, detach and attach, shrink a file, view dependencies and edit permissions.
public struct ObjectAdmin: Sendable {

    private let runner: AdminRunner

    public init(session: SQLServerSession) {
        self.runner = AdminRunner(session: session)
    }

    // MARK: Rename

    /// The `objtype` argument `sp_rename` needs for a given tree node.
    ///
    /// A database is deliberately absent: `sp_rename` cannot rename one, and
    /// `renameScript(node:to:)` emits `ALTER DATABASE … MODIFY NAME` for it instead.
    public static func renameObjectType(for kind: ObjectNodeKind) -> String? {
        switch kind {
        case .table, .view, .storedProcedure, .scalarFunction, .tableValuedFunction,
             .aggregateFunction, .synonym, .sequence, .userDefinedDataType,
             .userDefinedTableType, .externalTable:
            return "OBJECT"
        case .column:
            return "COLUMN"
        case .index, .primaryKey, .uniqueKey:
            return "INDEX"
        case .statistic:
            return "STATISTICS"
        case .databaseUser, .databaseRole, .applicationRole:
            return "USER"
        default:
            return nil
        }
    }

    /// Whether the Rename dialog can do anything with this node.
    public static func canRename(_ kind: ObjectNodeKind) -> Bool {
        kind == .database || renameObjectType(for: kind) != nil
    }

    /// `ALTER DATABASE` renames a database; `sp_rename` refuses to.
    public static func renameDatabaseScript(from oldName: String,
                                            to newName: String) throws -> String {
        let trimmed = try validatedNewName(newName)
        return "ALTER DATABASE \(SQLIdentifier.quote(oldName)) "
            + "MODIFY NAME = \(SQLIdentifier.quote(trimmed));"
    }

    private static func validatedNewName(_ newName: String) throws -> String {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SQLServerError.unsupportedOperation("A new name is required.")
        }
        guard !trimmed.contains(".") else {
            throw SQLServerError.unsupportedOperation(
                "A rename takes an unqualified new name; drop the schema prefix.")
        }
        guard trimmed.count <= 128 else {
            throw SQLServerError.unsupportedOperation("Identifiers are limited to 128 characters.")
        }
        return trimmed
    }

    /// `sp_rename` takes its target as a string, so the old name has to be assembled and
    /// escaped rather than interpolated. The new name is a bare identifier — SQL Server
    /// rejects a qualified one.
    public static func renameScript(objectType: String,
                                    schema: String?,
                                    parent: String?,
                                    currentName: String,
                                    newName: String) throws -> String {
        let trimmed = try validatedNewName(newName)

        var parts: [String] = []
        if let schema, !schema.isEmpty { parts.append(SQLIdentifier.quote(schema)) }
        if let parent, !parent.isEmpty { parts.append(SQLIdentifier.quote(parent)) }
        parts.append(SQLIdentifier.quote(currentName))
        let target = parts.joined(separator: ".")

        return "EXEC sys.sp_rename \(SQLIdentifier.literal(target)), "
            + "\(SQLIdentifier.literal(trimmed)), \(SQLIdentifier.literal(objectType));"
    }

    /// The statement the Rename dialog runs and scripts, for any renameable node.
    public static func renameScript(node: ObjectExplorerNode, to newName: String) throws -> String {
        if node.kind == .database {
            return try renameDatabaseScript(from: node.name ?? node.label, to: newName)
        }
        guard let objectType = ObjectAdmin.renameObjectType(for: node.kind) else {
            throw SQLServerError.unsupportedOperation(
                "Renaming is not supported for this object type.")
        }
        // A column, index or statistic is renamed relative to its table; everything else
        // is renamed relative to its schema.
        let needsParent = objectType == "COLUMN" || objectType == "INDEX"
            || objectType == "STATISTICS"
        return try renameScript(objectType: objectType,
                                schema: objectType == "USER" ? nil : node.schema,
                                parent: needsParent ? node.info["parentTable"] : nil,
                                currentName: node.name ?? node.label,
                                newName: newName)
    }

    public func rename(node: ObjectExplorerNode, to newName: String) async throws {
        let script = try ObjectAdmin.renameScript(node: node, to: newName)
        // Renaming a database has to run from outside it.
        try await runner.run(script, database: node.kind == .database ? "master" : node.database)
    }

    // MARK: Delete

    /// The `DROP` keyword for a node, or nil when the object cannot be dropped on its own.
    public static func dropKeyword(for kind: ObjectNodeKind) -> String? {
        switch kind {
        case .database: return "DATABASE"
        case .table, .externalTable: return "TABLE"
        case .view: return "VIEW"
        case .storedProcedure: return "PROCEDURE"
        case .scalarFunction, .tableValuedFunction, .aggregateFunction: return "FUNCTION"
        case .trigger: return "TRIGGER"
        case .synonym: return "SYNONYM"
        case .sequence: return "SEQUENCE"
        case .schema: return "SCHEMA"
        case .databaseUser: return "USER"
        case .databaseRole: return "ROLE"
        case .login: return "LOGIN"
        case .serverRole: return "SERVER ROLE"
        case .userDefinedDataType, .userDefinedTableType: return "TYPE"
        case .assembly: return "ASSEMBLY"
        case .xmlSchemaCollection: return "XML SCHEMA COLLECTION"
        case .partitionScheme: return "PARTITION SCHEME"
        case .partitionFunction: return "PARTITION FUNCTION"
        case .index: return "INDEX"
        case .statistic: return "STATISTICS"
        default: return nil
        }
    }

    /// The DDL behind Delete. Constraints and keys are dropped through their table, and a
    /// database is put into single user mode first, exactly as SSMS scripts it.
    public static func dropScript(node: ObjectExplorerNode) throws -> String {
        let name = node.name ?? node.label

        switch node.kind {
        case .primaryKey, .uniqueKey, .foreignKey, .checkConstraint, .defaultConstraint:
            guard let schema = node.schema, let table = node.info["parentTable"], !table.isEmpty else {
                throw SQLServerError.unsupportedOperation(
                    "The parent table of \(name) is unknown, so it cannot be dropped.")
            }
            return "ALTER TABLE \(SQLIdentifier.quote(schema: schema, name: table))\n"
                + "    DROP CONSTRAINT \(SQLIdentifier.quote(name));"

        case .index, .statistic:
            guard let schema = node.schema, let table = node.info["parentTable"], !table.isEmpty else {
                throw SQLServerError.unsupportedOperation(
                    "The parent table of \(name) is unknown, so it cannot be dropped.")
            }
            let keyword = node.kind == .index ? "DROP INDEX" : "DROP STATISTICS"
            return "\(keyword) \(SQLIdentifier.quote(name)) "
                + "ON \(SQLIdentifier.quote(schema: schema, name: table));"

        case .database:
            return "ALTER DATABASE \(SQLIdentifier.quote(name)) "
                + "SET SINGLE_USER WITH ROLLBACK IMMEDIATE;\nGO\n"
                + "DROP DATABASE \(SQLIdentifier.quote(name));"

        default:
            guard let keyword = ObjectAdmin.dropKeyword(for: node.kind) else {
                throw SQLServerError.unsupportedOperation(
                    "Deleting is not supported for this object type.")
            }
            let target = node.schema.map { SQLIdentifier.quote(schema: $0, name: name) }
                ?? SQLIdentifier.quote(name)
            return "DROP \(keyword) \(target);"
        }
    }

    public func drop(node: ObjectExplorerNode) async throws {
        let script = try ObjectAdmin.dropScript(node: node)
        // Dropping a database has to run from master, and its two statements are split by
        // GO, which only the client understands.
        if node.kind == .database {
            for statement in BatchSplitter.split(script) {
                let text = statement.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                try await runner.run(text, database: "master")
            }
            return
        }
        try await runner.run(script, database: node.database)
    }

    // MARK: Create database

    /// The CREATE DATABASE statement SSMS generates from the New Database dialog.
    public static func createDatabaseScript(_ options: NewDatabaseOptions) throws -> String {
        let name = options.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw SQLServerError.unsupportedOperation("A database name is required.")
        }
        guard name.count <= 128 else {
            throw SQLServerError.unsupportedOperation("Identifiers are limited to 128 characters.")
        }
        if !options.collation.isEmpty, !ObjectAdmin.isSafeCollation(options.collation) {
            throw SQLServerError.unsupportedOperation(
                "'\(options.collation)' is not a valid collation name.")
        }

        let quoted = SQLIdentifier.quote(name)
        var out = "CREATE DATABASE \(quoted)"

        // Only emit the ON/LOG ON clauses when the dialog was given a path; without one
        // SQL Server picks the instance defaults, which is what most people want.
        if !options.dataFilePath.isEmpty {
            out += "\n ON PRIMARY\n( " + fileClause(
                logicalName: options.effectiveDataFileName,
                path: options.dataFilePath,
                sizeMB: options.dataFileSizeMB,
                maxSizeMB: options.dataFileMaxSizeMB,
                growthMB: options.dataFileGrowthMB) + " )"
        }
        if !options.logFilePath.isEmpty {
            out += "\n LOG ON\n( " + fileClause(
                logicalName: options.effectiveLogFileName,
                path: options.logFilePath,
                sizeMB: options.logFileSizeMB,
                maxSizeMB: options.logFileMaxSizeMB,
                growthMB: options.logFileGrowthMB) + " )"
        }
        if !options.collation.isEmpty {
            out += "\n COLLATE \(options.collation)"
        }
        out += ";\nGO\n"

        if options.compatibilityLevel > 0 {
            out += "ALTER DATABASE \(quoted) SET COMPATIBILITY_LEVEL = "
                + "\(options.compatibilityLevel);\nGO\n"
        }
        if !options.recoveryModel.isEmpty {
            let model = options.recoveryModel.uppercased().replacingOccurrences(of: " ", with: "_")
            guard ["FULL", "SIMPLE", "BULK_LOGGED"].contains(model) else {
                throw SQLServerError.unsupportedOperation(
                    "Unknown recovery model '\(options.recoveryModel)'.")
            }
            out += "ALTER DATABASE \(quoted) SET RECOVERY \(model);\nGO\n"
        }
        if !options.owner.isEmpty {
            out += "ALTER AUTHORIZATION ON DATABASE::\(quoted) "
                + "TO \(SQLIdentifier.quote(options.owner));\nGO\n"
        }
        return out
    }

    private static func fileClause(logicalName: String,
                                   path: String,
                                   sizeMB: Int,
                                   maxSizeMB: Int,
                                   growthMB: Int) -> String {
        var parts = ["NAME = \(SQLIdentifier.quote(logicalName))",
                     "FILENAME = \(SQLIdentifier.literal(path))"]
        if sizeMB > 0 { parts.append("SIZE = \(sizeMB)MB") }
        parts.append(maxSizeMB > 0 ? "MAXSIZE = \(maxSizeMB)MB" : "MAXSIZE = UNLIMITED")
        parts.append(growthMB > 0 ? "FILEGROWTH = \(growthMB)MB" : "FILEGROWTH = 0")
        return parts.joined(separator: ",\n  ")
    }

    /// A collation name is an identifier SQL Server will not accept as a parameter, so it
    /// has to be validated rather than escaped.
    static func isSafeCollation(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 128
            && name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    public func createDatabase(_ options: NewDatabaseOptions) async throws {
        try await runner.requireBoxProduct("Creating a database from this dialog")
        let script = try ObjectAdmin.createDatabaseScript(options)
        for batch in BatchSplitter.split(script) {
            let text = batch.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            try await runner.run(text, database: "master")
        }
    }

    public func collations() async throws -> [String] {
        let rows = try await runner.read(
            "SELECT name FROM sys.fn_helpcollations() ORDER BY name;", database: "master")
        return rows.map { $0.string("name") }.filter { !$0.isEmpty }
    }

    // MARK: Detach and attach

    /// SSMS drops connections by switching to single user mode first, then detaches.
    public static func detachScript(database: String,
                                    dropConnections: Bool,
                                    updateStatistics: Bool) -> String {
        var out = ""
        if dropConnections {
            out += "ALTER DATABASE \(SQLIdentifier.quote(database)) "
                + "SET SINGLE_USER WITH ROLLBACK IMMEDIATE;\nGO\n"
        }
        out += "EXEC master.dbo.sp_detach_db @dbname = \(SQLIdentifier.literal(database)), "
            + "@skipchecks = \(updateStatistics ? "'false'" : "'true'");\nGO\n"
        return out
    }

    public func detach(database: String,
                       dropConnections: Bool = true,
                       updateStatistics: Bool = false) async throws {
        try await runner.requireBoxProduct("Detaching a database")
        for batch in BatchSplitter.split(ObjectAdmin.detachScript(database: database,
                                                                  dropConnections: dropConnections,
                                                                  updateStatistics: updateStatistics)) {
            let text = batch.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            try await runner.run(text, database: "master")
        }
    }

    public static func attachScript(database: String, files: [AttachFile]) throws -> String {
        let name = database.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw SQLServerError.unsupportedOperation("A database name is required.")
        }
        let paths = files.map(\.path).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !paths.isEmpty else {
            throw SQLServerError.unsupportedOperation("Attaching needs at least the .mdf file.")
        }
        let clauses = paths
            .map { "( FILENAME = \(SQLIdentifier.literal($0)) )" }
            .joined(separator: ",\n    ")
        return "CREATE DATABASE \(SQLIdentifier.quote(name))\n    ON \(clauses)\n    FOR ATTACH;"
    }

    public func attach(database: String, files: [AttachFile]) async throws {
        try await runner.requireBoxProduct("Attaching a database")
        try await runner.run(ObjectAdmin.attachScript(database: database, files: files),
                             database: "master")
    }

    // MARK: Shrink

    public enum ShrinkMode: String, Sendable, CaseIterable, Identifiable {
        /// Release unused space, reorganising pages first.
        case reorganize
        /// Release only the space past the last allocated extent.
        case truncateOnly
        /// Move everything out so the file can be removed from its filegroup.
        case emptyFile

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .reorganize: return "Release unused space, reorganising pages"
            case .truncateOnly: return "Release unused space only"
            case .emptyFile: return "Empty file by migrating data to other files"
            }
        }
    }

    public static func shrinkFileScript(logicalName: String,
                                        targetMB: Int,
                                        mode: ShrinkMode) -> String {
        let target = SQLIdentifier.literal(logicalName)
        switch mode {
        case .truncateOnly:
            return "DBCC SHRINKFILE (\(target), TRUNCATEONLY);"
        case .emptyFile:
            return "DBCC SHRINKFILE (\(target), EMPTYFILE);"
        case .reorganize:
            return "DBCC SHRINKFILE (\(target), \(max(0, targetMB)));"
        }
    }

    /// DBCC prints its result as info tokens, so the caller gets the text back.
    public func shrinkFile(database: String,
                           logicalName: String,
                           targetMB: Int,
                           mode: ShrinkMode) async throws -> [String] {
        let script = ObjectAdmin.shrinkFileScript(logicalName: logicalName,
                                                  targetMB: targetMB, mode: mode)
        let lines = try await runner.runCollectingMessages(script, database: database)
        return lines.isEmpty ? ["DBCC SHRINKFILE completed for '\(logicalName)'."] : lines
    }

    // MARK: Dependencies

    public func dependencies(database: String,
                             schema: String,
                             name: String,
                             direction: DependencyDirection) async throws -> [ObjectDependency] {
        let target = SQLIdentifier.literal("\(SQLIdentifier.quote(schema)).\(SQLIdentifier.quote(name))")

        // sys.sql_expression_dependencies covers module bodies; sys.foreign_keys covers
        // the referential dependencies a module never mentions. Both sides are unioned so
        // the dialog matches what SSMS shows.
        let sql: String
        switch direction {
        case .dependsOn:
            sql = """
            SELECT DISTINCT
                ISNULL(d.referenced_schema_name, ISNULL(s.name, N''))     AS SchemaName,
                ISNULL(o.name, d.referenced_entity_name)                  AS ObjectName,
                ISNULL(o.type, N'')                                       AS ObjectType,
                ISNULL(o.type_desc, N'')                                  AS TypeDesc,
                CAST(CASE WHEN o.object_id IS NULL THEN 1 ELSE 0 END AS int) AS IsUnresolved,
                ISNULL(c.name, N'')                                       AS ColumnName
            FROM sys.sql_expression_dependencies AS d
            LEFT JOIN sys.objects AS o ON o.object_id = d.referenced_id
            LEFT JOIN sys.schemas AS s ON s.schema_id = o.schema_id
            LEFT JOIN sys.columns AS c ON c.object_id = d.referenced_id
                 AND c.column_id = d.referenced_minor_id AND d.referenced_minor_id > 0
            WHERE d.referencing_id = OBJECT_ID(\(target))

            UNION

            SELECT DISTINCT
                rs.name, rt.name, rt.type, rt.type_desc, 0, N''
            FROM sys.foreign_keys AS fk
            JOIN sys.objects AS rt ON rt.object_id = fk.referenced_object_id
            JOIN sys.schemas AS rs ON rs.schema_id = rt.schema_id
            WHERE fk.parent_object_id = OBJECT_ID(\(target))

            ORDER BY SchemaName, ObjectName;
            """
        case .usedBy:
            sql = """
            SELECT DISTINCT
                ISNULL(s.name, N'')                                       AS SchemaName,
                ISNULL(o.name, N'')                                       AS ObjectName,
                ISNULL(o.type, N'')                                       AS ObjectType,
                ISNULL(o.type_desc, N'')                                  AS TypeDesc,
                0                                                         AS IsUnresolved,
                N''                                                       AS ColumnName
            FROM sys.sql_expression_dependencies AS d
            JOIN sys.objects AS o ON o.object_id = d.referencing_id
            JOIN sys.schemas AS s ON s.schema_id = o.schema_id
            WHERE d.referenced_id = OBJECT_ID(\(target))

            UNION

            SELECT DISTINCT
                ps.name, pt.name, pt.type, pt.type_desc, 0, N''
            FROM sys.foreign_keys AS fk
            JOIN sys.objects AS pt ON pt.object_id = fk.parent_object_id
            JOIN sys.schemas AS ps ON ps.schema_id = pt.schema_id
            WHERE fk.referenced_object_id = OBJECT_ID(\(target))

            ORDER BY SchemaName, ObjectName;
            """
        }

        return try await runner.read(sql, database: database).map { row in
            ObjectDependency(
                schema: row.string("SchemaName"),
                name: row.string("ObjectName"),
                dependencyType: row.string("ObjectType"),
                typeDescription: row.string("TypeDesc"),
                isUnresolved: row.bool("IsUnresolved"),
                columnName: row.string("ColumnName")
            )
        }
        .filter { !$0.name.isEmpty && !($0.schema == schema && $0.name == name) }
    }

    // MARK: Permissions

    public func permissions(database: String,
                            target: PermissionTarget) async throws -> [PermissionEntry] {
        if case .server = target {
            return try await serverPermissions()
        }

        let filter: String
        switch target {
        case .database:
            filter = "p.class = 0"
        case .schema(let name):
            filter = "p.class = 3 AND p.major_id = SCHEMA_ID(\(SQLIdentifier.literal(name)))"
        case .object(let schema, let name):
            let object = SQLIdentifier.literal(
                "\(SQLIdentifier.quote(schema)).\(SQLIdentifier.quote(name))")
            filter = "p.class = 1 AND p.major_id = OBJECT_ID(\(object))"
        case .server:
            filter = "1 = 0"
        }

        let sql = """
        SELECT
            dp.name                                        AS PrincipalName,
            ISNULL(dp.type_desc, N'')                      AS PrincipalType,
            p.permission_name                              AS PermissionName,
            p.state_desc                                   AS StateDesc,
            ISNULL(c.name, N'')                            AS ColumnName,
            ISNULL(gp.name, N'')                           AS GrantorName
        FROM sys.database_permissions AS p
        JOIN sys.database_principals AS dp ON dp.principal_id = p.grantee_principal_id
        LEFT JOIN sys.database_principals AS gp ON gp.principal_id = p.grantor_principal_id
        LEFT JOIN sys.columns AS c ON c.object_id = p.major_id
             AND c.column_id = p.minor_id AND p.minor_id > 0
        WHERE \(filter)
        ORDER BY dp.name, p.permission_name;
        """
        return try await runner.read(sql, database: database).map(Self.entry(from:))
    }

    private func serverPermissions() async throws -> [PermissionEntry] {
        try await runner.requireBoxProduct("Server level permissions")
        let sql = """
        SELECT
            sp.name                                        AS PrincipalName,
            ISNULL(sp.type_desc, N'')                      AS PrincipalType,
            p.permission_name                              AS PermissionName,
            p.state_desc                                   AS StateDesc,
            N''                                            AS ColumnName,
            ISNULL(gp.name, N'')                           AS GrantorName
        FROM sys.server_permissions AS p
        JOIN sys.server_principals AS sp ON sp.principal_id = p.grantee_principal_id
        LEFT JOIN sys.server_principals AS gp ON gp.principal_id = p.grantor_principal_id
        ORDER BY sp.name, p.permission_name;
        """
        return try await runner.read(sql, database: "master").map(Self.entry(from:))
    }

    private static func entry(from row: [String: TDSValue]) -> PermissionEntry {
        PermissionEntry(
            principal: row.string("PrincipalName"),
            principalType: row.string("PrincipalType"),
            permission: row.string("PermissionName"),
            state: row.string("StateDesc"),
            columnName: row.string("ColumnName"),
            grantor: row.string("GrantorName")
        )
    }

    /// The principals the Permissions page can grant to.
    public func principals(database: String, target: PermissionTarget) async throws -> [String] {
        if case .server = target {
            let sql = """
            SELECT name FROM sys.server_principals
            WHERE type IN ('S', 'U', 'G', 'R') AND name NOT LIKE '##%'
            ORDER BY name;
            """
            return try await runner.read(sql, database: "master").map { $0.string("name") }
        }
        let sql = """
        SELECT name FROM sys.database_principals
        WHERE type IN ('S', 'U', 'G', 'R', 'A', 'E', 'X')
          AND name NOT LIKE 'db_%' AND name NOT IN ('public', 'sys', 'INFORMATION_SCHEMA')
        ORDER BY name;
        """
        return try await runner.read(sql, database: database).map { $0.string("name") }
    }

    /// The permission names that apply to a target class, straight from
    /// `sys.fn_builtin_permissions` so the list matches the server's version.
    public func availablePermissions(database: String,
                                     target: PermissionTarget) async throws -> [String] {
        let className: String
        switch target {
        case .server: className = "SERVER"
        case .database: className = "DATABASE"
        case .schema: className = "SCHEMA"
        case .object: className = "OBJECT"
        }
        let sql = """
        SELECT DISTINCT permission_name
        FROM sys.fn_builtin_permissions(\(SQLIdentifier.literal(className)))
        ORDER BY permission_name;
        """
        let scope: String? = className == "SERVER" ? "master" : database
        return try await runner.read(sql, database: scope).map { $0.string("permission_name") }
    }

    /// The GRANT / DENY / REVOKE statement.
    ///
    /// A permission name is an unquoted keyword sequence, so it is validated instead of
    /// escaped; principals and object names go through the identifier quoter.
    public static func permissionStatement(action: PermissionAction,
                                           permission: String,
                                           on target: PermissionTarget,
                                           to principal: String,
                                           withGrantOption: Bool = false,
                                           cascade: Bool = false) throws -> String {
        let name = permission.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard ObjectAdmin.isSafePermissionName(name) else {
            throw SQLServerError.unsupportedOperation("'\(permission)' is not a permission name.")
        }
        let grantee = principal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !grantee.isEmpty else {
            throw SQLServerError.unsupportedOperation("A principal is required.")
        }

        var statement = "\(action.rawValue) \(name)\(target.onClause)"
        statement += action == .revoke ? " FROM " : " TO "
        statement += SQLIdentifier.quote(grantee)
        if action == .grant, withGrantOption { statement += " WITH GRANT OPTION" }
        if action == .revoke, cascade { statement += " CASCADE" }
        return statement + ";"
    }

    /// Permission names are made of letters and single spaces — `VIEW DEFINITION`,
    /// `ALTER ANY SCHEMA`. Anything else is rejected rather than quoted.
    static func isSafePermissionName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 128 else { return false }
        guard !name.hasPrefix(" "), !name.hasSuffix(" "), !name.contains("  ") else { return false }
        return name.allSatisfy { $0.isLetter || $0 == " " }
    }

    public func applyPermission(database: String,
                                action: PermissionAction,
                                permission: String,
                                target: PermissionTarget,
                                principal: String,
                                withGrantOption: Bool = false,
                                cascade: Bool = false) async throws {
        let statement = try ObjectAdmin.permissionStatement(action: action,
                                                            permission: permission,
                                                            on: target,
                                                            to: principal,
                                                            withGrantOption: withGrantOption,
                                                            cascade: cascade)
        if case .server = target {
            try await runner.run(statement, database: "master")
        } else {
            try await runner.run(statement, database: database)
        }
    }
}
