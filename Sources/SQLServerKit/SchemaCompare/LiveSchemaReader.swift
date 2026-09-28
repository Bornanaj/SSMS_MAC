import Foundation
import TDSKit

/// Reads a live database into a `SchemaSnapshot`.
///
/// Each object category is loaded with one catalog query for the whole database rather than
/// one query per object, so a database with thousands of objects is read in a few dozen
/// round trips. A category that cannot be read — a catalog view that does not exist on Azure
/// SQL Database, a permission that is missing — is recorded as a warning instead of failing
/// the read.
public struct LiveSchemaReader: Sendable {

    private let session: SQLServerSession

    public init(session: SQLServerSession) {
        self.session = session
    }

    public typealias Progress = @Sendable (Double, String) -> Void

    // MARK: - Entry point

    public func read(database: String, progress: Progress? = nil) async throws -> SchemaSnapshot {
        let info = await session.serverInfo
        var context = ReadContext(database: database, majorVersion: info.majorVersion,
                                  isAzure: info.isAzureSQLDatabase)
        context.origin = "\(info.serverName)/\(database)"

        let steps: [(String, (inout ReadContext) async throws -> Void)] = [
            ("database", { try await readDatabaseInfo(&$0) }),
            ("objects", { try await readObjects(&$0) }),
            ("principals", { try await readPrincipals(&$0) }),
            ("schemas", { try await readSchemas(&$0) }),
            ("columns", { try await readColumns(&$0) }),
            ("tables", { try await readTables(&$0) }),
            ("indexes", { try await readIndexes(&$0) }),
            ("constraints", { try await readConstraints(&$0) }),
            ("foreign keys", { try await readForeignKeys(&$0) }),
            ("modules", { try await readModules(&$0) }),
            ("CLR modules", { try await readCLRModules(&$0) }),
            ("triggers", { try await readTriggers(&$0) }),
            ("statistics", { try await readStatistics(&$0) }),
            ("synonyms", { try await readSynonyms(&$0) }),
            ("sequences", { try await readSequences(&$0) }),
            ("types", { try await readTypes(&$0) }),
            ("table types", { try await readTableTypes(&$0) }),
            ("XML schema collections", { try await readXmlSchemaCollections(&$0) }),
            ("partitioning", { try await readPartitioning(&$0) }),
            ("assemblies", { try await readAssemblies(&$0) }),
            ("full-text", { try await readFullText(&$0) }),
            ("security policies", { try await readSecurityPolicies(&$0) }),
            ("service broker", { try await readServiceBroker(&$0) }),
            ("permissions", { try await readPermissions(&$0) }),
            ("extended properties", { try await readExtendedProperties(&$0) }),
            ("dependencies", { try await readDependencies(&$0) })
        ]

        for (offset, step) in steps.enumerated() {
            try Task.checkCancellation()
            progress?(Double(offset) / Double(steps.count), "Reading \(step.0)")
            do {
                try await step.1(&context)
            } catch let error as CancellationError {
                throw error
            } catch {
                // Without the database and its object list there is nothing to compare.
                if offset < 2 { throw error }
                context.warnings.append("Could not read \(step.0): \(Self.describe(error))")
            }
        }
        progress?(1, "Done")
        return context.snapshot()
    }

    static func describe(_ error: Error) -> String {
        if let message = error as? TDSServerMessage { return message.text }
        return String(describing: error)
    }

    // MARK: - Query helper

    private func rows(_ sql: String, _ context: ReadContext) async throws -> [[String: TDSValue]] {
        let result = try await session.metadataQuery(sql, database: context.database)
        if let failure = result.errors.first(where: { $0.severity >= 11 }) { throw failure }
        return result.resultSets.first?.dictionaries() ?? []
    }

    private func resultSets(_ sql: String, _ context: ReadContext) async throws -> [[[String: TDSValue]]] {
        let result = try await session.metadataQuery(sql, database: context.database)
        if let failure = result.errors.first(where: { $0.severity >= 11 }) { throw failure }
        return result.resultSets.map { $0.dictionaries() }
    }

    // MARK: - Database and objects

    private func readDatabaseInfo(_ context: inout ReadContext) async throws {
        let sql = """
        SELECT DB_NAME() AS db_name,
               CONVERT(nvarchar(128), DATABASEPROPERTYEX(DB_NAME(), 'Collation')) AS collation_name,
               CONVERT(int, d.compatibility_level) AS compatibility_level,
               CONVERT(nvarchar(128), SERVERPROPERTY('ProductVersion')) AS product_version
        FROM sys.databases AS d
        WHERE d.database_id = DB_ID();
        """
        guard let row = try await rows(sql, context).first else {
            throw SQLServerError.objectNotFound(context.database)
        }
        context.databaseName = row.string("db_name", default: context.database)
        context.collation = row.string("collation_name")
        context.compatibilityLevel = row.int("compatibility_level")
        context.serverVersion = row.string("product_version")
    }

    private func readObjects(_ context: inout ReadContext) async throws {
        let sql = """
        SELECT o.object_id, o.name, SCHEMA_NAME(o.schema_id) AS schema_name, RTRIM(o.type) AS type,
               o.parent_object_id, ISNULL(USER_NAME(o.principal_id), N'') AS owner_name,
               CONVERT(int, CASE WHEN EXISTS (
                   SELECT 1 FROM sys.extended_properties AS ep
                   WHERE ep.class = 1 AND ep.major_id = o.object_id AND ep.minor_id = 0
                     AND ep.name = N'microsoft_database_tools_support') THEN 1 ELSE 0 END) AS is_tools,
               CONVERT(int, ISNULL(OBJECTPROPERTY(o.object_id, 'IsEncrypted'), 0)) AS is_encrypted
        FROM sys.objects AS o
        WHERE o.is_ms_shipped = 0;
        """
        for row in try await rows(sql, context) {
            let id = row.int("object_id")
            let type = row.string("type").uppercased()
            let entry = ObjectRow(id: id, name: row.string("name"), schema: row.string("schema_name"),
                                  type: type, parentID: row.int("parent_object_id"),
                                  owner: row.string("owner_name"), isTools: row.bool("is_tools"),
                                  isEncrypted: row.bool("is_encrypted"))
            context.objectRows[id] = entry
            if entry.isTools { continue }

            let objectType: SchemaObjectType?
            switch type {
            case "U": objectType = .table
            case "V": objectType = .view
            case "P", "PC": objectType = .storedProcedure
            case "FN", "IF", "TF", "FS", "FT", "AF": objectType = .function
            case "SN": objectType = .synonym
            case "SO": objectType = .sequence
            case "R": objectType = .rule
            case "D" where entry.parentID == 0: objectType = .defaultObject
            case "SQ": objectType = .queue
            case "SP": objectType = .securityPolicy
            default: objectType = nil
            }
            guard let objectType else { continue }
            var object = SchemaObject(type: objectType, schema: entry.schema, name: entry.name)
            object.subtype = objectType == .function || objectType == .storedProcedure ? type : ""
            if !entry.owner.isEmpty { object.owner = entry.owner }
            object.isEncrypted = entry.isEncrypted
            if objectType == .table { object.table = TableDefinition() }
            context.add(object, objectID: id)
        }
    }

    // MARK: - Principals and schemas

    private func readPrincipals(_ context: inout ReadContext) async throws {
        let sql = """
        SELECT dp.principal_id, dp.name, dp.type, ISNULL(dp.default_schema_name, N'') AS default_schema,
               ISNULL(dp.authentication_type_desc, N'') AS authentication_type,
               ISNULL(SUSER_SNAME(dp.sid), N'') AS login_name,
               ISNULL(owner.name, N'') AS owner_name,
               ISNULL(c.name, N'') AS certificate_name,
               ISNULL(ak.name, N'') AS asymmetric_key_name
        FROM sys.database_principals AS dp
        LEFT JOIN sys.database_principals AS owner ON owner.principal_id = dp.owning_principal_id
        LEFT JOIN sys.certificates AS c ON c.sid = dp.sid AND dp.type = 'C'
        LEFT JOIN sys.asymmetric_keys AS ak ON ak.sid = dp.sid AND dp.type = 'K'
        WHERE dp.principal_id > 4 AND dp.principal_id < 16384
          AND dp.is_fixed_role = 0 AND dp.name <> N'public'
          AND dp.type IN ('S', 'U', 'G', 'E', 'X', 'C', 'K', 'R', 'A');

        SELECT r.name AS role_name, m.principal_id AS member_id
        FROM sys.database_role_members AS rm
        JOIN sys.database_principals AS r ON r.principal_id = rm.role_principal_id
        JOIN sys.database_principals AS m ON m.principal_id = rm.member_principal_id
        WHERE m.principal_id > 4;
        """
        let sets = try await resultSets(sql, context)
        for row in sets.first ?? [] {
            let id = row.int("principal_id")
            let name = row.string("name")
            let type = row.string("type").trimmingCharacters(in: .whitespaces).uppercased()
            context.principalNames[id] = name
            var object: SchemaObject
            switch type {
            case "R":
                object = SchemaObject(type: .role, schema: "", name: name)
                let owner = row.string("owner_name")
                object.owner = owner.isEmpty ? "dbo" : owner
            case "A":
                object = SchemaObject(type: .applicationRole, schema: "", name: name)
                var body = "CREATE APPLICATION ROLE \(SQLIdentifier.quote(name)) WITH PASSWORD = N'<password>'"
                let schema = row.string("default_schema")
                if !schema.isEmpty { body += ", DEFAULT_SCHEMA = \(SQLIdentifier.quote(schema))" }
                object.body = body
            default:
                object = SchemaObject(type: .user, schema: "", name: name)
                object.body = Self.userBody(name: name, type: type,
                                            authentication: row.string("authentication_type"),
                                            login: row.string("login_name"),
                                            defaultSchema: row.string("default_schema"),
                                            certificate: row.string("certificate_name"),
                                            asymmetricKey: row.string("asymmetric_key_name"))
            }
            context.add(object, principalID: id)
        }
        for row in sets.count > 1 ? sets[1] : [] {
            let memberID = row.int("member_id")
            guard let key = context.principalKeys[memberID] else { continue }
            context.mutate(key) { $0.roleMemberships.append(row.string("role_name")) }
        }
    }

    static func userBody(name: String, type: String, authentication: String, login: String,
                         defaultSchema: String, certificate: String, asymmetricKey: String) -> String {
        let quoted = SQLIdentifier.quote(name)
        var body: String
        var withClauses: [String] = []
        switch (type, authentication.uppercased()) {
        case ("C", _):
            return "CREATE USER \(quoted) FOR CERTIFICATE \(SQLIdentifier.quote(certificate))"
        case ("K", _):
            return "CREATE USER \(quoted) FOR ASYMMETRIC KEY \(SQLIdentifier.quote(asymmetricKey))"
        case ("E", _), ("X", _), (_, "EXTERNAL"):
            body = "CREATE USER \(quoted) FROM EXTERNAL PROVIDER"
        case (_, "NONE"):
            body = "CREATE USER \(quoted) WITHOUT LOGIN"
        case (_, "DATABASE"):
            body = "CREATE USER \(quoted)"
            withClauses.append("PASSWORD = N'<password>'")
        default:
            body = login.isEmpty ? "CREATE USER \(quoted) WITHOUT LOGIN"
                : "CREATE USER \(quoted) FOR LOGIN \(SQLIdentifier.quote(login))"
        }
        if !defaultSchema.isEmpty {
            withClauses.append("DEFAULT_SCHEMA = \(SQLIdentifier.quote(defaultSchema))")
        }
        if !withClauses.isEmpty { body += " WITH " + withClauses.joined(separator: ", ") }
        return body
    }

    private func readSchemas(_ context: inout ReadContext) async throws {
        let sql = """
        SELECT s.schema_id, s.name, ISNULL(p.name, N'dbo') AS owner_name
        FROM sys.schemas AS s
        LEFT JOIN sys.database_principals AS p ON p.principal_id = s.principal_id
        WHERE s.schema_id > 4 AND s.schema_id < 16384;
        """
        for row in try await rows(sql, context) {
            var object = SchemaObject(type: .schema, schema: "", name: row.string("name"))
            object.owner = row.string("owner_name", default: "dbo")
            context.add(object, schemaID: row.int("schema_id"))
        }
    }

    // MARK: - Columns and tables

    private func readColumns(_ context: inout ReadContext) async throws {
        let sql = """
        SELECT c.object_id, c.column_id, c.name, t.name AS type_name,
               SCHEMA_NAME(t.schema_id) AS type_schema, CONVERT(int, t.is_user_defined) AS is_user_defined,
               CONVERT(int, c.max_length) AS max_length, CONVERT(int, c.precision) AS precision,
               CONVERT(int, c.scale) AS scale, CONVERT(int, c.is_nullable) AS is_nullable,
               CONVERT(int, c.is_identity) AS is_identity, CONVERT(int, c.is_rowguidcol) AS is_rowguidcol,
               CONVERT(int, c.is_filestream) AS is_filestream, CONVERT(int, c.is_sparse) AS is_sparse,
               CONVERT(int, c.is_column_set) AS is_column_set, ISNULL(c.collation_name, N'') AS collation_name,
               CONVERT(nvarchar(max), cc.definition) AS computed_definition,
               CONVERT(int, ISNULL(cc.is_persisted, 0)) AS is_persisted, CONVERT(int, c.is_computed) AS is_computed,
               CONVERT(nvarchar(64), ic.seed_value) AS seed_value,
               CONVERT(nvarchar(64), ic.increment_value) AS increment_value,
               CONVERT(int, ISNULL(ic.is_not_for_replication, 0)) AS identity_nfr,
               dc.name AS default_name, CONVERT(nvarchar(max), dc.definition) AS default_definition,
               CONVERT(int, ISNULL(dc.is_system_named, 0)) AS default_system_named,
               CONVERT(int, c.generated_always_type) AS generated_always_type,
               CONVERT(int, c.is_hidden) AS is_hidden,
               CONVERT(nvarchar(4000), mc.masking_function) AS masking_function,
               xsc.name AS xml_collection, SCHEMA_NAME(xsc.schema_id) AS xml_collection_schema,
               CONVERT(int, c.is_xml_document) AS is_xml_document,
               ro.name AS rule_name, SCHEMA_NAME(ro.schema_id) AS rule_schema,
               bd.name AS bound_default_name, SCHEMA_NAME(bd.schema_id) AS bound_default_schema
        FROM sys.columns AS c
        JOIN sys.types AS t ON t.user_type_id = c.user_type_id
        LEFT JOIN sys.computed_columns AS cc ON cc.object_id = c.object_id AND cc.column_id = c.column_id
        LEFT JOIN sys.identity_columns AS ic ON ic.object_id = c.object_id AND ic.column_id = c.column_id
        LEFT JOIN sys.default_constraints AS dc ON dc.object_id = c.default_object_id
        LEFT JOIN sys.masked_columns AS mc ON mc.object_id = c.object_id AND mc.column_id = c.column_id
        LEFT JOIN sys.xml_schema_collections AS xsc
               ON xsc.xml_collection_id = c.xml_collection_id AND c.xml_collection_id <> 0
        LEFT JOIN sys.objects AS ro ON ro.object_id = c.rule_object_id AND c.rule_object_id <> 0
        LEFT JOIN sys.objects AS bd ON bd.object_id = c.default_object_id AND bd.type = 'D'
              AND bd.parent_object_id = 0
        WHERE c.object_id IN (SELECT object_id FROM sys.tables WHERE is_ms_shipped = 0
                              UNION ALL SELECT type_table_object_id FROM sys.table_types)
        ORDER BY c.object_id, c.column_id;
        """
        for row in try await rows(sql, context) {
            let objectID = row.int("object_id")
            let column = Self.column(from: row)
            context.columnsByObject[objectID, default: []].append(column)
            context.columnNames[ColumnID(object: objectID, column: row.int("column_id"))] = column.name
            if let key = context.objectKeys[objectID], key.type == .table {
                context.mutate(key) { $0.table?.columns.append(column) }
                if column.isUserDefinedType {
                    let typeSchema = row.string("type_schema")
                    let typeName = row.string("type_name")
                    context.pendingTypeReferences.append((key, typeSchema, typeName))
                }
                if let xml = row["xml_collection"], !xml.isNull {
                    context.addReference(from: key, to: SchemaObjectKey(
                        type: .xmlSchemaCollection, schema: row.string("xml_collection_schema"),
                        name: row.string("xml_collection")))
                }
                if column.boundRule != nil {
                    context.addReference(from: key, to: SchemaObjectKey(
                        type: .rule, schema: row.string("rule_schema"), name: row.string("rule_name")))
                }
                if column.boundDefault != nil {
                    context.addReference(from: key, to: SchemaObjectKey(
                        type: .defaultObject, schema: row.string("bound_default_schema"),
                        name: row.string("bound_default_name")))
                }
            }
        }
    }

    static func column(from row: [String: TDSValue]) -> ColumnDefinition {
        let isUserDefined = row.bool("is_user_defined")
        var dataType = Self.formatType(name: row.string("type_name"), schema: row.string("type_schema"),
                                  isUserDefined: isUserDefined, maxLength: row.int("max_length"),
                                  precision: row.int("precision"), scale: row.int("scale"))
        if let xml = row["xml_collection"], !xml.isNull {
            let collection = SQLIdentifier.quote(schema: row.string("xml_collection_schema"),
                                                 name: row.string("xml_collection"))
            dataType = "xml(\(row.bool("is_xml_document") ? "DOCUMENT" : "CONTENT") \(collection))"
        }
        var column = ColumnDefinition(name: row.string("name"), dataType: dataType,
                                      isUserDefinedType: isUserDefined,
                                      isNullable: row.bool("is_nullable"))
        let collation = row.string("collation_name")
        column.collation = collation.isEmpty ? nil : collation
        if row.bool("is_identity") {
            column.identity = IdentitySpec(seed: row.string("seed_value", default: "1"),
                                           increment: row.string("increment_value", default: "1"),
                                           notForReplication: row.bool("identity_nfr"))
        }
        if row.bool("is_computed") {
            column.computedExpression = row.string("computed_definition")
            column.isPersisted = row.bool("is_persisted")
            column.collation = nil
        }
        if let name = row["default_name"], !name.isNull {
            column.defaultConstraint = DefaultConstraintDefinition(
                name: row.string("default_name"), definition: row.string("default_definition"),
                isSystemNamed: row.bool("default_system_named"))
        }
        column.isRowGuidCol = row.bool("is_rowguidcol")
        column.isFileStream = row.bool("is_filestream")
        column.isSparse = row.bool("is_sparse")
        column.isColumnSet = row.bool("is_column_set")
        switch row.int("generated_always_type") {
        case 1: column.generatedAlways = "ROW START"
        case 2: column.generatedAlways = "ROW END"
        default: break
        }
        column.isHidden = row.bool("is_hidden")
        let mask = row.string("masking_function")
        column.maskingFunction = mask.isEmpty ? nil : mask
        if let rule = row["rule_name"], !rule.isNull {
            column.boundRule = SQLIdentifier.quote(schema: row.string("rule_schema"), name: row.string("rule_name"))
        }
        if let bound = row["bound_default_name"], !bound.isNull {
            column.boundDefault = SQLIdentifier.quote(schema: row.string("bound_default_schema"),
                                                      name: row.string("bound_default_name"))
        }
        return column
    }

    /// Type text the way it appears in a column definition.
    public static func formatType(name: String, schema: String, isUserDefined: Bool,
                                  maxLength: Int, precision: Int, scale: Int) -> String {
        if isUserDefined { return SQLIdentifier.quote(schema: schema, name: name) }
        let lowered = name.lowercased()
        switch lowered {
        case "nvarchar", "nchar":
            return maxLength == -1 ? "\(lowered)(max)" : "\(lowered)(\(maxLength / 2))"
        case "varchar", "char", "varbinary", "binary":
            return maxLength == -1 ? "\(lowered)(max)" : "\(lowered)(\(maxLength))"
        case "decimal", "numeric":
            return "\(lowered)(\(precision),\(scale))"
        case "datetime2", "datetimeoffset", "time":
            return "\(lowered)(\(scale))"
        case "float":
            return precision == 53 || precision == 0 ? "float" : "float(\(precision))"
        default:
            return lowered
        }
    }

    private func readTables(_ context: inout ReadContext) async throws {
        let sql = """
        SELECT t.object_id, t.lock_escalation_desc, CONVERT(int, t.is_memory_optimized) AS is_memory_optimized,
               t.durability_desc, CONVERT(int, t.temporal_type) AS temporal_type, t.history_table_id,
               ds.name AS data_space, lob.name AS lob_data_space,
               (SELECT TOP (1) p.data_compression_desc FROM sys.partitions AS p
                 WHERE p.object_id = t.object_id AND p.index_id IN (0, 1)
                 ORDER BY p.partition_number) AS data_compression,
               (SELECT TOP (1) pc.name FROM sys.index_columns AS pic
                  JOIN sys.columns AS pc ON pc.object_id = pic.object_id AND pc.column_id = pic.column_id
                 WHERE pic.object_id = t.object_id AND pic.index_id IN (0, 1)
                   AND pic.partition_ordinal = 1) AS partition_column,
               CONVERT(int, CASE WHEN ctt.object_id IS NULL THEN 0 ELSE 1 END) AS change_tracking,
               CONVERT(int, ISNULL(ctt.is_track_columns_updated_on, 0)) AS track_columns,
               per.start_column_id, per.end_column_id
        FROM sys.tables AS t
        LEFT JOIN sys.indexes AS i ON i.object_id = t.object_id AND i.index_id IN (0, 1)
        LEFT JOIN sys.data_spaces AS ds ON ds.data_space_id = i.data_space_id
        LEFT JOIN sys.data_spaces AS lob ON lob.data_space_id = t.lob_data_space_id
              AND t.lob_data_space_id <> 0
        LEFT JOIN sys.change_tracking_tables AS ctt ON ctt.object_id = t.object_id
        LEFT JOIN sys.periods AS per ON per.object_id = t.object_id
        WHERE t.is_ms_shipped = 0;
        """
        for row in try await rows(sql, context) {
            let objectID = row.int("object_id")
            guard let key = context.objectKeys[objectID], key.type == .table else { continue }
            let memoryOptimized = row.bool("is_memory_optimized")
            var temporal: TemporalDefinition?
            if let startID = row["start_column_id"], !startID.isNull {
                let start = context.columnNames[ColumnID(object: objectID, column: row.int("start_column_id"))] ?? ""
                let end = context.columnNames[ColumnID(object: objectID, column: row.int("end_column_id"))] ?? ""
                temporal = TemporalDefinition(periodStartColumn: start, periodEndColumn: end)
                if row.int("temporal_type") == 2, let history = context.objectRows[row.int("history_table_id")] {
                    temporal?.historySchema = history.schema
                    temporal?.historyTable = history.name
                    context.addReference(from: key, to: SchemaObjectKey(type: .table, schema: history.schema,
                                                                        name: history.name))
                }
            }
            let dataSpace = row.string("data_space", default: "PRIMARY")
            let lob = row.string("lob_data_space")
            let partitionColumn = row.string("partition_column")
            let compression = row.string("data_compression", default: "NONE")
            let lockEscalation = row.string("lock_escalation_desc", default: "TABLE")
            let durability = row.string("durability_desc")
            let changeTracking = row.bool("change_tracking")
            let trackColumns = row.bool("track_columns")
            context.mutate(key) { object in
                object.table?.dataSpace = memoryOptimized ? "" : dataSpace
                object.table?.textImageDataSpace = lob.isEmpty ? nil : lob
                object.table?.partitionColumn = partitionColumn.isEmpty ? nil : partitionColumn
                object.table?.dataCompression = compression
                object.table?.lockEscalation = lockEscalation
                object.table?.isMemoryOptimized = memoryOptimized
                object.table?.durability = memoryOptimized ? durability : nil
                object.table?.changeTracking = changeTracking
                object.table?.changeTrackingColumnsUpdated = trackColumns
                object.table?.temporal = temporal
            }
        }
    }

    // MARK: - Indexes and constraints

    private func readIndexes(_ context: inout ReadContext) async throws {
        let sequentialKey = context.majorVersion >= 15 && !context.isAzure
            ? "CONVERT(int, i.optimize_for_sequential_key)" : "0"
        let sql = """
        SELECT i.object_id, i.index_id, i.name, CONVERT(int, i.type) AS index_type,
               CONVERT(int, i.is_unique) AS is_unique, CONVERT(int, i.is_primary_key) AS is_primary_key,
               CONVERT(int, i.is_unique_constraint) AS is_unique_constraint,
               CONVERT(int, i.fill_factor) AS fill_factor, CONVERT(int, i.is_padded) AS is_padded,
               CONVERT(int, i.ignore_dup_key) AS ignore_dup_key,
               CONVERT(int, i.allow_row_locks) AS allow_row_locks,
               CONVERT(int, i.allow_page_locks) AS allow_page_locks,
               CONVERT(nvarchar(max), i.filter_definition) AS filter_definition,
               CONVERT(int, i.is_disabled) AS is_disabled,
               ds.name AS data_space,
               CONVERT(int, ISNULL(st.no_recompute, 0)) AS no_recompute,
               (SELECT TOP (1) p.data_compression_desc FROM sys.partitions AS p
                 WHERE p.object_id = i.object_id AND p.index_id = i.index_id
                 ORDER BY p.partition_number) AS data_compression,
               CONVERT(int, ISNULL(kc.is_system_named, 0)) AS is_system_named,
               pxi.name AS primary_xml_index, xi.secondary_type_desc,
               sit.tessellation_scheme,
               sit.bounding_box_xmin, sit.bounding_box_ymin, sit.bounding_box_xmax, sit.bounding_box_ymax,
               sit.level_1_grid_desc, sit.level_2_grid_desc, sit.level_3_grid_desc, sit.level_4_grid_desc,
               sit.cells_per_object,
               \(sequentialKey) AS optimize_for_sequential_key
        FROM sys.indexes AS i
        JOIN sys.objects AS o ON o.object_id = i.object_id AND o.is_ms_shipped = 0 AND o.type IN ('U', 'V')
        LEFT JOIN sys.data_spaces AS ds ON ds.data_space_id = i.data_space_id
        LEFT JOIN sys.stats AS st ON st.object_id = i.object_id AND st.stats_id = i.index_id
        LEFT JOIN sys.key_constraints AS kc ON kc.parent_object_id = i.object_id
              AND kc.unique_index_id = i.index_id
        LEFT JOIN sys.xml_indexes AS xi ON xi.object_id = i.object_id AND xi.index_id = i.index_id
        LEFT JOIN sys.xml_indexes AS pxi ON pxi.object_id = xi.object_id AND pxi.index_id = xi.using_xml_index_id
        LEFT JOIN sys.spatial_index_tessellations AS sit ON sit.object_id = i.object_id
              AND sit.index_id = i.index_id
        WHERE i.index_id > 0 AND i.is_hypothetical = 0;

        SELECT ic.object_id, ic.index_id, CONVERT(int, ic.key_ordinal) AS key_ordinal,
               CONVERT(int, ic.index_column_id) AS index_column_id,
               CONVERT(int, ic.is_descending_key) AS is_descending_key,
               CONVERT(int, ic.is_included_column) AS is_included_column,
               CONVERT(int, ic.partition_ordinal) AS partition_ordinal, c.name
        FROM sys.index_columns AS ic
        JOIN sys.columns AS c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
        JOIN sys.objects AS o ON o.object_id = ic.object_id AND o.is_ms_shipped = 0 AND o.type IN ('U', 'V')
        ORDER BY ic.object_id, ic.index_id, ic.key_ordinal, ic.index_column_id;
        """
        let sets = try await resultSets(sql, context)
        var columns: [IndexID: [[String: TDSValue]]] = [:]
        for row in sets.count > 1 ? sets[1] : [] {
            columns[IndexID(object: row.int("object_id"), index: row.int("index_id")), default: []].append(row)
        }

        for row in sets.first ?? [] {
            let objectID = row.int("object_id")
            guard let key = context.objectKeys[objectID] else { continue }
            let indexID = IndexID(object: objectID, index: row.int("index_id"))
            let members = columns[indexID] ?? []
            let keyColumns: [IndexColumn] = members
                .filter { !$0.bool("is_included_column") && $0.int("key_ordinal") > 0 }
                .sorted { $0.int("key_ordinal") < $1.int("key_ordinal") }
                .map { IndexColumn(name: $0.string("name"), isDescending: $0.bool("is_descending_key")) }
            let included: [String] = members
                .filter { $0.bool("is_included_column") }
                .sorted { $0.int("index_column_id") < $1.int("index_column_id") }
                .map { $0.string("name") }
            let partitionColumn = members.first { $0.int("partition_ordinal") == 1 }?.string("name")

            let options = IndexOptions(fillFactor: row.int("fill_factor"), padIndex: row.bool("is_padded"),
                                       ignoreDupKey: row.bool("ignore_dup_key"),
                                       allowRowLocks: row.bool("allow_row_locks", default: true),
                                       allowPageLocks: row.bool("allow_page_locks", default: true),
                                       statisticsNoRecompute: row.bool("no_recompute"),
                                       dataCompression: row.string("data_compression", default: "NONE"),
                                       optimizeForSequentialKey: row.bool("optimize_for_sequential_key"))
            let dataSpace = row.string("data_space")
            let isMemoryOptimized = context.objects[key.matchKey]?.table?.isMemoryOptimized ?? false
            let name = row.string("name")

            if row.bool("is_primary_key") || row.bool("is_unique_constraint") {
                let constraint = KeyConstraintDefinition(
                    name: name, isSystemNamed: row.bool("is_system_named"),
                    isPrimaryKey: row.bool("is_primary_key"), isClustered: row.int("index_type") == 1,
                    columns: keyColumns, options: options,
                    dataSpace: isMemoryOptimized ? "" : dataSpace, partitionColumn: partitionColumn)
                context.mutate(key) { object in
                    if constraint.isPrimaryKey {
                        object.table?.primaryKey = constraint
                    } else {
                        object.table?.uniqueConstraints.append(constraint)
                    }
                }
                context.indexNames[indexID] = name
                context.constraintOwners[name.lowercased() + "|" + String(objectID)] = key
                continue
            }

            let kind: IndexKind
            switch row.int("index_type") {
            case 1: kind = .clustered
            case 3:
                let isSecondary: Bool = row["primary_xml_index"].map { !$0.isNull } ?? false
                kind = isSecondary ? .secondaryXml : .primaryXml
            case 4: kind = .spatial
            case 5: kind = .clusteredColumnstore
            case 6: kind = .nonclusteredColumnstore
            default: kind = .nonclustered
            }
            var index = IndexDefinition(name: name, kind: kind, isUnique: row.bool("is_unique"),
                                        columns: keyColumns,
                                        includedColumns: kind == .clusteredColumnstore ? [] : included,
                                        options: options, dataSpace: isMemoryOptimized ? "" : dataSpace,
                                        partitionColumn: partitionColumn, isDisabled: row.bool("is_disabled"))
            if kind == .spatial || kind == .primaryXml || kind == .secondaryXml {
                index.dataSpace = ""
                index.partitionColumn = nil
            }
            if kind == .nonclusteredColumnstore && keyColumns.isEmpty == false {
                index.includedColumns = keyColumns.map(\.name) + included
                index.columns = []
            }
            let filter = row.string("filter_definition")
            index.filter = filter.isEmpty ? nil : filter
            if kind == .secondaryXml {
                index.primaryXmlIndex = row.string("primary_xml_index")
                index.secondaryXmlType = row.string("secondary_type_desc")
            }
            if kind == .spatial {
                index.spatialTessellation = row.string("tessellation_scheme")
                index.spatialBoundingBox = Self.spatialOptions(row)
            }
            context.indexNames[indexID] = name
            context.mutate(key) { $0.indexes.append(index) }
        }
    }

    static func spatialOptions(_ row: [String: TDSValue]) -> String {
        var parts: [String] = []
        let scheme = row.string("tessellation_scheme").uppercased()
        if scheme.hasPrefix("GEOMETRY"), let xmin = row["bounding_box_xmin"], !xmin.isNull {
            parts.append("BOUNDING_BOX = (\(row["bounding_box_xmin"]!.displayString()), "
                         + "\(row["bounding_box_ymin"]!.displayString()), "
                         + "\(row["bounding_box_xmax"]!.displayString()), "
                         + "\(row["bounding_box_ymax"]!.displayString()))")
        }
        if !scheme.hasSuffix("AUTO_GRID") {
            let grids = (1...4).map { level in
                "LEVEL_\(level) = \(row.string("level_\(level)_grid_desc", default: "MEDIUM"))"
            }
            parts.append("GRIDS = (" + grids.joined(separator: ", ") + ")")
        }
        if let cells = row["cells_per_object"], !cells.isNull {
            parts.append("CELLS_PER_OBJECT = \(cells.displayString())")
        }
        return parts.joined(separator: ", ")
    }

    private func readConstraints(_ context: inout ReadContext) async throws {
        let sql = """
        SELECT cc.object_id, cc.parent_object_id, cc.name, CONVERT(nvarchar(max), cc.definition) AS definition,
               CONVERT(int, cc.is_not_for_replication) AS is_not_for_replication,
               CONVERT(int, cc.is_not_trusted) AS is_not_trusted, CONVERT(int, cc.is_disabled) AS is_disabled,
               CONVERT(int, cc.is_system_named) AS is_system_named
        FROM sys.check_constraints AS cc
        JOIN sys.objects AS o ON o.object_id = cc.parent_object_id AND o.is_ms_shipped = 0 AND o.type = 'U';
        """
        for row in try await rows(sql, context) {
            guard let key = context.objectKeys[row.int("parent_object_id")] else { continue }
            let check = CheckConstraintDefinition(name: row.string("name"),
                                                  isSystemNamed: row.bool("is_system_named"),
                                                  definition: row.string("definition"),
                                                  isNotForReplication: row.bool("is_not_for_replication"),
                                                  isNotTrusted: row.bool("is_not_trusted"),
                                                  isDisabled: row.bool("is_disabled"))
            context.mutate(key) { $0.table?.checkConstraints.append(check) }
        }
    }

    private func readForeignKeys(_ context: inout ReadContext) async throws {
        let sql = """
        SELECT fk.object_id, fk.parent_object_id, fk.name, CONVERT(int, fk.is_system_named) AS is_system_named,
               CONVERT(int, fk.is_not_for_replication) AS is_not_for_replication,
               CONVERT(int, fk.is_not_trusted) AS is_not_trusted, CONVERT(int, fk.is_disabled) AS is_disabled,
               fk.delete_referential_action_desc, fk.update_referential_action_desc,
               SCHEMA_NAME(ro.schema_id) AS referenced_schema, ro.name AS referenced_table
        FROM sys.foreign_keys AS fk
        JOIN sys.objects AS ro ON ro.object_id = fk.referenced_object_id
        JOIN sys.objects AS po ON po.object_id = fk.parent_object_id AND po.is_ms_shipped = 0;

        SELECT fkc.constraint_object_id, fkc.constraint_column_id, pc.name AS parent_column,
               rc.name AS referenced_column
        FROM sys.foreign_key_columns AS fkc
        JOIN sys.columns AS pc ON pc.object_id = fkc.parent_object_id AND pc.column_id = fkc.parent_column_id
        JOIN sys.columns AS rc ON rc.object_id = fkc.referenced_object_id
             AND rc.column_id = fkc.referenced_column_id
        ORDER BY fkc.constraint_object_id, fkc.constraint_column_id;
        """
        let sets = try await resultSets(sql, context)
        var columns: [Int: [(String, String)]] = [:]
        for row in sets.count > 1 ? sets[1] : [] {
            columns[row.int("constraint_object_id"), default: []]
                .append((row.string("parent_column"), row.string("referenced_column")))
        }
        for row in sets.first ?? [] {
            guard let key = context.objectKeys[row.int("parent_object_id")] else { continue }
            let pairs = columns[row.int("object_id")] ?? []
            let key2 = ForeignKeyDefinition(
                name: row.string("name"), isSystemNamed: row.bool("is_system_named"),
                columns: pairs.map(\.0), referencedSchema: row.string("referenced_schema"),
                referencedTable: row.string("referenced_table"), referencedColumns: pairs.map(\.1),
                deleteAction: row.string("delete_referential_action_desc", default: "NO_ACTION")
                    .replacingOccurrences(of: "_", with: " "),
                updateAction: row.string("update_referential_action_desc", default: "NO_ACTION")
                    .replacingOccurrences(of: "_", with: " "),
                isNotForReplication: row.bool("is_not_for_replication"),
                isNotTrusted: row.bool("is_not_trusted"), isDisabled: row.bool("is_disabled"))
            context.mutate(key) { $0.table?.foreignKeys.append(key2) }
        }
    }

    // MARK: - Modules and triggers

    private func readModules(_ context: inout ReadContext) async throws {
        let sql = """
        SELECT m.object_id, CONVERT(nvarchar(max), m.definition) AS definition,
               CONVERT(int, m.uses_ansi_nulls) AS uses_ansi_nulls,
               CONVERT(int, m.uses_quoted_identifier) AS uses_quoted_identifier,
               CONVERT(int, m.is_schema_bound) AS is_schema_bound
        FROM sys.sql_modules AS m
        JOIN sys.objects AS o ON o.object_id = m.object_id
        WHERE o.is_ms_shipped = 0 AND o.type IN ('V', 'P', 'FN', 'IF', 'TF', 'R', 'D');
        """
        for row in try await rows(sql, context) {
            guard let key = context.objectKeys[row.int("object_id")] else { continue }
            let definition = row.string("definition")
            let ansiNulls = row.bool("uses_ansi_nulls", default: true)
            let quotedIdentifier = row.bool("uses_quoted_identifier", default: true)
            let schemaBound = row.bool("is_schema_bound")
            context.mutate(key) { object in
                object.body = definition
                object.isEncrypted = object.isEncrypted || definition.isEmpty
                object.usesAnsiNulls = ansiNulls
                object.usesQuotedIdentifier = quotedIdentifier
                object.isSchemaBound = schemaBound
            }
        }
    }

    private func readCLRModules(_ context: inout ReadContext) async throws {
        let sql = """
        SELECT am.object_id, a.name AS assembly_name, am.assembly_class, am.assembly_method,
               ISNULL(USER_NAME(am.execute_as_principal_id), N'') AS execute_as,
               CONVERT(int, ISNULL(am.execute_as_principal_id, 0)) AS execute_as_id
        FROM sys.assembly_modules AS am
        JOIN sys.assemblies AS a ON a.assembly_id = am.assembly_id
        JOIN sys.objects AS o ON o.object_id = am.object_id AND o.is_ms_shipped = 0;

        SELECT p.object_id, p.parameter_id, p.name, t.name AS type_name, SCHEMA_NAME(t.schema_id) AS type_schema,
               CONVERT(int, t.is_user_defined) AS is_user_defined, CONVERT(int, p.max_length) AS max_length,
               CONVERT(int, p.precision) AS precision, CONVERT(int, p.scale) AS scale,
               CONVERT(int, p.is_output) AS is_output
        FROM sys.parameters AS p
        JOIN sys.types AS t ON t.user_type_id = p.user_type_id
        WHERE p.object_id IN (SELECT object_id FROM sys.assembly_modules)
        ORDER BY p.object_id, p.parameter_id;

        SELECT c.object_id, c.column_id, c.name, t.name AS type_name, SCHEMA_NAME(t.schema_id) AS type_schema,
               CONVERT(int, t.is_user_defined) AS is_user_defined, CONVERT(int, c.max_length) AS max_length,
               CONVERT(int, c.precision) AS precision, CONVERT(int, c.scale) AS scale
        FROM sys.columns AS c
        JOIN sys.types AS t ON t.user_type_id = c.user_type_id
        JOIN sys.objects AS o ON o.object_id = c.object_id AND o.type = 'FT'
        ORDER BY c.object_id, c.column_id;
        """
        let sets = try await resultSets(sql, context)
        guard let modules = sets.first, !modules.isEmpty else { return }
        var parameters: [Int: [[String: TDSValue]]] = [:]
        for row in sets.count > 1 ? sets[1] : [] { parameters[row.int("object_id"), default: []].append(row) }
        var tableColumns: [Int: [[String: TDSValue]]] = [:]
        for row in sets.count > 2 ? sets[2] : [] { tableColumns[row.int("object_id"), default: []].append(row) }

        for row in modules {
            let objectID = row.int("object_id")
            guard let key = context.objectKeys[objectID], let entry = context.objectRows[objectID] else { continue }
            let params = parameters[objectID] ?? []
            func typeText(_ p: [String: TDSValue]) -> String {
                Self.formatType(name: p.string("type_name"), schema: p.string("type_schema"),
                           isUserDefined: p.bool("is_user_defined"), maxLength: p.int("max_length"),
                           precision: p.int("precision"), scale: p.int("scale"))
            }
            let inputs = params.filter { $0.int("parameter_id") > 0 }.map { p -> String in
                "\(p.string("name")) \(typeText(p))" + (p.bool("is_output") ? " OUTPUT" : "")
            }
            let returns = params.first { $0.int("parameter_id") == 0 }.map(typeText)
            let external = "EXTERNAL NAME \(SQLIdentifier.quote(row.string("assembly_name")))."
                + SQLIdentifier.quote(row.string("assembly_class"))
            let method = row.string("assembly_method")
            let executeAs: String
            switch row.int("execute_as_id") {
            case 0: executeAs = ""
            case -2: executeAs = " WITH EXECUTE AS OWNER"
            default: executeAs = " WITH EXECUTE AS N'\(row.string("execute_as").replacingOccurrences(of: "'", with: "''"))'"
            }
            let name = key.quotedName
            var body: String
            switch entry.type {
            case "PC":
                body = "CREATE PROCEDURE \(name)"
                if !inputs.isEmpty { body += "\n    " + inputs.joined(separator: ",\n    ") }
                body += executeAs + "\nAS \(external).\(SQLIdentifier.quote(method))"
            case "AF":
                body = "CREATE AGGREGATE \(name) (" + inputs.joined(separator: ", ") + ")"
                body += "\nRETURNS \(returns ?? "sql_variant")\n\(external)"
            case "FT":
                let columns = (tableColumns[objectID] ?? []).map { "\(SQLIdentifier.quote($0.string("name"))) \(typeText($0))" }
                body = "CREATE FUNCTION \(name) (" + inputs.joined(separator: ", ") + ")"
                body += "\nRETURNS TABLE (" + columns.joined(separator: ", ") + ")"
                body += executeAs + "\nAS \(external).\(SQLIdentifier.quote(method))"
            default:
                body = "CREATE FUNCTION \(name) (" + inputs.joined(separator: ", ") + ")"
                body += "\nRETURNS \(returns ?? "sql_variant")"
                body += executeAs + "\nAS \(external).\(SQLIdentifier.quote(method))"
            }
            let assemblyKey = SchemaObjectKey(type: .assembly, schema: "", name: row.string("assembly_name"))
            context.mutate(key) { object in
                object.body = body
                object.isEncrypted = false
            }
            context.addReference(from: key, to: assemblyKey)
        }
    }

    private func readTriggers(_ context: inout ReadContext) async throws {
        let sql = """
        SELECT tr.object_id, tr.name, tr.parent_id, CONVERT(int, tr.parent_class) AS parent_class,
               CONVERT(int, tr.is_disabled) AS is_disabled,
               CONVERT(nvarchar(max), m.definition) AS definition,
               CONVERT(int, ISNULL(m.uses_ansi_nulls, 1)) AS uses_ansi_nulls,
               CONVERT(int, ISNULL(m.uses_quoted_identifier, 1)) AS uses_quoted_identifier,
               CONVERT(int, ISNULL(OBJECTPROPERTY(tr.object_id, 'IsEncrypted'), 0)) AS is_encrypted
        FROM sys.triggers AS tr
        LEFT JOIN sys.sql_modules AS m ON m.object_id = tr.object_id
        WHERE tr.is_ms_shipped = 0;

        SELECT te.object_id, te.type_desc, CONVERT(int, te.is_first) AS is_first,
               CONVERT(int, te.is_last) AS is_last
        FROM sys.trigger_events AS te
        WHERE te.is_first = 1 OR te.is_last = 1;
        """
        let sets = try await resultSets(sql, context)
        var orders: [Int: [String: String]] = [:]
        for row in sets.count > 1 ? sets[1] : [] {
            let order = row.bool("is_first") ? "First" : "Last"
            orders[row.int("object_id"), default: [:]][row.string("type_desc").uppercased()] = order
        }
        for row in sets.first ?? [] {
            let objectID = row.int("object_id")
            let name = row.string("name")
            let definition = row.string("definition")
            let order = orders[objectID] ?? [:]
            if row.int("parent_class") == 0 {
                var object = SchemaObject(type: .ddlTrigger, schema: "", name: name, body: definition)
                object.isEncrypted = row.bool("is_encrypted") || definition.isEmpty
                object.usesAnsiNulls = row.bool("uses_ansi_nulls", default: true)
                object.usesQuotedIdentifier = row.bool("uses_quoted_identifier", default: true)
                object.subtype = row.bool("is_disabled") ? "disabled" : ""
                object.triggerOrder = order
                context.add(object, objectID: objectID)
                continue
            }
            guard let parent = context.objectKeys[row.int("parent_id")] else { continue }
            let trigger = TriggerDefinition(name: name, definition: definition,
                                            isDisabled: row.bool("is_disabled"),
                                            usesQuotedIdentifier: row.bool("uses_quoted_identifier", default: true),
                                            usesAnsiNulls: row.bool("uses_ansi_nulls", default: true),
                                            order: order)
            context.triggerOwners[objectID] = parent
            context.mutate(parent) { $0.triggers.append(trigger) }
        }
    }

    private func readStatistics(_ context: inout ReadContext) async throws {
        let sql = """
        SELECT s.object_id, s.stats_id, s.name, CONVERT(nvarchar(max), s.filter_definition) AS filter_definition,
               CONVERT(int, s.no_recompute) AS no_recompute
        FROM sys.stats AS s
        JOIN sys.objects AS o ON o.object_id = s.object_id AND o.is_ms_shipped = 0 AND o.type IN ('U', 'V')
        WHERE s.user_created = 1;

        SELECT sc.object_id, sc.stats_id, sc.stats_column_id, c.name
        FROM sys.stats_columns AS sc
        JOIN sys.stats AS s ON s.object_id = sc.object_id AND s.stats_id = sc.stats_id AND s.user_created = 1
        JOIN sys.columns AS c ON c.object_id = sc.object_id AND c.column_id = sc.column_id
        ORDER BY sc.object_id, sc.stats_id, sc.stats_column_id;
        """
        let sets = try await resultSets(sql, context)
        var columns: [IndexID: [String]] = [:]
        for row in sets.count > 1 ? sets[1] : [] {
            columns[IndexID(object: row.int("object_id"), index: row.int("stats_id")), default: []]
                .append(row.string("name"))
        }
        for row in sets.first ?? [] {
            let objectID = row.int("object_id")
            guard let key = context.objectKeys[objectID] else { continue }
            let filter = row.string("filter_definition")
            let statistic = StatisticsDefinition(
                name: row.string("name"),
                columns: columns[IndexID(object: objectID, index: row.int("stats_id"))] ?? [],
                filter: filter.isEmpty ? nil : filter, noRecompute: row.bool("no_recompute"))
            context.mutate(key) { $0.statistics.append(statistic) }
        }
    }

    // MARK: - Catalog-built objects

    private func readSynonyms(_ context: inout ReadContext) async throws {
        let sql = "SELECT s.object_id, s.base_object_name FROM sys.synonyms AS s;"
        for row in try await rows(sql, context) {
            guard let key = context.objectKeys[row.int("object_id")] else { continue }
            let body = "CREATE SYNONYM \(key.quotedName) FOR \(row.string("base_object_name"))"
            context.mutate(key) { $0.body = body }
        }
    }

    private func readSequences(_ context: inout ReadContext) async throws {
        let sql = """
        SELECT s.object_id, t.name AS type_name, SCHEMA_NAME(t.schema_id) AS type_schema,
               CONVERT(int, t.is_user_defined) AS is_user_defined, CONVERT(int, s.precision) AS precision,
               CONVERT(int, s.scale) AS scale,
               CONVERT(nvarchar(64), s.start_value) AS start_value, CONVERT(nvarchar(64), s.increment) AS increment,
               CONVERT(nvarchar(64), s.minimum_value) AS minimum_value,
               CONVERT(nvarchar(64), s.maximum_value) AS maximum_value,
               CONVERT(int, s.is_cycling) AS is_cycling, CONVERT(int, s.is_cached) AS is_cached,
               s.cache_size
        FROM sys.sequences AS s
        JOIN sys.types AS t ON t.user_type_id = s.user_type_id;
        """
        for row in try await rows(sql, context) {
            guard let key = context.objectKeys[row.int("object_id")] else { continue }
            let type = Self.formatType(name: row.string("type_name"), schema: row.string("type_schema"),
                                  isUserDefined: row.bool("is_user_defined"), maxLength: 0,
                                  precision: row.int("precision"), scale: row.int("scale"))
            var body = "CREATE SEQUENCE \(key.quotedName)\n    AS \(type)\n"
            body += "    START WITH \(row.string("start_value"))\n"
            body += "    INCREMENT BY \(row.string("increment"))\n"
            body += "    MINVALUE \(row.string("minimum_value"))\n"
            body += "    MAXVALUE \(row.string("maximum_value"))\n"
            body += row.bool("is_cycling") ? "    CYCLE\n" : "    NO CYCLE\n"
            if row.bool("is_cached") {
                if let size = row["cache_size"], !size.isNull {
                    body += "    CACHE \(size.displayString())"
                } else {
                    body += "    CACHE"
                }
            } else {
                body += "    NO CACHE"
            }
            context.mutate(key) { $0.body = body }
            if row.bool("is_user_defined") {
                context.pendingTypeReferences.append((key, row.string("type_schema"), row.string("type_name")))
            }
        }
    }

    private func readTypes(_ context: inout ReadContext) async throws {
        let sql = """
        SELECT t.user_type_id, t.name, SCHEMA_NAME(t.schema_id) AS schema_name, bt.name AS base_name,
               CONVERT(int, t.max_length) AS max_length, CONVERT(int, t.precision) AS precision,
               CONVERT(int, t.scale) AS scale, CONVERT(int, t.is_nullable) AS is_nullable,
               ISNULL(USER_NAME(t.principal_id), N'') AS owner_name
        FROM sys.types AS t
        JOIN sys.types AS bt ON bt.user_type_id = t.system_type_id
        WHERE t.is_user_defined = 1 AND t.is_table_type = 0 AND t.is_assembly_type = 0;

        SELECT at.user_type_id, at.name, SCHEMA_NAME(at.schema_id) AS schema_name,
               a.name AS assembly_name, at.assembly_class
        FROM sys.assembly_types AS at
        JOIN sys.assemblies AS a ON a.assembly_id = at.assembly_id
        WHERE at.is_user_defined = 1;
        """
        let sets = try await resultSets(sql, context)
        for row in sets.first ?? [] {
            let schema = row.string("schema_name")
            let name = row.string("name")
            let base = Self.formatType(name: row.string("base_name"), schema: "", isUserDefined: false,
                                  maxLength: row.int("max_length"), precision: row.int("precision"),
                                  scale: row.int("scale"))
            var object = SchemaObject(type: .userDefinedType, schema: schema, name: name)
            object.body = "CREATE TYPE \(object.quotedName) FROM \(base)"
                + (row.bool("is_nullable") ? " NULL" : " NOT NULL")
            let owner = row.string("owner_name")
            if !owner.isEmpty { object.owner = owner }
            context.add(object, typeID: row.int("user_type_id"))
        }
        for row in sets.count > 1 ? sets[1] : [] {
            var object = SchemaObject(type: .userDefinedType, schema: row.string("schema_name"),
                                      name: row.string("name"))
            object.subtype = "CLR"
            object.body = "CREATE TYPE \(object.quotedName) EXTERNAL NAME "
                + "\(SQLIdentifier.quote(row.string("assembly_name"))).\(SQLIdentifier.quote(row.string("assembly_class")))"
            context.add(object, typeID: row.int("user_type_id"))
            context.addReference(from: object.key, to: SchemaObjectKey(type: .assembly, schema: "",
                                                                       name: row.string("assembly_name")))
        }
    }

    private func readTableTypes(_ context: inout ReadContext) async throws {
        let sql = """
        SELECT tt.user_type_id, tt.name, SCHEMA_NAME(tt.schema_id) AS schema_name, tt.type_table_object_id,
               CONVERT(int, tt.is_memory_optimized) AS is_memory_optimized,
               ISNULL(USER_NAME(tt.principal_id), N'') AS owner_name
        FROM sys.table_types AS tt
        WHERE tt.is_user_defined = 1;

        SELECT i.object_id, i.index_id, i.name, CONVERT(int, i.type) AS index_type,
               CONVERT(int, i.is_unique) AS is_unique, CONVERT(int, i.is_primary_key) AS is_primary_key,
               CONVERT(int, i.is_unique_constraint) AS is_unique_constraint,
               CONVERT(int, i.ignore_dup_key) AS ignore_dup_key
        FROM sys.indexes AS i
        WHERE i.object_id IN (SELECT type_table_object_id FROM sys.table_types) AND i.index_id > 0;

        SELECT ic.object_id, ic.index_id, CONVERT(int, ic.key_ordinal) AS key_ordinal,
               CONVERT(int, ic.is_descending_key) AS is_descending_key,
               CONVERT(int, ic.is_included_column) AS is_included_column, c.name
        FROM sys.index_columns AS ic
        JOIN sys.columns AS c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
        WHERE ic.object_id IN (SELECT type_table_object_id FROM sys.table_types)
        ORDER BY ic.object_id, ic.index_id, ic.key_ordinal;

        SELECT cc.parent_object_id, CONVERT(nvarchar(max), cc.definition) AS definition
        FROM sys.check_constraints AS cc
        WHERE cc.parent_object_id IN (SELECT type_table_object_id FROM sys.table_types)
        ORDER BY cc.parent_object_id, cc.object_id;
        """
        let sets = try await resultSets(sql, context)
        var indexes: [Int: [[String: TDSValue]]] = [:]
        for row in sets.count > 1 ? sets[1] : [] { indexes[row.int("object_id"), default: []].append(row) }
        var indexColumns: [IndexID: [[String: TDSValue]]] = [:]
        for row in sets.count > 2 ? sets[2] : [] {
            indexColumns[IndexID(object: row.int("object_id"), index: row.int("index_id")), default: []].append(row)
        }
        var checks: [Int: [String]] = [:]
        for row in sets.count > 3 ? sets[3] : [] {
            checks[row.int("parent_object_id"), default: []].append(row.string("definition"))
        }

        let writer = SchemaScriptWriter()
        for row in sets.first ?? [] {
            let tableID = row.int("type_table_object_id")
            var object = SchemaObject(type: .tableType, schema: row.string("schema_name"), name: row.string("name"))
            var columns = context.columnsByObject[tableID] ?? []
            for index in columns.indices {
                // Table type constraints are always system named; drop the names so two
                // databases that agree render the same text.
                if columns[index].defaultConstraint != nil {
                    columns[index].defaultConstraint?.name = ""
                    columns[index].defaultConstraint?.isSystemNamed = true
                }
            }
            var lines: [String] = columns.map { "    " + writer.columnDefinition($0) }
            for index in (indexes[tableID] ?? []).sorted(by: { $0.int("index_id") < $1.int("index_id") }) {
                let members = (indexColumns[IndexID(object: tableID, index: index.int("index_id"))] ?? [])
                    .filter { !$0.bool("is_included_column") }
                    .map { IndexColumn(name: $0.string("name"), isDescending: $0.bool("is_descending_key")) }
                let list = writer.indexColumnList(members)
                let clustered = index.int("index_type") == 1 ? "CLUSTERED" : "NONCLUSTERED"
                let ignoreDup = index.bool("ignore_dup_key") ? " WITH (IGNORE_DUP_KEY = ON)" : ""
                if index.bool("is_primary_key") {
                    lines.append("    PRIMARY KEY \(clustered) (\(list))\(ignoreDup)")
                } else if index.bool("is_unique_constraint") {
                    lines.append("    UNIQUE \(clustered) (\(list))\(ignoreDup)")
                } else {
                    let unique = index.bool("is_unique") ? "UNIQUE " : ""
                    lines.append("    INDEX \(SQLIdentifier.quote(index.string("name"))) \(unique)\(clustered) (\(list))")
                }
            }
            for check in checks[tableID] ?? [] {
                lines.append("    CHECK " + SchemaScriptWriter.parenthesized(check))
            }
            var body = "CREATE TYPE \(object.quotedName) AS TABLE\n(\n" + lines.joined(separator: ",\n") + "\n)"
            if row.bool("is_memory_optimized") { body += "\nWITH (MEMORY_OPTIMIZED = ON)" }
            object.body = body
            let owner = row.string("owner_name")
            if !owner.isEmpty { object.owner = owner }
            context.add(object, typeID: row.int("user_type_id"))
            for column in columns where column.isUserDefinedType {
                let parts = column.dataType.replacingOccurrences(of: "[", with: "")
                    .replacingOccurrences(of: "]", with: "").split(separator: ".").map(String.init)
                if parts.count == 2 {
                    context.pendingTypeReferences.append((object.key, parts[0], parts[1]))
                }
            }
        }
    }

    private func readXmlSchemaCollections(_ context: inout ReadContext) async throws {
        let sql = """
        SELECT x.xml_collection_id, x.name, SCHEMA_NAME(x.schema_id) AS schema_name,
               CONVERT(nvarchar(max), XML_SCHEMA_NAMESPACE(SCHEMA_NAME(x.schema_id), x.name)) AS schema_text,
               ISNULL(USER_NAME(x.principal_id), N'') AS owner_name
        FROM sys.xml_schema_collections AS x
        WHERE x.xml_collection_id > 65535;
        """
        for row in try await rows(sql, context) {
            var object = SchemaObject(type: .xmlSchemaCollection, schema: row.string("schema_name"),
                                      name: row.string("name"))
            object.body = "CREATE XML SCHEMA COLLECTION \(object.quotedName) AS "
                + SQLIdentifier.literal(row.string("schema_text"))
            let owner = row.string("owner_name")
            if !owner.isEmpty { object.owner = owner }
            context.add(object, xmlCollectionID: row.int("xml_collection_id"))
        }
    }

    private func readPartitioning(_ context: inout ReadContext) async throws {
        let sql = """
        SELECT pf.function_id, pf.name, CONVERT(int, pf.boundary_value_on_right) AS is_right,
               t.name AS type_name, CONVERT(int, pp.max_length) AS max_length,
               CONVERT(int, pp.precision) AS precision, CONVERT(int, pp.scale) AS scale,
               pp.collation_name
        FROM sys.partition_functions AS pf
        JOIN sys.partition_parameters AS pp ON pp.function_id = pf.function_id
        JOIN sys.types AS t ON t.user_type_id = pp.user_type_id;

        SELECT rv.function_id, rv.boundary_id, rv.value
        FROM sys.partition_range_values AS rv
        ORDER BY rv.function_id, rv.boundary_id;

        SELECT ps.data_space_id, ps.name, pf.name AS function_name, dds.destination_id, fg.name AS filegroup_name
        FROM sys.partition_schemes AS ps
        JOIN sys.partition_functions AS pf ON pf.function_id = ps.function_id
        JOIN sys.destination_data_spaces AS dds ON dds.partition_scheme_id = ps.data_space_id
        JOIN sys.filegroups AS fg ON fg.data_space_id = dds.data_space_id
        ORDER BY ps.name, dds.destination_id;
        """
        let sets = try await resultSets(sql, context)
        var boundaries: [Int: [String]] = [:]
        for row in sets.count > 1 ? sets[1] : [] {
            boundaries[row.int("function_id"), default: []].append(SQLLiteral.render(row["value"] ?? .null))
        }
        for row in sets.first ?? [] {
            let name = row.string("name")
            let type = Self.formatType(name: row.string("type_name"), schema: "", isUserDefined: false,
                                  maxLength: row.int("max_length"), precision: row.int("precision"),
                                  scale: row.int("scale"))
            var object = SchemaObject(type: .partitionFunction, schema: "", name: name)
            object.body = "CREATE PARTITION FUNCTION \(SQLIdentifier.quote(name)) (\(type))\n"
                + "    AS RANGE \(row.bool("is_right") ? "RIGHT" : "LEFT")\n"
                + "    FOR VALUES (" + (boundaries[row.int("function_id")] ?? []).joined(separator: ", ") + ")"
            context.add(object)
        }
        var schemes: [String: (String, [String])] = [:]
        var schemeOrder: [String] = []
        for row in sets.count > 2 ? sets[2] : [] {
            let name = row.string("name")
            if schemes[name] == nil {
                schemes[name] = (row.string("function_name"), [])
                schemeOrder.append(name)
            }
            schemes[name]?.1.append(SQLIdentifier.quote(row.string("filegroup_name")))
        }
        for name in schemeOrder {
            guard let (function, filegroups) = schemes[name] else { continue }
            var object = SchemaObject(type: .partitionScheme, schema: "", name: name)
            object.body = "CREATE PARTITION SCHEME \(SQLIdentifier.quote(name))\n"
                + "    AS PARTITION \(SQLIdentifier.quote(function))\n"
                + "    TO (" + filegroups.joined(separator: ", ") + ")"
            context.add(object)
            context.partitionSchemes.insert(name.lowercased())
            context.addReference(from: object.key, to: SchemaObjectKey(type: .partitionFunction, schema: "",
                                                                       name: function))
        }
        // Tables were read before partitioning; point them at their schemes now.
        let tables: [SchemaObject] = context.objects.values.filter { $0.type == .table }
        for object in tables {
            if let space = object.table?.dataSpace, context.partitionSchemes.contains(space.lowercased()) {
                context.addReference(from: object.key, to: SchemaObjectKey(type: .partitionScheme, schema: "",
                                                                           name: space))
            }
        }
    }

    private func readAssemblies(_ context: inout ReadContext) async throws {
        let sql = """
        SELECT a.assembly_id, a.name, a.permission_set_desc, ISNULL(USER_NAME(a.principal_id), N'') AS owner_name,
               af.content
        FROM sys.assemblies AS a
        JOIN sys.assembly_files AS af ON af.assembly_id = a.assembly_id AND af.file_id = 1
        WHERE a.is_user_defined = 1;
        """
        for row in try await rows(sql, context) {
            let name = row.string("name")
            var object = SchemaObject(type: .assembly, schema: "", name: name)
            var bytes: [UInt8] = []
            if case .binary(let content)? = row["content"] { bytes = content }
            let permission = row.string("permission_set_desc", default: "SAFE_ACCESS")
                .replacingOccurrences(of: "_ACCESS", with: "")
            var body = "CREATE ASSEMBLY \(SQLIdentifier.quote(name))"
            let owner = row.string("owner_name")
            if !owner.isEmpty { body += " AUTHORIZATION \(SQLIdentifier.quote(owner))" }
            body += "\nFROM 0x" + SQLLiteral.hex(bytes)
            body += "\nWITH PERMISSION_SET = \(permission)"
            object.body = body
            context.add(object, assemblyID: row.int("assembly_id"))
        }
    }

    private func readFullText(_ context: inout ReadContext) async throws {
        let sql = """
        SELECT c.fulltext_catalog_id, c.name, CONVERT(int, c.is_default) AS is_default,
               CONVERT(int, c.is_accent_sensitivity_on) AS is_accent_sensitive,
               ISNULL(USER_NAME(c.principal_id), N'') AS owner_name
        FROM sys.fulltext_catalogs AS c;

        SELECT sl.stoplist_id, sl.name, ISNULL(USER_NAME(sl.principal_id), N'') AS owner_name
        FROM sys.fulltext_stoplists AS sl;

        SELECT sw.stoplist_id, sw.stopword, sw.language_id
        FROM sys.fulltext_stopwords AS sw
        ORDER BY sw.stoplist_id, sw.language_id, sw.stopword;

        SELECT fi.object_id, c.name AS catalog_name, i.name AS key_index,
               fi.change_tracking_state_desc, fi.stoplist_id, sl.name AS stoplist_name
        FROM sys.fulltext_indexes AS fi
        JOIN sys.fulltext_catalogs AS c ON c.fulltext_catalog_id = fi.fulltext_catalog_id
        JOIN sys.indexes AS i ON i.object_id = fi.object_id AND i.index_id = fi.unique_index_id
        LEFT JOIN sys.fulltext_stoplists AS sl ON sl.stoplist_id = fi.stoplist_id;

        SELECT fic.object_id, c.name, tc.name AS type_column, CONVERT(int, fic.language_id) AS language_id
        FROM sys.fulltext_index_columns AS fic
        JOIN sys.columns AS c ON c.object_id = fic.object_id AND c.column_id = fic.column_id
        LEFT JOIN sys.columns AS tc ON tc.object_id = fic.object_id AND tc.column_id = fic.type_column_id
        ORDER BY fic.object_id, fic.column_id;
        """
        let sets = try await resultSets(sql, context)
        for row in sets.first ?? [] {
            let name = row.string("name")
            var object = SchemaObject(type: .fullTextCatalog, schema: "", name: name)
            var body = "CREATE FULLTEXT CATALOG \(SQLIdentifier.quote(name))"
            body += " WITH ACCENT_SENSITIVITY = \(row.bool("is_accent_sensitive") ? "ON" : "OFF")"
            if row.bool("is_default") { body += " AS DEFAULT" }
            let owner = row.string("owner_name")
            if !owner.isEmpty, owner != "dbo" { body += " AUTHORIZATION \(SQLIdentifier.quote(owner))" }
            object.body = body
            context.add(object, fullTextCatalogID: row.int("fulltext_catalog_id"))
        }
        var words: [Int: [String]] = [:]
        for row in sets.count > 2 ? sets[2] : [] {
            let word = row.string("stopword").replacingOccurrences(of: "'", with: "''")
            words[row.int("stoplist_id"), default: []].append("'\(word)' LANGUAGE \(row.int("language_id"))")
        }
        for row in sets.count > 1 ? sets[1] : [] {
            let name = row.string("name")
            var object = SchemaObject(type: .fullTextStoplist, schema: "", name: name)
            var body = "CREATE FULLTEXT STOPLIST \(SQLIdentifier.quote(name))"
            let owner = row.string("owner_name")
            if !owner.isEmpty, owner != "dbo" { body += " AUTHORIZATION \(SQLIdentifier.quote(owner))" }
            body += ";"
            for word in words[row.int("stoplist_id")] ?? [] {
                body += "\nALTER FULLTEXT STOPLIST \(SQLIdentifier.quote(name)) ADD \(word);"
            }
            object.body = body
            context.add(object, stoplistID: row.int("stoplist_id"))
        }
        var ftColumns: [Int: [FullTextIndexColumn]] = [:]
        for row in sets.count > 4 ? sets[4] : [] {
            let type = row.string("type_column")
            ftColumns[row.int("object_id"), default: []].append(
                FullTextIndexColumn(name: row.string("name"), typeColumn: type.isEmpty ? nil : type,
                                    language: row.int("language_id")))
        }
        for row in sets.count > 3 ? sets[3] : [] {
            let objectID = row.int("object_id")
            guard let key = context.objectKeys[objectID] else { continue }
            let stoplist: String?
            if let id = row["stoplist_id"], !id.isNull {
                stoplist = row.int("stoplist_id") == 0 ? "SYSTEM" : row.string("stoplist_name")
            } else {
                stoplist = "OFF"
            }
            let index = FullTextIndexDefinition(catalog: row.string("catalog_name"),
                                                keyIndex: row.string("key_index"),
                                                columns: ftColumns[objectID] ?? [],
                                                changeTracking: row.string("change_tracking_state_desc",
                                                                           default: "AUTO"),
                                                stoplist: stoplist)
            context.mutate(key) { $0.table?.fullTextIndex = index }
            context.addReference(from: key, to: SchemaObjectKey(type: .fullTextCatalog, schema: "",
                                                                name: index.catalog))
            if let stoplist, stoplist != "SYSTEM", stoplist != "OFF" {
                context.addReference(from: key, to: SchemaObjectKey(type: .fullTextStoplist, schema: "",
                                                                    name: stoplist))
            }
        }
    }

    private func readSecurityPolicies(_ context: inout ReadContext) async throws {
        let sql = """
        SELECT sp.object_id, CONVERT(int, sp.is_enabled) AS is_enabled,
               CONVERT(int, sp.is_schema_bound) AS is_schema_bound,
               CONVERT(int, sp.is_not_for_replication) AS is_not_for_replication
        FROM sys.security_policies AS sp;

        SELECT pr.object_id, pr.security_predicate_id, pr.predicate_type_desc, pr.operation_desc,
               CONVERT(nvarchar(max), pr.predicate_definition) AS predicate_definition,
               SCHEMA_NAME(t.schema_id) AS target_schema, t.name AS target_name
        FROM sys.security_predicates AS pr
        JOIN sys.objects AS t ON t.object_id = pr.target_object_id
        ORDER BY pr.object_id, pr.security_predicate_id;
        """
        let sets = try await resultSets(sql, context)
        var predicates: [Int: [[String: TDSValue]]] = [:]
        for row in sets.count > 1 ? sets[1] : [] { predicates[row.int("object_id"), default: []].append(row) }
        for row in sets.first ?? [] {
            let objectID = row.int("object_id")
            guard let key = context.objectKeys[objectID] else { continue }
            var clauses: [String] = []
            for predicate in predicates[objectID] ?? [] {
                var definition = predicate.string("predicate_definition").trimmingCharacters(in: .whitespaces)
                if definition.hasPrefix("("), definition.hasSuffix(")") {
                    definition = String(definition.dropFirst().dropLast())
                }
                let target = SQLIdentifier.quote(schema: predicate.string("target_schema"),
                                                 name: predicate.string("target_name"))
                var clause = "ADD \(predicate.string("predicate_type_desc").uppercased()) PREDICATE "
                    + "\(definition) ON \(target)"
                let operation = predicate.string("operation_desc")
                if !operation.isEmpty { clause += " \(operation.uppercased())" }
                clauses.append(clause)
                context.addReference(from: key, to: SchemaObjectKey(type: .table,
                                                                    schema: predicate.string("target_schema"),
                                                                    name: predicate.string("target_name")))
            }
            var body = "CREATE SECURITY POLICY \(key.quotedName)\n" + clauses.joined(separator: ",\n")
            body += "\nWITH (STATE = \(row.bool("is_enabled") ? "ON" : "OFF"), "
                + "SCHEMABINDING = \(row.bool("is_schema_bound") ? "ON" : "OFF"))"
            if row.bool("is_not_for_replication") { body += "\nNOT FOR REPLICATION" }
            context.mutate(key) { $0.body = body }
        }
    }

    private func readServiceBroker(_ context: inout ReadContext) async throws {
        let sql = """
        SELECT mt.message_type_id, mt.name, mt.validation, xsc.name AS xml_collection,
               SCHEMA_NAME(xsc.schema_id) AS xml_collection_schema
        FROM sys.service_message_types AS mt
        LEFT JOIN sys.xml_schema_collections AS xsc ON xsc.xml_collection_id = mt.xml_collection_id
        WHERE mt.message_type_id > 65535;

        SELECT sc.service_contract_id, sc.name
        FROM sys.service_contracts AS sc
        WHERE sc.service_contract_id > 65535;

        SELECT u.service_contract_id, mt.name AS message_type,
               CONVERT(int, u.is_sent_by_initiator) AS by_initiator, CONVERT(int, u.is_sent_by_target) AS by_target
        FROM sys.service_contract_message_usages AS u
        JOIN sys.service_message_types AS mt ON mt.message_type_id = u.message_type_id
        WHERE u.service_contract_id > 65535
        ORDER BY u.service_contract_id, mt.name;

        SELECT q.object_id, CONVERT(int, q.is_receive_enabled) AS is_receive_enabled,
               CONVERT(int, q.is_retention_enabled) AS is_retention_enabled,
               CONVERT(int, q.is_activation_enabled) AS is_activation_enabled,
               q.activation_procedure, q.max_readers,
               q.execute_as_principal_id, ISNULL(USER_NAME(q.execute_as_principal_id), N'') AS execute_as,
               CONVERT(int, q.is_poison_message_handling_enabled) AS is_poison_message_handling_enabled
        FROM sys.service_queues AS q
        WHERE q.is_ms_shipped = 0;

        SELECT s.service_id, s.name, SCHEMA_NAME(q.schema_id) AS queue_schema, q.name AS queue_name
        FROM sys.services AS s
        JOIN sys.service_queues AS q ON q.object_id = s.service_queue_id
        WHERE s.service_id > 65535 AND q.is_ms_shipped = 0;

        SELECT scu.service_id, sc.name AS contract_name
        FROM sys.service_contract_usages AS scu
        JOIN sys.service_contracts AS sc ON sc.service_contract_id = scu.service_contract_id
        WHERE scu.service_id > 65535
        ORDER BY scu.service_id, sc.name;
        """
        let sets = try await resultSets(sql, context)
        for row in sets.first ?? [] {
            let name = row.string("name")
            var object = SchemaObject(type: .messageType, schema: "", name: name)
            var body = "CREATE MESSAGE TYPE \(SQLIdentifier.quote(name)) VALIDATION = "
            switch row.string("validation").trimmingCharacters(in: .whitespaces).uppercased() {
            case "E": body += "EMPTY"
            case "N": body += "NONE"
            default:
                if let collection = row["xml_collection"], !collection.isNull {
                    let collectionKey = SchemaObjectKey(type: .xmlSchemaCollection,
                                                        schema: row.string("xml_collection_schema"),
                                                        name: row.string("xml_collection"))
                    body += "VALID_XML WITH SCHEMA COLLECTION \(collectionKey.quotedName)"
                    context.addReference(from: object.key, to: collectionKey)
                } else {
                    body += "WELL_FORMED_XML"
                }
            }
            object.body = body
            context.add(object, messageTypeID: row.int("message_type_id"))
        }
        var usages: [Int: [String]] = [:]
        var usedTypes: [Int: [String]] = [:]
        for row in sets.count > 2 ? sets[2] : [] {
            let sentBy: String
            switch (row.bool("by_initiator"), row.bool("by_target")) {
            case (true, true): sentBy = "ANY"
            case (true, false): sentBy = "INITIATOR"
            default: sentBy = "TARGET"
            }
            usages[row.int("service_contract_id"), default: []]
                .append("\(SQLIdentifier.quote(row.string("message_type"))) SENT BY \(sentBy)")
            usedTypes[row.int("service_contract_id"), default: []].append(row.string("message_type"))
        }
        for row in sets.count > 1 ? sets[1] : [] {
            let name = row.string("name")
            let id = row.int("service_contract_id")
            var object = SchemaObject(type: .contract, schema: "", name: name)
            object.body = "CREATE CONTRACT \(SQLIdentifier.quote(name)) ("
                + (usages[id] ?? []).joined(separator: ", ") + ")"
            context.add(object, contractID: id)
            for type in usedTypes[id] ?? [] {
                context.addReference(from: object.key, to: SchemaObjectKey(type: .messageType, schema: "", name: type))
            }
        }
        for row in sets.count > 3 ? sets[3] : [] {
            guard let key = context.objectKeys[row.int("object_id")] else { continue }
            var clauses = ["STATUS = \(row.bool("is_receive_enabled") ? "ON" : "OFF")",
                           "RETENTION = \(row.bool("is_retention_enabled") ? "ON" : "OFF")"]
            let procedure = row.string("activation_procedure")
            if !procedure.isEmpty {
                // Stored as a three-part name; the database part would pin the queue to the
                // source database.
                let parts = ModuleText.readName(TSQLLexer().significantTokens(procedure), from: 0).0
                let twoPart = parts.suffix(2)
                let procedureName = twoPart.count == 2
                    ? SQLIdentifier.quote(schema: twoPart.first!, name: twoPart.last!) : procedure
                var activation = "STATUS = \(row.bool("is_activation_enabled") ? "ON" : "OFF"), "
                    + "PROCEDURE_NAME = \(procedureName), MAX_QUEUE_READERS = \(row.int("max_readers"))"
                if let principal = row["execute_as_principal_id"], !principal.isNull {
                    let id = row.int("execute_as_principal_id")
                    activation += id == -2 ? ", EXECUTE AS OWNER"
                        : ", EXECUTE AS N'\(row.string("execute_as").replacingOccurrences(of: "'", with: "''"))'"
                } else {
                    activation += ", EXECUTE AS SELF"
                }
                clauses.append("ACTIVATION (\(activation))")
                if twoPart.count == 2 {
                    context.addReference(from: key, to: SchemaObjectKey(type: .storedProcedure,
                                                                        schema: twoPart.first!, name: twoPart.last!))
                }
            }
            clauses.append("POISON_MESSAGE_HANDLING (STATUS = "
                           + (row.bool("is_poison_message_handling_enabled", default: true) ? "ON" : "OFF") + ")")
            let body = "CREATE QUEUE \(key.quotedName) WITH " + clauses.joined(separator: ", ")
            context.mutate(key) { $0.body = body }
        }
        var serviceContracts: [Int: [String]] = [:]
        for row in sets.count > 5 ? sets[5] : [] {
            serviceContracts[row.int("service_id"), default: []].append(row.string("contract_name"))
        }
        for row in sets.count > 4 ? sets[4] : [] {
            let name = row.string("name")
            let id = row.int("service_id")
            let queue = SchemaObjectKey(type: .queue, schema: row.string("queue_schema"), name: row.string("queue_name"))
            var object = SchemaObject(type: .service, schema: "", name: name)
            let contracts = serviceContracts[id] ?? []
            object.body = "CREATE SERVICE \(SQLIdentifier.quote(name)) ON QUEUE \(queue.quotedName)"
            if !contracts.isEmpty {
                object.body += " (" + contracts.map(SQLIdentifier.quote).joined(separator: ", ") + ")"
            }
            context.add(object, serviceID: id)
            context.addReference(from: object.key, to: queue)
            for contract in contracts where !contract.hasPrefix("http://schemas.microsoft.com/") {
                context.addReference(from: object.key, to: SchemaObjectKey(type: .contract, schema: "", name: contract))
            }
        }
    }

    // MARK: - Permissions, properties, dependencies

    private func readPermissions(_ context: inout ReadContext) async throws {
        let sql = """
        SELECT CONVERT(int, p.class) AS class, p.major_id, p.minor_id, p.permission_name, p.state,
               pr.name AS grantee, CONVERT(int, pr.principal_id) AS grantee_id,
               CASE WHEN p.class = 1 AND p.minor_id > 0 THEN COL_NAME(p.major_id, p.minor_id) END AS column_name
        FROM sys.database_permissions AS p
        JOIN sys.database_principals AS pr ON pr.principal_id = p.grantee_principal_id
        WHERE p.class IN (0, 1, 3, 5, 6, 10, 15, 16, 17, 23, 29)
          AND p.state IN ('G', 'D', 'W');
        """
        for row in try await rows(sql, context) {
            let state: String
            switch row.string("state").trimmingCharacters(in: .whitespaces).uppercased() {
            case "D": state = "DENY"
            case "W": state = "GRANT_WITH_GRANT_OPTION"
            default: state = "GRANT"
            }
            let column = row.string("column_name")
            let permission = PermissionDefinition(state: state, permission: row.string("permission_name"),
                                                  grantee: row.string("grantee"),
                                                  column: column.isEmpty ? nil : column)
            let majorID = row.int("major_id")
            let target: SchemaObjectKey?
            switch row.int("class") {
            case 0:
                // Database-level permissions are part of the grantee principal. CONNECT is
                // implied by CREATE USER and would show up as noise on every user.
                guard permission.permission.uppercased() != "CONNECT" else { continue }
                target = context.principalKeys[row.int("grantee_id")]
            case 1: target = context.objectKeys[majorID]
            case 3: target = context.schemaKeys[majorID]
            case 5: target = context.assemblyKeys[majorID]
            case 6: target = context.typeKeys[majorID]
            case 10: target = context.xmlCollectionKeys[majorID]
            case 15: target = context.messageTypeKeys[majorID]
            case 16: target = context.contractKeys[majorID]
            case 17: target = context.serviceKeys[majorID]
            case 23: target = context.fullTextCatalogKeys[majorID]
            case 29: target = context.stoplistKeys[majorID]
            default: target = nil
            }
            guard let key = target else { continue }
            context.mutate(key) { $0.permissions.append(permission) }
        }
    }

    private func readExtendedProperties(_ context: inout ReadContext) async throws {
        let sql = """
        SELECT CONVERT(int, ep.class) AS class, ep.major_id, ep.minor_id, ep.name,
               CONVERT(nvarchar(max), ep.value) AS value,
               CASE WHEN ep.class = 2 THEN (SELECT p.name FROM sys.parameters AS p
                                            WHERE p.object_id = ep.major_id AND p.parameter_id = ep.minor_id)
               END AS parameter_name
        FROM sys.extended_properties AS ep
        WHERE ep.class IN (1, 2, 3, 4, 5, 6, 7, 10, 15, 16, 17)
          AND ep.name <> N'microsoft_database_tools_support';
        """
        for row in try await rows(sql, context) {
            let majorID = row.int("major_id")
            let minorID = row.int("minor_id")
            var property = ExtendedPropertyDefinition(name: row.string("name"), value: row.string("value"))
            var target: SchemaObjectKey?
            switch row.int("class") {
            case 1:
                if let key = context.objectKeys[majorID] {
                    target = key
                    if minorID > 0 {
                        property.childType = "COLUMN"
                        property.childName = context.columnNames[ColumnID(object: majorID, column: minorID)]
                    }
                } else if let owner = context.triggerOwners[majorID], let row2 = context.objectRows[majorID] {
                    target = owner
                    property.childType = "TRIGGER"
                    property.childName = row2.name
                } else if let row2 = context.objectRows[majorID], row2.parentID != 0,
                          let parent = context.objectKeys[row2.parentID] {
                    // Constraints are objects of their own, documented under their table.
                    target = parent
                    property.childType = "CONSTRAINT"
                    property.childName = row2.name
                }
            case 2:
                target = context.objectKeys[majorID]
                property.childType = "PARAMETER"
                property.childName = row.string("parameter_name")
            case 3: target = context.schemaKeys[majorID]
            case 4: target = context.principalKeys[majorID]
            case 5: target = context.assemblyKeys[majorID]
            case 6: target = context.typeKeys[majorID]
            case 7:
                if let key = context.objectKeys[majorID],
                   let indexName = context.indexNames[IndexID(object: majorID, index: minorID)] {
                    target = key
                    property.childType = "INDEX"
                    property.childName = indexName
                }
            case 10: target = context.xmlCollectionKeys[majorID]
            case 15: target = context.messageTypeKeys[majorID]
            case 16: target = context.contractKeys[majorID]
            case 17: target = context.serviceKeys[majorID]
            default: target = nil
            }
            guard let key = target else { continue }
            if property.childType != nil && property.childName == nil { continue }
            context.mutate(key) { $0.extendedProperties.append(property) }
        }
    }

    private func readDependencies(_ context: inout ReadContext) async throws {
        let sql = """
        SELECT sed.referencing_id, CONVERT(int, sed.referenced_class) AS referenced_class, sed.referenced_id
        FROM sys.sql_expression_dependencies AS sed
        WHERE sed.referenced_id IS NOT NULL AND sed.referencing_class = 1
          AND sed.referenced_database_name IS NULL AND sed.referenced_server_name IS NULL
          AND sed.referenced_id <> sed.referencing_id;
        """
        for row in try await rows(sql, context) {
            let referencingID = row.int("referencing_id")
            var from = context.objectKeys[referencingID]
            if from == nil, let owner = context.triggerOwners[referencingID] {
                from = owner
            }
            if from == nil, let entry = context.objectRows[referencingID], entry.parentID != 0 {
                from = context.objectKeys[entry.parentID]
            }
            guard let source = from else { continue }
            let referencedID = row.int("referenced_id")
            let to: SchemaObjectKey?
            switch row.int("referenced_class") {
            case 1: to = context.objectKeys[referencedID] ?? context.objectRows[referencedID].flatMap {
                $0.parentID != 0 ? context.objectKeys[$0.parentID] : nil
            }
            case 6: to = context.typeKeys[referencedID]
            case 10: to = context.xmlCollectionKeys[referencedID]
            default: to = nil
            }
            if let target = to, target != source { context.addReference(from: source, to: target) }
        }
    }
}

// MARK: - Read context

private struct ObjectRow {
    var id: Int
    var name: String
    var schema: String
    var type: String
    var parentID: Int
    var owner: String
    var isTools: Bool
    var isEncrypted: Bool
}

private struct ColumnID: Hashable {
    var object: Int
    var column: Int
}

private struct IndexID: Hashable {
    var object: Int
    var index: Int
}

/// Everything accumulated while reading, keyed by the catalog IDs the queries return.
private struct ReadContext {
    var database: String
    var majorVersion: Int
    var isAzure: Bool
    var origin = ""
    var databaseName = ""
    var collation = ""
    var compatibilityLevel = 0
    var serverVersion = ""
    var warnings: [String] = []

    var objects: [String: SchemaObject] = [:]
    var order: [String] = []

    var objectRows: [Int: ObjectRow] = [:]
    var objectKeys: [Int: SchemaObjectKey] = [:]
    var principalKeys: [Int: SchemaObjectKey] = [:]
    var principalNames: [Int: String] = [:]
    var schemaKeys: [Int: SchemaObjectKey] = [:]
    var typeKeys: [Int: SchemaObjectKey] = [:]
    var xmlCollectionKeys: [Int: SchemaObjectKey] = [:]
    var assemblyKeys: [Int: SchemaObjectKey] = [:]
    var fullTextCatalogKeys: [Int: SchemaObjectKey] = [:]
    var stoplistKeys: [Int: SchemaObjectKey] = [:]
    var messageTypeKeys: [Int: SchemaObjectKey] = [:]
    var contractKeys: [Int: SchemaObjectKey] = [:]
    var serviceKeys: [Int: SchemaObjectKey] = [:]
    var columnNames: [ColumnID: String] = [:]
    var columnsByObject: [Int: [ColumnDefinition]] = [:]
    var indexNames: [IndexID: String] = [:]
    var constraintOwners: [String: SchemaObjectKey] = [:]
    var triggerOwners: [Int: SchemaObjectKey] = [:]
    var partitionSchemes: Set<String> = []
    var pendingTypeReferences: [(SchemaObjectKey, String, String)] = []
    var references: [String: Set<SchemaObjectKey>] = [:]

    init(database: String, majorVersion: Int, isAzure: Bool) {
        self.database = database
        self.majorVersion = majorVersion
        self.isAzure = isAzure
    }

    mutating func add(_ object: SchemaObject, objectID: Int? = nil, principalID: Int? = nil,
                      schemaID: Int? = nil, typeID: Int? = nil, xmlCollectionID: Int? = nil,
                      assemblyID: Int? = nil, fullTextCatalogID: Int? = nil, stoplistID: Int? = nil,
                      messageTypeID: Int? = nil, contractID: Int? = nil, serviceID: Int? = nil) {
        let key = object.key
        if objects[key.matchKey] == nil { order.append(key.matchKey) }
        objects[key.matchKey] = object
        if let objectID { objectKeys[objectID] = key }
        if let principalID { principalKeys[principalID] = key }
        if let schemaID { schemaKeys[schemaID] = key }
        if let typeID { typeKeys[typeID] = key }
        if let xmlCollectionID { xmlCollectionKeys[xmlCollectionID] = key }
        if let assemblyID { assemblyKeys[assemblyID] = key }
        if let fullTextCatalogID { fullTextCatalogKeys[fullTextCatalogID] = key }
        if let stoplistID { stoplistKeys[stoplistID] = key }
        if let messageTypeID { messageTypeKeys[messageTypeID] = key }
        if let contractID { contractKeys[contractID] = key }
        if let serviceID { serviceKeys[serviceID] = key }
    }

    mutating func mutate(_ key: SchemaObjectKey, _ body: (inout SchemaObject) -> Void) {
        guard var object = objects[key.matchKey] else { return }
        body(&object)
        objects[key.matchKey] = object
    }

    mutating func addReference(from: SchemaObjectKey, to: SchemaObjectKey) {
        guard from != to else { return }
        references[from.matchKey, default: []].insert(to)
    }

    func snapshot() -> SchemaSnapshot {
        var typeLookup: [String: SchemaObjectKey] = [:]
        for object in objects.values where object.type == .userDefinedType || object.type == .tableType {
            typeLookup[object.key.namespaceKey] = object.key
        }

        var result: [SchemaObject] = []
        result.reserveCapacity(order.count)
        var extraReferences = references
        for (key, schema, name) in pendingTypeReferences {
            if let type = typeLookup["\(schema.lowercased()).\(name.lowercased())"] {
                extraReferences[key.matchKey, default: []].insert(type)
            }
        }
        for matchKey in order {
            guard var object = objects[matchKey] else { continue }
            var refs = extraReferences[matchKey] ?? []
            if object.type.isSchemaScoped, !object.schema.isEmpty {
                refs.insert(SchemaObjectKey(type: .schema, schema: "", name: object.schema))
            }
            if object.type == .schema, let owner = object.owner {
                refs.insert(SchemaObjectKey(type: .user, schema: "", name: owner))
                refs.insert(SchemaObjectKey(type: .role, schema: "", name: owner))
                refs.insert(SchemaObjectKey(type: .applicationRole, schema: "", name: owner))
            }
            if let owner = object.owner, object.type != .schema {
                refs.insert(SchemaObjectKey(type: .user, schema: "", name: owner))
                refs.insert(SchemaObjectKey(type: .role, schema: "", name: owner))
            }
            for role in object.roleMemberships {
                refs.insert(SchemaObjectKey(type: .role, schema: "", name: role))
            }
            // Keep only references to objects that exist in this database.
            object.references = refs.filter { $0 != object.key && objects[$0.matchKey] != nil }.sorted()
            object.permissions.sort()
            object.extendedProperties.sort()
            object.roleMemberships.sort { $0.lowercased() < $1.lowercased() }
            object.indexes.sort { $0.name.lowercased() < $1.name.lowercased() }
            object.triggers.sort { $0.name.lowercased() < $1.name.lowercased() }
            object.statistics.sort { $0.name.lowercased() < $1.name.lowercased() }
            if object.type == .table {
                object.table?.uniqueConstraints.sort { $0.name.lowercased() < $1.name.lowercased() }
                object.table?.checkConstraints.sort { $0.name.lowercased() < $1.name.lowercased() }
                object.table?.foreignKeys.sort { $0.name.lowercased() < $1.name.lowercased() }
            }
            result.append(object)
        }
        result.sort { $0.key < $1.key }
        return SchemaSnapshot(origin: origin, databaseName: databaseName, serverVersion: serverVersion,
                              compatibilityLevel: compatibilityLevel, defaultCollation: collation,
                              createdAt: Date(), objects: result, warnings: warnings)
    }
}
