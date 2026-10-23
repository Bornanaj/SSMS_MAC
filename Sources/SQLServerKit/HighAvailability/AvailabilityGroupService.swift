import Foundation
import TDSKit

/// A database that could still be added to an availability group, with the two
/// prerequisites SSMS checks before it lets you pick it.
public struct AvailabilityCandidateDatabase: Sendable, Hashable, Identifiable {
    public var id: String { name }
    public var name: String
    public var recoveryModel: String
    public var hasLogBackup: Bool

    public init(name: String, recoveryModel: String, hasLogBackup: Bool) {
        self.name = name
        self.recoveryModel = recoveryModel
        self.hasLogBackup = hasLogBackup
    }

    public var isFullRecovery: Bool { recoveryModel.uppercased() == "FULL" }
    public var isReady: Bool { isFullRecovery && hasLogBackup }

    public var blocker: String {
        if !isFullRecovery { return "Not in the full recovery model" }
        if !hasLogBackup { return "No full backup has been taken" }
        return ""
    }
}

/// Everything the Always On dashboard reads. One service per session; each call is a
/// single round trip, and the dashboard batches what it needs per refresh.
public struct AvailabilityGroupService: Sendable {
    private let session: SQLServerSession

    public init(session: SQLServerSession) {
        self.session = session
    }

    // MARK: - Capability

    /// Always On arrived in SQL Server 2012 and is not a thing on Azure SQL Database,
    /// where the geo-replication story is a different feature entirely.
    public func availability() async -> (supported: Bool, enabled: Bool, reason: String) {
        let info = await session.serverInfo
        if info.isAzureSQLDatabase {
            return (false, false, "Azure SQL Database has no Always On availability groups. "
                    + "Use active geo-replication or failover groups in the Azure portal.")
        }
        if info.isAzureSynapse {
            return (false, false, "Always On availability groups do not apply to Synapse.")
        }
        if info.majorVersion > 0 && info.majorVersion < 11 {
            return (false, false, "Always On availability groups need SQL Server 2012 or later.")
        }
        let sql = """
        SELECT CONVERT(int, ISNULL(SERVERPROPERTY('IsHadrEnabled'), 0)) AS is_enabled
        """
        guard let result = try? await session.metadataQuery(sql, database: "master"),
              let row = result.resultSets.first?.dictionaries().first else {
            return (true, false, "The Always On state could not be read on this instance.")
        }
        let enabled = row.int("is_enabled") == 1
        return (true, enabled, enabled
                ? ""
                : "Always On availability groups are not enabled on this instance. "
                    + "Enable them in SQL Server Configuration Manager and restart the service.")
    }

    private func requireAlwaysOn() async throws {
        let state = await availability()
        guard state.supported else {
            throw SQLServerError.unsupportedOperation(state.reason)
        }
        guard state.enabled else {
            throw SQLServerError.unsupportedOperation(state.reason)
        }
    }

    /// Which columns this engine actually has. Asking for one it does not is an
    /// "Invalid column name" error that takes the whole query with it, so each group of
    /// columns is gated by the version that introduced it:
    ///
    /// - 2016 (13.x): `db_failover`, `dtc_support`, `basic_features`,
    ///   `required_synchronized_secondaries_to_commit`, `is_distributed`, `seeding_mode_desc`
    /// - 2017 (14.x): `cluster_type_desc`, and `secondary_lag_seconds` as a column that
    ///   is there on every build (2016 only got it in SP2)
    public static func capabilities(_ info: ServerInfo)
        -> (modern: Bool, seeding: Bool, clusterType: Bool, lag: Bool) {
        let major = info.majorVersion
        return (major >= 13, major >= 13, major >= 14, major >= 14)
    }

    // MARK: - Reads

    /// The availability group query, built for one engine version.
    ///
    /// Columns are gated rather than assumed: asking an engine for a column it does
    /// not have is an "Invalid column name" error that takes the whole query with it,
    /// and an availability group is exactly the kind of thing that is still running on
    /// an older build.
    public static func groupsQuery(_ info: ServerInfo) -> String {
        let caps = AvailabilityGroupService.capabilities(info)
        let modernColumns = caps.modern
            ? """
              CONVERT(int, ag.db_failover) AS db_failover,
                     CONVERT(int, ag.dtc_support) AS dtc_support,
                     CONVERT(int, ag.basic_features) AS basic_features,
                     ag.required_synchronized_secondaries_to_commit AS required_secondaries,
                     CONVERT(int, ag.is_distributed) AS is_distributed,
              """
            : """
              0 AS db_failover, 0 AS dtc_support, 0 AS basic_features,
                     0 AS required_secondaries, 0 AS is_distributed,
              """
        // CLUSTER_TYPE arrived with the Linux-era 2017 engine; before that every group
        // is on a Windows cluster by definition.
        let clusterTypeColumn = caps.clusterType
            ? "ISNULL(ag.cluster_type_desc, N'WSFC') AS cluster_type,"
            : "N'WSFC' AS cluster_type,"

        let sql = """
        SELECT ag.name AS group_name,
               CONVERT(nvarchar(36), ag.group_id) AS group_id,
               ISNULL(ags.primary_replica, N'') AS primary_replica,
               ISNULL(ag.automated_backup_preference_desc, N'SECONDARY') AS backup_preference,
               ISNULL(ag.failure_condition_level, 3) AS failure_condition_level,
               ISNULL(ag.health_check_timeout, 30000) AS health_check_timeout,
               ISNULL(ags.synchronization_health_desc, N'') AS sync_health,
               ISNULL(ags.primary_recovery_health_desc, N'') AS recovery_health,
               \(modernColumns)
               \(clusterTypeColumn)
               (SELECT COUNT(*) FROM sys.availability_replicas AS r
                WHERE r.group_id = ag.group_id) AS replica_count,
               (SELECT COUNT(DISTINCT drs.group_database_id)
                FROM sys.dm_hadr_database_replica_cluster_states AS drs
                JOIN sys.availability_replicas AS r2 ON r2.replica_id = drs.replica_id
                WHERE r2.group_id = ag.group_id) AS database_count,
               ISNULL(STUFF((SELECT N', ' + l.dns_name + N',' + CAST(l.port AS nvarchar(10))
                             FROM sys.availability_group_listeners AS l
                             WHERE l.group_id = ag.group_id
                             ORDER BY l.dns_name
                             FOR XML PATH(N''), TYPE).value(N'.', N'nvarchar(max)'),
                            1, 2, N''), N'') AS listeners,
               CASE WHEN ISNULL(ags.primary_replica, N'') =
                         CAST(SERVERPROPERTY('ServerName') AS nvarchar(256))
                    THEN 1 ELSE 0 END AS is_local_primary
        FROM sys.availability_groups AS ag
        LEFT JOIN sys.dm_hadr_availability_group_states AS ags ON ags.group_id = ag.group_id
        ORDER BY ag.name
        """
        return sql
    }

    public func groups() async throws -> [AvailabilityGroup] {
        try await requireAlwaysOn()
        let sql = AvailabilityGroupService.groupsQuery(await session.serverInfo)
        return try await rows(sql).map { row in
            AvailabilityGroup(
                name: row.string("group_name"),
                groupID: row.string("group_id"),
                primaryReplica: row.string("primary_replica"),
                clusterTypeDescription: row.string("cluster_type"),
                isDistributed: row.int("is_distributed") == 1,
                automatedBackupPreference: BackupPreference(
                    rawValue: row.string("backup_preference").uppercased()) ?? .secondary,
                failureConditionLevel: row.int("failure_condition_level"),
                healthCheckTimeout: row.int("health_check_timeout"),
                databaseLevelHealthDetection: row.int("db_failover") == 1,
                dtcSupport: row.int("dtc_support") == 1,
                basicFeatures: row.int("basic_features") == 1,
                requiredSynchronizedSecondariesToCommit: row.int("required_secondaries"),
                synchronizationHealth: row.string("sync_health"),
                primaryRecoveryHealth: row.string("recovery_health"),
                isLocalPrimary: row.int("is_local_primary") == 1,
                replicaCount: row.int("replica_count"),
                databaseCount: row.int("database_count"),
                listenerSummary: row.string("listeners"))
        }
    }

    /// SEEDING_MODE is 2016 and later; before that a secondary is always seeded by
    /// hand, so the column is answered with a constant rather than asked for.
    public static func replicasQuery(group: String, info: ServerInfo) -> String {
        let seeding = AvailabilityGroupService.capabilities(info).seeding
            ? "ISNULL(ar.seeding_mode_desc, N'MANUAL')"
            : "N'MANUAL'"
        return """
        SELECT CONVERT(nvarchar(36), ar.replica_id) AS replica_id,
               ag.name AS group_name,
               ar.replica_server_name,
               ISNULL(ar.endpoint_url, N'') AS endpoint_url,
               ISNULL(ar.availability_mode_desc, N'ASYNCHRONOUS_COMMIT') AS availability_mode,
               ISNULL(ar.failover_mode_desc, N'MANUAL') AS failover_mode,
               \(seeding) AS seeding_mode,
               ISNULL(ar.primary_role_allow_connections_desc, N'ALL') AS primary_connections,
               ISNULL(ar.secondary_role_allow_connections_desc, N'NO') AS secondary_connections,
               ISNULL(ar.read_only_routing_url, N'') AS read_only_routing_url,
               ISNULL(ar.session_timeout, 10) AS session_timeout,
               ISNULL(ar.backup_priority, 50) AS backup_priority,
               ISNULL(ars.role_desc, N'') AS role_desc,
               ISNULL(ars.operational_state_desc, N'') AS operational_state,
               ISNULL(ars.connected_state_desc, N'') AS connected_state,
               ISNULL(ars.synchronization_health_desc, N'') AS sync_health,
               ISNULL(ars.recovery_health_desc, N'') AS recovery_health,
               ISNULL(ars.last_connect_error_description, N'') AS last_connect_error,
               CONVERT(int, ISNULL(ars.is_local, 0)) AS is_local
        FROM sys.availability_replicas AS ar
        JOIN sys.availability_groups AS ag ON ag.group_id = ar.group_id
        LEFT JOIN sys.dm_hadr_availability_replica_states AS ars
               ON ars.replica_id = ar.replica_id
        WHERE ag.name = \(SQLIdentifier.literal(group))
        ORDER BY CASE WHEN ISNULL(ars.role_desc, N'') = N'PRIMARY' THEN 0 ELSE 1 END,
                 ar.replica_server_name
        """
    }

    public func replicas(group: String) async throws -> [AvailabilityReplica] {
        try await requireAlwaysOn()
        let sql = AvailabilityGroupService.replicasQuery(group: group,
                                                         info: await session.serverInfo)
        return try await rows(sql).map { row in
            AvailabilityReplica(
                replicaID: row.string("replica_id"),
                groupName: row.string("group_name"),
                serverName: row.string("replica_server_name"),
                endpointURL: row.string("endpoint_url"),
                role: row.string("role_desc"),
                availabilityMode: AvailabilityMode(
                    rawValue: row.string("availability_mode").uppercased()) ?? .asynchronousCommit,
                failoverMode: FailoverMode(
                    rawValue: row.string("failover_mode").uppercased()) ?? .manual,
                seedingMode: SeedingMode(
                    rawValue: row.string("seeding_mode").uppercased()) ?? .manual,
                primaryRoleConnections: PrimaryRoleConnections(
                    rawValue: row.string("primary_connections").uppercased()) ?? .all,
                secondaryRoleConnections: SecondaryRoleConnections(
                    rawValue: row.string("secondary_connections").uppercased()) ?? .no,
                readOnlyRoutingURL: row.string("read_only_routing_url"),
                sessionTimeout: row.int("session_timeout"),
                backupPriority: row.int("backup_priority"),
                connectedState: row.string("connected_state"),
                operationalState: row.string("operational_state"),
                synchronizationHealth: row.string("sync_health"),
                recoveryHealth: row.string("recovery_health"),
                lastConnectError: row.string("last_connect_error"),
                isLocal: row.int("is_local") == 1)
        }
    }

    /// The cluster view is the driver rather than the state DMV, so a database that has
    /// been added to the group but not yet joined on a secondary still shows up — and
    /// `is_failover_ready` and `is_database_joined` live on that view, not on the state
    /// one, which is the kind of detail that costs a whole pane when it is wrong.
    public static func databasesQuery(group: String, info: ServerInfo) -> String {
        let lag = AvailabilityGroupService.capabilities(info).lag
            ? "CONVERT(int, ISNULL(drs.secondary_lag_seconds, -1))"
            : "-1"
        return """
        SELECT ag.name AS group_name,
               dcs.database_name,
               ar.replica_server_name,
               CONVERT(int, ISNULL(drs.is_primary_replica, 0)) AS is_primary_replica,
               CONVERT(int, ISNULL(drs.is_local, 0)) AS is_local,
               CONVERT(int, ISNULL(dcs.is_database_joined, 0)) AS is_joined,
               ISNULL(drs.synchronization_state_desc, N'') AS sync_state,
               ISNULL(drs.synchronization_health_desc, N'') AS sync_health,
               ISNULL(drs.database_state_desc, N'') AS database_state,
               CONVERT(int, ISNULL(drs.is_suspended, 0)) AS is_suspended,
               ISNULL(drs.suspend_reason_desc, N'') AS suspend_reason,
               -- is_failover_ready belongs to the cluster view, not the state DMV.
               CONVERT(int, ISNULL(dcs.is_failover_ready, 0)) AS is_failover_ready,
               CONVERT(bigint, ISNULL(drs.log_send_queue_size, 0)) AS log_send_queue,
               CONVERT(bigint, ISNULL(drs.log_send_rate, 0)) AS log_send_rate,
               CONVERT(bigint, ISNULL(drs.redo_queue_size, 0)) AS redo_queue,
               CONVERT(bigint, ISNULL(drs.redo_rate, 0)) AS redo_rate,
               ISNULL(CONVERT(nvarchar(30), drs.last_commit_time, 120), N'') AS last_commit_time,
               ISNULL(CONVERT(nvarchar(30), drs.last_hardened_time, 120), N'') AS last_hardened_time,
               \(lag) AS lag_seconds
        FROM sys.dm_hadr_database_replica_cluster_states AS dcs
        JOIN sys.availability_replicas AS ar ON ar.replica_id = dcs.replica_id
        JOIN sys.availability_groups AS ag ON ag.group_id = ar.group_id
        LEFT JOIN sys.dm_hadr_database_replica_states AS drs
               ON drs.group_database_id = dcs.group_database_id
              AND drs.replica_id = dcs.replica_id
        WHERE ag.name = \(SQLIdentifier.literal(group))
        ORDER BY dcs.database_name,
                 CASE WHEN ISNULL(drs.is_primary_replica, 0) = 1 THEN 0 ELSE 1 END,
                 ar.replica_server_name
        """
    }

    public func databases(group: String) async throws -> [AvailabilityDatabaseState] {
        try await requireAlwaysOn()
        let sql = AvailabilityGroupService.databasesQuery(group: group,
                                                          info: await session.serverInfo)
        return try await rows(sql).map { row in
            AvailabilityDatabaseState(
                groupName: row.string("group_name"),
                databaseName: row.string("database_name"),
                replicaServerName: row.string("replica_server_name"),
                isPrimaryReplica: row.int("is_primary_replica") == 1,
                isLocal: row.int("is_local") == 1,
                synchronizationState: row.string("sync_state"),
                synchronizationHealth: row.string("sync_health"),
                databaseState: row.string("database_state"),
                isSuspended: row.int("is_suspended") == 1,
                suspendReason: row.string("suspend_reason"),
                isFailoverReady: row.int("is_failover_ready") == 1,
                isJoined: row.int("is_joined") == 1,
                logSendQueueKB: row.int64("log_send_queue"),
                logSendRateKBps: row.int64("log_send_rate"),
                redoQueueKB: row.int64("redo_queue"),
                redoRateKBps: row.int64("redo_rate"),
                lastCommitTime: row.string("last_commit_time"),
                lastHardenedTime: row.string("last_hardened_time"),
                secondaryLagSeconds: row.int("lag_seconds"))
        }
    }

    public func listeners(group: String) async throws -> [AvailabilityListener] {
        try await requireAlwaysOn()
        let name = SQLIdentifier.literal(group)
        // Two result sets in one round trip: the listeners, then their addresses.
        let sql = """
        SELECT ag.name AS group_name, l.dns_name, l.port,
               CONVERT(int, ISNULL(l.is_conformant, 0)) AS is_conformant,
               ISNULL(l.ip_configuration_string_from_cluster, N'') AS ip_configuration
        FROM sys.availability_group_listeners AS l
        JOIN sys.availability_groups AS ag ON ag.group_id = l.group_id
        WHERE ag.name = \(name)
        ORDER BY l.dns_name;

        SELECT l.dns_name,
               ISNULL(ip.ip_address, N'') AS ip_address,
               ISNULL(ip.ip_subnet_mask, N'') AS ip_subnet_mask,
               CONVERT(int, ISNULL(ip.is_dhcp, 0)) AS is_dhcp,
               ISNULL(ip.state_desc, N'') AS state_desc
        FROM sys.availability_group_listener_ip_addresses AS ip
        JOIN sys.availability_group_listeners AS l ON l.listener_id = ip.listener_id
        JOIN sys.availability_groups AS ag ON ag.group_id = l.group_id
        WHERE ag.name = \(name)
        ORDER BY l.dns_name, ip.ip_address;
        """
        let result = try await session.metadataQuery(sql, database: "master")
        if let failure = result.errors.first { throw failure }
        let listenerRows = result.resultSets.first?.dictionaries() ?? []
        let addressRows = result.resultSets.count > 1
            ? result.resultSets[1].dictionaries()
            : []

        return listenerRows.map { row in
            let dnsName = row.string("dns_name")
            let addresses = addressRows
                .filter { $0.string("dns_name").caseInsensitiveCompare(dnsName) == .orderedSame }
                .map {
                    AvailabilityListenerIP(address: $0.string("ip_address"),
                                           subnetMask: $0.string("ip_subnet_mask"),
                                           isDHCP: $0.int("is_dhcp") == 1,
                                           state: $0.string("state_desc"))
                }
            return AvailabilityListener(groupName: row.string("group_name"),
                                        dnsName: dnsName,
                                        port: row.int("port"),
                                        isConformant: row.int("is_conformant") == 1,
                                        ipConfiguration: row.string("ip_configuration"),
                                        addresses: addresses)
        }
    }

    /// The WSFC view. Empty on a CLUSTER_TYPE = NONE or EXTERNAL configuration, which
    /// is not an error — the dashboard just has nothing to show there.
    public func cluster() async throws -> AlwaysOnClusterInfo {
        try await requireAlwaysOn()
        let sql = """
        SELECT ISNULL(cluster_name, N'') AS cluster_name,
               ISNULL(quorum_type_desc, N'') AS quorum_type,
               ISNULL(quorum_state_desc, N'') AS quorum_state
        FROM sys.dm_hadr_cluster;

        SELECT member_name, ISNULL(member_type_desc, N'') AS member_type,
               ISNULL(member_state_desc, N'') AS member_state,
               ISNULL(number_of_quorum_votes, 0) AS quorum_votes
        FROM sys.dm_hadr_cluster_members
        ORDER BY member_name;
        """
        let result = try await session.metadataQuery(sql, database: "master")
        if let failure = result.errors.first { throw failure }
        let head = result.resultSets.first?.dictionaries().first
        let members = (result.resultSets.count > 1
                       ? result.resultSets[1].dictionaries()
                       : []).map {
            AlwaysOnClusterMember(name: $0.string("member_name"),
                                  type: $0.string("member_type"),
                                  state: $0.string("member_state"),
                                  quorumVotes: $0.int("quorum_votes"))
        }
        return AlwaysOnClusterInfo(clusterName: head?.string("cluster_name") ?? "",
                                   quorumType: head?.string("quorum_type") ?? "",
                                   quorumState: head?.string("quorum_state") ?? "",
                                   members: members)
    }

    /// Databases on this instance that are not in a group yet, with the prerequisites
    /// the Add Database wizard checks.
    public func candidateDatabases() async throws -> [AvailabilityCandidateDatabase] {
        try await requireAlwaysOn()
        let sql = """
        SELECT d.name,
               d.recovery_model_desc,
               CASE WHEN EXISTS (SELECT 1 FROM msdb.dbo.backupset AS b
                                 WHERE b.database_name = d.name AND b.type = 'D')
                    THEN 1 ELSE 0 END AS has_backup
        FROM sys.databases AS d
        WHERE d.database_id > 4
          AND d.state = 0
          AND d.source_database_id IS NULL
          AND d.replica_id IS NULL
          AND d.is_read_only = 0
        ORDER BY d.name
        """
        return try await rows(sql).map {
            AvailabilityCandidateDatabase(name: $0.string("name"),
                                          recoveryModel: $0.string("recovery_model_desc"),
                                          hasLogBackup: $0.int("has_backup") == 1)
        }
    }

    // MARK: - Writes

    /// Runs a script built by `AvailabilityGroupScripts`, always in master: the ALTER
    /// AVAILABILITY GROUP statements are server scoped, and a database being removed
    /// from a group cannot be the current one.
    public func execute(_ script: String) async throws {
        let connection = try await session.openConnection(database: "master")
        defer { Task { try? await connection.close() } }
        let result = try await connection.query(script)
        if let failure = result.errors.first { throw failure }
    }

    // MARK: - Helpers

    private func rows(_ sql: String) async throws -> [[String: TDSValue]] {
        let result = try await session.metadataQuery(sql, database: "master")
        if let failure = result.errors.first { throw failure }
        return result.resultSets.first?.dictionaries() ?? []
    }
}
