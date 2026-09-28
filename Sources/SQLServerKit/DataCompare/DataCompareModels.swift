import Foundation
import TDSKit

// MARK: - Options

/// How rows are matched and values compared, and how the synchronization script is written.
public struct DataCompareOptions: Codable, Hashable, Sendable {

    // MARK: Comparison

    /// Compare text byte for byte instead of following each column's collation.
    public var forceBinaryCollation: Bool = false
    /// `'a'` and `'a  '` are equal, as they are in SQL Server's own `=`.
    public var ignoreTrailingSpaces: Bool = true
    /// Every run of white space counts as one space, and leading/trailing space is dropped.
    public var ignoreWhiteSpace: Bool = false
    public var treatEmptyStringsAsNull: Bool = false
    /// Round float and real values to this many decimal places before comparing; -1 compares
    /// them exactly.
    public var floatDecimalPlaces: Int = -1
    /// Compare datetime values to the second.
    public var ignoreFractionalSeconds: Bool = false
    public var includeTimestampColumns: Bool = false
    public var includeIdentityColumns: Bool = true
    public var includeComputedColumns: Bool = false
    public var ignoreLargeObjects: Bool = false
    /// Tables whose row count and CHECKSUM_AGG agree are reported identical without reading
    /// their rows.
    public var useChecksumComparison: Bool = false
    /// Keep identical rows so the results grid can show them.
    public var keepIdenticalRows: Bool = true
    /// Rows of each kind kept per table for display and deployment.
    public var maximumRowsKept: Int = 250_000
    public var includeViews: Bool = true

    // MARK: Deployment

    public var disableForeignKeys: Bool = true
    public var disableDMLTriggers: Bool = true
    public var reseedIdentityColumns: Bool = false
    public var doNotUseTransactions: Bool = false
    public var includeComments: Bool = true
    public var rowsPerBatch: Int = 500
    public var deployInserts: Bool = true
    public var deployUpdates: Bool = true
    public var deployDeletes: Bool = true
    public var addDatabaseUseStatement: Bool = false

    public init() {}

    public struct Descriptor: Identifiable {
        public var id: String { name }
        public let name: String
        public let title: String
        public let detail: String
        public let isDeployment: Bool
        public let keyPath: WritableKeyPath<DataCompareOptions, Bool>
    }

    public static let descriptors: [Descriptor] = [
        Descriptor(name: "forceBinaryCollation", title: "Force binary collation (case sensitive)",
                   detail: "Text is compared byte for byte instead of by each column's collation.",
                   isDeployment: false, keyPath: \.forceBinaryCollation),
        Descriptor(name: "ignoreTrailingSpaces", title: "Ignore trailing spaces",
                   detail: "'abc' and 'abc  ' are equal, as SQL Server's = operator treats them.",
                   isDeployment: false, keyPath: \.ignoreTrailingSpaces),
        Descriptor(name: "ignoreWhiteSpace", title: "Ignore white space",
                   detail: "Runs of spaces, tabs and line breaks inside text are treated as one space.",
                   isDeployment: false, keyPath: \.ignoreWhiteSpace),
        Descriptor(name: "treatEmptyStringsAsNull", title: "Treat empty strings as NULL",
                   detail: "An empty string and NULL are considered equal.",
                   isDeployment: false, keyPath: \.treatEmptyStringsAsNull),
        Descriptor(name: "ignoreFractionalSeconds", title: "Ignore fractional seconds",
                   detail: "Date and time values are compared to the whole second.",
                   isDeployment: false, keyPath: \.ignoreFractionalSeconds),
        Descriptor(name: "includeTimestampColumns", title: "Include timestamp (rowversion) columns",
                   detail: "Rowversions differ between databases by nature, so they are skipped by default.",
                   isDeployment: false, keyPath: \.includeTimestampColumns),
        Descriptor(name: "includeIdentityColumns", title: "Include identity columns",
                   detail: "Identity values are compared and copied with IDENTITY_INSERT.",
                   isDeployment: false, keyPath: \.includeIdentityColumns),
        Descriptor(name: "includeComputedColumns", title: "Compare computed columns",
                   detail: "Computed values are compared (they are never written).",
                   isDeployment: false, keyPath: \.includeComputedColumns),
        Descriptor(name: "ignoreLargeObjects", title: "Ignore large object columns",
                   detail: "(max), text, ntext, image and xml columns are left out of the comparison.",
                   isDeployment: false, keyPath: \.ignoreLargeObjects),
        Descriptor(name: "useChecksumComparison", title: "Use CHECKSUM comparison",
                   detail: "Tables whose row count and CHECKSUM_AGG match are treated as identical "
                   + "without reading their rows.", isDeployment: false, keyPath: \.useChecksumComparison),
        Descriptor(name: "keepIdenticalRows", title: "Show identical rows",
                   detail: "Identical rows are kept so they can be browsed in the results.",
                   isDeployment: false, keyPath: \.keepIdenticalRows),
        Descriptor(name: "includeViews", title: "Include views",
                   detail: "Views with a unique index, or a comparison key you choose, can be compared.",
                   isDeployment: false, keyPath: \.includeViews),
        Descriptor(name: "disableForeignKeys", title: "Disable foreign keys",
                   detail: "Foreign keys are switched off during deployment and checked again afterwards.",
                   isDeployment: true, keyPath: \.disableForeignKeys),
        Descriptor(name: "disableDMLTriggers", title: "Disable DML triggers",
                   detail: "Triggers do not fire for the synchronization statements.",
                   isDeployment: true, keyPath: \.disableDMLTriggers),
        Descriptor(name: "reseedIdentityColumns", title: "Reseed identity columns",
                   detail: "Identity columns in the target continue from the source's current value.",
                   isDeployment: true, keyPath: \.reseedIdentityColumns),
        Descriptor(name: "doNotUseTransactions", title: "Do not use transactions",
                   detail: "The script runs without BEGIN TRANSACTION / COMMIT.",
                   isDeployment: true, keyPath: \.doNotUseTransactions),
        Descriptor(name: "includeComments", title: "Include comments and PRINT statements",
                   detail: "The script reports each table as it runs.",
                   isDeployment: true, keyPath: \.includeComments),
        Descriptor(name: "deployInserts", title: "Insert rows that exist only in the source",
                   detail: "", isDeployment: true, keyPath: \.deployInserts),
        Descriptor(name: "deployUpdates", title: "Update rows that are different",
                   detail: "", isDeployment: true, keyPath: \.deployUpdates),
        Descriptor(name: "deployDeletes", title: "Delete rows that exist only in the target",
                   detail: "", isDeployment: true, keyPath: \.deployDeletes),
        Descriptor(name: "addDatabaseUseStatement", title: "Add database USE statement",
                   detail: "The script starts with USE [target database].",
                   isDeployment: true, keyPath: \.addDatabaseUseStatement)
    ]

    @discardableResult
    public mutating func apply(list: String) -> [String] {
        var unknown: [String] = []
        for raw in list.split(separator: ",") {
            var item = raw.trimmingCharacters(in: .whitespaces)
            guard !item.isEmpty else { continue }
            if item.lowercased() == "default" { self = DataCompareOptions(); continue }
            var value = true
            if item.hasPrefix("-") { value = false; item.removeFirst() }
            else if item.hasPrefix("+") { item.removeFirst() }
            if let (name, number) = Self.numericSetting(item) {
                switch name {
                case "floatdecimalplaces": floatDecimalPlaces = number
                case "rowsperbatch": rowsPerBatch = max(1, number)
                case "maximumrowskept": maximumRowsKept = max(1, number)
                default: unknown.append(item)
                }
                continue
            }
            guard let descriptor = Self.descriptors.first(where: {
                $0.name.caseInsensitiveCompare(item) == .orderedSame
            }) else {
                unknown.append(item)
                continue
            }
            self[keyPath: descriptor.keyPath] = value
        }
        return unknown
    }

    // Missing keys fall back to defaults, so project files survive new options.
    public init(from decoder: Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: DynamicKey.self)
        for descriptor in Self.descriptors {
            if let key = DynamicKey(stringValue: descriptor.name),
               let value = try container.decodeIfPresent(Bool.self, forKey: key) {
                self[keyPath: descriptor.keyPath] = value
            }
        }
        if let key = DynamicKey(stringValue: "floatDecimalPlaces"),
           let value = try container.decodeIfPresent(Int.self, forKey: key) { floatDecimalPlaces = value }
        if let key = DynamicKey(stringValue: "maximumRowsKept"),
           let value = try container.decodeIfPresent(Int.self, forKey: key) { maximumRowsKept = value }
        if let key = DynamicKey(stringValue: "rowsPerBatch"),
           let value = try container.decodeIfPresent(Int.self, forKey: key) { rowsPerBatch = value }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DynamicKey.self)
        for descriptor in Self.descriptors {
            if let key = DynamicKey(stringValue: descriptor.name) {
                try container.encode(self[keyPath: descriptor.keyPath], forKey: key)
            }
        }
        if let key = DynamicKey(stringValue: "floatDecimalPlaces") { try container.encode(floatDecimalPlaces, forKey: key) }
        if let key = DynamicKey(stringValue: "maximumRowsKept") { try container.encode(maximumRowsKept, forKey: key) }
        if let key = DynamicKey(stringValue: "rowsPerBatch") { try container.encode(rowsPerBatch, forKey: key) }
    }

    private static func numericSetting(_ item: String) -> (String, Int)? {
        let parts = item.split(separator: "=").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, let number = Int(parts[1]) else { return nil }
        return (parts[0].lowercased(), number)
    }
}

// MARK: - Catalog

/// A table or view as Data Compare sees it.
public struct DataTableInfo: Codable, Hashable, Sendable, Identifiable {
    public var schema: String
    public var name: String
    public var isView: Bool
    public var columns: [DataColumnInfo]
    public var keys: [DataKeyInfo]
    public var approximateRows: Int64
    /// Triggers that are currently enabled, so deployment can switch off exactly those.
    public var enabledTriggers: [String]

    public init(schema: String, name: String, isView: Bool, columns: [DataColumnInfo], keys: [DataKeyInfo],
                approximateRows: Int64 = 0, enabledTriggers: [String] = []) {
        self.schema = schema
        self.name = name
        self.isView = isView
        self.columns = columns
        self.keys = keys
        self.approximateRows = approximateRows
        self.enabledTriggers = enabledTriggers
    }

    public var id: String { "\(schema.lowercased()).\(name.lowercased())" }
    public var qualifiedName: String { "\(schema).\(name)" }
    public var quotedName: String { SQLIdentifier.quote(schema: schema, name: name) }

    public func column(_ name: String) -> DataColumnInfo? {
        columns.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }
}

public struct DataColumnInfo: Codable, Hashable, Sendable {
    public var name: String
    public var dataType: String
    public var isNullable: Bool
    public var isIdentity: Bool
    public var isComputed: Bool
    public var isTimestamp: Bool
    public var isLargeObject: Bool
    public var collation: String?
    /// GENERATED ALWAYS period columns of temporal tables.
    public var isGenerated: Bool
    /// Base system type, for user-defined alias types (`nvarchar(20)` for `dbo.Phone`).
    public var baseType: String

    public init(name: String, dataType: String, isNullable: Bool = true, isIdentity: Bool = false,
                isComputed: Bool = false, isTimestamp: Bool = false, isLargeObject: Bool = false,
                collation: String? = nil, isGenerated: Bool = false, baseType: String = "") {
        self.name = name
        self.dataType = dataType
        self.isNullable = isNullable
        self.isIdentity = isIdentity
        self.isComputed = isComputed
        self.isTimestamp = isTimestamp
        self.isLargeObject = isLargeObject
        self.collation = collation
        self.isGenerated = isGenerated
        self.baseType = baseType.isEmpty ? dataType : baseType
    }

    /// Columns SQL Server will not let an INSERT or UPDATE write.
    public var isReadOnly: Bool { isComputed || isTimestamp || isGenerated }
}

public struct DataKeyInfo: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case primaryKey
        case uniqueConstraint
        case uniqueIndex
    }

    public var kind: Kind
    public var name: String
    public var columns: [String]

    public init(kind: Kind, name: String, columns: [String]) {
        self.kind = kind
        self.name = name
        self.columns = columns
    }

    public var title: String {
        switch kind {
        case .primaryKey: return "Primary key \(name)"
        case .uniqueConstraint: return "Unique constraint \(name)"
        case .uniqueIndex: return "Unique index \(name)"
        }
    }
}

/// A foreign key between two tables of one database.
public struct DataForeignKeyInfo: Codable, Hashable, Sendable {
    public var name: String
    /// Lowercased `schema.name` of the table that owns the key, for matching.
    public var table: String
    public var referencedTable: String
    /// The owning table's name as written, for scripts.
    public var quotedTable: String
    public var isEnabled: Bool
    public var isTrusted: Bool

    public init(name: String, table: String, referencedTable: String, quotedTable: String, isEnabled: Bool,
                isTrusted: Bool) {
        self.name = name
        self.table = table
        self.referencedTable = referencedTable
        self.quotedTable = quotedTable
        self.isEnabled = isEnabled
        self.isTrusted = isTrusted
    }
}

// MARK: - Mapping

public struct DataColumnMapping: Codable, Hashable, Sendable, Identifiable {
    public var sourceColumn: String
    public var targetColumn: String
    public var isIncluded: Bool
    public var isKey: Bool
    public var source: DataColumnInfo
    public var target: DataColumnInfo

    public init(source: DataColumnInfo, target: DataColumnInfo, isIncluded: Bool = true, isKey: Bool = false) {
        self.sourceColumn = source.name
        self.targetColumn = target.name
        self.isIncluded = isIncluded
        self.isKey = isKey
        self.source = source
        self.target = target
    }

    public var id: String { sourceColumn.lowercased() + "->" + targetColumn.lowercased() }

    /// Different types mean values may need converting on the way.
    public var typesDiffer: Bool {
        source.dataType.lowercased() != target.dataType.lowercased()
    }
}

/// One source table paired with one target table.
public struct DataTableMapping: Codable, Hashable, Sendable, Identifiable {
    public enum KeySource: String, Codable, Sendable {
        case primaryKey
        case uniqueConstraint
        case uniqueIndex
        case custom
        case none
    }

    public var source: DataTableInfo
    public var target: DataTableInfo
    public var isIncluded: Bool
    public var columns: [DataColumnMapping]
    public var keySource: KeySource
    public var keyName: String
    public var sourceWhere: String
    public var targetWhere: String

    public init(source: DataTableInfo, target: DataTableInfo, isIncluded: Bool = true,
                columns: [DataColumnMapping] = [], keySource: KeySource = .none, keyName: String = "",
                sourceWhere: String = "", targetWhere: String = "") {
        self.source = source
        self.target = target
        self.isIncluded = isIncluded
        self.columns = columns
        self.keySource = keySource
        self.keyName = keyName
        self.sourceWhere = sourceWhere
        self.targetWhere = targetWhere
    }

    public var id: String { source.id + "=>" + target.id }
    public var displayName: String {
        source.qualifiedName.caseInsensitiveCompare(target.qualifiedName) == .orderedSame
            ? source.qualifiedName : "\(source.qualifiedName) → \(target.qualifiedName)"
    }

    public var keyColumns: [DataColumnMapping] { columns.filter(\.isKey) }
    /// Non-key columns that take part in the comparison.
    public var comparedColumns: [DataColumnMapping] { columns.filter { $0.isIncluded && !$0.isKey } }
    public var hasKey: Bool { !keyColumns.isEmpty }

    public var keyDescription: String {
        switch keySource {
        case .none: return "No comparison key"
        case .custom: return "Custom: " + keyColumns.map(\.sourceColumn).joined(separator: ", ")
        default: return keyName.isEmpty ? keyColumns.map(\.sourceColumn).joined(separator: ", ") : keyName
        }
    }
}

// MARK: - Results

public enum DataRowStatus: String, Codable, CaseIterable, Sendable {
    case different
    case onlyInSource
    case onlyInTarget
    case identical

    public var title: String {
        switch self {
        case .different: return "Different"
        case .onlyInSource: return "Only in source"
        case .onlyInTarget: return "Only in target"
        case .identical: return "Identical"
        }
    }
}

public struct DataRowDifference: Identifiable, Sendable, Hashable {
    public var id: Int
    public var status: DataRowStatus
    /// Values of the key columns, in mapping order.
    public var key: [TDSValue]
    /// Values of the compared (non-key) columns, in mapping order. nil on the side that has
    /// no such row.
    public var source: [TDSValue]?
    public var target: [TDSValue]?
    /// Positions in `source`/`target` whose values differ.
    public var differingColumns: [Int]
    public var isSelected: Bool

    public init(id: Int, status: DataRowStatus, key: [TDSValue], source: [TDSValue]?, target: [TDSValue]?,
                differingColumns: [Int] = [], isSelected: Bool = true) {
        self.id = id
        self.status = status
        self.key = key
        self.source = source
        self.target = target
        self.differingColumns = differingColumns
        self.isSelected = isSelected
    }
}

public struct DataTableResult: Identifiable, Sendable {
    public var mapping: DataTableMapping
    public var sourceRows: Int
    public var targetRows: Int
    public var identical: Int
    public var different: Int
    public var onlyInSource: Int
    public var onlyInTarget: Int
    public var rows: [DataRowDifference]
    /// Some rows were counted but not kept because of `maximumRowsKept`.
    public var isTruncated: Bool
    public var comparedByChecksum: Bool
    public var sourceIdentity: TDSValue?
    public var error: String?
    /// Things worth knowing that are not failures, e.g. duplicate key values.
    public var notes: [String]
    public var duration: TimeInterval
    /// Deploy this table's differences.
    public var isSelected: Bool

    public init(mapping: DataTableMapping) {
        self.mapping = mapping
        sourceRows = 0
        targetRows = 0
        identical = 0
        different = 0
        onlyInSource = 0
        onlyInTarget = 0
        rows = []
        isTruncated = false
        comparedByChecksum = false
        sourceIdentity = nil
        error = nil
        notes = []
        duration = 0
        isSelected = true
    }

    public var id: String { mapping.id }
    public var hasDifferences: Bool { different + onlyInSource + onlyInTarget > 0 }

    public func count(_ status: DataRowStatus) -> Int {
        switch status {
        case .different: return different
        case .onlyInSource: return onlyInSource
        case .onlyInTarget: return onlyInTarget
        case .identical: return identical
        }
    }

    /// Key columns then compared columns, the layout of `key + source/target`.
    public var columnNames: [String] {
        mapping.keyColumns.map(\.sourceColumn) + mapping.comparedColumns.map(\.sourceColumn)
    }
}

public struct DataComparison: Sendable {
    public var sourceDescription: String
    public var targetDescription: String
    public var sourceDatabase: String
    public var targetDatabase: String
    public var options: DataCompareOptions
    public var tables: [DataTableResult]
    /// Foreign keys in the target, for ordering and disabling during deployment.
    public var targetForeignKeys: [DataForeignKeyInfo]
    public var comparedAt: Date
    public var duration: TimeInterval

    public init(sourceDescription: String, targetDescription: String, sourceDatabase: String,
                targetDatabase: String, options: DataCompareOptions, tables: [DataTableResult],
                targetForeignKeys: [DataForeignKeyInfo] = [], comparedAt: Date = Date(),
                duration: TimeInterval = 0) {
        self.sourceDescription = sourceDescription
        self.targetDescription = targetDescription
        self.sourceDatabase = sourceDatabase
        self.targetDatabase = targetDatabase
        self.options = options
        self.tables = tables
        self.targetForeignKeys = targetForeignKeys
        self.comparedAt = comparedAt
        self.duration = duration
    }

    public var hasDifferences: Bool { tables.contains { $0.hasDifferences } }

    public func total(_ status: DataRowStatus) -> Int {
        tables.reduce(0) { $0 + $1.count(status) }
    }
}
