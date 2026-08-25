import Foundation

/// What an Object Explorer node represents. Drives icons, context menus and scripting.
public enum ObjectNodeKind: String, Codable, Sendable, Hashable, CaseIterable {
    case server
    case folder
    case database
    case table
    case view
    case column
    case index
    case primaryKey
    case uniqueKey
    case foreignKey
    case checkConstraint
    case defaultConstraint
    case trigger
    case storedProcedure
    case scalarFunction
    case tableValuedFunction
    case aggregateFunction
    case synonym
    case sequence
    case userDefinedDataType
    case userDefinedTableType
    case schema
    case databaseUser
    case databaseRole
    case applicationRole
    case login
    case serverRole
    case credential
    case linkedServer
    case filegroup
    case databaseFile
    case parameter
    case statistic
    case assembly
    case xmlSchemaCollection
    case partitionFunction
    case partitionScheme
    case agentJob
    case externalTable
    case securityPolicy
    case unknown
}

/// Logical folders in the tree. The value tells the metadata service what to load next.
public enum ObjectFolderKind: String, Codable, Sendable, Hashable, CaseIterable {
    case databases
    case systemDatabases
    case databaseSnapshots
    case tables
    case systemTables
    case externalTables
    case fileTables
    case graphTables
    case views
    case systemViews
    case columns
    case keys
    case constraints
    case indexes
    case triggers
    case statistics
    case programmability
    case storedProcedures
    case systemStoredProcedures
    case functions
    case tableValuedFunctions
    case scalarValuedFunctions
    case aggregateFunctions
    case systemFunctions
    case databaseTriggers
    case assemblies
    case types
    case systemDataTypes
    case userDefinedDataTypes
    case userDefinedTableTypes
    case xmlSchemaCollections
    case sequences
    case synonyms
    case serviceBroker
    case storage
    case fullTextCatalogs
    case partitionSchemes
    case partitionFunctions
    case filegroups
    case databaseFiles
    case security
    case databaseUsers
    case databaseRoles
    case applicationRoles
    case schemas
    case asymmetricKeys
    case certificates
    case symmetricKeys
    case databaseScopedCredentials
    case serverObjects
    case logins
    case serverRoles
    case credentials
    case linkedServers
    case endpoints
    case triggersServer
    case management
    case agent
    case agentJobs
    case replication
    case alwaysOn
    case parameters
    case securityPolicies
}

/// One row in the Object Explorer tree.
///
/// Nodes are value types produced fresh on every expand, so the UI can diff them
/// cheaply. `id` is stable for a given (session, path) pair, which lets the tree
/// keep its expansion state across a refresh.
public struct ObjectExplorerNode: Identifiable, Hashable, Sendable {
    public var id: String
    public var parentID: String?
    public var kind: ObjectNodeKind
    public var folder: ObjectFolderKind?
    public var label: String
    /// Grey text after the label, e.g. `(PK, int, not null)` on a column.
    public var detail: String?
    /// SF Symbol name used by the tree.
    public var iconName: String
    public var isExpandable: Bool
    public var database: String?
    public var schema: String?
    public var name: String?
    public var objectID: Int?
    public var isSystemObject: Bool
    /// Free-form extras consumed by property sheets, scripting and context menus.
    public var info: [String: String]

    public init(id: String,
                parentID: String? = nil,
                kind: ObjectNodeKind,
                folder: ObjectFolderKind? = nil,
                label: String,
                detail: String? = nil,
                iconName: String,
                isExpandable: Bool,
                database: String? = nil,
                schema: String? = nil,
                name: String? = nil,
                objectID: Int? = nil,
                isSystemObject: Bool = false,
                info: [String: String] = [:]) {
        self.id = id
        self.parentID = parentID
        self.kind = kind
        self.folder = folder
        self.label = label
        self.detail = detail
        self.iconName = iconName
        self.isExpandable = isExpandable
        self.database = database
        self.schema = schema
        self.name = name
        self.objectID = objectID
        self.isSystemObject = isSystemObject
        self.info = info
    }

    /// `[db].[schema].[name]` when all three are known.
    public var qualifiedName: String? {
        guard let name else { return nil }
        if let schema, let database {
            return SQLIdentifier.quote(database: database, schema: schema, name: name)
        }
        if let schema { return SQLIdentifier.quote(schema: schema, name: name) }
        return SQLIdentifier.quote(name)
    }

    /// `schema.name` without brackets, for display in title bars.
    public var displayPath: String {
        guard let name else { return label }
        if let schema { return "\(schema).\(name)" }
        return name
    }

    public var isTableLike: Bool {
        kind == .table || kind == .view || kind == .externalTable
    }

    public var isModule: Bool {
        switch kind {
        case .storedProcedure, .scalarFunction, .tableValuedFunction,
             .aggregateFunction, .trigger, .view:
            return true
        default:
            return false
        }
    }
}

/// Options that control how much of the tree is materialised.
public struct ObjectExplorerOptions: Sendable, Hashable {
    /// Show system databases, system tables/views and system stored procedures.
    public var showSystemObjects: Bool
    /// Applies the Object Explorer filter box, matched against the object name.
    public var nameFilter: String?
    /// Cap on children per folder; SSMS defaults to 1000 before showing a filter hint.
    public var maxChildren: Int

    public init(showSystemObjects: Bool = false, nameFilter: String? = nil, maxChildren: Int = 2000) {
        self.showSystemObjects = showSystemObjects
        self.nameFilter = nameFilter
        self.maxChildren = maxChildren
    }
}
