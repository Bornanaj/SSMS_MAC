import Foundation
import TDSKit

/// Reads the tables and views of a database the way Data Compare needs them: columns with
/// the traits that decide comparison and deployment, candidate comparison keys, enabled
/// triggers and foreign keys.
public struct DataCompareCatalog: Sendable {
    private let session: SQLServerSession

    public init(session: SQLServerSession) {
        self.session = session
    }

    public struct Contents: Sendable {
        public var tables: [DataTableInfo]
        public var foreignKeys: [DataForeignKeyInfo]
    }

    public func read(database: String, includeViews: Bool = true) async throws -> Contents {
        let types = includeViews ? "'U', 'V'" : "'U'"
        let sql = """
        SELECT o.object_id, SCHEMA_NAME(o.schema_id) AS schema_name, o.name, RTRIM(o.type) AS type,
               CONVERT(bigint, ISNULL((SELECT SUM(p.rows) FROM sys.partitions AS p
                                       WHERE p.object_id = o.object_id AND p.index_id IN (0, 1)), 0)) AS row_count
        FROM sys.objects AS o
        WHERE o.is_ms_shipped = 0 AND o.type IN (\(types))
          AND NOT EXISTS (SELECT 1 FROM sys.tables AS t WHERE t.object_id = o.object_id AND t.temporal_type = 1)
          AND NOT EXISTS (SELECT 1 FROM sys.extended_properties AS ep
                          WHERE ep.class = 1 AND ep.major_id = o.object_id AND ep.minor_id = 0
                            AND ep.name = N'microsoft_database_tools_support');

        SELECT c.object_id, c.column_id, c.name, t.name AS type_name, SCHEMA_NAME(t.schema_id) AS type_schema,
               CONVERT(int, t.is_user_defined) AS is_user_defined, bt.name AS base_name,
               CONVERT(int, c.max_length) AS max_length, CONVERT(int, c.precision) AS precision,
               CONVERT(int, c.scale) AS scale, CONVERT(int, c.is_nullable) AS is_nullable,
               CONVERT(int, c.is_identity) AS is_identity, CONVERT(int, c.is_computed) AS is_computed,
               ISNULL(c.collation_name, N'') AS collation_name,
               CONVERT(int, c.generated_always_type) AS generated_always_type
        FROM sys.columns AS c
        JOIN sys.types AS t ON t.user_type_id = c.user_type_id
        LEFT JOIN sys.types AS bt ON bt.user_type_id = t.system_type_id
        JOIN sys.objects AS o ON o.object_id = c.object_id AND o.is_ms_shipped = 0 AND o.type IN (\(types))
        ORDER BY c.object_id, c.column_id;

        SELECT i.object_id, i.index_id, i.name, CONVERT(int, i.is_primary_key) AS is_primary_key,
               CONVERT(int, i.is_unique_constraint) AS is_unique_constraint
        FROM sys.indexes AS i
        JOIN sys.objects AS o ON o.object_id = i.object_id AND o.is_ms_shipped = 0 AND o.type IN (\(types))
        WHERE i.is_unique = 1 AND i.has_filter = 0 AND i.is_disabled = 0 AND i.is_hypothetical = 0
          AND i.type IN (1, 2);

        SELECT ic.object_id, ic.index_id, c.name
        FROM sys.index_columns AS ic
        JOIN sys.indexes AS i ON i.object_id = ic.object_id AND i.index_id = ic.index_id AND i.is_unique = 1
        JOIN sys.columns AS c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
        JOIN sys.objects AS o ON o.object_id = ic.object_id AND o.is_ms_shipped = 0 AND o.type IN (\(types))
        WHERE ic.is_included_column = 0 AND ic.key_ordinal > 0
        ORDER BY ic.object_id, ic.index_id, ic.key_ordinal;

        SELECT tr.parent_id, tr.name
        FROM sys.triggers AS tr
        WHERE tr.parent_class = 1 AND tr.is_disabled = 0 AND tr.is_ms_shipped = 0;

        SELECT fk.name, SCHEMA_NAME(po.schema_id) AS parent_schema, po.name AS parent_name,
               SCHEMA_NAME(ro.schema_id) AS referenced_schema, ro.name AS referenced_name,
               CONVERT(int, fk.is_disabled) AS is_disabled, CONVERT(int, fk.is_not_trusted) AS is_not_trusted
        FROM sys.foreign_keys AS fk
        JOIN sys.objects AS po ON po.object_id = fk.parent_object_id
        JOIN sys.objects AS ro ON ro.object_id = fk.referenced_object_id;
        """
        let result = try await session.metadataQuery(sql, database: database)
        if let failure = result.errors.first(where: { $0.severity >= 11 }) { throw failure }
        let sets = result.resultSets.map { $0.dictionaries() }
        func set(_ index: Int) -> [[String: TDSValue]] { index < sets.count ? sets[index] : [] }

        var columns: [Int: [DataColumnInfo]] = [:]
        for row in set(1) {
            columns[row.int("object_id"), default: []].append(Self.column(row))
        }
        var indexColumns: [String: [String]] = [:]
        for row in set(3) {
            indexColumns["\(row.int("object_id"))/\(row.int("index_id"))", default: []].append(row.string("name"))
        }
        var keys: [Int: [DataKeyInfo]] = [:]
        for row in set(2) {
            let objectID = row.int("object_id")
            let kind: DataKeyInfo.Kind = row.bool("is_primary_key") ? .primaryKey
                : (row.bool("is_unique_constraint") ? .uniqueConstraint : .uniqueIndex)
            let members = indexColumns["\(objectID)/\(row.int("index_id"))"] ?? []
            keys[objectID, default: []].append(DataKeyInfo(kind: kind, name: row.string("name"), columns: members))
        }
        var triggers: [Int: [String]] = [:]
        for row in set(4) { triggers[row.int("parent_id"), default: []].append(row.string("name")) }

        var tables: [DataTableInfo] = []
        for row in set(0) {
            let objectID = row.int("object_id")
            let ordered = (keys[objectID] ?? []).sorted { lhs, rhs in
                Self.rank(lhs.kind) != Self.rank(rhs.kind) ? Self.rank(lhs.kind) < Self.rank(rhs.kind)
                    : lhs.name.lowercased() < rhs.name.lowercased()
            }
            tables.append(DataTableInfo(schema: row.string("schema_name"), name: row.string("name"),
                                        isView: row.string("type").uppercased() == "V",
                                        columns: columns[objectID] ?? [], keys: ordered,
                                        approximateRows: row.int64("row_count"),
                                        enabledTriggers: (triggers[objectID] ?? []).sorted()))
        }
        tables.sort { $0.qualifiedName.lowercased() < $1.qualifiedName.lowercased() }
        let foreignKeys = set(5).map { row in
            DataForeignKeyInfo(name: row.string("name"),
                               table: "\(row.string("parent_schema")).\(row.string("parent_name"))".lowercased(),
                               referencedTable: "\(row.string("referenced_schema")).\(row.string("referenced_name"))"
                                   .lowercased(),
                               quotedTable: SQLIdentifier.quote(schema: row.string("parent_schema"),
                                                                name: row.string("parent_name")),
                               isEnabled: !row.bool("is_disabled"), isTrusted: !row.bool("is_not_trusted"))
        }
        return Contents(tables: tables, foreignKeys: foreignKeys)
    }

    private static func rank(_ kind: DataKeyInfo.Kind) -> Int {
        switch kind {
        case .primaryKey: return 0
        case .uniqueConstraint: return 1
        case .uniqueIndex: return 2
        }
    }

    static func column(_ row: [String: TDSValue]) -> DataColumnInfo {
        let dataType = LiveSchemaReader.formatType(name: row.string("type_name"), schema: row.string("type_schema"),
                                                   isUserDefined: row.bool("is_user_defined"),
                                                   maxLength: row.int("max_length"), precision: row.int("precision"),
                                                   scale: row.int("scale"))
        let baseName = row.string("base_name", default: row.string("type_name"))
        let baseType = LiveSchemaReader.formatType(name: baseName, schema: "", isUserDefined: false,
                                                   maxLength: row.int("max_length"), precision: row.int("precision"),
                                                   scale: row.int("scale"))
        let lowered = baseName.lowercased()
        let isTimestamp = lowered == "timestamp" || lowered == "rowversion"
        let isLob = ["text", "ntext", "image", "xml", "geography", "geometry"].contains(lowered)
            || row.int("max_length") == -1
        let collation = row.string("collation_name")
        return DataColumnInfo(name: row.string("name"), dataType: dataType, isNullable: row.bool("is_nullable"),
                              isIdentity: row.bool("is_identity"), isComputed: row.bool("is_computed"),
                              isTimestamp: isTimestamp, isLargeObject: isLob,
                              collation: collation.isEmpty ? nil : collation,
                              isGenerated: row.int("generated_always_type") != 0, baseType: baseType)
    }
}

// MARK: - Mapping

/// Pairs source and target tables, their columns and a comparison key automatically, the way
/// Data Compare's Tables & Views page does before the user adjusts anything.
public enum DataCompareMapper {

    public struct Result: Sendable {
        public var mappings: [DataTableMapping]
        public var unmatchedSource: [DataTableInfo]
        public var unmatchedTarget: [DataTableInfo]
    }

    public static func map(source: [DataTableInfo], target: [DataTableInfo],
                           schemaMappings: [SchemaNameMapping] = [], tablePairs: [String: String] = [:],
                           options: DataCompareOptions = DataCompareOptions()) -> Result {
        var targetByName: [String: DataTableInfo] = [:]
        for table in target { targetByName[table.id] = table }
        var used: Set<String> = []
        var mappings: [DataTableMapping] = []
        var unmatchedSource: [DataTableInfo] = []
        for table in source {
            if table.isView && !options.includeViews { continue }
            var wanted = table.id
            if let explicit = tablePairs[table.qualifiedName] ?? tablePairs[table.id] {
                wanted = explicit.lowercased()
            } else if let mapped = schemaMappings.first(where: {
                $0.source.caseInsensitiveCompare(table.schema) == .orderedSame
            }) {
                wanted = "\(mapped.target.lowercased()).\(table.name.lowercased())"
            }
            guard let other = targetByName[wanted], !used.contains(other.id) else {
                unmatchedSource.append(table)
                continue
            }
            used.insert(other.id)
            var mapping = DataTableMapping(source: table, target: other)
            mapColumns(&mapping, options: options)
            chooseKey(&mapping)
            mapping.isIncluded = mapping.hasKey
            mappings.append(mapping)
        }
        let unmatchedTarget = target.filter { !used.contains($0.id) && (!$0.isView || options.includeViews) }
        return Result(mappings: mappings, unmatchedSource: unmatchedSource, unmatchedTarget: unmatchedTarget)
    }

    /// Columns paired by name; those that should not be compared by default start excluded.
    public static func mapColumns(_ mapping: inout DataTableMapping, options: DataCompareOptions) {
        var columns: [DataColumnMapping] = []
        for column in mapping.source.columns {
            guard let other = mapping.target.column(column.name) else { continue }
            var pair = DataColumnMapping(source: column, target: other)
            pair.isIncluded = defaultInclusion(column, other, options: options)
            columns.append(pair)
        }
        mapping.columns = columns
    }

    static func defaultInclusion(_ source: DataColumnInfo, _ target: DataColumnInfo,
                                 options: DataCompareOptions) -> Bool {
        if (source.isTimestamp || target.isTimestamp) && !options.includeTimestampColumns { return false }
        if (source.isComputed || target.isComputed) && !options.includeComputedColumns { return false }
        if source.isGenerated || target.isGenerated { return false }
        if (source.isIdentity || target.isIdentity) && !options.includeIdentityColumns { return false }
        if (source.isLargeObject || target.isLargeObject) && options.ignoreLargeObjects { return false }
        return true
    }

    /// The primary key if both sides can use it, else the first unique constraint or index
    /// whose columns exist on both sides.
    public static func chooseKey(_ mapping: inout DataTableMapping) {
        for index in mapping.columns.indices { mapping.columns[index].isKey = false }
        let mapped = Set(mapping.columns.map { $0.sourceColumn.lowercased() })
        for key in mapping.source.keys {
            let columns = key.columns.map { $0.lowercased() }
            guard !columns.isEmpty, columns.allSatisfy({ mapped.contains($0) }) else { continue }
            let usable = mapping.columns.filter { columns.contains($0.sourceColumn.lowercased()) }
            guard usable.allSatisfy({ !$0.source.isLargeObject && !$0.target.isLargeObject }) else { continue }
            setKey(&mapping, columns: key.columns)
            switch key.kind {
            case .primaryKey: mapping.keySource = .primaryKey
            case .uniqueConstraint: mapping.keySource = .uniqueConstraint
            case .uniqueIndex: mapping.keySource = .uniqueIndex
            }
            mapping.keyName = key.name
            return
        }
        // Views often have no key of their own; the target's may still apply.
        for key in mapping.target.keys {
            let names = key.columns.compactMap { name in
                mapping.columns.first { $0.targetColumn.caseInsensitiveCompare(name) == .orderedSame }?.sourceColumn
            }
            guard names.count == key.columns.count, !names.isEmpty else { continue }
            setKey(&mapping, columns: names)
            mapping.keySource = key.kind == .primaryKey ? .primaryKey : .uniqueIndex
            mapping.keyName = key.name
            return
        }
        mapping.keySource = .none
        mapping.keyName = ""
    }

    /// Use `columns` (source names) as the comparison key.
    public static func setCustomKey(_ mapping: inout DataTableMapping, columns: [String]) {
        for index in mapping.columns.indices { mapping.columns[index].isKey = false }
        setKey(&mapping, columns: columns)
        mapping.keySource = mapping.hasKey ? .custom : .none
        mapping.keyName = ""
    }

    private static func setKey(_ mapping: inout DataTableMapping, columns: [String]) {
        // Key columns go first, in key order.
        var keyed: [DataColumnMapping] = []
        var rest = mapping.columns
        for name in columns {
            guard let index = rest.firstIndex(where: { $0.sourceColumn.caseInsensitiveCompare(name) == .orderedSame })
            else { continue }
            var column = rest.remove(at: index)
            column.isKey = true
            column.isIncluded = true
            keyed.append(column)
        }
        mapping.columns = keyed + rest
    }

    /// Re-applies saved per-table choices after the catalog has been read again.
    public static func apply(_ settings: [DataTableSettings], to mappings: inout [DataTableMapping]) {
        var byID: [String: DataTableSettings] = [:]
        for setting in settings { byID[setting.mappingID] = setting }
        for index in mappings.indices {
            guard let setting = byID[mappings[index].id] else { continue }
            mappings[index].isIncluded = setting.isIncluded
            mappings[index].sourceWhere = setting.sourceWhere
            mappings[index].targetWhere = setting.targetWhere
            if !setting.keyColumns.isEmpty { setCustomKey(&mappings[index], columns: setting.keyColumns) }
            let excluded = Set(setting.excludedColumns.map { $0.lowercased() })
            for column in mappings[index].columns.indices where !mappings[index].columns[column].isKey {
                mappings[index].columns[column].isIncluded = !excluded.contains(
                    mappings[index].columns[column].sourceColumn.lowercased())
            }
        }
    }
}
