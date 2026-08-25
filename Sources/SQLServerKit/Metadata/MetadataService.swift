import Foundation
import TDSKit

// MARK: - Column metadata

/// One row of `sys.columns`, already formatted for display.
///
/// The grid, the column designer and the scripter all read this, so the type name is
/// pre-rendered (`nvarchar(50)`, `decimal(18,2)`) and `maxLength` is in characters
/// rather than the bytes `sys.columns` reports for Unicode types.
public struct ColumnMetadata: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var ordinal: Int
    public var typeName: String
    public var baseTypeName: String
    public var maxLength: Int
    public var precision: Int
    public var scale: Int
    public var isNullable: Bool
    public var isIdentity: Bool
    public var isComputed: Bool
    public var isPrimaryKey: Bool
    public var isRowGuidCol: Bool
    public var collation: String
    public var defaultDefinition: String
    public var computedDefinition: String
    public var columnDescription: String
    public var identitySeed: String
    public var identityIncrement: String
    public var isSparse: Bool
    public var isFileStream: Bool
    /// 0 none, 1 `GENERATED ALWAYS AS ROW START`, 2 `... ROW END`.
    public var generatedAlwaysType: Int

    public init(name: String,
                ordinal: Int,
                typeName: String = "",
                baseTypeName: String = "",
                maxLength: Int = 0,
                precision: Int = 0,
                scale: Int = 0,
                isNullable: Bool = true,
                isIdentity: Bool = false,
                isComputed: Bool = false,
                isPrimaryKey: Bool = false,
                isRowGuidCol: Bool = false,
                collation: String = "",
                defaultDefinition: String = "",
                computedDefinition: String = "",
                columnDescription: String = "",
                identitySeed: String = "",
                identityIncrement: String = "",
                isSparse: Bool = false,
                isFileStream: Bool = false,
                generatedAlwaysType: Int = 0) {
        self.id = "\(ordinal):\(name)"
        self.name = name
        self.ordinal = ordinal
        self.typeName = typeName
        self.baseTypeName = baseTypeName
        self.maxLength = maxLength
        self.precision = precision
        self.scale = scale
        self.isNullable = isNullable
        self.isIdentity = isIdentity
        self.isComputed = isComputed
        self.isPrimaryKey = isPrimaryKey
        self.isRowGuidCol = isRowGuidCol
        self.collation = collation
        self.defaultDefinition = defaultDefinition
        self.computedDefinition = computedDefinition
        self.columnDescription = columnDescription
        self.identitySeed = identitySeed
        self.identityIncrement = identityIncrement
        self.isSparse = isSparse
        self.isFileStream = isFileStream
        self.generatedAlwaysType = generatedAlwaysType
    }

    /// `(PK, nvarchar(50), not null)` – the grey text SSMS puts after a column name.
    public var explorerDetail: String {
        var parts: [String] = []
        if isPrimaryKey { parts.append("PK") }
        if isComputed { parts.append("Computed") }
        parts.append(typeName)
        parts.append(isNullable ? "null" : "not null")
        return "(" + parts.joined(separator: ", ") + ")"
    }
}

// MARK: - Metadata service

/// Builds the Object Explorer tree and answers the metadata questions the editor asks.
///
/// Every folder expansion is exactly one round trip: the catalog queries aggregate
/// child lists (index key columns, trigger events, statistics columns) server-side with
/// `FOR XML PATH` instead of issuing a query per row.
public struct MetadataService: Sendable {

    private let session: SQLServerSession

    public init(session: SQLServerSession) {
        self.session = session
    }

    // MARK: Public API

    public func rootNode() async -> ObjectExplorerNode {
        let info = await session.serverInfo
        let profile = session.profile
        let name = info.serverName.isEmpty ? profile.server : info.serverName
        var detail = info.friendlyVersion
        if !info.productVersion.isEmpty { detail += " \(info.productVersion)" }
        if !info.loginName.isEmpty { detail += " - \(info.loginName)" }
        return ObjectExplorerNode(
            id: MetadataNodeID.root(session.id),
            parentID: nil,
            kind: .server,
            folder: nil,
            label: name,
            detail: "(\(detail))",
            iconName: MetadataIcon.name(for: .server),
            isExpandable: true,
            database: nil,
            schema: nil,
            name: name,
            objectID: nil,
            isSystemObject: false,
            info: [
                "edition": info.edition,
                "productLevel": info.productLevel,
                "collation": info.collation,
                "engineEdition": String(info.engineEdition),
                "isSysadmin": info.isSysadmin ? "1" : "0"
            ]
        )
    }

    public func children(of node: ObjectExplorerNode,
                         options: ObjectExplorerOptions) async throws -> [ObjectExplorerNode] {
        let info = await session.serverInfo
        switch node.kind {
        case .server:
            return serverChildren(node, info: info)
        case .database:
            return databaseChildren(node, info: info)
        case .table, .externalTable:
            return tableChildren(node)
        case .userDefinedTableType:
            return tableTypeChildren(node)
        case .view:
            return viewChildren(node)
        case .storedProcedure, .scalarFunction, .aggregateFunction:
            return [makeFolder(.parameters, parent: node, carryObject: true)]
        case .tableValuedFunction:
            return [
                makeFolder(.columns, parent: node, carryObject: true),
                makeFolder(.parameters, parent: node, carryObject: true)
            ]
        case .folder:
            guard let folder = node.folder else { return [] }
            return try await folderChildren(node, folder: folder, options: options, info: info)
        default:
            return []
        }
    }

    public func databaseNames(includeSystem: Bool) async throws -> [String] {
        let rows = try await rows(CatalogQueries.databaseNames(includeSystem: includeSystem))
        return rows.map { $0.string("DatabaseName") }.filter { !$0.isEmpty }
    }

    public func columns(database: String,
                        schema: String,
                        table: String) async throws -> [ColumnMetadata] {
        let sql = CatalogQueries.columns(schema: schema, table: table)
        let rows = try await rows(sql, database: database)
        guard !rows.isEmpty else {
            throw SQLServerError.objectNotFound("\(database).\(schema).\(table)")
        }
        return rows.map(Self.columnMetadata(from:))
    }

    public func search(text: String,
                       database: String,
                       limit: Int) async throws -> [ObjectExplorerNode] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let sql = CatalogQueries.search(text: trimmed, limit: max(limit, 1))
        let rows = try await rows(sql, database: database)
        return rows.compactMap { searchNode(from: $0, database: database) }
    }

    // MARK: Query helpers

    private func rows(_ sql: String, database: String? = nil) async throws -> [[String: TDSValue]] {
        let result = try await session.metadataQuery(sql, database: database)
        if let failure = result.errors.first { throw failure }
        return result.resultSets.first?.dictionaries() ?? []
    }

    /// Server-scoped catalog views live in `master` on Azure SQL Database, where a user
    /// database cannot see them at all. Elsewhere the current context is fine.
    private func serverScope(_ info: ServerInfo) -> String? {
        info.isAzureSQLDatabase ? "master" : nil
    }

    // MARK: Static tree levels

    private func serverChildren(_ node: ObjectExplorerNode,
                                info: ServerInfo) -> [ObjectExplorerNode] {
        [
            makeFolder(.databases, parent: node, carryObject: false),
            makeFolder(.security, parent: node, label: "Security", carryObject: false),
            makeFolder(.serverObjects, parent: node, carryObject: false),
            makeFolder(.management, parent: node,
                       isExpandable: !info.isAzureSQLDatabase, carryObject: false)
        ]
    }

    private func databaseChildren(_ node: ObjectExplorerNode,
                                  info: ServerInfo) -> [ObjectExplorerNode] {
        [
            makeFolder(.tables, parent: node, carryObject: false),
            makeFolder(.views, parent: node, carryObject: false),
            makeFolder(.synonyms, parent: node, carryObject: false),
            makeFolder(.programmability, parent: node, carryObject: false),
            makeFolder(.storage, parent: node, carryObject: false),
            makeFolder(.security, parent: node, label: "Security", carryObject: false)
        ]
    }

    private func tableChildren(_ node: ObjectExplorerNode) -> [ObjectExplorerNode] {
        [
            makeFolder(.columns, parent: node, carryObject: true),
            makeFolder(.keys, parent: node, carryObject: true),
            makeFolder(.constraints, parent: node, carryObject: true),
            makeFolder(.triggers, parent: node, carryObject: true),
            makeFolder(.indexes, parent: node, carryObject: true),
            makeFolder(.statistics, parent: node, carryObject: true)
        ]
    }

    /// A table type has no triggers and carries its statistics with the type, so it
    /// exposes fewer folders than a real table.
    private func tableTypeChildren(_ node: ObjectExplorerNode) -> [ObjectExplorerNode] {
        [
            makeFolder(.columns, parent: node, carryObject: true),
            makeFolder(.keys, parent: node, carryObject: true),
            makeFolder(.constraints, parent: node, carryObject: true),
            makeFolder(.indexes, parent: node, carryObject: true)
        ]
    }

    private func viewChildren(_ node: ObjectExplorerNode) -> [ObjectExplorerNode] {
        [
            makeFolder(.columns, parent: node, carryObject: true),
            makeFolder(.triggers, parent: node, carryObject: true),
            makeFolder(.indexes, parent: node, carryObject: true),
            makeFolder(.statistics, parent: node, carryObject: true)
        ]
    }

    // MARK: Folder dispatch

    private func folderChildren(_ node: ObjectExplorerNode,
                                folder: ObjectFolderKind,
                                options: ObjectExplorerOptions,
                                info: ServerInfo) async throws -> [ObjectExplorerNode] {
        switch folder {

        // Server level -------------------------------------------------------
        case .databases:
            var children: [ObjectExplorerNode] = [
                makeFolder(.systemDatabases, parent: node, isSystemFolder: true, carryObject: false)
            ]
            children += try await databaseNodes(node, scope: .user, options: options)
            return children

        case .systemDatabases:
            return try await databaseNodes(node, scope: .system, options: options)

        case .serverObjects:
            return [
                makeFolder(.linkedServers, parent: node, carryObject: false),
                makeFolder(.endpoints, parent: node, carryObject: false)
            ]

        case .management:
            return [makeFolder(.agent, parent: node, label: "SQL Server Agent", carryObject: false)]

        case .agent:
            return [makeFolder(.agentJobs, parent: node, label: "Jobs", carryObject: false)]

        case .agentJobs:
            return try await agentJobNodes(node, options: options, info: info)

        case .logins:
            return try await loginNodes(node, options: options, info: info)

        case .serverRoles:
            return try await serverRoleNodes(node, options: options, info: info)

        case .credentials:
            return try await credentialNodes(node, options: options, info: info)

        case .linkedServers:
            return try await linkedServerNodes(node, options: options, info: info)

        case .endpoints:
            return try await endpointNodes(node, options: options, info: info)

        // Security folder is reused at server and database scope --------------
        case .security:
            if node.database == nil {
                return [
                    makeFolder(.logins, parent: node, carryObject: false),
                    makeFolder(.serverRoles, parent: node, carryObject: false),
                    makeFolder(.credentials, parent: node, carryObject: false)
                ]
            }
            return [
                makeFolder(.databaseUsers, parent: node, label: "Users", carryObject: false),
                makeFolder(.databaseRoles, parent: node, carryObject: false),
                makeFolder(.applicationRoles, parent: node, carryObject: false),
                makeFolder(.schemas, parent: node, carryObject: false)
            ]

        // Tables and views ----------------------------------------------------
        case .tables:
            var children: [ObjectExplorerNode] = []
            if options.showSystemObjects {
                children.append(makeFolder(.systemTables, parent: node,
                                           isSystemFolder: true, carryObject: false))
            }
            children += try await tableNodes(node, systemObjects: false, options: options)
            return children

        case .systemTables:
            guard options.showSystemObjects else { return [] }
            return try await tableNodes(node, systemObjects: true, options: options)

        case .views:
            var children: [ObjectExplorerNode] = []
            if options.showSystemObjects {
                children.append(makeFolder(.systemViews, parent: node,
                                           isSystemFolder: true, carryObject: false))
            }
            children += try await viewNodes(node, systemObjects: false, options: options)
            return children

        case .systemViews:
            guard options.showSystemObjects else { return [] }
            return try await viewNodes(node, systemObjects: true, options: options)

        // Per-object detail folders -------------------------------------------
        case .columns:
            return try await columnNodes(node)

        case .keys:
            return try await keyNodes(node)

        case .constraints:
            return try await constraintNodes(node)

        case .indexes:
            return try await indexNodes(node)

        case .statistics:
            return try await statisticNodes(node)

        case .triggers:
            return try await objectTriggerNodes(node)

        case .parameters:
            return try await parameterNodes(node)

        // Programmability ------------------------------------------------------
        case .programmability:
            var children: [ObjectExplorerNode] = [
                makeFolder(.storedProcedures, parent: node, carryObject: false),
                makeFolder(.functions, parent: node, carryObject: false),
                makeFolder(.databaseTriggers, parent: node, carryObject: false),
                makeFolder(.assemblies, parent: node, carryObject: false),
                makeFolder(.types, parent: node, carryObject: false)
            ]
            if info.supportsSequences {
                children.append(makeFolder(.sequences, parent: node, carryObject: false))
            }
            children.append(makeFolder(.xmlSchemaCollections, parent: node, carryObject: false))
            return children

        case .storedProcedures:
            var children: [ObjectExplorerNode] = []
            if options.showSystemObjects {
                children.append(makeFolder(.systemStoredProcedures, parent: node,
                                           isSystemFolder: true, carryObject: false))
            }
            children += try await procedureNodes(node, systemObjects: false, options: options)
            return children

        case .systemStoredProcedures:
            guard options.showSystemObjects else { return [] }
            return try await procedureNodes(node, systemObjects: true, options: options)

        case .functions:
            var children: [ObjectExplorerNode] = [
                makeFolder(.tableValuedFunctions, parent: node,
                           label: "Table-valued Functions", carryObject: false),
                makeFolder(.scalarValuedFunctions, parent: node,
                           label: "Scalar-valued Functions", carryObject: false),
                makeFolder(.aggregateFunctions, parent: node,
                           label: "Aggregate Functions", carryObject: false)
            ]
            if options.showSystemObjects {
                children.append(makeFolder(.systemFunctions, parent: node,
                                           label: "System Functions",
                                           isSystemFolder: true, carryObject: false))
            }
            return children

        case .tableValuedFunctions:
            return try await functionNodes(node, group: .tableValued, options: options)

        case .scalarValuedFunctions:
            return try await functionNodes(node, group: .scalarValued, options: options)

        case .aggregateFunctions:
            return try await functionNodes(node, group: .aggregate, options: options)

        case .systemFunctions:
            guard options.showSystemObjects else { return [] }
            return try await functionNodes(node, group: .system, options: options)

        case .databaseTriggers:
            return try await databaseTriggerNodes(node, options: options)

        case .assemblies:
            return try await assemblyNodes(node, options: options)

        case .types:
            return [
                makeFolder(.systemDataTypes, parent: node,
                           isSystemFolder: true, carryObject: false),
                makeFolder(.userDefinedDataTypes, parent: node, carryObject: false),
                makeFolder(.userDefinedTableTypes, parent: node, carryObject: false)
            ]

        case .systemDataTypes:
            return try await systemDataTypeNodes(node, options: options)

        case .userDefinedDataTypes:
            return try await userDefinedDataTypeNodes(node, options: options)

        case .userDefinedTableTypes:
            return try await userDefinedTableTypeNodes(node, options: options)

        case .sequences:
            return try await sequenceNodes(node, options: options)

        case .synonyms:
            return try await synonymNodes(node, options: options)

        case .xmlSchemaCollections:
            return try await xmlSchemaCollectionNodes(node, options: options)

        // Storage ---------------------------------------------------------------
        case .storage:
            return [
                makeFolder(.filegroups, parent: node, carryObject: false),
                makeFolder(.databaseFiles, parent: node, carryObject: false),
                makeFolder(.partitionSchemes, parent: node, carryObject: false),
                makeFolder(.partitionFunctions, parent: node, carryObject: false)
            ]

        case .filegroups:
            return try await filegroupNodes(node, options: options)

        case .databaseFiles:
            return try await databaseFileNodes(node, options: options)

        case .partitionSchemes:
            return try await partitionSchemeNodes(node, options: options)

        case .partitionFunctions:
            return try await partitionFunctionNodes(node, options: options)

        // Database security ------------------------------------------------------
        case .databaseUsers:
            return try await databaseUserNodes(node, options: options)

        case .databaseRoles:
            return try await databaseRoleNodes(node, applicationRoles: false, options: options)

        case .applicationRoles:
            return try await databaseRoleNodes(node, applicationRoles: true, options: options)

        case .schemas:
            return try await schemaNodes(node, options: options)

        default:
            return []
        }
    }

    // MARK: Database level

    private func databaseNodes(_ parent: ObjectExplorerNode,
                               scope: CatalogQueries.DatabaseScope,
                               options: ObjectExplorerOptions) async throws -> [ObjectExplorerNode] {
        let rows = try await rows(CatalogQueries.databases(scope: scope, options: options))
        return rows.map { row in
            let name = row.string("DatabaseName")
            let state = row.string("StateDesc", default: "ONLINE")
            let isSystem = row.bool("IsSystem")
            return ObjectExplorerNode(
                id: MetadataNodeID.database(session.id, name),
                parentID: parent.id,
                kind: .database,
                folder: nil,
                label: name,
                detail: state == "ONLINE" ? nil : "(\(MetadataLabels.humanized(state)))",
                iconName: MetadataIcon.name(for: .database),
                isExpandable: state == "ONLINE",
                database: name,
                schema: nil,
                name: name,
                objectID: row.int("DatabaseId"),
                isSystemObject: isSystem,
                info: [
                    "state": state,
                    "recoveryModel": row.string("RecoveryModel"),
                    "compatibilityLevel": String(row.int("CompatibilityLevel")),
                    "collation": row.string("CollationName"),
                    "owner": row.string("OwnerName"),
                    "userAccess": row.string("UserAccess"),
                    "createDate": row.string("CreateDate"),
                    "isReadOnly": row.bool("IsReadOnly") ? "1" : "0"
                ]
            )
        }
    }

    // MARK: Tables and views

    private func tableNodes(_ parent: ObjectExplorerNode,
                            systemObjects: Bool,
                            options: ObjectExplorerOptions) async throws -> [ObjectExplorerNode] {
        let sql = CatalogQueries.tables(systemObjects: systemObjects, options: options)
        let rows = try await rows(sql, database: parent.database)
        return rows.map { row in
            let schema = row.string("SchemaName")
            let name = row.string("TableName")
            let isExternal = row.bool("IsExternal")
            let temporal = row.int("TemporalType")
            var detailParts: [String] = []
            if isExternal { detailParts.append("External") }
            if temporal == 2 { detailParts.append("System-Versioned") }
            if temporal == 1 { detailParts.append("History") }
            if row.bool("IsMemoryOptimized") { detailParts.append("Memory Optimized") }
            let kind: ObjectNodeKind = isExternal ? .externalTable : .table
            return ObjectExplorerNode(
                id: MetadataNodeID.object(parent.id, kind, schema: schema, name: name),
                parentID: parent.id,
                kind: kind,
                folder: nil,
                label: "\(schema).\(name)",
                detail: detailParts.isEmpty ? nil : "(\(detailParts.joined(separator: ", ")))",
                iconName: MetadataIcon.name(for: kind),
                isExpandable: true,
                database: parent.database,
                schema: schema,
                name: name,
                objectID: row.int("ObjectId"),
                isSystemObject: systemObjects,
                info: [
                    "createDate": row.string("CreateDate"),
                    "modifyDate": row.string("ModifyDate"),
                    "description": row.string("ObjectDescription"),
                    "temporalType": String(temporal)
                ]
            )
        }
    }

    private func viewNodes(_ parent: ObjectExplorerNode,
                           systemObjects: Bool,
                           options: ObjectExplorerOptions) async throws -> [ObjectExplorerNode] {
        let sql = CatalogQueries.views(systemObjects: systemObjects, options: options)
        let rows = try await rows(sql, database: parent.database)
        return rows.map { row in
            let schema = row.string("SchemaName")
            let name = row.string("ViewName")
            return ObjectExplorerNode(
                id: MetadataNodeID.object(parent.id, .view, schema: schema, name: name),
                parentID: parent.id,
                kind: .view,
                folder: nil,
                label: "\(schema).\(name)",
                detail: nil,
                iconName: MetadataIcon.name(for: .view),
                isExpandable: true,
                database: parent.database,
                schema: schema,
                name: name,
                objectID: row.int("ObjectId"),
                isSystemObject: systemObjects,
                info: [
                    "createDate": row.string("CreateDate"),
                    "modifyDate": row.string("ModifyDate"),
                    "description": row.string("ObjectDescription"),
                    "withCheckOption": row.bool("WithCheckOption") ? "1" : "0"
                ]
            )
        }
    }

    // MARK: Per-object detail folders

    private func columnNodes(_ parent: ObjectExplorerNode) async throws -> [ObjectExplorerNode] {
        guard let objectID = parent.objectID else { return [] }
        let rows = try await rows(CatalogQueries.columns(objectID: objectID),
                                  database: parent.database)
        return rows.map { row in
            let column = Self.columnMetadata(from: row)
            return ObjectExplorerNode(
                id: MetadataNodeID.object(parent.id, .column, schema: nil, name: column.name),
                parentID: parent.id,
                kind: .column,
                folder: nil,
                label: column.name,
                detail: column.explorerDetail,
                iconName: MetadataIcon.name(for: .column),
                isExpandable: false,
                database: parent.database,
                schema: parent.schema,
                name: column.name,
                objectID: objectID,
                isSystemObject: parent.isSystemObject,
                info: [
                    "ordinal": String(column.ordinal),
                    "type": column.typeName,
                    "baseType": column.baseTypeName,
                    "nullable": column.isNullable ? "1" : "0",
                    "identity": column.isIdentity ? "1" : "0",
                    "computed": column.computedDefinition,
                    "default": column.defaultDefinition,
                    "collation": column.collation,
                    "description": column.columnDescription
                ]
            )
        }
    }

    private func keyNodes(_ parent: ObjectExplorerNode) async throws -> [ObjectExplorerNode] {
        guard let objectID = parent.objectID else { return [] }
        let rows = try await rows(CatalogQueries.keys(objectID: objectID), database: parent.database)
        return rows.map { row in
            let name = row.string("KeyName")
            let type = row.string("KeyType")
            let kind: ObjectNodeKind
            var detail: String?
            switch type {
            case "PK":
                kind = .primaryKey
                let indexType = row.string("TypeDesc")
                detail = indexType.isEmpty ? nil : "(\(MetadataLabels.indexType(indexType)))"
            case "FK":
                kind = .foreignKey
                let referenced = "\(row.string("ReferencedSchema")).\(row.string("ReferencedTable"))"
                detail = "(referencing \(referenced))"
            default:
                kind = .uniqueKey
                let indexType = row.string("TypeDesc")
                detail = indexType.isEmpty ? nil : "(Unique, \(MetadataLabels.indexType(indexType)))"
            }
            return ObjectExplorerNode(
                id: MetadataNodeID.object(parent.id, kind, schema: nil, name: name),
                parentID: parent.id,
                kind: kind,
                folder: nil,
                label: name,
                detail: detail,
                iconName: MetadataIcon.name(for: kind),
                isExpandable: false,
                database: parent.database,
                schema: parent.schema,
                name: name,
                objectID: row.int("KeyObjectId"),
                isSystemObject: parent.isSystemObject,
                info: [
                    "keyType": type,
                    "columns": row.string("KeyColumns"),
                    "referencedSchema": row.string("ReferencedSchema"),
                    "referencedTable": row.string("ReferencedTable"),
                    "deleteAction": row.string("DeleteAction"),
                    "updateAction": row.string("UpdateAction"),
                    "isDisabled": row.bool("IsDisabled") ? "1" : "0",
                    "isNotTrusted": row.bool("IsNotTrusted") ? "1" : "0",
                    "parentTable": parent.name ?? ""
                ]
            )
        }
    }

    private func constraintNodes(_ parent: ObjectExplorerNode) async throws -> [ObjectExplorerNode] {
        guard let objectID = parent.objectID else { return [] }
        let rows = try await rows(CatalogQueries.constraints(objectID: objectID),
                                  database: parent.database)
        return rows.map { row in
            let name = row.string("ConstraintName")
            let type = row.string("ConstraintType")
            let isCheck = type == "CHECK"
            let kind: ObjectNodeKind = isCheck ? .checkConstraint : .defaultConstraint
            let column = row.string("ColumnName")
            var detail: String?
            if !isCheck, !column.isEmpty { detail = "(\(column))" }
            if isCheck, row.bool("IsDisabled") { detail = "(Disabled)" }
            return ObjectExplorerNode(
                id: MetadataNodeID.object(parent.id, kind, schema: nil, name: name),
                parentID: parent.id,
                kind: kind,
                folder: nil,
                label: name,
                detail: detail,
                iconName: MetadataIcon.name(for: kind),
                isExpandable: false,
                database: parent.database,
                schema: parent.schema,
                name: name,
                objectID: row.int("ConstraintObjectId"),
                isSystemObject: parent.isSystemObject,
                info: [
                    "constraintType": type,
                    "definition": row.string("Definition"),
                    "column": column,
                    "isDisabled": row.bool("IsDisabled") ? "1" : "0",
                    "isNotTrusted": row.bool("IsNotTrusted") ? "1" : "0",
                    "parentTable": parent.name ?? ""
                ]
            )
        }
    }

    private func indexNodes(_ parent: ObjectExplorerNode) async throws -> [ObjectExplorerNode] {
        guard let objectID = parent.objectID else { return [] }
        let rows = try await rows(CatalogQueries.indexes(objectID: objectID),
                                  database: parent.database)
        return rows.map { row in
            let name = row.string("IndexName")
            let typeLabel = MetadataLabels.indexType(row.string("TypeDesc"))
            let isPrimary = row.bool("IsPrimaryKey")
            let unique = row.bool("IsUnique")
            let detail = isPrimary
                ? "(\(typeLabel))"
                : "(\(unique ? "Unique" : "Non-Unique"), \(typeLabel))"
            var suffix = detail
            if row.bool("IsDisabled") { suffix = "(Disabled, " + detail.dropFirst() }
            return ObjectExplorerNode(
                id: MetadataNodeID.object(parent.id, .index, schema: nil, name: name),
                parentID: parent.id,
                kind: .index,
                folder: nil,
                label: name,
                detail: suffix,
                iconName: MetadataIcon.name(for: .index),
                isExpandable: false,
                database: parent.database,
                schema: parent.schema,
                name: name,
                objectID: objectID,
                isSystemObject: parent.isSystemObject,
                info: [
                    "indexId": String(row.int("IndexId")),
                    "typeDesc": row.string("TypeDesc"),
                    "columns": row.string("KeyColumns"),
                    "includedColumns": row.string("IncludedColumns"),
                    "isUnique": unique ? "1" : "0",
                    "isPrimaryKey": isPrimary ? "1" : "0",
                    "isUniqueConstraint": row.bool("IsUniqueConstraint") ? "1" : "0",
                    "isDisabled": row.bool("IsDisabled") ? "1" : "0",
                    "fillFactor": String(row.int("FillFactor")),
                    "isPadded": row.bool("IsPadded") ? "1" : "0",
                    "filterDefinition": row.string("FilterDefinition"),
                    "dataSpace": row.string("DataSpaceName"),
                    "parentTable": parent.name ?? ""
                ]
            )
        }
    }

    private func statisticNodes(_ parent: ObjectExplorerNode) async throws -> [ObjectExplorerNode] {
        guard let objectID = parent.objectID else { return [] }
        let rows = try await rows(CatalogQueries.statistics(objectID: objectID),
                                  database: parent.database)
        return rows.map { row in
            let name = row.string("StatsName")
            var flags: [String] = []
            if row.bool("AutoCreated") { flags.append("Auto Created") }
            if row.bool("UserCreated") { flags.append("User Created") }
            if row.bool("HasFilter") { flags.append("Filtered") }
            return ObjectExplorerNode(
                id: MetadataNodeID.object(parent.id, .statistic, schema: nil, name: name),
                parentID: parent.id,
                kind: .statistic,
                folder: nil,
                label: name,
                detail: flags.isEmpty ? nil : "(\(flags.joined(separator: ", ")))",
                iconName: MetadataIcon.name(for: .statistic),
                isExpandable: false,
                database: parent.database,
                schema: parent.schema,
                name: name,
                objectID: objectID,
                isSystemObject: parent.isSystemObject,
                info: [
                    "statsId": String(row.int("StatsId")),
                    "columns": row.string("StatsColumns"),
                    "noRecompute": row.bool("NoRecompute") ? "1" : "0",
                    "filterDefinition": row.string("FilterDefinition"),
                    "parentTable": parent.name ?? ""
                ]
            )
        }
    }

    private func objectTriggerNodes(_ parent: ObjectExplorerNode) async throws -> [ObjectExplorerNode] {
        guard let objectID = parent.objectID else { return [] }
        let rows = try await rows(CatalogQueries.objectTriggers(objectID: objectID),
                                  database: parent.database)
        return rows.map { triggerNode(from: $0, parent: parent) }
    }

    private func databaseTriggerNodes(_ parent: ObjectExplorerNode,
                                      options: ObjectExplorerOptions) async throws -> [ObjectExplorerNode] {
        let rows = try await rows(CatalogQueries.databaseTriggers(options: options),
                                  database: parent.database)
        return rows.map { triggerNode(from: $0, parent: parent) }
    }

    private func triggerNode(from row: [String: TDSValue],
                             parent: ObjectExplorerNode) -> ObjectExplorerNode {
        let name = row.string("TriggerName")
        var flags: [String] = []
        if row.bool("IsDisabled") { flags.append("Disabled") }
        if row.bool("IsInsteadOf") { flags.append("Instead Of") }
        return ObjectExplorerNode(
            id: MetadataNodeID.object(parent.id, .trigger, schema: nil, name: name),
            parentID: parent.id,
            kind: .trigger,
            folder: nil,
            label: name,
            detail: flags.isEmpty ? nil : "(\(flags.joined(separator: ", ")))",
            iconName: MetadataIcon.name(for: .trigger),
            isExpandable: false,
            database: parent.database,
            schema: parent.schema,
            name: name,
            objectID: row.int("ObjectId"),
            isSystemObject: row.bool("IsMSShipped"),
            info: [
                "typeDesc": row.string("TypeDesc"),
                "events": row.string("EventList"),
                "isDisabled": row.bool("IsDisabled") ? "1" : "0",
                "parentTable": parent.name ?? ""
            ]
        )
    }

    private func parameterNodes(_ parent: ObjectExplorerNode) async throws -> [ObjectExplorerNode] {
        guard let objectID = parent.objectID else { return [] }
        let rows = try await rows(CatalogQueries.parameters(objectID: objectID),
                                  database: parent.database)
        return rows.map { row in
            let name = row.string("ParameterName")
            let base = row.string("BaseTypeName")
            let declared = row.string("TypeName")
            let typeName = MetadataTypeFormatter.format(
                declared: declared,
                base: base,
                rawMaxLength: row.int("MaxLength"),
                precision: row.int("TypePrecision"),
                scale: row.int("TypeScale")
            )
            let direction = row.bool("IsOutput") ? "Output" : "Input"
            return ObjectExplorerNode(
                id: MetadataNodeID.object(parent.id, .parameter, schema: nil, name: name),
                parentID: parent.id,
                kind: .parameter,
                folder: nil,
                label: name,
                detail: "(\(typeName), \(direction))",
                iconName: MetadataIcon.name(for: .parameter),
                isExpandable: false,
                database: parent.database,
                schema: parent.schema,
                name: name,
                objectID: objectID,
                isSystemObject: parent.isSystemObject,
                info: [
                    "ordinal": String(row.int("ParameterId")),
                    "type": typeName,
                    "direction": direction,
                    "isReadOnly": row.bool("IsReadOnly") ? "1" : "0",
                    "hasDefault": row.bool("HasDefaultValue") ? "1" : "0",
                    "defaultValue": row.string("DefaultValue")
                ]
            )
        }
    }

    // MARK: Programmability

    private func procedureNodes(_ parent: ObjectExplorerNode,
                                systemObjects: Bool,
                                options: ObjectExplorerOptions) async throws -> [ObjectExplorerNode] {
        let sql = CatalogQueries.procedures(systemObjects: systemObjects, options: options)
        let rows = try await rows(sql, database: parent.database)
        return rows.map { moduleNode(from: $0, parent: parent, kind: .storedProcedure,
                                     isSystemObject: systemObjects) }
    }

    private func functionNodes(_ parent: ObjectExplorerNode,
                               group: CatalogQueries.FunctionGroup,
                               options: ObjectExplorerOptions) async throws -> [ObjectExplorerNode] {
        let sql = CatalogQueries.functions(group: group, options: options)
        let rows = try await rows(sql, database: parent.database)
        return rows.map { row in
            let kind = Self.functionKind(for: row.string("ObjectType"))
            return moduleNode(from: row, parent: parent, kind: kind,
                              isSystemObject: group == .system)
        }
    }

    private func moduleNode(from row: [String: TDSValue],
                            parent: ObjectExplorerNode,
                            kind: ObjectNodeKind,
                            isSystemObject: Bool) -> ObjectExplorerNode {
        let schema = row.string("SchemaName")
        let name = row.string("ObjectName")
        return ObjectExplorerNode(
            id: MetadataNodeID.object(parent.id, kind, schema: schema, name: name),
            parentID: parent.id,
            kind: kind,
            folder: nil,
            label: "\(schema).\(name)",
            detail: nil,
            iconName: MetadataIcon.name(for: kind),
            isExpandable: true,
            database: parent.database,
            schema: schema,
            name: name,
            objectID: row.int("ObjectId"),
            isSystemObject: isSystemObject || row.bool("IsMSShipped"),
            info: [
                "typeDesc": row.string("TypeDesc"),
                "objectType": row.string("ObjectType"),
                "createDate": row.string("CreateDate"),
                "modifyDate": row.string("ModifyDate")
            ]
        )
    }

    private func assemblyNodes(_ parent: ObjectExplorerNode,
                               options: ObjectExplorerOptions) async throws -> [ObjectExplorerNode] {
        let rows = try await rows(CatalogQueries.assemblies(options: options),
                                  database: parent.database)
        return rows.map { row in
            let name = row.string("AssemblyName")
            return ObjectExplorerNode(
                id: MetadataNodeID.object(parent.id, .assembly, schema: nil, name: name),
                parentID: parent.id,
                kind: .assembly,
                folder: nil,
                label: name,
                detail: "(\(MetadataLabels.humanized(row.string("PermissionSet"))))",
                iconName: MetadataIcon.name(for: .assembly),
                isExpandable: false,
                database: parent.database,
                schema: nil,
                name: name,
                objectID: row.int("AssemblyId"),
                isSystemObject: !row.bool("IsUserDefined"),
                info: ["clrName": row.string("ClrName"),
                       "permissionSet": row.string("PermissionSet")]
            )
        }
    }

    private func systemDataTypeNodes(_ parent: ObjectExplorerNode,
                                     options: ObjectExplorerOptions) async throws -> [ObjectExplorerNode] {
        let rows = try await rows(CatalogQueries.systemDataTypes(options: options),
                                  database: parent.database)
        return rows.map { typeNode(from: $0, parent: parent, isSystem: true) }
    }

    private func userDefinedDataTypeNodes(
        _ parent: ObjectExplorerNode,
        options: ObjectExplorerOptions
    ) async throws -> [ObjectExplorerNode] {
        let rows = try await rows(CatalogQueries.userDefinedDataTypes(options: options),
                                  database: parent.database)
        return rows.map { typeNode(from: $0, parent: parent, isSystem: false) }
    }

    private func typeNode(from row: [String: TDSValue],
                          parent: ObjectExplorerNode,
                          isSystem: Bool) -> ObjectExplorerNode {
        let schema = row.string("SchemaName")
        let name = row.string("TypeName")
        let base = row.string("BaseTypeName")
        let formatted = MetadataTypeFormatter.format(
            declared: base,
            base: base,
            rawMaxLength: row.int("MaxLength"),
            precision: row.int("TypePrecision"),
            scale: row.int("TypeScale")
        )
        let label = isSystem ? name : "\(schema).\(name)"
        var detailParts = [formatted]
        if !isSystem { detailParts.append(row.bool("IsNullable") ? "null" : "not null") }
        return ObjectExplorerNode(
            id: MetadataNodeID.object(parent.id, .userDefinedDataType,
                                      schema: isSystem ? nil : schema, name: name),
            parentID: parent.id,
            kind: .userDefinedDataType,
            folder: nil,
            label: label,
            detail: isSystem ? nil : "(\(detailParts.joined(separator: ", ")))",
            iconName: MetadataIcon.name(for: .userDefinedDataType),
            isExpandable: false,
            database: parent.database,
            schema: schema,
            name: name,
            objectID: row.int("TypeId"),
            isSystemObject: isSystem,
            info: [
                "baseType": base,
                "formattedType": formatted,
                "collation": row.string("CollationName"),
                "default": row.string("DefaultDefinition"),
                "isNullable": row.bool("IsNullable") ? "1" : "0"
            ]
        )
    }

    private func userDefinedTableTypeNodes(
        _ parent: ObjectExplorerNode,
        options: ObjectExplorerOptions
    ) async throws -> [ObjectExplorerNode] {
        let rows = try await rows(CatalogQueries.userDefinedTableTypes(options: options),
                                  database: parent.database)
        return rows.map { row in
            let schema = row.string("SchemaName")
            let name = row.string("TypeName")
            return ObjectExplorerNode(
                id: MetadataNodeID.object(parent.id, .userDefinedTableType,
                                          schema: schema, name: name),
                parentID: parent.id,
                kind: .userDefinedTableType,
                folder: nil,
                label: "\(schema).\(name)",
                detail: row.bool("IsMemoryOptimized") ? "(Memory Optimized)" : nil,
                iconName: MetadataIcon.name(for: .userDefinedTableType),
                isExpandable: true,
                database: parent.database,
                schema: schema,
                name: name,
                objectID: row.int("ObjectId"),
                isSystemObject: false,
                info: ["typeId": String(row.int("TypeId"))]
            )
        }
    }

    private func sequenceNodes(_ parent: ObjectExplorerNode,
                               options: ObjectExplorerOptions) async throws -> [ObjectExplorerNode] {
        let rows = try await rows(CatalogQueries.sequences(options: options),
                                  database: parent.database)
        return rows.map { row in
            let schema = row.string("SchemaName")
            let name = row.string("SequenceName")
            return ObjectExplorerNode(
                id: MetadataNodeID.object(parent.id, .sequence, schema: schema, name: name),
                parentID: parent.id,
                kind: .sequence,
                folder: nil,
                label: "\(schema).\(name)",
                detail: "(\(row.string("TypeName")))",
                iconName: MetadataIcon.name(for: .sequence),
                isExpandable: false,
                database: parent.database,
                schema: schema,
                name: name,
                objectID: row.int("ObjectId"),
                isSystemObject: false,
                info: [
                    "type": row.string("TypeName"),
                    "startValue": row.string("StartValue"),
                    "increment": row.string("IncrementValue"),
                    "currentValue": row.string("CurrentValue"),
                    "minimumValue": row.string("MinimumValue"),
                    "maximumValue": row.string("MaximumValue"),
                    "isCycling": row.bool("IsCycling") ? "1" : "0",
                    "cacheSize": String(row.int("CacheSize"))
                ]
            )
        }
    }

    private func synonymNodes(_ parent: ObjectExplorerNode,
                              options: ObjectExplorerOptions) async throws -> [ObjectExplorerNode] {
        let rows = try await rows(CatalogQueries.synonyms(options: options),
                                  database: parent.database)
        return rows.map { row in
            let schema = row.string("SchemaName")
            let name = row.string("SynonymName")
            let base = row.string("BaseObjectName")
            return ObjectExplorerNode(
                id: MetadataNodeID.object(parent.id, .synonym, schema: schema, name: name),
                parentID: parent.id,
                kind: .synonym,
                folder: nil,
                label: "\(schema).\(name)",
                detail: base.isEmpty ? nil : "(\(base))",
                iconName: MetadataIcon.name(for: .synonym),
                isExpandable: false,
                database: parent.database,
                schema: schema,
                name: name,
                objectID: row.int("ObjectId"),
                isSystemObject: false,
                info: ["baseObject": base]
            )
        }
    }

    private func xmlSchemaCollectionNodes(
        _ parent: ObjectExplorerNode,
        options: ObjectExplorerOptions
    ) async throws -> [ObjectExplorerNode] {
        let showSystem = options.showSystemObjects
        let rows = try await rows(
            CatalogQueries.xmlSchemaCollections(systemObjects: showSystem, options: options),
            database: parent.database
        )
        return rows.map { row in
            let schema = row.string("SchemaName")
            let name = row.string("CollectionName")
            return ObjectExplorerNode(
                id: MetadataNodeID.object(parent.id, .xmlSchemaCollection,
                                          schema: schema, name: name),
                parentID: parent.id,
                kind: .xmlSchemaCollection,
                folder: nil,
                label: "\(schema).\(name)",
                detail: nil,
                iconName: MetadataIcon.name(for: .xmlSchemaCollection),
                isExpandable: false,
                database: parent.database,
                schema: schema,
                name: name,
                objectID: row.int("CollectionId"),
                isSystemObject: schema == "sys",
                info: ["createDate": row.string("CreateDate")]
            )
        }
    }

    // MARK: Storage

    private func filegroupNodes(_ parent: ObjectExplorerNode,
                                options: ObjectExplorerOptions) async throws -> [ObjectExplorerNode] {
        let rows = try await rows(CatalogQueries.filegroups(options: options),
                                  database: parent.database)
        return rows.map { row in
            let name = row.string("FilegroupName")
            var flags: [String] = []
            if row.bool("IsDefault") { flags.append("Default") }
            if row.bool("IsReadOnly") { flags.append("Read-Only") }
            return ObjectExplorerNode(
                id: MetadataNodeID.object(parent.id, .filegroup, schema: nil, name: name),
                parentID: parent.id,
                kind: .filegroup,
                folder: nil,
                label: name,
                detail: flags.isEmpty ? nil : "(\(flags.joined(separator: ", ")))",
                iconName: MetadataIcon.name(for: .filegroup),
                isExpandable: false,
                database: parent.database,
                schema: nil,
                name: name,
                objectID: row.int("DataSpaceId"),
                isSystemObject: false,
                info: ["typeDesc": row.string("TypeDesc")]
            )
        }
    }

    private func databaseFileNodes(_ parent: ObjectExplorerNode,
                                   options: ObjectExplorerOptions) async throws -> [ObjectExplorerNode] {
        let rows = try await rows(CatalogQueries.databaseFiles(options: options),
                                  database: parent.database)
        return rows.map { row in
            let name = row.string("LogicalName")
            let sizeKB = row.int64("SizeKB")
            let detail = "(\(MetadataLabels.humanized(row.string("TypeDesc"))), "
                + "\(MetadataLabels.fileSize(kilobytes: sizeKB)))"
            return ObjectExplorerNode(
                id: MetadataNodeID.object(parent.id, .databaseFile, schema: nil, name: name),
                parentID: parent.id,
                kind: .databaseFile,
                folder: nil,
                label: name,
                detail: detail,
                iconName: MetadataIcon.name(for: .databaseFile),
                isExpandable: false,
                database: parent.database,
                schema: nil,
                name: name,
                objectID: row.int("FileId"),
                isSystemObject: false,
                info: [
                    "physicalName": row.string("PhysicalName"),
                    "typeDesc": row.string("TypeDesc"),
                    "state": row.string("StateDesc"),
                    "sizeKB": String(sizeKB),
                    "maxSize": String(row.int("MaxSize")),
                    "growth": String(row.int("Growth")),
                    "isPercentGrowth": row.bool("IsPercentGrowth") ? "1" : "0",
                    "filegroup": row.string("FilegroupName")
                ]
            )
        }
    }

    private func partitionSchemeNodes(_ parent: ObjectExplorerNode,
                                      options: ObjectExplorerOptions) async throws -> [ObjectExplorerNode] {
        let rows = try await rows(CatalogQueries.partitionSchemes(options: options),
                                  database: parent.database)
        return rows.map { row in
            let name = row.string("SchemeName")
            let function = row.string("FunctionName")
            return ObjectExplorerNode(
                id: MetadataNodeID.object(parent.id, .partitionScheme, schema: nil, name: name),
                parentID: parent.id,
                kind: .partitionScheme,
                folder: nil,
                label: name,
                detail: function.isEmpty ? nil : "(\(function))",
                iconName: MetadataIcon.name(for: .partitionScheme),
                isExpandable: false,
                database: parent.database,
                schema: nil,
                name: name,
                objectID: row.int("DataSpaceId"),
                isSystemObject: false,
                info: ["partitionFunction": function]
            )
        }
    }

    private func partitionFunctionNodes(_ parent: ObjectExplorerNode,
                                        options: ObjectExplorerOptions) async throws -> [ObjectExplorerNode] {
        let rows = try await rows(CatalogQueries.partitionFunctions(options: options),
                                  database: parent.database)
        return rows.map { row in
            let name = row.string("FunctionName")
            let boundary = row.bool("RangeRight") ? "Range Right" : "Range Left"
            return ObjectExplorerNode(
                id: MetadataNodeID.object(parent.id, .partitionFunction, schema: nil, name: name),
                parentID: parent.id,
                kind: .partitionFunction,
                folder: nil,
                label: name,
                detail: "(\(boundary), \(row.int("Fanout")) partitions)",
                iconName: MetadataIcon.name(for: .partitionFunction),
                isExpandable: false,
                database: parent.database,
                schema: nil,
                name: name,
                objectID: row.int("FunctionId"),
                isSystemObject: false,
                info: ["fanout": String(row.int("Fanout")), "boundary": boundary]
            )
        }
    }

    // MARK: Database security

    private func databaseUserNodes(_ parent: ObjectExplorerNode,
                                   options: ObjectExplorerOptions) async throws -> [ObjectExplorerNode] {
        let rows = try await rows(CatalogQueries.databaseUsers(options: options),
                                  database: parent.database)
        return rows.compactMap { row in
            let isSystem = row.bool("IsSystem")
            guard options.showSystemObjects || !isSystem else { return nil }
            let name = row.string("PrincipalName")
            return ObjectExplorerNode(
                id: MetadataNodeID.object(parent.id, .databaseUser, schema: nil, name: name),
                parentID: parent.id,
                kind: .databaseUser,
                folder: nil,
                label: name,
                detail: nil,
                iconName: MetadataIcon.name(for: .databaseUser),
                isExpandable: false,
                database: parent.database,
                schema: nil,
                name: name,
                objectID: row.int("PrincipalId"),
                isSystemObject: isSystem,
                info: [
                    "typeDesc": row.string("TypeDesc"),
                    "principalType": row.string("PrincipalType"),
                    "defaultSchema": row.string("DefaultSchema"),
                    "authenticationType": row.string("AuthenticationType"),
                    "createDate": row.string("CreateDate")
                ]
            )
        }
    }

    private func databaseRoleNodes(_ parent: ObjectExplorerNode,
                                   applicationRoles: Bool,
                                   options: ObjectExplorerOptions) async throws -> [ObjectExplorerNode] {
        let sql = CatalogQueries.databaseRoles(applicationRoles: applicationRoles, options: options)
        let rows = try await rows(sql, database: parent.database)
        let kind: ObjectNodeKind = applicationRoles ? .applicationRole : .databaseRole
        return rows.map { row in
            let name = row.string("PrincipalName")
            let isFixed = row.bool("IsFixedRole")
            return ObjectExplorerNode(
                id: MetadataNodeID.object(parent.id, kind, schema: nil, name: name),
                parentID: parent.id,
                kind: kind,
                folder: nil,
                label: name,
                detail: isFixed ? "(Fixed)" : nil,
                iconName: MetadataIcon.name(for: kind),
                isExpandable: false,
                database: parent.database,
                schema: nil,
                name: name,
                objectID: row.int("PrincipalId"),
                isSystemObject: isFixed,
                info: [
                    "typeDesc": row.string("TypeDesc"),
                    "owner": row.string("OwnerName"),
                    "defaultSchema": row.string("DefaultSchema"),
                    "createDate": row.string("CreateDate")
                ]
            )
        }
    }

    private func schemaNodes(_ parent: ObjectExplorerNode,
                             options: ObjectExplorerOptions) async throws -> [ObjectExplorerNode] {
        let rows = try await rows(CatalogQueries.schemas(options: options),
                                  database: parent.database)
        return rows.compactMap { row in
            let isSystem = row.bool("IsSystem")
            guard options.showSystemObjects || !isSystem else { return nil }
            let name = row.string("SchemaName")
            return ObjectExplorerNode(
                id: MetadataNodeID.object(parent.id, .schema, schema: nil, name: name),
                parentID: parent.id,
                kind: .schema,
                folder: nil,
                label: name,
                detail: nil,
                iconName: MetadataIcon.name(for: .schema),
                isExpandable: false,
                database: parent.database,
                schema: name,
                name: name,
                objectID: row.int("SchemaId"),
                isSystemObject: isSystem,
                info: ["owner": row.string("OwnerName")]
            )
        }
    }

    // MARK: Server security and server objects

    private func loginNodes(_ parent: ObjectExplorerNode,
                            options: ObjectExplorerOptions,
                            info: ServerInfo) async throws -> [ObjectExplorerNode] {
        let rows = try await rows(CatalogQueries.logins(options: options),
                                  database: serverScope(info))
        return rows.compactMap { row in
            let isSystem = row.bool("IsSystem")
            guard options.showSystemObjects || !isSystem else { return nil }
            let name = row.string("PrincipalName")
            return ObjectExplorerNode(
                id: MetadataNodeID.object(parent.id, .login, schema: nil, name: name),
                parentID: parent.id,
                kind: .login,
                folder: nil,
                label: name,
                detail: row.bool("IsDisabled") ? "(Disabled)" : nil,
                iconName: MetadataIcon.name(for: .login),
                isExpandable: false,
                database: nil,
                schema: nil,
                name: name,
                objectID: row.int("PrincipalId"),
                isSystemObject: isSystem,
                info: [
                    "typeDesc": row.string("TypeDesc"),
                    "principalType": row.string("PrincipalType"),
                    "defaultDatabase": row.string("DefaultDatabase"),
                    "defaultLanguage": row.string("DefaultLanguage"),
                    "isDisabled": row.bool("IsDisabled") ? "1" : "0",
                    "createDate": row.string("CreateDate")
                ]
            )
        }
    }

    private func serverRoleNodes(_ parent: ObjectExplorerNode,
                                 options: ObjectExplorerOptions,
                                 info: ServerInfo) async throws -> [ObjectExplorerNode] {
        let rows = try await rows(CatalogQueries.serverRoles(options: options),
                                  database: serverScope(info))
        return rows.map { row in
            let name = row.string("PrincipalName")
            let isFixed = row.bool("IsFixedRole")
            return ObjectExplorerNode(
                id: MetadataNodeID.object(parent.id, .serverRole, schema: nil, name: name),
                parentID: parent.id,
                kind: .serverRole,
                folder: nil,
                label: name,
                detail: isFixed ? "(Fixed)" : nil,
                iconName: MetadataIcon.name(for: .serverRole),
                isExpandable: false,
                database: nil,
                schema: nil,
                name: name,
                objectID: row.int("PrincipalId"),
                isSystemObject: isFixed,
                info: [
                    "typeDesc": row.string("TypeDesc"),
                    "owner": row.string("OwnerName"),
                    "createDate": row.string("CreateDate")
                ]
            )
        }
    }

    private func credentialNodes(_ parent: ObjectExplorerNode,
                                 options: ObjectExplorerOptions,
                                 info: ServerInfo) async throws -> [ObjectExplorerNode] {
        let rows = try await rows(CatalogQueries.credentials(options: options),
                                  database: serverScope(info))
        return rows.map { row in
            let name = row.string("CredentialName")
            let identity = row.string("CredentialIdentity")
            return ObjectExplorerNode(
                id: MetadataNodeID.object(parent.id, .credential, schema: nil, name: name),
                parentID: parent.id,
                kind: .credential,
                folder: nil,
                label: name,
                detail: identity.isEmpty ? nil : "(\(identity))",
                iconName: MetadataIcon.name(for: .credential),
                isExpandable: false,
                database: nil,
                schema: nil,
                name: name,
                objectID: row.int("CredentialId"),
                isSystemObject: false,
                info: ["identity": identity, "createDate": row.string("CreateDate")]
            )
        }
    }

    private func linkedServerNodes(_ parent: ObjectExplorerNode,
                                   options: ObjectExplorerOptions,
                                   info: ServerInfo) async throws -> [ObjectExplorerNode] {
        let rows = try await rows(CatalogQueries.linkedServers(options: options),
                                  database: serverScope(info))
        return rows.map { row in
            let name = row.string("ServerName")
            let product = row.string("Product")
            return ObjectExplorerNode(
                id: MetadataNodeID.object(parent.id, .linkedServer, schema: nil, name: name),
                parentID: parent.id,
                kind: .linkedServer,
                folder: nil,
                label: name,
                detail: product.isEmpty ? nil : "(\(product))",
                iconName: MetadataIcon.name(for: .linkedServer),
                isExpandable: false,
                database: nil,
                schema: nil,
                name: name,
                objectID: row.int("ServerId"),
                isSystemObject: false,
                info: [
                    "product": product,
                    "provider": row.string("Provider"),
                    "dataSource": row.string("DataSource"),
                    "catalog": row.string("CatalogName"),
                    "dataAccess": row.bool("IsDataAccessEnabled") ? "1" : "0"
                ]
            )
        }
    }

    private func endpointNodes(_ parent: ObjectExplorerNode,
                               options: ObjectExplorerOptions,
                               info: ServerInfo) async throws -> [ObjectExplorerNode] {
        let rows = try await rows(CatalogQueries.endpoints(options: options),
                                  database: serverScope(info))
        return rows.map { row in
            let name = row.string("EndpointName")
            return ObjectExplorerNode(
                id: MetadataNodeID.object(parent.id, .unknown, schema: nil, name: name),
                parentID: parent.id,
                kind: .unknown,
                folder: nil,
                label: name,
                detail: "(\(MetadataLabels.humanized(row.string("StateDesc"))))",
                iconName: MetadataIcon.folder,
                isExpandable: false,
                database: nil,
                schema: nil,
                name: name,
                objectID: row.int("EndpointId"),
                isSystemObject: false,
                info: [
                    "typeDesc": row.string("TypeDesc"),
                    "protocol": row.string("ProtocolDesc"),
                    "state": row.string("StateDesc")
                ]
            )
        }
    }

    private func agentJobNodes(_ parent: ObjectExplorerNode,
                               options: ObjectExplorerOptions,
                               info: ServerInfo) async throws -> [ObjectExplorerNode] {
        guard !info.isAzureSQLDatabase else { return [] }
        let rows = try await rows(CatalogQueries.agentJobs(options: options))
        return rows.map { row in
            let name = row.string("JobName")
            return ObjectExplorerNode(
                id: MetadataNodeID.object(parent.id, .agentJob, schema: nil, name: name),
                parentID: parent.id,
                kind: .agentJob,
                folder: nil,
                label: name,
                detail: row.bool("IsEnabled") ? nil : "(Disabled)",
                iconName: MetadataIcon.name(for: .agentJob),
                isExpandable: false,
                database: nil,
                schema: nil,
                name: name,
                objectID: nil,
                isSystemObject: false,
                info: [
                    "jobId": row.string("JobId"),
                    "description": row.string("JobDescription"),
                    "owner": row.string("OwnerName"),
                    "category": row.string("CategoryName"),
                    "createDate": row.string("CreateDate"),
                    "isEnabled": row.bool("IsEnabled") ? "1" : "0"
                ]
            )
        }
    }

    // MARK: Search

    /// Search hits carry the id they would have inside the tree, so the UI can reveal
    /// the match in place instead of opening a detached node.
    private func searchNode(from row: [String: TDSValue],
                            database: String) -> ObjectExplorerNode? {
        let schema = row.string("SchemaName")
        let name = row.string("ObjectName")
        guard !name.isEmpty else { return nil }
        let objectType = row.string("ObjectType")
        let isColumn = row.string("MatchKind") == "column"
        let parentName = row.string("ParentName")
        let objectKind = Self.nodeKind(for: objectType)

        let databaseID = MetadataNodeID.database(session.id, database)
        let ownerFolderID = MetadataNodeID.folderPath(databaseID, for: objectKind)
        let ownerID = MetadataNodeID.object(ownerFolderID, objectKind, schema: schema,
                                            name: isColumn ? parentName : name)

        if isColumn {
            let columnsFolder = MetadataNodeID.folder(ownerID, .columns)
            return ObjectExplorerNode(
                id: MetadataNodeID.object(columnsFolder, .column, schema: nil, name: name),
                parentID: columnsFolder,
                kind: .column,
                folder: nil,
                label: "\(schema).\(parentName).\(name)",
                detail: "(Column)",
                iconName: MetadataIcon.name(for: .column),
                isExpandable: false,
                database: database,
                schema: schema,
                name: name,
                objectID: row.int("ObjectId"),
                isSystemObject: false,
                info: ["parentTable": parentName, "matchKind": "column"]
            )
        }

        return ObjectExplorerNode(
            id: ownerID,
            parentID: ownerFolderID,
            kind: objectKind,
            folder: nil,
            label: "\(schema).\(name)",
            detail: "(\(MetadataLabels.kindTitle(objectKind)))",
            iconName: MetadataIcon.name(for: objectKind),
            isExpandable: objectKind != .synonym && objectKind != .sequence,
            database: database,
            schema: schema,
            name: name,
            objectID: row.int("ObjectId"),
            isSystemObject: false,
            info: ["matchKind": "object", "objectType": objectType]
        )
    }

    // MARK: Row decoding

    private static func columnMetadata(from row: [String: TDSValue]) -> ColumnMetadata {
        let base = row.string("BaseTypeName")
        let declared = row.string("TypeName")
        let rawMaxLength = row.int("MaxLength")
        let precision = row.int("TypePrecision")
        let scale = row.int("TypeScale")
        return ColumnMetadata(
            name: row.string("ColumnName"),
            ordinal: row.int("ColumnId"),
            typeName: MetadataTypeFormatter.format(declared: declared, base: base,
                                                   rawMaxLength: rawMaxLength,
                                                   precision: precision, scale: scale),
            baseTypeName: base,
            maxLength: MetadataTypeFormatter.characterLength(base: base, rawMaxLength: rawMaxLength),
            precision: precision,
            scale: scale,
            isNullable: row.bool("IsNullable"),
            isIdentity: row.bool("IsIdentity"),
            isComputed: row.bool("IsComputed"),
            isPrimaryKey: row.bool("IsPrimaryKey"),
            isRowGuidCol: row.bool("IsRowGuidCol"),
            collation: row.string("CollationName"),
            defaultDefinition: row.string("DefaultDefinition"),
            computedDefinition: row.string("ComputedDefinition"),
            columnDescription: row.string("ColumnDescription"),
            identitySeed: row.string("IdentitySeed"),
            identityIncrement: row.string("IdentityIncrement"),
            isSparse: row.bool("IsSparse"),
            isFileStream: row.bool("IsFileStream"),
            generatedAlwaysType: row.int("GeneratedAlwaysType")
        )
    }

    private static func functionKind(for objectType: String) -> ObjectNodeKind {
        switch objectType.uppercased() {
        case "IF", "TF", "FT": return .tableValuedFunction
        case "AF": return .aggregateFunction
        default: return .scalarFunction
        }
    }

    private static func nodeKind(for objectType: String) -> ObjectNodeKind {
        switch objectType.uppercased() {
        case "U": return .table
        case "V": return .view
        case "P", "PC", "X": return .storedProcedure
        case "FN", "FS": return .scalarFunction
        case "IF", "TF", "FT": return .tableValuedFunction
        case "AF": return .aggregateFunction
        case "SN": return .synonym
        case "SO": return .sequence
        case "TR", "TA": return .trigger
        default: return .unknown
        }
    }

    // MARK: Folder construction

    private func makeFolder(_ kind: ObjectFolderKind,
                            parent: ObjectExplorerNode,
                            label: String? = nil,
                            isExpandable: Bool = true,
                            isSystemFolder: Bool = false,
                            carryObject: Bool) -> ObjectExplorerNode {
        ObjectExplorerNode(
            id: MetadataNodeID.folder(parent.id, kind),
            parentID: parent.id,
            kind: .folder,
            folder: kind,
            label: label ?? MetadataLabels.folderTitle(kind),
            detail: nil,
            iconName: MetadataIcon.folder,
            isExpandable: isExpandable,
            database: parent.database,
            schema: carryObject ? parent.schema : nil,
            name: carryObject ? parent.name : nil,
            objectID: carryObject ? parent.objectID : nil,
            isSystemObject: isSystemFolder || parent.isSystemObject,
            info: carryObject ? parent.info : [:]
        )
    }
}

// MARK: - Node identity

/// Path-style node ids. They contain no row ids, so a refresh that renumbers
/// `object_id` values still produces the same id and the tree keeps its expansion.
private enum MetadataNodeID {

    static func root(_ sessionID: UUID) -> String {
        sessionID.uuidString
    }

    static func database(_ sessionID: UUID, _ name: String) -> String {
        "\(sessionID.uuidString)/db:\(name)"
    }

    static func folder(_ parent: String, _ kind: ObjectFolderKind) -> String {
        "\(parent)/folder:\(kind.rawValue)"
    }

    static func object(_ parent: String,
                       _ kind: ObjectNodeKind,
                       schema: String?,
                       name: String) -> String {
        if let schema, !schema.isEmpty {
            return "\(parent)/\(kind.rawValue):\(schema).\(name)"
        }
        return "\(parent)/\(kind.rawValue):\(name)"
    }

    /// The folder an object of `kind` lives in, relative to its database node.
    /// Used by search so a hit reuses the id the tree would give it.
    static func folderPath(_ databaseID: String, for kind: ObjectNodeKind) -> String {
        let programmability = folder(databaseID, .programmability)
        switch kind {
        case .table, .externalTable:
            return folder(databaseID, .tables)
        case .view:
            return folder(databaseID, .views)
        case .synonym:
            return folder(databaseID, .synonyms)
        case .storedProcedure:
            return folder(programmability, .storedProcedures)
        case .scalarFunction:
            return folder(folder(programmability, .functions), .scalarValuedFunctions)
        case .tableValuedFunction:
            return folder(folder(programmability, .functions), .tableValuedFunctions)
        case .aggregateFunction:
            return folder(folder(programmability, .functions), .aggregateFunctions)
        case .sequence:
            return folder(programmability, .sequences)
        case .trigger:
            return folder(programmability, .databaseTriggers)
        case .userDefinedTableType:
            return folder(folder(programmability, .types), .userDefinedTableTypes)
        case .userDefinedDataType:
            return folder(folder(programmability, .types), .userDefinedDataTypes)
        default:
            return databaseID
        }
    }
}

// MARK: - Icons

/// Single place where node kinds turn into SF Symbols.
private enum MetadataIcon {

    static let folder = "folder"

    static func name(for kind: ObjectNodeKind) -> String {
        switch kind {
        case .server:
            return "server.rack"
        case .database:
            return "cylinder"
        case .table, .externalTable, .userDefinedTableType:
            return "tablecells"
        case .view:
            return "eye"
        case .column, .parameter:
            return "list.bullet.rectangle"
        case .primaryKey, .uniqueKey, .foreignKey, .index, .statistic,
             .checkConstraint, .defaultConstraint:
            return "key.fill"
        case .sequence, .userDefinedDataType:
            return "number"
        case .storedProcedure, .scalarFunction, .tableValuedFunction,
             .aggregateFunction, .trigger:
            return "function"
        case .databaseUser, .databaseRole, .applicationRole, .login,
             .serverRole, .schema, .credential:
            return "person.crop.circle"
        default:
            return folder
        }
    }
}

// MARK: - Display labels

private enum MetadataLabels {

    static func folderTitle(_ kind: ObjectFolderKind) -> String {
        switch kind {
        case .databases: return "Databases"
        case .systemDatabases: return "System Databases"
        case .tables: return "Tables"
        case .systemTables: return "System Tables"
        case .views: return "Views"
        case .systemViews: return "System Views"
        case .columns: return "Columns"
        case .keys: return "Keys"
        case .constraints: return "Constraints"
        case .indexes: return "Indexes"
        case .triggers: return "Triggers"
        case .statistics: return "Statistics"
        case .programmability: return "Programmability"
        case .storedProcedures: return "Stored Procedures"
        case .systemStoredProcedures: return "System Stored Procedures"
        case .functions: return "Functions"
        case .tableValuedFunctions: return "Table-valued Functions"
        case .scalarValuedFunctions: return "Scalar-valued Functions"
        case .aggregateFunctions: return "Aggregate Functions"
        case .systemFunctions: return "System Functions"
        case .databaseTriggers: return "Database Triggers"
        case .assemblies: return "Assemblies"
        case .types: return "Types"
        case .systemDataTypes: return "System Data Types"
        case .userDefinedDataTypes: return "User-Defined Data Types"
        case .userDefinedTableTypes: return "User-Defined Table Types"
        case .xmlSchemaCollections: return "XML Schema Collections"
        case .sequences: return "Sequences"
        case .synonyms: return "Synonyms"
        case .storage: return "Storage"
        case .filegroups: return "Filegroups"
        case .databaseFiles: return "Database Files"
        case .partitionSchemes: return "Partition Schemes"
        case .partitionFunctions: return "Partition Functions"
        case .security: return "Security"
        case .databaseUsers: return "Users"
        case .databaseRoles: return "Database Roles"
        case .applicationRoles: return "Application Roles"
        case .schemas: return "Schemas"
        case .serverObjects: return "Server Objects"
        case .logins: return "Logins"
        case .serverRoles: return "Server Roles"
        case .credentials: return "Credentials"
        case .linkedServers: return "Linked Servers"
        case .endpoints: return "Endpoints"
        case .management: return "Management"
        case .agent: return "SQL Server Agent"
        case .agentJobs: return "Jobs"
        case .parameters: return "Parameters"
        default: return humanized(kind.rawValue)
        }
    }

    static func kindTitle(_ kind: ObjectNodeKind) -> String {
        switch kind {
        case .table: return "Table"
        case .externalTable: return "External Table"
        case .view: return "View"
        case .storedProcedure: return "Stored Procedure"
        case .scalarFunction: return "Scalar-valued Function"
        case .tableValuedFunction: return "Table-valued Function"
        case .aggregateFunction: return "Aggregate Function"
        case .synonym: return "Synonym"
        case .sequence: return "Sequence"
        case .trigger: return "Trigger"
        case .column: return "Column"
        default: return humanized(kind.rawValue)
        }
    }

    /// `NONCLUSTERED COLUMNSTORE` -> `Non-Clustered Columnstore`.
    static func indexType(_ typeDesc: String) -> String {
        let words = typeDesc.split(separator: " ").map { word -> String in
            switch word.uppercased() {
            case "NONCLUSTERED": return "Non-Clustered"
            case "CLUSTERED": return "Clustered"
            case "COLUMNSTORE": return "Columnstore"
            case "XML": return "XML"
            case "HASH": return "Hash"
            case "SPATIAL": return "Spatial"
            case "HEAP": return "Heap"
            default: return String(word).capitalized
            }
        }
        return words.isEmpty ? "Non-Clustered" : words.joined(separator: " ")
    }

    /// `ROWS` -> `Rows`, `READ_WRITE` -> `Read Write`, `camelCase` -> `Camel Case`.
    static func humanized(_ raw: String) -> String {
        guard !raw.isEmpty else { return raw }
        if raw == raw.uppercased() {
            return raw.split(whereSeparator: { $0 == "_" || $0 == " " })
                .map { String($0).capitalized }
                .joined(separator: " ")
        }
        var spaced = ""
        for character in raw {
            if character.isUppercase && !spaced.isEmpty { spaced.append(" ") }
            spaced.append(character)
        }
        return spaced.prefix(1).uppercased() + spaced.dropFirst()
    }

    static func fileSize(kilobytes: Int64) -> String {
        if kilobytes >= 1_048_576 { return "\(kilobytes / 1_048_576) GB" }
        if kilobytes >= 1_024 { return "\(kilobytes / 1_024) MB" }
        return "\(kilobytes) KB"
    }
}

// MARK: - Type formatting

/// Turns the raw `sys.columns` / `sys.parameters` shape into what SSMS prints.
private enum MetadataTypeFormatter {

    private static let unicodeTypes: Set<String> = ["nchar", "nvarchar", "sysname"]

    private static let lengthTypes: Set<String> = [
        "char", "varchar", "nchar", "nvarchar", "binary", "varbinary", "sysname"
    ]

    private static let precisionScaleTypes: Set<String> = ["decimal", "numeric"]

    private static let scaleOnlyTypes: Set<String> = ["datetime2", "datetimeoffset", "time"]

    /// `sys.columns.max_length` is bytes; the UI and DDL both want characters.
    static func characterLength(base: String, rawMaxLength: Int) -> Int {
        guard rawMaxLength != -1 else { return -1 }
        if unicodeTypes.contains(base.lowercased()) { return rawMaxLength / 2 }
        return rawMaxLength
    }

    static func format(declared: String,
                       base: String,
                       rawMaxLength: Int,
                       precision: Int,
                       scale: Int) -> String {
        let baseKey = base.lowercased()
        let display = declared.isEmpty ? base : declared
        if lengthTypes.contains(baseKey) {
            let length = characterLength(base: baseKey, rawMaxLength: rawMaxLength)
            return length == -1 ? "\(display)(max)" : "\(display)(\(length))"
        }
        if precisionScaleTypes.contains(baseKey) {
            return "\(display)(\(precision),\(scale))"
        }
        if scaleOnlyTypes.contains(baseKey) {
            return "\(display)(\(scale))"
        }
        // float(53) is the default; only a narrowed float carries its precision.
        if baseKey == "float" && precision != 53 && precision > 0 {
            return "\(display)(\(precision))"
        }
        return display
    }
}
