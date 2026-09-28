import Foundation

/// One side of a comparison: a live database, a snapshot file or a scripts folder.
public struct CompareEndpoint: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case database
        case snapshot
        case scriptsFolder

        public var title: String {
            switch self {
            case .database: return "Database"
            case .snapshot: return "Snapshot"
            case .scriptsFolder: return "Scripts folder"
            }
        }
    }

    public var kind: Kind
    /// For databases: the saved connection, without its password (that stays in the keychain).
    public var connection: ConnectionProfile?
    public var database: String
    /// For snapshots and scripts folders.
    public var path: String

    public init(kind: Kind = .database, connection: ConnectionProfile? = nil, database: String = "",
                path: String = "") {
        self.kind = kind
        self.connection = connection
        self.database = database
        self.path = path
    }

    public var displayName: String {
        switch kind {
        case .database:
            let server = connection?.displayName ?? "(no server)"
            return database.isEmpty ? server : "\(server) · \(database)"
        case .snapshot, .scriptsFolder:
            return path.isEmpty ? "(not chosen)" : URL(fileURLWithPath: path).lastPathComponent
        }
    }

    public var isComplete: Bool {
        switch kind {
        case .database: return connection != nil && !database.isEmpty
        case .snapshot, .scriptsFolder: return !path.isEmpty
        }
    }
}

public struct SchemaProjectSettings: Codable, Hashable, Sendable {
    public var options: SchemaCompareOptions
    public var filter: SchemaFilter
    public var mappings: SchemaMappings
    /// Differences the user unticked, by difference ID, so a reopened project deploys the
    /// same selection.
    public var deselected: Set<String>

    public init(options: SchemaCompareOptions = SchemaCompareOptions(), filter: SchemaFilter = SchemaFilter(),
                mappings: SchemaMappings = SchemaMappings(), deselected: Set<String> = []) {
        self.options = options
        self.filter = filter
        self.mappings = mappings
        self.deselected = deselected
    }
}

/// Per-table choices that survive re-reading the catalog: inclusion, key, column choices
/// and WHERE clauses, keyed by the mapping ID.
public struct DataTableSettings: Codable, Hashable, Sendable {
    public var mappingID: String
    public var sourceTable: String
    public var targetTable: String
    public var isIncluded: Bool
    public var keyColumns: [String]
    public var excludedColumns: [String]
    public var sourceWhere: String
    public var targetWhere: String

    public init(mapping: DataTableMapping) {
        mappingID = mapping.id
        sourceTable = mapping.source.qualifiedName
        targetTable = mapping.target.qualifiedName
        isIncluded = mapping.isIncluded
        keyColumns = mapping.keySource == .custom ? mapping.keyColumns.map(\.sourceColumn) : []
        excludedColumns = mapping.columns.filter { !$0.isIncluded && !$0.isKey }.map(\.sourceColumn)
        sourceWhere = mapping.sourceWhere
        targetWhere = mapping.targetWhere
    }
}

public struct DataProjectSettings: Codable, Hashable, Sendable {
    public var options: DataCompareOptions
    public var schemaMappings: [SchemaNameMapping]
    public var tables: [DataTableSettings]
    /// Explicit pairs for tables whose names differ, as `source -> target` qualified names.
    public var tablePairs: [String: String]

    public init(options: DataCompareOptions = DataCompareOptions(), schemaMappings: [SchemaNameMapping] = [],
                tables: [DataTableSettings] = [], tablePairs: [String: String] = [:]) {
        self.options = options
        self.schemaMappings = schemaMappings
        self.tables = tables
        self.tablePairs = tablePairs
    }
}

/// A saved comparison: what is compared with what, and every choice made along the way.
public struct CompareProject: Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case schema
        case data

        public var fileExtension: String { self == .schema ? "scmp" : "dcmp" }
    }

    public static let formatVersion = 1

    public var formatVersion: Int
    public var kind: Kind
    public var name: String
    public var source: CompareEndpoint
    public var target: CompareEndpoint
    public var schema: SchemaProjectSettings?
    public var data: DataProjectSettings?
    public var savedAt: Date

    public init(kind: Kind, name: String = "", source: CompareEndpoint = CompareEndpoint(),
                target: CompareEndpoint = CompareEndpoint(), schema: SchemaProjectSettings? = nil,
                data: DataProjectSettings? = nil) {
        self.formatVersion = CompareProject.formatVersion
        self.kind = kind
        self.name = name
        self.source = source
        self.target = target
        self.schema = schema ?? (kind == .schema ? SchemaProjectSettings() : nil)
        self.data = data ?? (kind == .data ? DataProjectSettings() : nil)
        self.savedAt = Date()
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> CompareProject {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(CompareProject.self, from: data)
    }

    public func write(to url: URL) throws {
        var copy = self
        copy.savedAt = Date()
        try copy.encoded().write(to: url, options: .atomic)
    }

    public static func read(from url: URL) throws -> CompareProject {
        try decode(Data(contentsOf: url))
    }
}
