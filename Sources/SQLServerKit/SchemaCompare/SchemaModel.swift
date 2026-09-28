import Foundation

// MARK: - Object types

/// Every kind of database object Schema Compare reads, compares and deploys.
///
/// The order of the cases is the order objects are created in when nothing more specific
/// is known: principals before the schemas they own, types before the tables that use
/// them, tables before the modules that read them.
public enum SchemaObjectType: String, Codable, CaseIterable, Sendable, Comparable {
    case user
    case role
    case applicationRole
    case schema
    case assembly
    case xmlSchemaCollection
    case userDefinedType
    case tableType
    case partitionFunction
    case partitionScheme
    case fullTextCatalog
    case fullTextStoplist
    case sequence
    case rule
    case defaultObject
    case table
    case function
    case view
    case storedProcedure
    case synonym
    case securityPolicy
    case messageType
    case contract
    case queue
    case service
    case ddlTrigger

    public static func < (lhs: SchemaObjectType, rhs: SchemaObjectType) -> Bool {
        lhs.creationOrder < rhs.creationOrder
    }

    public var creationOrder: Int {
        SchemaObjectType.allCases.firstIndex(of: self) ?? 0
    }

    public var title: String {
        switch self {
        case .user: return "User"
        case .role: return "Role"
        case .applicationRole: return "Application role"
        case .schema: return "Schema"
        case .assembly: return "Assembly"
        case .xmlSchemaCollection: return "XML schema collection"
        case .userDefinedType: return "User-defined type"
        case .tableType: return "Table type"
        case .partitionFunction: return "Partition function"
        case .partitionScheme: return "Partition scheme"
        case .fullTextCatalog: return "Full-text catalog"
        case .fullTextStoplist: return "Full-text stoplist"
        case .sequence: return "Sequence"
        case .rule: return "Rule"
        case .defaultObject: return "Default"
        case .table: return "Table"
        case .function: return "Function"
        case .view: return "View"
        case .storedProcedure: return "Stored procedure"
        case .synonym: return "Synonym"
        case .securityPolicy: return "Security policy"
        case .messageType: return "Message type"
        case .contract: return "Contract"
        case .queue: return "Queue"
        case .service: return "Service"
        case .ddlTrigger: return "DDL trigger"
        }
    }

    public var pluralTitle: String {
        switch self {
        case .user: return "Users"
        case .role: return "Roles"
        case .applicationRole: return "Application roles"
        case .schema: return "Schemas"
        case .assembly: return "Assemblies"
        case .xmlSchemaCollection: return "XML schema collections"
        case .userDefinedType: return "User-defined types"
        case .tableType: return "Table types"
        case .partitionFunction: return "Partition functions"
        case .partitionScheme: return "Partition schemes"
        case .fullTextCatalog: return "Full-text catalogs"
        case .fullTextStoplist: return "Full-text stoplists"
        case .sequence: return "Sequences"
        case .rule: return "Rules"
        case .defaultObject: return "Defaults"
        case .table: return "Tables"
        case .function: return "Functions"
        case .view: return "Views"
        case .storedProcedure: return "Stored procedures"
        case .synonym: return "Synonyms"
        case .securityPolicy: return "Security policies"
        case .messageType: return "Message types"
        case .contract: return "Contracts"
        case .queue: return "Queues"
        case .service: return "Services"
        case .ddlTrigger: return "DDL triggers"
        }
    }

    /// Folder used for the object in a scripts folder, following the layout most
    /// source-controlled SQL Server projects already use.
    public var folderName: String {
        switch self {
        case .user: return "Security/Users"
        case .role: return "Security/Roles"
        case .applicationRole: return "Security/Application Roles"
        case .schema: return "Security/Schemas"
        case .assembly: return "Assemblies"
        case .xmlSchemaCollection: return "Types/XML Schema Collections"
        case .userDefinedType: return "Types/User-defined Data Types"
        case .tableType: return "Types/User-defined Table Types"
        case .partitionFunction: return "Storage/Partition Functions"
        case .partitionScheme: return "Storage/Partition Schemes"
        case .fullTextCatalog: return "Storage/Full Text Catalogs"
        case .fullTextStoplist: return "Storage/Full Text Stoplists"
        case .sequence: return "Sequences"
        case .rule: return "Rules"
        case .defaultObject: return "Defaults"
        case .table: return "Tables"
        case .function: return "Functions"
        case .view: return "Views"
        case .storedProcedure: return "Stored Procedures"
        case .synonym: return "Synonyms"
        case .securityPolicy: return "Security/Security Policies"
        case .messageType: return "Service Broker/Message Types"
        case .contract: return "Service Broker/Contracts"
        case .queue: return "Service Broker/Queues"
        case .service: return "Service Broker/Services"
        case .ddlTrigger: return "Database Triggers"
        }
    }

    /// SF Symbol name for lists.
    public var iconName: String {
        switch self {
        case .user: return "person"
        case .role, .applicationRole: return "person.2"
        case .schema: return "folder"
        case .assembly: return "shippingbox"
        case .xmlSchemaCollection: return "chevron.left.forwardslash.chevron.right"
        case .userDefinedType, .tableType: return "textformat"
        case .partitionFunction, .partitionScheme: return "square.split.2x1"
        case .fullTextCatalog, .fullTextStoplist: return "text.magnifyingglass"
        case .sequence: return "number"
        case .rule, .defaultObject: return "checkmark.seal"
        case .table: return "tablecells"
        case .function: return "function"
        case .view: return "rectangle.on.rectangle"
        case .storedProcedure: return "gearshape"
        case .synonym: return "arrow.triangle.branch"
        case .securityPolicy: return "lock.shield"
        case .messageType, .contract, .queue, .service: return "envelope"
        case .ddlTrigger: return "bolt"
        }
    }

    /// Objects that live inside a schema and are therefore named `schema.name`.
    public var isSchemaScoped: Bool {
        switch self {
        case .user, .role, .applicationRole, .schema, .assembly, .partitionFunction,
             .partitionScheme, .fullTextCatalog, .fullTextStoplist, .messageType, .contract,
             .service, .ddlTrigger:
            return false
        default:
            return true
        }
    }

    /// Objects whose body is T-SQL text kept in `sys.sql_modules`.
    public var isModule: Bool {
        switch self {
        case .view, .function, .storedProcedure, .ddlTrigger, .rule, .defaultObject: return true
        default: return false
        }
    }

    /// The keyword used in `DROP <keyword>`.
    public var dropKeyword: String {
        switch self {
        case .user: return "USER"
        case .role: return "ROLE"
        case .applicationRole: return "APPLICATION ROLE"
        case .schema: return "SCHEMA"
        case .assembly: return "ASSEMBLY"
        case .xmlSchemaCollection: return "XML SCHEMA COLLECTION"
        case .userDefinedType, .tableType: return "TYPE"
        case .partitionFunction: return "PARTITION FUNCTION"
        case .partitionScheme: return "PARTITION SCHEME"
        case .fullTextCatalog: return "FULLTEXT CATALOG"
        case .fullTextStoplist: return "FULLTEXT STOPLIST"
        case .sequence: return "SEQUENCE"
        case .rule: return "RULE"
        case .defaultObject: return "DEFAULT"
        case .table: return "TABLE"
        case .function: return "FUNCTION"
        case .view: return "VIEW"
        case .storedProcedure: return "PROCEDURE"
        case .synonym: return "SYNONYM"
        case .securityPolicy: return "SECURITY POLICY"
        case .messageType: return "MESSAGE TYPE"
        case .contract: return "CONTRACT"
        case .queue: return "QUEUE"
        case .service: return "SERVICE"
        case .ddlTrigger: return "TRIGGER"
        }
    }

    /// Securable class used by GRANT and ALTER AUTHORIZATION, `OBJECT::` when empty.
    public var securableClass: String {
        switch self {
        case .schema: return "SCHEMA"
        case .userDefinedType, .tableType: return "TYPE"
        case .xmlSchemaCollection: return "XML SCHEMA COLLECTION"
        case .assembly: return "ASSEMBLY"
        case .user: return "USER"
        case .role, .applicationRole: return "ROLE"
        case .fullTextCatalog: return "FULLTEXT CATALOG"
        case .fullTextStoplist: return "FULLTEXT STOPLIST"
        case .messageType: return "MESSAGE TYPE"
        case .contract: return "CONTRACT"
        case .service: return "SERVICE"
        default: return "OBJECT"
        }
    }

    /// `sp_addextendedproperty` level 0/1 type words.
    public var extendedPropertyLevel1: String? {
        switch self {
        case .table: return "TABLE"
        case .view: return "VIEW"
        case .function: return "FUNCTION"
        case .storedProcedure: return "PROCEDURE"
        case .synonym: return "SYNONYM"
        case .sequence: return "SEQUENCE"
        case .userDefinedType, .tableType: return "TYPE"
        case .xmlSchemaCollection: return "XML SCHEMA COLLECTION"
        case .rule: return "RULE"
        case .defaultObject: return "DEFAULT"
        case .queue: return "QUEUE"
        default: return nil
        }
    }
}

// MARK: - Keys

/// Identity of an object inside one database. Names compare case-insensitively, which is
/// what SQL Server does under every default collation.
public struct SchemaObjectKey: Hashable, Codable, Sendable, Comparable, CustomStringConvertible {
    public var type: SchemaObjectType
    public var schema: String
    public var name: String

    public init(type: SchemaObjectType, schema: String, name: String) {
        self.type = type
        self.schema = schema
        self.name = name
    }

    /// Lowercased form used for matching.
    public var matchKey: String {
        "\(type.rawValue)|\(schema.lowercased())|\(name.lowercased())"
    }

    /// Namespace key: SQL Server keeps tables, views, procedures, functions, synonyms,
    /// sequences and queues in one per-schema namespace.
    public var namespaceKey: String {
        "\(schema.lowercased()).\(name.lowercased())"
    }

    public var qualifiedName: String {
        schema.isEmpty ? name : "\(schema).\(name)"
    }

    public var quotedName: String {
        schema.isEmpty ? SQLIdentifier.quote(name) : SQLIdentifier.quote(schema: schema, name: name)
    }

    public var description: String { "\(type.title) \(qualifiedName)" }

    public static func == (lhs: SchemaObjectKey, rhs: SchemaObjectKey) -> Bool {
        lhs.matchKey == rhs.matchKey
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(matchKey)
    }

    public static func < (lhs: SchemaObjectKey, rhs: SchemaObjectKey) -> Bool {
        if lhs.type != rhs.type { return lhs.type < rhs.type }
        let left = lhs.qualifiedName.lowercased()
        let right = rhs.qualifiedName.lowercased()
        if left != right { return left < right }
        return lhs.qualifiedName < rhs.qualifiedName
    }
}

// MARK: - Table parts

public struct IdentitySpec: Codable, Hashable, Sendable {
    public var seed: String
    public var increment: String
    public var notForReplication: Bool

    public init(seed: String = "1", increment: String = "1", notForReplication: Bool = false) {
        self.seed = seed
        self.increment = increment
        self.notForReplication = notForReplication
    }
}

public struct DefaultConstraintDefinition: Codable, Hashable, Sendable {
    public var name: String
    public var definition: String
    public var isSystemNamed: Bool

    public init(name: String, definition: String, isSystemNamed: Bool = false) {
        self.name = name
        self.definition = definition
        self.isSystemNamed = isSystemNamed
    }
}

public struct ColumnDefinition: Codable, Hashable, Sendable {
    public var name: String
    /// Rendered type: `int`, `nvarchar(50)`, `decimal(18,2)`, `[dbo].[Phone]`, `xml(CONTENT [dbo].[X])`.
    public var dataType: String
    public var isUserDefinedType: Bool
    public var isNullable: Bool
    /// Actual collation of a character column. nil for non-character types.
    public var collation: String?
    public var identity: IdentitySpec?
    public var computedExpression: String?
    public var isPersisted: Bool
    public var defaultConstraint: DefaultConstraintDefinition?
    public var isRowGuidCol: Bool
    public var isSparse: Bool
    public var isFileStream: Bool
    public var isColumnSet: Bool
    /// `ROW START` / `ROW END` for system-versioned period columns.
    public var generatedAlways: String?
    public var isHidden: Bool
    public var maskingFunction: String?
    /// Legacy `sp_bindrule` / `sp_bindefault` bindings, as quoted two-part names.
    public var boundRule: String?
    public var boundDefault: String?

    public init(name: String, dataType: String, isUserDefinedType: Bool = false,
                isNullable: Bool = true, collation: String? = nil, identity: IdentitySpec? = nil,
                computedExpression: String? = nil, isPersisted: Bool = false,
                defaultConstraint: DefaultConstraintDefinition? = nil, isRowGuidCol: Bool = false,
                isSparse: Bool = false, isFileStream: Bool = false, isColumnSet: Bool = false,
                generatedAlways: String? = nil, isHidden: Bool = false,
                maskingFunction: String? = nil, boundRule: String? = nil,
                boundDefault: String? = nil) {
        self.name = name
        self.dataType = dataType
        self.isUserDefinedType = isUserDefinedType
        self.isNullable = isNullable
        self.collation = collation
        self.identity = identity
        self.computedExpression = computedExpression
        self.isPersisted = isPersisted
        self.defaultConstraint = defaultConstraint
        self.isRowGuidCol = isRowGuidCol
        self.isSparse = isSparse
        self.isFileStream = isFileStream
        self.isColumnSet = isColumnSet
        self.generatedAlways = generatedAlways
        self.isHidden = isHidden
        self.maskingFunction = maskingFunction
        self.boundRule = boundRule
        self.boundDefault = boundDefault
    }

    public var isComputed: Bool { computedExpression != nil }

    /// Base type name without length, lowercased: `nvarchar`, `decimal`, `dbo.phone`.
    public var baseTypeName: String {
        SchemaTypes.baseName(of: dataType)
    }
}

public struct IndexColumn: Codable, Hashable, Sendable {
    public var name: String
    public var isDescending: Bool

    public init(name: String, isDescending: Bool = false) {
        self.name = name
        self.isDescending = isDescending
    }
}

public struct IndexOptions: Codable, Hashable, Sendable {
    public var fillFactor: Int
    public var padIndex: Bool
    public var ignoreDupKey: Bool
    public var allowRowLocks: Bool
    public var allowPageLocks: Bool
    public var statisticsNoRecompute: Bool
    public var dataCompression: String
    public var optimizeForSequentialKey: Bool

    public init(fillFactor: Int = 0, padIndex: Bool = false, ignoreDupKey: Bool = false,
                allowRowLocks: Bool = true, allowPageLocks: Bool = true,
                statisticsNoRecompute: Bool = false, dataCompression: String = "NONE",
                optimizeForSequentialKey: Bool = false) {
        self.fillFactor = fillFactor
        self.padIndex = padIndex
        self.ignoreDupKey = ignoreDupKey
        self.allowRowLocks = allowRowLocks
        self.allowPageLocks = allowPageLocks
        self.statisticsNoRecompute = statisticsNoRecompute
        self.dataCompression = dataCompression
        self.optimizeForSequentialKey = optimizeForSequentialKey
    }

    /// 100 and 0 both mean "fill completely".
    public var effectiveFillFactor: Int { fillFactor == 100 ? 0 : fillFactor }
}

public struct KeyConstraintDefinition: Codable, Hashable, Sendable {
    public var name: String
    public var isSystemNamed: Bool
    public var isPrimaryKey: Bool
    public var isClustered: Bool
    public var columns: [IndexColumn]
    public var options: IndexOptions
    /// Filegroup or partition scheme.
    public var dataSpace: String
    public var partitionColumn: String?

    public init(name: String, isSystemNamed: Bool = false, isPrimaryKey: Bool,
                isClustered: Bool, columns: [IndexColumn], options: IndexOptions = IndexOptions(),
                dataSpace: String = "PRIMARY", partitionColumn: String? = nil) {
        self.name = name
        self.isSystemNamed = isSystemNamed
        self.isPrimaryKey = isPrimaryKey
        self.isClustered = isClustered
        self.columns = columns
        self.options = options
        self.dataSpace = dataSpace
        self.partitionColumn = partitionColumn
    }
}

public struct CheckConstraintDefinition: Codable, Hashable, Sendable {
    public var name: String
    public var isSystemNamed: Bool
    public var definition: String
    public var isNotForReplication: Bool
    public var isNotTrusted: Bool
    public var isDisabled: Bool

    public init(name: String, isSystemNamed: Bool = false, definition: String,
                isNotForReplication: Bool = false, isNotTrusted: Bool = false,
                isDisabled: Bool = false) {
        self.name = name
        self.isSystemNamed = isSystemNamed
        self.definition = definition
        self.isNotForReplication = isNotForReplication
        self.isNotTrusted = isNotTrusted
        self.isDisabled = isDisabled
    }
}

public struct ForeignKeyDefinition: Codable, Hashable, Sendable {
    public var name: String
    public var isSystemNamed: Bool
    public var columns: [String]
    public var referencedSchema: String
    public var referencedTable: String
    public var referencedColumns: [String]
    /// `NO ACTION`, `CASCADE`, `SET NULL`, `SET DEFAULT`.
    public var deleteAction: String
    public var updateAction: String
    public var isNotForReplication: Bool
    public var isNotTrusted: Bool
    public var isDisabled: Bool

    public init(name: String, isSystemNamed: Bool = false, columns: [String],
                referencedSchema: String, referencedTable: String, referencedColumns: [String],
                deleteAction: String = "NO ACTION", updateAction: String = "NO ACTION",
                isNotForReplication: Bool = false, isNotTrusted: Bool = false,
                isDisabled: Bool = false) {
        self.name = name
        self.isSystemNamed = isSystemNamed
        self.columns = columns
        self.referencedSchema = referencedSchema
        self.referencedTable = referencedTable
        self.referencedColumns = referencedColumns
        self.deleteAction = deleteAction
        self.updateAction = updateAction
        self.isNotForReplication = isNotForReplication
        self.isNotTrusted = isNotTrusted
        self.isDisabled = isDisabled
    }

    public var referencedKey: SchemaObjectKey {
        SchemaObjectKey(type: .table, schema: referencedSchema, name: referencedTable)
    }
}

public enum IndexKind: String, Codable, Hashable, Sendable {
    case clustered
    case nonclustered
    case clusteredColumnstore
    case nonclusteredColumnstore
    case primaryXml
    case secondaryXml
    case spatial

    public var isClustered: Bool { self == .clustered || self == .clusteredColumnstore }
}

public struct IndexDefinition: Codable, Hashable, Sendable {
    public var name: String
    public var kind: IndexKind
    public var isUnique: Bool
    public var columns: [IndexColumn]
    public var includedColumns: [String]
    public var filter: String?
    public var options: IndexOptions
    public var dataSpace: String
    public var partitionColumn: String?
    public var isDisabled: Bool
    /// Secondary XML indexes name their primary index and PATH / VALUE / PROPERTY.
    public var primaryXmlIndex: String?
    public var secondaryXmlType: String?
    /// Spatial indexes: `GEOMETRY_AUTO_GRID`, `GEOGRAPHY_AUTO_GRID`, … plus the bounding box.
    public var spatialTessellation: String?
    public var spatialBoundingBox: String?

    public init(name: String, kind: IndexKind, isUnique: Bool = false, columns: [IndexColumn],
                includedColumns: [String] = [], filter: String? = nil,
                options: IndexOptions = IndexOptions(), dataSpace: String = "PRIMARY",
                partitionColumn: String? = nil, isDisabled: Bool = false,
                primaryXmlIndex: String? = nil, secondaryXmlType: String? = nil,
                spatialTessellation: String? = nil, spatialBoundingBox: String? = nil) {
        self.name = name
        self.kind = kind
        self.isUnique = isUnique
        self.columns = columns
        self.includedColumns = includedColumns
        self.filter = filter
        self.options = options
        self.dataSpace = dataSpace
        self.partitionColumn = partitionColumn
        self.isDisabled = isDisabled
        self.primaryXmlIndex = primaryXmlIndex
        self.secondaryXmlType = secondaryXmlType
        self.spatialTessellation = spatialTessellation
        self.spatialBoundingBox = spatialBoundingBox
    }
}

public struct TriggerDefinition: Codable, Hashable, Sendable {
    public var name: String
    public var definition: String
    public var isDisabled: Bool
    public var usesQuotedIdentifier: Bool
    public var usesAnsiNulls: Bool
    /// Events for which the trigger is set to fire first or last, e.g. `INSERT` -> `First`.
    public var order: [String: String]

    public init(name: String, definition: String, isDisabled: Bool = false,
                usesQuotedIdentifier: Bool = true, usesAnsiNulls: Bool = true,
                order: [String: String] = [:]) {
        self.name = name
        self.definition = definition
        self.isDisabled = isDisabled
        self.usesQuotedIdentifier = usesQuotedIdentifier
        self.usesAnsiNulls = usesAnsiNulls
        self.order = order
    }
}

public struct StatisticsDefinition: Codable, Hashable, Sendable {
    public var name: String
    public var columns: [String]
    public var filter: String?
    public var noRecompute: Bool

    public init(name: String, columns: [String], filter: String? = nil, noRecompute: Bool = false) {
        self.name = name
        self.columns = columns
        self.filter = filter
        self.noRecompute = noRecompute
    }
}

public struct FullTextIndexColumn: Codable, Hashable, Sendable {
    public var name: String
    public var typeColumn: String?
    public var language: Int?

    public init(name: String, typeColumn: String? = nil, language: Int? = nil) {
        self.name = name
        self.typeColumn = typeColumn
        self.language = language
    }
}

public struct FullTextIndexDefinition: Codable, Hashable, Sendable {
    public var catalog: String
    public var keyIndex: String
    public var columns: [FullTextIndexColumn]
    /// `AUTO`, `MANUAL` or `OFF`.
    public var changeTracking: String
    public var stoplist: String?

    public init(catalog: String, keyIndex: String, columns: [FullTextIndexColumn],
                changeTracking: String = "AUTO", stoplist: String? = nil) {
        self.catalog = catalog
        self.keyIndex = keyIndex
        self.columns = columns
        self.changeTracking = changeTracking
        self.stoplist = stoplist
    }
}

public struct TemporalDefinition: Codable, Hashable, Sendable {
    public var periodStartColumn: String
    public var periodEndColumn: String
    public var historySchema: String?
    public var historyTable: String?

    public init(periodStartColumn: String, periodEndColumn: String,
                historySchema: String? = nil, historyTable: String? = nil) {
        self.periodStartColumn = periodStartColumn
        self.periodEndColumn = periodEndColumn
        self.historySchema = historySchema
        self.historyTable = historyTable
    }

    public var isSystemVersioned: Bool { historyTable != nil }
}

public struct TableDefinition: Codable, Hashable, Sendable {
    public var columns: [ColumnDefinition]
    public var primaryKey: KeyConstraintDefinition?
    public var uniqueConstraints: [KeyConstraintDefinition]
    public var checkConstraints: [CheckConstraintDefinition]
    public var foreignKeys: [ForeignKeyDefinition]
    public var dataSpace: String
    public var partitionColumn: String?
    public var textImageDataSpace: String?
    /// `TABLE`, `AUTO` or `DISABLE`.
    public var lockEscalation: String
    /// Compression of the heap or the clustered index.
    public var dataCompression: String
    public var isMemoryOptimized: Bool
    public var durability: String?
    public var changeTracking: Bool
    public var changeTrackingColumnsUpdated: Bool
    public var temporal: TemporalDefinition?
    public var fullTextIndex: FullTextIndexDefinition?

    public init(columns: [ColumnDefinition] = [], primaryKey: KeyConstraintDefinition? = nil,
                uniqueConstraints: [KeyConstraintDefinition] = [],
                checkConstraints: [CheckConstraintDefinition] = [],
                foreignKeys: [ForeignKeyDefinition] = [], dataSpace: String = "PRIMARY",
                partitionColumn: String? = nil, textImageDataSpace: String? = nil,
                lockEscalation: String = "TABLE", dataCompression: String = "NONE",
                isMemoryOptimized: Bool = false, durability: String? = nil,
                changeTracking: Bool = false, changeTrackingColumnsUpdated: Bool = false,
                temporal: TemporalDefinition? = nil,
                fullTextIndex: FullTextIndexDefinition? = nil) {
        self.columns = columns
        self.primaryKey = primaryKey
        self.uniqueConstraints = uniqueConstraints
        self.checkConstraints = checkConstraints
        self.foreignKeys = foreignKeys
        self.dataSpace = dataSpace
        self.partitionColumn = partitionColumn
        self.textImageDataSpace = textImageDataSpace
        self.lockEscalation = lockEscalation
        self.dataCompression = dataCompression
        self.isMemoryOptimized = isMemoryOptimized
        self.durability = durability
        self.changeTracking = changeTracking
        self.changeTrackingColumnsUpdated = changeTrackingColumnsUpdated
        self.temporal = temporal
        self.fullTextIndex = fullTextIndex
    }

    public func column(named name: String) -> ColumnDefinition? {
        columns.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }
}

// MARK: - Security and documentation

public struct PermissionDefinition: Codable, Hashable, Sendable, Comparable {
    /// `GRANT`, `DENY`, or `GRANT_WITH_GRANT_OPTION`.
    public var state: String
    public var permission: String
    public var grantee: String
    public var column: String?

    public init(state: String, permission: String, grantee: String, column: String? = nil) {
        self.state = state
        self.permission = permission
        self.grantee = grantee
        self.column = column
    }

    public static func < (lhs: PermissionDefinition, rhs: PermissionDefinition) -> Bool {
        lhs.sortKey < rhs.sortKey
    }

    var sortKey: String {
        "\(grantee.lowercased())|\(permission)|\(column?.lowercased() ?? "")|\(state)"
    }

    /// Identity without the state, so GRANT → DENY reads as one change.
    var slotKey: String {
        "\(grantee.lowercased())|\(permission.uppercased())|\(column?.lowercased() ?? "")"
    }
}

public struct ExtendedPropertyDefinition: Codable, Hashable, Sendable, Comparable {
    public var name: String
    public var value: String
    /// Level-2 type (`COLUMN`, `INDEX`, `CONSTRAINT`, `TRIGGER`, `PARAMETER`) and name, when
    /// the property hangs off a part of the object rather than the object itself.
    public var childType: String?
    public var childName: String?

    public init(name: String, value: String, childType: String? = nil, childName: String? = nil) {
        self.name = name
        self.value = value
        self.childType = childType
        self.childName = childName
    }

    public static func < (lhs: ExtendedPropertyDefinition, rhs: ExtendedPropertyDefinition) -> Bool {
        lhs.slotKey < rhs.slotKey
    }

    var slotKey: String {
        "\(childType ?? "")|\(childName?.lowercased() ?? "")|\(name.lowercased())"
    }
}

// MARK: - Object

/// One comparable database object.
///
/// Modules keep their original text in `body`. Everything else is rebuilt from catalog rows
/// into `body` as a canonical CREATE statement, so two databases that agree render the same
/// text no matter how the object was first written.
public struct SchemaObject: Codable, Hashable, Sendable, Identifiable {
    public var type: SchemaObjectType
    public var schema: String
    public var name: String
    /// Module text for modules; canonical CREATE statement for catalog-built objects. Tables
    /// leave it empty because they are rendered from `table`.
    public var body: String
    /// Extra classification, e.g. the function kind (`FN`, `IF`, `TF`, `FS`, `FT`, `AF`).
    public var subtype: String
    /// Explicit owner (`ALTER AUTHORIZATION`); nil when the object follows its schema owner.
    public var owner: String?
    public var table: TableDefinition?
    /// Indexes on tables and indexed views.
    public var indexes: [IndexDefinition]
    /// DML triggers on tables and views.
    public var triggers: [TriggerDefinition]
    public var statistics: [StatisticsDefinition]
    public var permissions: [PermissionDefinition]
    public var extendedProperties: [ExtendedPropertyDefinition]
    /// Database roles this principal is a member of.
    public var roleMemberships: [String]
    /// Objects this one refers to, used to order deployment.
    public var references: [SchemaObjectKey]
    public var usesQuotedIdentifier: Bool
    public var usesAnsiNulls: Bool
    public var isSchemaBound: Bool
    /// The definition is hidden by `WITH ENCRYPTION` and cannot be compared or deployed.
    public var isEncrypted: Bool
    /// Order settings for DDL triggers, same shape as `TriggerDefinition.order`.
    public var triggerOrder: [String: String]

    public init(type: SchemaObjectType, schema: String, name: String, body: String = "",
                subtype: String = "", owner: String? = nil, table: TableDefinition? = nil,
                indexes: [IndexDefinition] = [], triggers: [TriggerDefinition] = [],
                statistics: [StatisticsDefinition] = [],
                permissions: [PermissionDefinition] = [],
                extendedProperties: [ExtendedPropertyDefinition] = [],
                roleMemberships: [String] = [], references: [SchemaObjectKey] = [],
                usesQuotedIdentifier: Bool = true, usesAnsiNulls: Bool = true,
                isSchemaBound: Bool = false, isEncrypted: Bool = false,
                triggerOrder: [String: String] = [:]) {
        self.type = type
        self.schema = schema
        self.name = name
        self.body = body
        self.subtype = subtype
        self.owner = owner
        self.table = table
        self.indexes = indexes
        self.triggers = triggers
        self.statistics = statistics
        self.permissions = permissions
        self.extendedProperties = extendedProperties
        self.roleMemberships = roleMemberships
        self.references = references
        self.usesQuotedIdentifier = usesQuotedIdentifier
        self.usesAnsiNulls = usesAnsiNulls
        self.isSchemaBound = isSchemaBound
        self.isEncrypted = isEncrypted
        self.triggerOrder = triggerOrder
    }

    public var key: SchemaObjectKey { SchemaObjectKey(type: type, schema: schema, name: name) }
    public var id: String { key.matchKey }
    public var qualifiedName: String { key.qualifiedName }
    public var quotedName: String { key.quotedName }

    /// Scalar and table-valued functions cannot be altered into each other.
    public var functionFamily: String {
        switch subtype.uppercased() {
        case "FN", "FS": return "scalar"
        case "IF": return "inline"
        case "TF", "FT": return "table"
        case "AF": return "aggregate"
        default: return subtype.uppercased()
        }
    }

    public var isCLR: Bool {
        ["FS", "FT", "AF", "PC"].contains(subtype.uppercased())
    }
}

// MARK: - Snapshot

/// A whole database schema at one moment: what the live reader produces, what a snapshot
/// file stores and what a scripts folder parses into.
public struct SchemaSnapshot: Codable, Sendable {
    public static let currentFormatVersion = 1

    public var formatVersion: Int
    /// Where it came from, for headers and reports: `server/database`, a file path, ….
    public var origin: String
    public var databaseName: String
    public var serverVersion: String
    public var compatibilityLevel: Int
    public var defaultCollation: String
    public var createdAt: Date
    public var objects: [SchemaObject]
    /// Things the reader could not load, reported instead of failing the whole read.
    public var warnings: [String]

    public init(origin: String = "", databaseName: String = "", serverVersion: String = "",
                compatibilityLevel: Int = 0, defaultCollation: String = "",
                createdAt: Date = Date(), objects: [SchemaObject] = [], warnings: [String] = []) {
        self.formatVersion = SchemaSnapshot.currentFormatVersion
        self.origin = origin
        self.databaseName = databaseName
        self.serverVersion = serverVersion
        self.compatibilityLevel = compatibilityLevel
        self.defaultCollation = defaultCollation
        self.createdAt = createdAt
        self.objects = objects
        self.warnings = warnings
    }

    public func object(_ key: SchemaObjectKey) -> SchemaObject? {
        objects.first { $0.key == key }
    }

    /// Index by `matchKey`, built once per comparison.
    public func indexed() -> [String: SchemaObject] {
        var result: [String: SchemaObject] = [:]
        for object in objects { result[object.key.matchKey] = object }
        return result
    }
}

// MARK: - Type helpers

public enum SchemaTypes {
    public static let characterTypes: Set<String> =
        ["char", "varchar", "nchar", "nvarchar", "text", "ntext", "sysname"]

    /// `nvarchar(50)` -> `nvarchar`; `[dbo].[Phone]` -> `dbo.phone`.
    public static func baseName(of dataType: String) -> String {
        var text = dataType.trimmingCharacters(in: .whitespaces)
        if let paren = text.firstIndex(of: "(") { text = String(text[text.startIndex..<paren]) }
        return text.replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "")
            .trimmingCharacters(in: .whitespaces).lowercased()
    }

    public static func isCharacter(_ dataType: String) -> Bool {
        characterTypes.contains(baseName(of: dataType))
    }

    /// Length argument of a sized type, -1 for `max`, nil when there is none.
    public static func length(of dataType: String) -> Int? {
        guard let open = dataType.firstIndex(of: "("),
              let close = dataType.lastIndex(of: ")"), open < close else { return nil }
        let inner = dataType[dataType.index(after: open)..<close]
        let first = inner.split(separator: ",").first.map(String.init)?
            .trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        if first == "max" { return -1 }
        return Int(first)
    }

    /// Precision and scale for decimal/numeric.
    public static func precisionScale(of dataType: String) -> (Int, Int)? {
        guard let open = dataType.firstIndex(of: "("),
              let close = dataType.lastIndex(of: ")"), open < close else { return nil }
        let parts = dataType[dataType.index(after: open)..<close].split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let precision = parts.first.flatMap({ Int($0) }) else { return nil }
        let scale = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        return (precision, scale)
    }

    /// Types that can never be part of an index key or compared with `=`.
    public static func isLargeObject(_ dataType: String) -> Bool {
        let base = baseName(of: dataType)
        if ["text", "ntext", "image", "xml", "geography", "geometry"].contains(base) { return true }
        return length(of: dataType) == -1
    }

    /// Canonical spelling so `NVARCHAR (50)` and `nvarchar(50)` compare equal and
    /// `decimal(18, 2)` renders as `decimal(18,2)`.
    public static func canonical(_ dataType: String) -> String {
        let trimmed = dataType.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("[") || trimmed.contains("].") {
            return trimmed
        }
        var out = ""
        var inParens = false
        for character in trimmed {
            if character == "(" { inParens = true }
            if character == ")" { inParens = false }
            if character == " " && (inParens || out.hasSuffix(" ")) { continue }
            out.append(character)
        }
        out = out.replacingOccurrences(of: " (", with: "(")
        guard let paren = out.firstIndex(of: "(") else { return out.lowercased() }
        let head = String(out[out.startIndex..<paren]).lowercased()
        let tail = String(out[paren...]).lowercased()
        return head + tail
    }
}
