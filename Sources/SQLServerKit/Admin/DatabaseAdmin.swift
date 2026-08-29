import Foundation
import TDSKit

// MARK: - Models

/// One row of the Files page of SSMS's Database Properties dialog.
public struct DatabaseFileInfo: Sendable, Hashable, Identifiable {
    public var id: String { name }

    public var name: String
    public var physicalName: String
    /// "ROWS", "LOG" or "FILESTREAM", straight from `sys.database_files.type_desc`.
    public var type: String
    public var sizeMB: Double
    /// -1 means unrestricted growth, matching `sys.database_files.max_size`.
    public var maxSizeMB: Double
    /// SSMS style autogrowth text, e.g. "By 64 MB, Unlimited".
    public var growth: String
    public var filegroup: String
    public var usedMB: Double

    public init(name: String = "",
                physicalName: String = "",
                type: String = "",
                sizeMB: Double = 0,
                maxSizeMB: Double = -1,
                growth: String = "",
                filegroup: String = "",
                usedMB: Double = 0) {
        self.name = name
        self.physicalName = physicalName
        self.type = type
        self.sizeMB = sizeMB
        self.maxSizeMB = maxSizeMB
        self.growth = growth
        self.filegroup = filegroup
        self.usedMB = usedMB
    }
}

public struct DatabaseProperties: Sendable, Hashable {
    public var name: String
    public var databaseID: Int
    public var owner: String
    public var createDate: String
    public var collation: String
    public var compatibilityLevel: Int
    public var recoveryModel: String
    public var state: String
    public var isReadOnly: Bool
    public var isAutoClose: Bool
    public var isAutoShrink: Bool
    public var snapshotIsolationState: String
    public var isReadCommittedSnapshotOn: Bool
    public var pageVerifyOption: String
    public var userAccess: String
    public var sizeMB: Double
    public var spaceAvailableMB: Double
    public var lastFullBackup: String
    public var lastDifferentialBackup: String
    public var lastLogBackup: String
    public var files: [DatabaseFileInfo]

    public init(name: String = "",
                databaseID: Int = 0,
                owner: String = "",
                createDate: String = "",
                collation: String = "",
                compatibilityLevel: Int = 0,
                recoveryModel: String = "",
                state: String = "",
                isReadOnly: Bool = false,
                isAutoClose: Bool = false,
                isAutoShrink: Bool = false,
                snapshotIsolationState: String = "",
                isReadCommittedSnapshotOn: Bool = false,
                pageVerifyOption: String = "",
                userAccess: String = "",
                sizeMB: Double = 0,
                spaceAvailableMB: Double = 0,
                lastFullBackup: String = "",
                lastDifferentialBackup: String = "",
                lastLogBackup: String = "",
                files: [DatabaseFileInfo] = []) {
        self.name = name
        self.databaseID = databaseID
        self.owner = owner
        self.createDate = createDate
        self.collation = collation
        self.compatibilityLevel = compatibilityLevel
        self.recoveryModel = recoveryModel
        self.state = state
        self.isReadOnly = isReadOnly
        self.isAutoClose = isAutoClose
        self.isAutoShrink = isAutoShrink
        self.snapshotIsolationState = snapshotIsolationState
        self.isReadCommittedSnapshotOn = isReadCommittedSnapshotOn
        self.pageVerifyOption = pageVerifyOption
        self.userAccess = userAccess
        self.sizeMB = sizeMB
        self.spaceAvailableMB = spaceAvailableMB
        self.lastFullBackup = lastFullBackup
        self.lastDifferentialBackup = lastDifferentialBackup
        self.lastLogBackup = lastLogBackup
        self.files = files
    }
}

public struct TableProperties: Sendable, Hashable {
    public var schema: String
    public var name: String
    public var objectID: Int
    public var createDate: String
    public var modifyDate: String
    public var rowCount: Int64
    public var dataSpaceKB: Int64
    public var indexSpaceKB: Int64
    public var unusedSpaceKB: Int64
    public var totalSpaceKB: Int64
    public var hasPrimaryKey: Bool
    public var isMemoryOptimized: Bool
    public var isTemporal: Bool
    public var partitionCount: Int
    public var fileGroup: String
    public var indexCount: Int
    public var columnCount: Int

    public init(schema: String = "",
                name: String = "",
                objectID: Int = 0,
                createDate: String = "",
                modifyDate: String = "",
                rowCount: Int64 = 0,
                dataSpaceKB: Int64 = 0,
                indexSpaceKB: Int64 = 0,
                unusedSpaceKB: Int64 = 0,
                totalSpaceKB: Int64 = 0,
                hasPrimaryKey: Bool = false,
                isMemoryOptimized: Bool = false,
                isTemporal: Bool = false,
                partitionCount: Int = 1,
                fileGroup: String = "",
                indexCount: Int = 0,
                columnCount: Int = 0) {
        self.schema = schema
        self.name = name
        self.objectID = objectID
        self.createDate = createDate
        self.modifyDate = modifyDate
        self.rowCount = rowCount
        self.dataSpaceKB = dataSpaceKB
        self.indexSpaceKB = indexSpaceKB
        self.unusedSpaceKB = unusedSpaceKB
        self.totalSpaceKB = totalSpaceKB
        self.hasPrimaryKey = hasPrimaryKey
        self.isMemoryOptimized = isMemoryOptimized
        self.isTemporal = isTemporal
        self.partitionCount = partitionCount
        self.fileGroup = fileGroup
        self.indexCount = indexCount
        self.columnCount = columnCount
    }

    public var qualifiedName: String { SQLIdentifier.quote(schema: schema, name: name) }
}

public struct BackupRequest: Sendable {
    public enum Kind: String, Sendable, CaseIterable {
        case full, differential, log

        /// The label SSMS puts in the default media set name.
        public var mediaLabel: String {
            switch self {
            case .full: return "Full Database Backup"
            case .differential: return "Diff Database Backup"
            case .log: return "Transaction Log Backup"
            }
        }
    }

    public var database: String
    public var kind: Kind
    public var path: String
    public var compression: Bool
    public var checksum: Bool
    public var copyOnly: Bool
    /// INIT overwrites the media set; NOINIT appends to it.
    public var initialize: Bool
    public var name: String
    public var backupDescription: String
    public var verify: Bool

    public init(database: String,
                kind: Kind = .full,
                path: String,
                compression: Bool = true,
                checksum: Bool = true,
                copyOnly: Bool = false,
                initialize: Bool = false,
                name: String = "",
                backupDescription: String = "",
                verify: Bool = false) {
        self.database = database
        self.kind = kind
        self.path = path
        self.compression = compression
        self.checksum = checksum
        self.copyOnly = copyOnly
        self.initialize = initialize
        self.name = name
        self.backupDescription = backupDescription
        self.verify = verify
    }

    public var effectiveName: String {
        name.isEmpty ? "\(database)-\(kind.mediaLabel)" : name
    }
}

/// One backup set inside a media set, as reported by RESTORE HEADERONLY.
public struct RestoreHeaderInfo: Sendable, Hashable, Identifiable {
    public var id: Int { position }

    public var position: Int
    public var backupName: String
    public var backupDescription: String
    /// "Full", "Differential", "Transaction Log", ... derived from the numeric BackupType.
    public var backupType: String
    public var databaseName: String
    public var serverName: String
    public var userName: String
    public var recoveryModel: String
    public var backupStartDate: String
    public var backupFinishDate: String
    public var backupSizeBytes: Int64
    public var compressedSizeBytes: Int64
    public var firstLSN: String
    public var lastLSN: String
    public var checkpointLSN: String
    public var databaseBackupLSN: String

    public init(position: Int = 1,
                backupName: String = "",
                backupDescription: String = "",
                backupType: String = "",
                databaseName: String = "",
                serverName: String = "",
                userName: String = "",
                recoveryModel: String = "",
                backupStartDate: String = "",
                backupFinishDate: String = "",
                backupSizeBytes: Int64 = 0,
                compressedSizeBytes: Int64 = 0,
                firstLSN: String = "",
                lastLSN: String = "",
                checkpointLSN: String = "",
                databaseBackupLSN: String = "") {
        self.position = position
        self.backupName = backupName
        self.backupDescription = backupDescription
        self.backupType = backupType
        self.databaseName = databaseName
        self.serverName = serverName
        self.userName = userName
        self.recoveryModel = recoveryModel
        self.backupStartDate = backupStartDate
        self.backupFinishDate = backupFinishDate
        self.backupSizeBytes = backupSizeBytes
        self.compressedSizeBytes = compressedSizeBytes
        self.firstLSN = firstLSN
        self.lastLSN = lastLSN
        self.checkpointLSN = checkpointLSN
        self.databaseBackupLSN = databaseBackupLSN
    }
}

/// One file inside a backup set, as reported by RESTORE FILELISTONLY.
public struct RestoreFileInfo: Sendable, Hashable, Identifiable {
    public var id: String { logicalName }

    public var logicalName: String
    public var physicalName: String
    /// "ROWS", "LOG" or "FILESTREAM".
    public var type: String
    public var fileGroup: String
    public var sizeMB: Double
    public var maxSizeMB: Double
    public var fileID: Int

    public init(logicalName: String = "",
                physicalName: String = "",
                type: String = "",
                fileGroup: String = "",
                sizeMB: Double = 0,
                maxSizeMB: Double = 0,
                fileID: Int = 0) {
        self.logicalName = logicalName
        self.physicalName = physicalName
        self.type = type
        self.fileGroup = fileGroup
        self.sizeMB = sizeMB
        self.maxSizeMB = maxSizeMB
        self.fileID = fileID
    }
}

public struct IndexFragmentation: Sendable, Hashable, Identifiable {
    public var id: String { "\(schema).\(table).\(indexName)" }

    public var schema: String
    public var table: String
    public var indexName: String
    public var indexType: String
    public var fragmentationPercent: Double
    public var pageCount: Int64
    /// "REBUILD", "REORGANIZE" or "None".
    public var recommendation: String

    public init(schema: String = "",
                table: String = "",
                indexName: String = "",
                indexType: String = "",
                fragmentationPercent: Double = 0,
                pageCount: Int64 = 0,
                recommendation: String = "None") {
        self.schema = schema
        self.table = table
        self.indexName = indexName
        self.indexType = indexType
        self.fragmentationPercent = fragmentationPercent
        self.pageCount = pageCount
        self.recommendation = recommendation
    }
}

// MARK: - Database administration

/// The database-level operations behind SSMS's Database Properties dialog and the
/// Tasks submenu: state changes, maintenance, backup and restore.
public struct DatabaseAdmin: Sendable {

    private let session: SQLServerSession

    public init(session: SQLServerSession) {
        self.session = session
    }

    // MARK: - Properties

    public func properties(database: String) async throws -> DatabaseProperties {
        let info = await session.serverInfo
        // On Azure SQL Database sys.databases only ever shows the database you are
        // connected to, so the header has to be read from inside it.
        let headerContext: String? = info.isAzureSQLDatabase ? database : nil

        let headerSQL = """
        SELECT
            d.name                                                       AS DatabaseName,
            CAST(d.database_id AS int)                                   AS DatabaseId,
            ISNULL(SUSER_SNAME(d.owner_sid), N'')                        AS OwnerName,
            ISNULL(CONVERT(nvarchar(23), d.create_date, 121), N'')       AS CreateDate,
            ISNULL(d.collation_name, N'')                                AS Collation,
            CAST(d.compatibility_level AS int)                           AS CompatibilityLevel,
            ISNULL(d.recovery_model_desc, N'')                           AS RecoveryModel,
            ISNULL(d.state_desc, N'')                                    AS StateDesc,
            CAST(d.is_read_only AS int)                                  AS IsReadOnly,
            CAST(d.is_auto_close_on AS int)                              AS IsAutoClose,
            CAST(d.is_auto_shrink_on AS int)                             AS IsAutoShrink,
            ISNULL(d.snapshot_isolation_state_desc, N'')                 AS SnapshotIsolationState,
            CAST(d.is_read_committed_snapshot_on AS int)                 AS IsReadCommittedSnapshotOn,
            ISNULL(d.page_verify_option_desc, N'')                       AS PageVerifyOption,
            ISNULL(d.user_access_desc, N'')                              AS UserAccess
        FROM sys.databases AS d
        WHERE d.name = \(SQLIdentifier.literal(database));
        """

        let headerResult = try await session.metadataQuery(headerSQL, database: headerContext)
        guard let row = headerResult.resultSets.first?.dictionaries().first else {
            throw SQLServerError.objectNotFound(database)
        }

        var properties = DatabaseProperties(
            name: row.string("DatabaseName", default: database),
            databaseID: row.int("DatabaseId"),
            owner: row.string("OwnerName"),
            createDate: row.string("CreateDate"),
            collation: row.string("Collation"),
            compatibilityLevel: row.int("CompatibilityLevel"),
            recoveryModel: row.string("RecoveryModel"),
            state: row.string("StateDesc"),
            isReadOnly: row.bool("IsReadOnly"),
            isAutoClose: row.bool("IsAutoClose"),
            isAutoShrink: row.bool("IsAutoShrink"),
            snapshotIsolationState: row.string("SnapshotIsolationState"),
            isReadCommittedSnapshotOn: row.bool("IsReadCommittedSnapshotOn"),
            pageVerifyOption: row.string("PageVerifyOption"),
            userAccess: row.string("UserAccess")
        )

        // FILEPROPERTY and sys.database_files need the database to be online; an offline or
        // restoring database still deserves its header, so failure here is not fatal.
        if let files = try? await self.files(database: database) {
            properties.files = files
            properties.sizeMB = files.reduce(0) { $0 + $1.sizeMB }
            properties.spaceAvailableMB = max(0, properties.sizeMB - files.reduce(0) { $0 + $1.usedMB })
        }

        if !info.isAzureSQLDatabase, let backups = try? await backupHistory(database: database) {
            properties.lastFullBackup = backups.full
            properties.lastDifferentialBackup = backups.differential
            properties.lastLogBackup = backups.log
        }

        return properties
    }

    private func files(database: String) async throws -> [DatabaseFileInfo] {
        let sql = """
        SELECT
            f.name                                                AS FileName,
            ISNULL(f.physical_name, N'')                          AS PhysicalName,
            ISNULL(f.type_desc, N'')                              AS FileType,
            CAST(f.size AS bigint)                                AS SizePages,
            CAST(f.max_size AS bigint)                            AS MaxSizePages,
            CAST(f.growth AS bigint)                              AS GrowthUnits,
            CAST(f.is_percent_growth AS int)                      AS IsPercentGrowth,
            ISNULL(fg.name, N'')                                  AS FilegroupName,
            CAST(ISNULL(FILEPROPERTY(f.name, 'SpaceUsed'), 0) AS bigint) AS UsedPages
        FROM sys.database_files AS f
        LEFT JOIN sys.filegroups AS fg
            ON fg.data_space_id = f.data_space_id
        ORDER BY f.type, f.file_id;
        """

        let result = try await session.metadataQuery(sql, database: database)
        guard let set = result.resultSets.first else { return [] }
        return set.dictionaries().map { row in
            let type = row.string("FileType")
            let sizePages = row.int64("SizePages")
            let maxSizePages = row.int64("MaxSizePages")
            return DatabaseFileInfo(
                name: row.string("FileName"),
                physicalName: row.string("PhysicalName"),
                type: type,
                sizeMB: DatabaseAdmin.megabytes(pages: sizePages),
                maxSizeMB: maxSizePages < 0 ? -1 : DatabaseAdmin.megabytes(pages: maxSizePages),
                growth: DatabaseAdmin.growthDescription(growthUnits: row.int64("GrowthUnits"),
                                                        isPercent: row.bool("IsPercentGrowth"),
                                                        maxSizePages: maxSizePages,
                                                        fileType: type),
                filegroup: row.string("FilegroupName"),
                usedMB: DatabaseAdmin.megabytes(pages: row.int64("UsedPages"))
            )
        }
    }

    private func backupHistory(database: String) async throws
        -> (full: String, differential: String, log: String) {
        // msdb is unreachable on Azure SQL Database; callers guard on that before asking.
        let sql = """
        SELECT
            ISNULL(CONVERT(nvarchar(23),
                MAX(CASE WHEN b.type = 'D' THEN b.backup_finish_date END), 121), N'') AS LastFull,
            ISNULL(CONVERT(nvarchar(23),
                MAX(CASE WHEN b.type = 'I' THEN b.backup_finish_date END), 121), N'') AS LastDifferential,
            ISNULL(CONVERT(nvarchar(23),
                MAX(CASE WHEN b.type = 'L' THEN b.backup_finish_date END), 121), N'') AS LastLog
        FROM msdb.dbo.backupset AS b
        WHERE b.database_name = \(SQLIdentifier.literal(database));
        """
        let result = try await session.metadataQuery(sql)
        guard let row = result.resultSets.first?.dictionaries().first else { return ("", "", "") }
        return (row.string("LastFull"), row.string("LastDifferential"), row.string("LastLog"))
    }

    public func tableProperties(database: String,
                                schema: String,
                                table: String) async throws -> TableProperties {
        let info = await session.serverInfo
        // temporal_type only exists from SQL Server 2016 onwards.
        let temporalExpression = info.supportsTemporalTables
            ? "CAST(CASE WHEN t.temporal_type <> 0 THEN 1 ELSE 0 END AS int)"
            : "CAST(0 AS int)"

        let sql = """
        SELECT
            s.name                                                       AS SchemaName,
            t.name                                                       AS TableName,
            CAST(t.object_id AS int)                                     AS ObjectId,
            ISNULL(CONVERT(nvarchar(23), t.create_date, 121), N'')       AS CreateDate,
            ISNULL(CONVERT(nvarchar(23), t.modify_date, 121), N'')       AS ModifyDate,
            ISNULL((SELECT SUM(p.row_count)
                    FROM sys.dm_db_partition_stats AS p
                    WHERE p.object_id = t.object_id AND p.index_id < 2), 0)      AS RowCnt,
            ISNULL((SELECT SUM(p.reserved_page_count) * 8
                    FROM sys.dm_db_partition_stats AS p
                    WHERE p.object_id = t.object_id), 0)                          AS ReservedKB,
            ISNULL((SELECT SUM(p.used_page_count) * 8
                    FROM sys.dm_db_partition_stats AS p
                    WHERE p.object_id = t.object_id), 0)                          AS UsedKB,
            ISNULL((SELECT SUM(CASE WHEN p.index_id < 2
                                    THEN p.in_row_data_page_count
                                         + p.lob_used_page_count
                                         + p.row_overflow_used_page_count
                                    ELSE p.lob_used_page_count
                                         + p.row_overflow_used_page_count END) * 8
                    FROM sys.dm_db_partition_stats AS p
                    WHERE p.object_id = t.object_id), 0)                          AS DataKB,
            CAST(CASE WHEN EXISTS (SELECT 1 FROM sys.key_constraints AS k
                                   WHERE k.parent_object_id = t.object_id
                                     AND k.type = 'PK') THEN 1 ELSE 0 END AS int) AS HasPrimaryKey,
            CAST(t.is_memory_optimized AS int)                                    AS IsMemoryOptimized,
            \(temporalExpression)                                                 AS IsTemporal,
            ISNULL((SELECT COUNT(*) FROM sys.partitions AS pr
                    WHERE pr.object_id = t.object_id AND pr.index_id IN (0, 1)), 1) AS PartitionCount,
            ISNULL((SELECT TOP (1) ds.name
                    FROM sys.indexes AS i
                    JOIN sys.data_spaces AS ds ON ds.data_space_id = i.data_space_id
                    WHERE i.object_id = t.object_id AND i.index_id IN (0, 1)), N'') AS FileGroupName,
            ISNULL((SELECT COUNT(*) FROM sys.indexes AS ix
                    WHERE ix.object_id = t.object_id AND ix.index_id > 0), 0)     AS IndexCount,
            ISNULL((SELECT COUNT(*) FROM sys.columns AS c
                    WHERE c.object_id = t.object_id), 0)                          AS ColumnCount
        FROM sys.tables AS t
        JOIN sys.schemas AS s ON s.schema_id = t.schema_id
        WHERE s.name = \(SQLIdentifier.literal(schema))
          AND t.name = \(SQLIdentifier.literal(table));
        """

        let result = try await session.metadataQuery(sql, database: database)
        guard let row = result.resultSets.first?.dictionaries().first else {
            throw SQLServerError.objectNotFound("\(schema).\(table)")
        }

        let reserved = row.int64("ReservedKB")
        let used = row.int64("UsedKB")
        let data = row.int64("DataKB")
        return TableProperties(
            schema: row.string("SchemaName", default: schema),
            name: row.string("TableName", default: table),
            objectID: row.int("ObjectId"),
            createDate: row.string("CreateDate"),
            modifyDate: row.string("ModifyDate"),
            rowCount: row.int64("RowCnt"),
            dataSpaceKB: data,
            indexSpaceKB: max(0, used - data),
            unusedSpaceKB: max(0, reserved - used),
            totalSpaceKB: reserved,
            hasPrimaryKey: row.bool("HasPrimaryKey"),
            isMemoryOptimized: row.bool("IsMemoryOptimized"),
            isTemporal: row.bool("IsTemporal"),
            partitionCount: max(1, row.int("PartitionCount", default: 1)),
            fileGroup: row.string("FileGroupName"),
            indexCount: row.int("IndexCount"),
            columnCount: row.int("ColumnCount")
        )
    }

    // MARK: - Database options

    public func setRecoveryModel(database: String, model: String) async throws {
        let normalized = model.uppercased().replacingOccurrences(of: " ", with: "_")
        let allowed = ["FULL", "SIMPLE", "BULK_LOGGED"]
        guard allowed.contains(normalized) else {
            throw SQLServerError.unsupportedOperation(
                "Unknown recovery model '\(model)'. Use FULL, SIMPLE or BULK_LOGGED.")
        }
        try await alterDatabase(database,
                                clause: "RECOVERY \(normalized)",
                                azureFeature: "Changing the recovery model")
    }

    public func setCompatibilityLevel(database: String, level: Int) async throws {
        let allowed = [100, 110, 120, 130, 140, 150, 160, 170]
        guard allowed.contains(level) else {
            throw SQLServerError.unsupportedOperation(
                "Compatibility level \(level) is not a value SQL Server accepts.")
        }
        try await alterDatabase(database, clause: "COMPATIBILITY_LEVEL = \(level)", azureFeature: nil)
    }

    public func setReadOnly(database: String, readOnly: Bool) async throws {
        try await alterDatabase(database,
                                clause: readOnly ? "READ_ONLY" : "READ_WRITE",
                                azureFeature: nil,
                                terminate: true)
    }

    public func takeOffline(database: String) async throws {
        try await alterDatabase(database,
                                clause: "OFFLINE",
                                azureFeature: "Taking a database offline",
                                terminate: true)
    }

    public func bringOnline(database: String) async throws {
        try await alterDatabase(database, clause: "ONLINE", azureFeature: "Bringing a database online")
    }

    /// `clause` is always built from validated constants, never from raw user text.
    private func alterDatabase(_ database: String,
                               clause: String,
                               azureFeature: String?,
                               terminate: Bool = false) async throws {
        let info = await session.serverInfo
        if info.isAzureSQLDatabase, let feature = azureFeature {
            throw SQLServerError.unsupportedOperation(
                "\(feature) is not supported on Azure SQL Database.")
        }

        if info.isAzureSQLDatabase {
            // Azure SQL Database has no cross-database ALTER and no termination clause.
            try await run("ALTER DATABASE CURRENT SET \(clause);", database: database)
        } else {
            let rollback = terminate ? " WITH ROLLBACK IMMEDIATE" : ""
            // Run from master so the statement is never blocked by our own connection.
            try await run("ALTER DATABASE \(SQLIdentifier.quote(database)) SET \(clause)\(rollback);",
                          database: "master")
        }
    }

    // MARK: - Maintenance

    public func shrinkDatabase(_ database: String, targetPercent: Int) async throws {
        let percent = min(max(targetPercent, 0), 99)
        let info = await session.serverInfo
        let context = info.isAzureSQLDatabase ? database : "master"
        try await run("DBCC SHRINKDATABASE (\(SQLIdentifier.literal(database)), \(percent));",
                      database: context)
    }

    /// Returns everything DBCC CHECKDB printed. A clean run reports a single summary line.
    public func checkDatabase(_ database: String) async throws -> [String] {
        let info = await session.serverInfo
        let sql: String
        let context: String
        if info.isAzureSQLDatabase {
            // Azure SQL Database only checks the database you are connected to.
            sql = "DBCC CHECKDB WITH NO_INFOMSGS;"
            context = database
        } else {
            sql = "DBCC CHECKDB (\(SQLIdentifier.literal(database))) WITH NO_INFOMSGS;"
            context = "master"
        }

        let collector = DatabaseAdminMessageCollector()
        let connection = try await session.openConnection(database: context)
        do {
            try await connection.execute(sql) { event in
                switch event {
                case .info(let message), .error(let message):
                    collector.append(message)
                default:
                    break
                }
            }
            try? await connection.close()
        } catch {
            try? await connection.close()
            throw error
        }

        let lines = collector.lines
        if lines.isEmpty {
            return ["DBCC CHECKDB completed. No errors were reported for '\(database)'."]
        }
        return lines
    }

    public func updateStatistics(database: String, schema: String, table: String?) async throws {
        let sql: String
        if let table, !table.isEmpty {
            sql = "UPDATE STATISTICS \(SQLIdentifier.quote(schema: schema, name: table));"
        } else {
            sql = "EXEC sys.sp_updatestats;"
        }
        try await run(sql, database: database)
    }

    public func rebuildIndexes(database: String,
                               schema: String,
                               table: String,
                               online: Bool) async throws {
        let target = SQLIdentifier.quote(schema: schema, name: table)
        let options = online ? " WITH (ONLINE = ON)" : ""
        try await run("ALTER INDEX ALL ON \(target) REBUILD\(options);", database: database)
    }

    /// One index rather than all of them, which is what the index context menu asks for.
    public func rebuildIndex(database: String,
                             schema: String,
                             table: String,
                             index: String,
                             online: Bool) async throws {
        let target = SQLIdentifier.quote(schema: schema, name: table)
        let options = online ? " WITH (ONLINE = ON)" : ""
        try await run("ALTER INDEX \(SQLIdentifier.quote(index)) ON \(target) REBUILD\(options);",
                      database: database)
    }

    /// Disabling an index keeps its definition but drops its data; re-enabling it needs a
    /// rebuild, which is what SQL Server requires and what this emits.
    public func setIndexEnabled(database: String,
                                schema: String,
                                table: String,
                                index: String,
                                enabled: Bool) async throws {
        let target = SQLIdentifier.quote(schema: schema, name: table)
        let statement = enabled ? "REBUILD" : "DISABLE"
        try await run("ALTER INDEX \(SQLIdentifier.quote(index)) ON \(target) \(statement);",
                      database: database)
    }

    public func reorganizeIndex(database: String,
                                schema: String,
                                table: String,
                                index: String) async throws {
        let target = SQLIdentifier.quote(schema: schema, name: table)
        try await run("ALTER INDEX \(SQLIdentifier.quote(index)) ON \(target) REORGANIZE;",
                      database: database)
    }

    /// LIMITED mode only reads the parent level of the b-tree, which is what SSMS's
    /// index maintenance reports use. Indexes below 1000 pages are not worth touching.
    public func indexFragmentation(database: String) async throws -> [IndexFragmentation] {
        let sql = """
        SELECT
            s.name                                            AS SchemaName,
            o.name                                            AS TableName,
            i.name                                            AS IndexName,
            ISNULL(i.type_desc, N'')                          AS IndexType,
            CAST(SUM(ips.avg_fragmentation_in_percent * ips.page_count)
                 / NULLIF(SUM(ips.page_count), 0) AS float)   AS FragmentationPercent,
            CAST(SUM(ips.page_count) AS bigint)               AS PageCount
        FROM sys.dm_db_index_physical_stats(DB_ID(), NULL, NULL, NULL, 'LIMITED') AS ips
        JOIN sys.indexes AS i
            ON i.object_id = ips.object_id
           AND i.index_id = ips.index_id
        JOIN sys.objects AS o
            ON o.object_id = ips.object_id
        JOIN sys.schemas AS s
            ON s.schema_id = o.schema_id
        WHERE ips.index_id > 0
          AND ips.alloc_unit_type_desc = N'IN_ROW_DATA'
          AND i.name IS NOT NULL
          AND o.is_ms_shipped = 0
        GROUP BY s.name, o.name, i.name, i.type_desc
        HAVING SUM(ips.page_count) >= 1000
        ORDER BY FragmentationPercent DESC;
        """

        let result = try await run(sql, database: database)
        guard let set = result.resultSets.first else { return [] }
        return set.dictionaries().map { row in
            let fragmentation = row.double("FragmentationPercent")
            return IndexFragmentation(
                schema: row.string("SchemaName"),
                table: row.string("TableName"),
                indexName: row.string("IndexName"),
                indexType: row.string("IndexType"),
                fragmentationPercent: fragmentation,
                pageCount: row.int64("PageCount"),
                recommendation: DatabaseAdmin.recommendation(forFragmentation: fragmentation)
            )
        }
    }

    private static func recommendation(forFragmentation percent: Double) -> String {
        if percent > 30 { return "REBUILD" }
        if percent >= 5 { return "REORGANIZE" }
        return "None"
    }

    // MARK: - Backup

    public func backupScript(_ request: BackupRequest) async throws -> String {
        try await backupStatements(request).joined(separator: "\n\n")
    }

    public func performBackup(_ request: BackupRequest) async throws {
        let statements = try await backupStatements(request)
        for statement in statements {
            try await run(statement, database: "master")
        }
    }

    private func backupStatements(_ request: BackupRequest) async throws -> [String] {
        try await requireBackupSupport("BACKUP")
        guard !request.path.isEmpty else {
            throw SQLServerError.unsupportedOperation("A backup needs a destination path.")
        }

        let target = SQLIdentifier.quote(request.database)
        let device = "DISK = \(SQLIdentifier.literal(request.path))"
        let verb = request.kind == .log ? "BACKUP LOG \(target)" : "BACKUP DATABASE \(target)"

        var options: [String] = []
        if request.kind == .differential { options.append("DIFFERENTIAL") }
        if request.copyOnly { options.append("COPY_ONLY") }
        options.append(request.initialize ? "INIT" : "NOINIT")
        options.append("NOFORMAT")
        options.append("SKIP")
        options.append("NOREWIND")
        options.append("NOUNLOAD")
        options.append("NAME = \(SQLIdentifier.literal(request.effectiveName))")
        if !request.backupDescription.isEmpty {
            options.append("DESCRIPTION = \(SQLIdentifier.literal(request.backupDescription))")
        }
        if request.compression { options.append("COMPRESSION") }
        if request.checksum { options.append("CHECKSUM") }
        options.append("STATS = 10")

        var statements = ["\(verb)\n    TO \(device)\n    WITH \(options.joined(separator: ", "));"]
        if request.verify {
            statements.append("RESTORE VERIFYONLY\n    FROM \(device)\n    WITH NOUNLOAD, NOREWIND;")
        }
        return statements
    }

    // MARK: - Restore

    public func restoreScript(database: String,
                              fromPath: String,
                              replace: Bool,
                              moveFiles: [(logical: String, physical: String)]) -> String {
        var clauses = ["FILE = 1"]
        for file in moveFiles {
            clauses.append("MOVE \(SQLIdentifier.literal(file.logical)) "
                + "TO \(SQLIdentifier.literal(file.physical))")
        }
        clauses.append("NOUNLOAD")
        if replace { clauses.append("REPLACE") }
        clauses.append("RECOVERY")
        clauses.append("STATS = 5")

        let body = clauses.joined(separator: ",\n         ")
        return "RESTORE DATABASE \(SQLIdentifier.quote(database))\n"
            + "    FROM DISK = \(SQLIdentifier.literal(fromPath))\n"
            + "    WITH \(body);"
    }

    public func readBackupHeader(path: String) async throws -> [RestoreHeaderInfo] {
        try await requireBackupSupport("RESTORE HEADERONLY")
        let result = try await run("RESTORE HEADERONLY FROM DISK = \(SQLIdentifier.literal(path));",
                                   database: "master")
        guard let set = result.resultSets.first else { return [] }
        return set.dictionaries().enumerated().map { index, row in
            RestoreHeaderInfo(
                position: row.int("Position", default: index + 1),
                backupName: row.string("BackupName"),
                backupDescription: row.string("BackupDescription"),
                backupType: DatabaseAdmin.backupTypeName(row.int("BackupType")),
                databaseName: row.string("DatabaseName"),
                serverName: row.string("ServerName"),
                userName: row.string("UserName"),
                recoveryModel: row.string("RecoveryModel"),
                backupStartDate: row.string("BackupStartDate"),
                backupFinishDate: row.string("BackupFinishDate"),
                backupSizeBytes: row.int64("BackupSize"),
                compressedSizeBytes: row.int64("CompressedBackupSize"),
                firstLSN: row.string("FirstLSN"),
                lastLSN: row.string("LastLSN"),
                checkpointLSN: row.string("CheckpointLSN"),
                databaseBackupLSN: row.string("DatabaseBackupLSN")
            )
        }
    }

    public func readBackupFileList(path: String) async throws -> [RestoreFileInfo] {
        try await requireBackupSupport("RESTORE FILELISTONLY")
        let result = try await run("RESTORE FILELISTONLY FROM DISK = \(SQLIdentifier.literal(path));",
                                   database: "master")
        guard let set = result.resultSets.first else { return [] }
        return set.dictionaries().map { row in
            RestoreFileInfo(
                logicalName: row.string("LogicalName"),
                physicalName: row.string("PhysicalName"),
                type: DatabaseAdmin.fileTypeName(row.string("Type")),
                fileGroup: row.string("FileGroupName"),
                sizeMB: row.double("Size") / 1_048_576.0,
                maxSizeMB: row.double("MaxSize") / 1_048_576.0,
                fileID: row.int("FileId", default: row.int("FileID"))
            )
        }
    }

    private func requireBackupSupport(_ statement: String) async throws {
        let info = await session.serverInfo
        guard !info.isAzureSQLDatabase else {
            throw SQLServerError.unsupportedOperation(
                "\(statement) is not available on Azure SQL Database. Azure SQL Database manages "
                + "backups automatically; use point-in-time restore or a BACPAC export instead.")
        }
    }

    // MARK: - Execution helper

    /// Maintenance, backup and restore all run long. They get a connection of their own so the
    /// Object Explorer's shared metadata connection stays responsive.
    @discardableResult
    private func run(_ sql: String, database: String?) async throws -> TDSQueryResult {
        let connection = try await session.openConnection(database: database)
        do {
            let result = try await connection.query(sql)
            try? await connection.close()
            return result
        } catch {
            try? await connection.close()
            throw error
        }
    }

    // MARK: - Formatting helpers

    private static func megabytes(pages: Int64) -> Double {
        Double(pages) * 8.0 / 1024.0
    }

    private static func sizeText(pages: Int64) -> String {
        let kilobytes = pages * 8
        if kilobytes % 1024 == 0 { return "\(kilobytes / 1024) MB" }
        return "\(kilobytes) KB"
    }

    /// SSMS renders autogrowth as "By 64 MB, Unlimited" or "By 10 percent, Limited to 100 MB".
    private static func growthDescription(growthUnits: Int64,
                                          isPercent: Bool,
                                          maxSizePages: Int64,
                                          fileType: String) -> String {
        guard growthUnits != 0, maxSizePages != 0 else { return "None" }

        let growthPart = isPercent ? "By \(growthUnits) percent" : "By \(sizeText(pages: growthUnits))"
        // A log file capped at 2 TB is SQL Server's way of saying unrestricted.
        let logUnlimited = fileType.uppercased() == "LOG" && maxSizePages == 268_435_456
        let limitPart = (maxSizePages < 0 || logUnlimited)
            ? "Unlimited"
            : "Limited to \(sizeText(pages: maxSizePages))"
        return "\(growthPart), \(limitPart)"
    }

    private static func backupTypeName(_ code: Int) -> String {
        switch code {
        case 1: return "Full"
        case 2: return "Transaction Log"
        case 4: return "File or Filegroup"
        case 5: return "Differential"
        case 6: return "Differential File"
        case 7: return "Partial"
        case 8: return "Differential Partial"
        default: return "Unknown (\(code))"
        }
    }

    private static func fileTypeName(_ code: String) -> String {
        switch code.uppercased() {
        case "D": return "ROWS"
        case "L": return "LOG"
        case "S", "F": return "FILESTREAM"
        default: return code
        }
    }
}

// MARK: - Message collection

/// DBCC reports its findings as info and error tokens rather than result sets, and the
/// stream sink is called off the caller's isolation, so the buffer needs its own lock.
private final class DatabaseAdminMessageCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: [String] = []

    func append(_ message: TDSServerMessage) {
        let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        lock.lock()
        buffer.append(text)
        lock.unlock()
    }

    var lines: [String] {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }
}
