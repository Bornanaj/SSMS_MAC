import Foundation

/// Every statement the Always On dashboard can run, built as text first. Nothing here
/// touches a connection: the UI shows the script, the user reads it, and only then is it
/// sent — the same contract the security and Agent dialogs use.
///
/// Statements are emitted one option per `ALTER`, which is what SSMS scripts out: the
/// engine rejects some option combinations inside a single `MODIFY REPLICA`.
public enum AvailabilityGroupScripts {

    /// What a replica is being changed to. `nil` leaves that option alone.
    public struct ReplicaChange: Sendable, Hashable {
        public var availabilityMode: AvailabilityMode?
        public var failoverMode: FailoverMode?
        public var seedingMode: SeedingMode?
        public var primaryRoleConnections: PrimaryRoleConnections?
        public var secondaryRoleConnections: SecondaryRoleConnections?
        public var backupPriority: Int?
        public var sessionTimeoutSeconds: Int?
        public var readOnlyRoutingURL: String?
        /// Server names, in the order the primary should hand out read-intent traffic.
        public var readOnlyRoutingList: [String]?
        public var endpointURL: String?

        public init(availabilityMode: AvailabilityMode? = nil,
                    failoverMode: FailoverMode? = nil,
                    seedingMode: SeedingMode? = nil,
                    primaryRoleConnections: PrimaryRoleConnections? = nil,
                    secondaryRoleConnections: SecondaryRoleConnections? = nil,
                    backupPriority: Int? = nil,
                    sessionTimeoutSeconds: Int? = nil,
                    readOnlyRoutingURL: String? = nil,
                    readOnlyRoutingList: [String]? = nil,
                    endpointURL: String? = nil) {
            self.availabilityMode = availabilityMode
            self.failoverMode = failoverMode
            self.seedingMode = seedingMode
            self.primaryRoleConnections = primaryRoleConnections
            self.secondaryRoleConnections = secondaryRoleConnections
            self.backupPriority = backupPriority
            self.sessionTimeoutSeconds = sessionTimeoutSeconds
            self.readOnlyRoutingURL = readOnlyRoutingURL
            self.readOnlyRoutingList = readOnlyRoutingList
            self.endpointURL = endpointURL
        }

        public var isEmpty: Bool {
            availabilityMode == nil && failoverMode == nil && seedingMode == nil
                && primaryRoleConnections == nil && secondaryRoleConnections == nil
                && backupPriority == nil && sessionTimeoutSeconds == nil
                && readOnlyRoutingURL == nil && readOnlyRoutingList == nil
                && endpointURL == nil
        }
    }

    /// Group-level options, as the SSMS availability group properties page exposes them.
    public struct GroupChange: Sendable, Hashable {
        public var automatedBackupPreference: BackupPreference?
        public var failureConditionLevel: Int?
        public var healthCheckTimeoutMilliseconds: Int?
        public var databaseLevelHealthDetection: Bool?
        public var requiredSynchronizedSecondariesToCommit: Int?

        public init(automatedBackupPreference: BackupPreference? = nil,
                    failureConditionLevel: Int? = nil,
                    healthCheckTimeoutMilliseconds: Int? = nil,
                    databaseLevelHealthDetection: Bool? = nil,
                    requiredSynchronizedSecondariesToCommit: Int? = nil) {
            self.automatedBackupPreference = automatedBackupPreference
            self.failureConditionLevel = failureConditionLevel
            self.healthCheckTimeoutMilliseconds = healthCheckTimeoutMilliseconds
            self.databaseLevelHealthDetection = databaseLevelHealthDetection
            self.requiredSynchronizedSecondariesToCommit = requiredSynchronizedSecondariesToCommit
        }

        public var isEmpty: Bool {
            automatedBackupPreference == nil && failureConditionLevel == nil
                && healthCheckTimeoutMilliseconds == nil && databaseLevelHealthDetection == nil
                && requiredSynchronizedSecondariesToCommit == nil
        }
    }

    // MARK: - Failover

    /// Planned failover. It runs on the secondary that is taking over, never on the
    /// current primary, so the caller has to be connected there.
    public static func failover(group: String) throws -> String {
        "ALTER AVAILABILITY GROUP \(try name(group)) FAILOVER;"
    }

    /// Forced failover. Accepts the data loss that an asynchronous or unsynchronized
    /// replica implies, which is why it is never offered without a confirmation.
    public static func forcedFailover(group: String) throws -> String {
        "ALTER AVAILABILITY GROUP \(try name(group)) FORCE_FAILOVER_ALLOW_DATA_LOSS;"
    }

    /// The header SSMS puts on a failover script, naming the instance it has to run on.
    public static func failoverScript(group: String, targetReplica: String,
                                      allowDataLoss: Bool) throws -> String {
        let statement = allowDataLoss
            ? try forcedFailover(group: group)
            : try failover(group: group)
        return """
        -- Run this on \(targetReplica), the replica that is to become the primary.
        -- Connecting anywhere else fails with "the availability replica is not hosted
        -- by this instance".
        \(statement)
        """
    }

    // MARK: - Data movement

    public static func suspendDataMovement(database: String) throws -> String {
        "ALTER DATABASE \(try name(database)) SET HADR SUSPEND;"
    }

    public static func resumeDataMovement(database: String) throws -> String {
        "ALTER DATABASE \(try name(database)) SET HADR RESUME;"
    }

    public static func suspendDataMovement(databases: [String]) throws -> String {
        try databases.map { try suspendDataMovement(database: $0) }.joined(separator: "\n")
    }

    public static func resumeDataMovement(databases: [String]) throws -> String {
        try databases.map { try resumeDataMovement(database: $0) }.joined(separator: "\n")
    }

    // MARK: - Databases

    public static func addDatabases(group: String, databases: [String]) throws -> String {
        guard !databases.isEmpty else {
            throw SQLServerError.invalidProfile("Select at least one database to add.")
        }
        let list = try databases.map { try name($0) }.joined(separator: ", ")
        return "ALTER AVAILABILITY GROUP \(try name(group)) ADD DATABASE \(list);"
    }

    public static func removeDatabase(group: String, database: String) throws -> String {
        "ALTER AVAILABILITY GROUP \(try name(group)) REMOVE DATABASE \(try name(database));"
    }

    /// What a secondary runs to pick a database up when seeding is manual: the restore
    /// has already happened, this only joins it to the group.
    public static func joinDatabaseOnSecondary(group: String, database: String) throws -> String {
        "ALTER DATABASE \(try name(database)) SET HADR AVAILABILITY GROUP = \(try name(group));"
    }

    /// Takes a database out of the group from the secondary's side.
    public static func removeDatabaseOnSecondary(database: String) throws -> String {
        "ALTER DATABASE \(try name(database)) SET HADR OFF;"
    }

    // MARK: - Replicas

    public static func modifyReplica(group: String, replicaServerName: String,
                                     change: ReplicaChange) throws -> String {
        guard !change.isEmpty else {
            throw SQLServerError.invalidProfile("Nothing was changed on this replica.")
        }
        let groupName = try name(group)
        let server = try literal(replicaServerName, what: "replica server name")
        var statements: [String] = []

        func alter(_ option: String) {
            statements.append("""
            ALTER AVAILABILITY GROUP \(groupName)
                MODIFY REPLICA ON \(server) WITH (\(option));
            """)
        }

        if let endpointURL = change.endpointURL {
            alter("ENDPOINT_URL = \(SQLIdentifier.literal(endpointURL))")
        }
        if let mode = change.availabilityMode {
            alter("AVAILABILITY_MODE = \(mode.rawValue)")
        }
        if let mode = change.failoverMode {
            // The engine rejects automatic failover on an asynchronous replica, and the
            // pairing is easy to get wrong when both are changed at once.
            if mode == .automatic, let availability = change.availabilityMode,
               !availability.supportsAutomaticFailover {
                throw SQLServerError.invalidProfile(
                    "Automatic failover requires synchronous commit on this replica.")
            }
            alter("FAILOVER_MODE = \(mode.rawValue)")
        }
        if let mode = change.seedingMode {
            alter("SEEDING_MODE = \(mode.rawValue)")
        }
        if let priority = change.backupPriority {
            guard (0...100).contains(priority) else {
                throw SQLServerError.invalidProfile("Backup priority runs from 0 to 100.")
            }
            alter("BACKUP_PRIORITY = \(priority)")
        }
        if let timeout = change.sessionTimeoutSeconds {
            guard timeout >= 5 else {
                throw SQLServerError.invalidProfile(
                    "A session timeout below 5 seconds makes false failures likely.")
            }
            alter("SESSION_TIMEOUT = \(timeout)")
        }
        if let connections = change.primaryRoleConnections {
            alter("PRIMARY_ROLE (ALLOW_CONNECTIONS = \(connections.rawValue))")
        }
        if let connections = change.secondaryRoleConnections {
            alter("SECONDARY_ROLE (ALLOW_CONNECTIONS = \(connections.rawValue))")
        }
        if let url = change.readOnlyRoutingURL {
            alter("SECONDARY_ROLE (READ_ONLY_ROUTING_URL = \(SQLIdentifier.literal(url)))")
        }
        if let list = change.readOnlyRoutingList {
            let targets = list.isEmpty
                ? "NONE"
                : "(" + list.map { SQLIdentifier.literal($0) }.joined(separator: ", ") + ")"
            alter("PRIMARY_ROLE (READ_ONLY_ROUTING_LIST = \(targets))")
        }
        return statements.joined(separator: "\n")
    }

    public static func addReplica(group: String, replica: AvailabilityReplica,
                                  supportsSeeding: Bool = true) throws -> String {
        let server = try literal(replica.serverName, what: "replica server name")
        guard !replica.endpointURL.isEmpty else {
            throw SQLServerError.invalidProfile(
                "An endpoint URL is required, for example TCP://node2.contoso.com:5022.")
        }
        if replica.failoverMode == .automatic, !replica.availabilityMode.supportsAutomaticFailover {
            throw SQLServerError.invalidProfile(
                "Automatic failover requires synchronous commit on this replica.")
        }
        var options: [String] = [
            "ENDPOINT_URL = \(SQLIdentifier.literal(replica.endpointURL))",
            "AVAILABILITY_MODE = \(replica.availabilityMode.rawValue)",
            "FAILOVER_MODE = \(replica.failoverMode.rawValue)"
        ]
        if supportsSeeding { options.append("SEEDING_MODE = \(replica.seedingMode.rawValue)") }
        options.append("BACKUP_PRIORITY = \(replica.backupPriority)")
        options.append("SESSION_TIMEOUT = \(replica.sessionTimeout)")
        options.append("PRIMARY_ROLE (ALLOW_CONNECTIONS = \(replica.primaryRoleConnections.rawValue))")
        var secondary = "ALLOW_CONNECTIONS = \(replica.secondaryRoleConnections.rawValue)"
        if !replica.readOnlyRoutingURL.isEmpty {
            secondary += ", READ_ONLY_ROUTING_URL = \(SQLIdentifier.literal(replica.readOnlyRoutingURL))"
        }
        options.append("SECONDARY_ROLE (\(secondary))")

        return """
        ALTER AVAILABILITY GROUP \(try name(group))
            ADD REPLICA ON \(server) WITH (
                \(options.joined(separator: ",\n        "))
                );
        """
    }

    public static func removeReplica(group: String, replicaServerName: String) throws -> String {
        let server = try literal(replicaServerName, what: "replica server name")
        return "ALTER AVAILABILITY GROUP \(try name(group)) REMOVE REPLICA ON \(server);"
    }

    /// What the new secondary itself runs after the primary has added it.
    public static func joinGroupOnSecondary(group: String, clusterType: String?) throws -> String {
        var lines = ["ALTER AVAILABILITY GROUP \(try name(group)) JOIN"]
        if let clusterType, !clusterType.isEmpty, clusterType.uppercased() != "WSFC" {
            lines[0] += " WITH (CLUSTER_TYPE = \(clusterType.uppercased()))"
        }
        lines[0] += ";"
        lines.append("ALTER AVAILABILITY GROUP \(try name(group)) GRANT CREATE ANY DATABASE;")
        return lines.joined(separator: "\n")
    }

    /// Automatic seeding creates the secondary's databases, which needs this grant.
    public static func grantCreateAnyDatabase(group: String, granted: Bool) throws -> String {
        let verb = granted ? "GRANT" : "DENY"
        return "ALTER AVAILABILITY GROUP \(try name(group)) \(verb) CREATE ANY DATABASE;"
    }

    // MARK: - Listeners

    public static func addListener(group: String, listenerName: String, port: Int,
                                   addresses: [AvailabilityListenerIP]) throws -> String {
        let listener = try literal(listenerName, what: "listener name")
        try checkPort(port)
        // DHCP is a listener-wide choice, not a per-address one: with no address at all
        // the cluster picks the subnet, and one DHCP address names the subnet to use.
        let configuration: String
        if addresses.isEmpty {
            configuration = "WITH DHCP"
        } else if let dhcp = addresses.first, dhcp.isDHCP {
            configuration = "WITH DHCP ON (\(try ipPair(dhcp)))"
        } else {
            let entries = try addresses.map { try ipPair($0) }
            configuration = "WITH IP (\(entries.map { "(\($0))" }.joined(separator: ", ")))"
        }
        return """
        ALTER AVAILABILITY GROUP \(try name(group))
            ADD LISTENER \(listener) (
                \(configuration),
                PORT = \(port)
                );
        """
    }

    public static func modifyListenerPort(group: String, listenerName: String,
                                          port: Int) throws -> String {
        try checkPort(port)
        return """
        ALTER AVAILABILITY GROUP \(try name(group))
            MODIFY LISTENER \(try literal(listenerName, what: "listener name")) (PORT = \(port));
        """
    }

    public static func addListenerIP(group: String, listenerName: String,
                                     address: AvailabilityListenerIP) throws -> String {
        guard !address.address.isEmpty, !address.subnetMask.isEmpty else {
            throw SQLServerError.invalidProfile("An address and a subnet mask are both required.")
        }
        return """
        ALTER AVAILABILITY GROUP \(try name(group))
            MODIFY LISTENER \(try literal(listenerName, what: "listener name"))
            (ADD IP (\(try ipPair(address))));
        """
    }

    public static func removeListener(group: String, listenerName: String) throws -> String {
        "ALTER AVAILABILITY GROUP \(try name(group)) "
            + "REMOVE LISTENER \(try literal(listenerName, what: "listener name"));"
    }

    // MARK: - Group options

    public static func modifyGroup(group: String, change: GroupChange) throws -> String {
        guard !change.isEmpty else {
            throw SQLServerError.invalidProfile("Nothing was changed on this availability group.")
        }
        var options: [String] = []
        if let preference = change.automatedBackupPreference {
            options.append("AUTOMATED_BACKUP_PREFERENCE = \(preference.rawValue)")
        }
        if let level = change.failureConditionLevel {
            guard (1...5).contains(level) else {
                throw SQLServerError.invalidProfile("The failure condition level runs from 1 to 5.")
            }
            options.append("FAILURE_CONDITION_LEVEL = \(level)")
        }
        if let timeout = change.healthCheckTimeoutMilliseconds {
            guard timeout >= 15000 else {
                throw SQLServerError.invalidProfile(
                    "The health check timeout cannot be below 15000 milliseconds.")
            }
            options.append("HEALTH_CHECK_TIMEOUT = \(timeout)")
        }
        if let detection = change.databaseLevelHealthDetection {
            options.append("DB_FAILOVER = \(detection ? "ON" : "OFF")")
        }
        if let required = change.requiredSynchronizedSecondariesToCommit {
            guard required >= 0 else {
                throw SQLServerError.invalidProfile(
                    "The required synchronized secondary count cannot be negative.")
            }
            options.append("REQUIRED_SYNCHRONIZED_SECONDARIES_TO_COMMIT = \(required)")
        }
        let groupName = try name(group)
        return options
            .map { "ALTER AVAILABILITY GROUP \(groupName) SET (\($0));" }
            .joined(separator: "\n")
    }

    public static func dropGroup(group: String) throws -> String {
        "DROP AVAILABILITY GROUP \(try name(group));"
    }

    // MARK: - Script the group as CREATE

    /// The CREATE SSMS produces under "Script Availability Group as", from the state
    /// read out of the DMVs. `supportsClusterType` keeps the 2017 options off a script
    /// aimed at an older engine.
    public static func createGroup(_ group: AvailabilityGroup,
                                   replicas: [AvailabilityReplica],
                                   databases: [String],
                                   listener: AvailabilityListener?,
                                   supportsClusterType: Bool) throws -> String {
        let groupName = try name(group.name)
        var options: [String] = [
            "AUTOMATED_BACKUP_PREFERENCE = \(group.automatedBackupPreference.rawValue)",
            "FAILURE_CONDITION_LEVEL = \(group.failureConditionLevel)",
            "HEALTH_CHECK_TIMEOUT = \(group.healthCheckTimeout)",
            "DB_FAILOVER = \(group.databaseLevelHealthDetection ? "ON" : "OFF")"
        ]
        if supportsClusterType {
            options.append("DTC_SUPPORT = \(group.dtcSupport ? "PER_DB" : "NONE")")
            options.append("REQUIRED_SYNCHRONIZED_SECONDARIES_TO_COMMIT = "
                           + "\(group.requiredSynchronizedSecondariesToCommit)")
            let clusterType = group.clusterTypeDescription.isEmpty
                ? "WSFC" : group.clusterTypeDescription.uppercased()
            options.append("CLUSTER_TYPE = \(clusterType)")
        }

        var lines: [String] = []
        lines.append("CREATE AVAILABILITY GROUP \(groupName)")
        lines.append("WITH (")
        lines.append("    " + options.joined(separator: ",\n    "))
        lines.append("    )")

        if !databases.isEmpty {
            let list = try databases.map { try name($0) }.joined(separator: ", ")
            lines.append("FOR DATABASE \(list)")
        }

        if !replicas.isEmpty {
            lines.append("REPLICA ON")
            let blocks = try replicas.map { replica -> String in
                let server = try literal(replica.serverName, what: "replica server name")
                var replicaOptions: [String] = [
                    "ENDPOINT_URL = \(SQLIdentifier.literal(replica.endpointURL))",
                    "AVAILABILITY_MODE = \(replica.availabilityMode.rawValue)",
                    "FAILOVER_MODE = \(replica.failoverMode.rawValue)"
                ]
                if supportsClusterType {
                    replicaOptions.append("SEEDING_MODE = \(replica.seedingMode.rawValue)")
                }
                replicaOptions.append("BACKUP_PRIORITY = \(replica.backupPriority)")
                replicaOptions.append("SESSION_TIMEOUT = \(replica.sessionTimeout)")
                replicaOptions.append("PRIMARY_ROLE (ALLOW_CONNECTIONS = "
                                      + "\(replica.primaryRoleConnections.rawValue))")
                var secondary = "ALLOW_CONNECTIONS = \(replica.secondaryRoleConnections.rawValue)"
                if !replica.readOnlyRoutingURL.isEmpty {
                    secondary += ", READ_ONLY_ROUTING_URL = "
                        + SQLIdentifier.literal(replica.readOnlyRoutingURL)
                }
                replicaOptions.append("SECONDARY_ROLE (\(secondary))")
                return "    \(server) WITH (\n        "
                    + replicaOptions.joined(separator: ",\n        ") + "\n        )"
            }
            lines.append(blocks.joined(separator: ",\n"))
        }

        if let listener, !listener.dnsName.isEmpty {
            let addresses = listener.addresses
                .filter { !$0.address.isEmpty && !$0.subnetMask.isEmpty }
                .map { "(\(SQLIdentifier.literal($0.address)), "
                    + "\(SQLIdentifier.literal($0.subnetMask)))" }
            let configuration = addresses.isEmpty
                ? "WITH DHCP"
                : "WITH IP (\(addresses.joined(separator: ", ")))"
            lines.append("LISTENER \(SQLIdentifier.literal(listener.dnsName)) (")
            lines.append("    \(configuration),")
            lines.append("    PORT = \(listener.port)")
            lines.append("    )")
        }

        return lines.joined(separator: "\n") + ";\nGO"
    }

    // MARK: - Helpers

    private static func name(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SQLServerError.invalidProfile("A name is required.")
        }
        return SQLIdentifier.quote(trimmed)
    }

    private static func literal(_ raw: String, what: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SQLServerError.invalidProfile("The \(what) is required.")
        }
        return SQLIdentifier.literal(trimmed)
    }

    /// `N'10.0.0.5', N'255.255.255.0'` — the pair every listener IP clause takes.
    private static func ipPair(_ address: AvailabilityListenerIP) throws -> String {
        guard !address.address.isEmpty else {
            throw SQLServerError.invalidProfile("A listener IP address is empty.")
        }
        guard !address.subnetMask.isEmpty else {
            throw SQLServerError.invalidProfile(
                "A listener IP needs a subnet mask, for example 255.255.255.0.")
        }
        return "\(SQLIdentifier.literal(address.address)), "
            + "\(SQLIdentifier.literal(address.subnetMask))"
    }

    private static func checkPort(_ port: Int) throws {
        guard (1...65535).contains(port) else {
            throw SQLServerError.invalidProfile("A TCP port runs from 1 to 65535.")
        }
    }
}
