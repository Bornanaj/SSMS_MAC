import Foundation

// MARK: - Option enumerations

/// The T-SQL spellings are the raw values, so a script is built by interpolation and a
/// `*_desc` column from the DMVs maps straight back onto the case.
public enum AvailabilityMode: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case synchronousCommit = "SYNCHRONOUS_COMMIT"
    case asynchronousCommit = "ASYNCHRONOUS_COMMIT"
    /// 2017+ configuration-only replica, which holds no user data.
    case configurationOnly = "CONFIGURATION_ONLY"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .synchronousCommit: return "Synchronous commit"
        case .asynchronousCommit: return "Asynchronous commit"
        case .configurationOnly: return "Configuration only"
        }
    }

    /// Automatic failover is only ever offered on a synchronous replica.
    public var supportsAutomaticFailover: Bool { self == .synchronousCommit }
}

public enum FailoverMode: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case automatic = "AUTOMATIC"
    case manual = "MANUAL"
    /// Driven by an external cluster manager, e.g. Pacemaker on Linux.
    case external = "EXTERNAL"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .automatic: return "Automatic"
        case .manual: return "Manual"
        case .external: return "External"
        }
    }
}

public enum SeedingMode: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case automatic = "AUTOMATIC"
    case manual = "MANUAL"

    public var id: String { rawValue }

    public var displayName: String {
        self == .automatic ? "Automatic seeding" : "Manual (backup and restore)"
    }
}

public enum PrimaryRoleConnections: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case all = "ALL"
    case readWrite = "READ_WRITE"

    public var id: String { rawValue }

    public var displayName: String {
        self == .all ? "Allow all connections" : "Allow read/write connections"
    }
}

public enum SecondaryRoleConnections: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case no = "NO"
    case readOnly = "READ_ONLY"
    case all = "ALL"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .no: return "No connections"
        case .readOnly: return "Read-intent only"
        case .all: return "Yes, readable secondary"
        }
    }
}

public enum BackupPreference: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case primary = "PRIMARY"
    case secondaryOnly = "SECONDARY_ONLY"
    case secondary = "SECONDARY"
    case none = "NONE"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .primary: return "Primary"
        case .secondaryOnly: return "Prefer secondary, secondary only"
        case .secondary: return "Prefer secondary"
        case .none: return "Any replica"
        }
    }
}

// MARK: - Catalog model

/// One availability group, merged from `sys.availability_groups` and
/// `sys.dm_hadr_availability_group_states`.
public struct AvailabilityGroup: Sendable, Hashable, Identifiable {
    public var id: String { name }
    public var name: String
    public var groupID: String
    public var primaryReplica: String
    public var clusterTypeDescription: String
    public var isDistributed: Bool
    public var automatedBackupPreference: BackupPreference
    public var failureConditionLevel: Int
    public var healthCheckTimeout: Int
    public var databaseLevelHealthDetection: Bool
    public var dtcSupport: Bool
    public var basicFeatures: Bool
    public var requiredSynchronizedSecondariesToCommit: Int
    public var synchronizationHealth: String
    public var primaryRecoveryHealth: String
    /// True when the instance this session is connected to currently hosts the primary.
    public var isLocalPrimary: Bool
    public var replicaCount: Int
    public var databaseCount: Int
    public var listenerSummary: String

    public init(name: String, groupID: String = "", primaryReplica: String = "",
                clusterTypeDescription: String = "", isDistributed: Bool = false,
                automatedBackupPreference: BackupPreference = .secondary,
                failureConditionLevel: Int = 3, healthCheckTimeout: Int = 30000,
                databaseLevelHealthDetection: Bool = false, dtcSupport: Bool = false,
                basicFeatures: Bool = false,
                requiredSynchronizedSecondariesToCommit: Int = 0,
                synchronizationHealth: String = "", primaryRecoveryHealth: String = "",
                isLocalPrimary: Bool = false, replicaCount: Int = 0,
                databaseCount: Int = 0, listenerSummary: String = "") {
        self.name = name
        self.groupID = groupID
        self.primaryReplica = primaryReplica
        self.clusterTypeDescription = clusterTypeDescription
        self.isDistributed = isDistributed
        self.automatedBackupPreference = automatedBackupPreference
        self.failureConditionLevel = failureConditionLevel
        self.healthCheckTimeout = healthCheckTimeout
        self.databaseLevelHealthDetection = databaseLevelHealthDetection
        self.dtcSupport = dtcSupport
        self.basicFeatures = basicFeatures
        self.requiredSynchronizedSecondariesToCommit = requiredSynchronizedSecondariesToCommit
        self.synchronizationHealth = synchronizationHealth
        self.primaryRecoveryHealth = primaryRecoveryHealth
        self.isLocalPrimary = isLocalPrimary
        self.replicaCount = replicaCount
        self.databaseCount = databaseCount
        self.listenerSummary = listenerSummary
    }

    public var isHealthy: Bool { synchronizationHealth.uppercased() == "HEALTHY" }
}

public struct AvailabilityReplica: Sendable, Hashable, Identifiable {
    public var id: String { replicaID.isEmpty ? serverName : replicaID }
    public var replicaID: String
    public var groupName: String
    public var serverName: String
    public var endpointURL: String
    public var role: String
    public var availabilityMode: AvailabilityMode
    public var failoverMode: FailoverMode
    public var seedingMode: SeedingMode
    public var primaryRoleConnections: PrimaryRoleConnections
    public var secondaryRoleConnections: SecondaryRoleConnections
    public var readOnlyRoutingURL: String
    public var sessionTimeout: Int
    public var backupPriority: Int
    public var connectedState: String
    public var operationalState: String
    public var synchronizationHealth: String
    public var recoveryHealth: String
    public var lastConnectError: String
    public var isLocal: Bool

    public init(replicaID: String = "", groupName: String = "", serverName: String,
                endpointURL: String = "", role: String = "",
                availabilityMode: AvailabilityMode = .asynchronousCommit,
                failoverMode: FailoverMode = .manual,
                seedingMode: SeedingMode = .manual,
                primaryRoleConnections: PrimaryRoleConnections = .all,
                secondaryRoleConnections: SecondaryRoleConnections = .no,
                readOnlyRoutingURL: String = "", sessionTimeout: Int = 10,
                backupPriority: Int = 50, connectedState: String = "",
                operationalState: String = "", synchronizationHealth: String = "",
                recoveryHealth: String = "", lastConnectError: String = "",
                isLocal: Bool = false) {
        self.replicaID = replicaID
        self.groupName = groupName
        self.serverName = serverName
        self.endpointURL = endpointURL
        self.role = role
        self.availabilityMode = availabilityMode
        self.failoverMode = failoverMode
        self.seedingMode = seedingMode
        self.primaryRoleConnections = primaryRoleConnections
        self.secondaryRoleConnections = secondaryRoleConnections
        self.readOnlyRoutingURL = readOnlyRoutingURL
        self.sessionTimeout = sessionTimeout
        self.backupPriority = backupPriority
        self.connectedState = connectedState
        self.operationalState = operationalState
        self.synchronizationHealth = synchronizationHealth
        self.recoveryHealth = recoveryHealth
        self.lastConnectError = lastConnectError
        self.isLocal = isLocal
    }

    public var isPrimary: Bool { role.uppercased() == "PRIMARY" }
    public var isConnected: Bool { connectedState.uppercased() == "CONNECTED" }
    public var isReadable: Bool { secondaryRoleConnections != .no }
}

/// One database on one replica: `sys.dm_hadr_database_replica_states`.
public struct AvailabilityDatabaseState: Sendable, Hashable, Identifiable {
    public var id: String { "\(replicaServerName)/\(databaseName)" }
    public var groupName: String
    public var databaseName: String
    public var replicaServerName: String
    public var isPrimaryReplica: Bool
    public var isLocal: Bool
    public var synchronizationState: String
    public var synchronizationHealth: String
    public var databaseState: String
    public var isSuspended: Bool
    public var suspendReason: String
    public var isFailoverReady: Bool
    public var isJoined: Bool
    public var logSendQueueKB: Int64
    public var logSendRateKBps: Int64
    public var redoQueueKB: Int64
    public var redoRateKBps: Int64
    public var lastCommitTime: String
    public var lastHardenedTime: String
    /// `secondary_lag_seconds` where the engine reports it, else -1.
    public var secondaryLagSeconds: Int

    public init(groupName: String = "", databaseName: String, replicaServerName: String,
                isPrimaryReplica: Bool = false, isLocal: Bool = false,
                synchronizationState: String = "", synchronizationHealth: String = "",
                databaseState: String = "", isSuspended: Bool = false,
                suspendReason: String = "", isFailoverReady: Bool = false,
                isJoined: Bool = true, logSendQueueKB: Int64 = 0, logSendRateKBps: Int64 = 0,
                redoQueueKB: Int64 = 0, redoRateKBps: Int64 = 0, lastCommitTime: String = "",
                lastHardenedTime: String = "", secondaryLagSeconds: Int = -1) {
        self.groupName = groupName
        self.databaseName = databaseName
        self.replicaServerName = replicaServerName
        self.isPrimaryReplica = isPrimaryReplica
        self.isLocal = isLocal
        self.synchronizationState = synchronizationState
        self.synchronizationHealth = synchronizationHealth
        self.databaseState = databaseState
        self.isSuspended = isSuspended
        self.suspendReason = suspendReason
        self.isFailoverReady = isFailoverReady
        self.isJoined = isJoined
        self.logSendQueueKB = logSendQueueKB
        self.logSendRateKBps = logSendRateKBps
        self.redoQueueKB = redoQueueKB
        self.redoRateKBps = redoRateKBps
        self.lastCommitTime = lastCommitTime
        self.lastHardenedTime = lastHardenedTime
        self.secondaryLagSeconds = secondaryLagSeconds
    }

    public var isSynchronized: Bool {
        synchronizationState.uppercased() == "SYNCHRONIZED"
    }

    /// How long the send queue needs at the current rate, which is what the SSMS
    /// dashboard calls "estimated recovery time" / "estimated data loss".
    public var estimatedSecondsBehind: Int {
        if secondaryLagSeconds >= 0 { return secondaryLagSeconds }
        guard logSendRateKBps > 0 else { return logSendQueueKB > 0 ? -1 : 0 }
        return Int(logSendQueueKB / logSendRateKBps)
    }

    public var estimatedRedoSeconds: Int {
        guard redoRateKBps > 0 else { return redoQueueKB > 0 ? -1 : 0 }
        return Int(redoQueueKB / redoRateKBps)
    }
}

public struct AvailabilityListenerIP: Sendable, Hashable, Identifiable {
    public var id: String { address }
    public var address: String
    public var subnetMask: String
    public var isDHCP: Bool
    public var state: String

    public init(address: String, subnetMask: String = "", isDHCP: Bool = false,
                state: String = "") {
        self.address = address
        self.subnetMask = subnetMask
        self.isDHCP = isDHCP
        self.state = state
    }
}

public struct AvailabilityListener: Sendable, Hashable, Identifiable {
    public var id: String { dnsName }
    public var groupName: String
    public var dnsName: String
    public var port: Int
    public var isConformant: Bool
    public var ipConfiguration: String
    public var addresses: [AvailabilityListenerIP]

    public init(groupName: String = "", dnsName: String, port: Int = 1433,
                isConformant: Bool = true, ipConfiguration: String = "",
                addresses: [AvailabilityListenerIP] = []) {
        self.groupName = groupName
        self.dnsName = dnsName
        self.port = port
        self.isConformant = isConformant
        self.ipConfiguration = ipConfiguration
        self.addresses = addresses
    }

    public var connectionString: String { "\(dnsName),\(port)" }
}

/// `sys.dm_hadr_cluster` and `sys.dm_hadr_cluster_members`, empty on a cluster-less
/// (CLUSTER_TYPE = NONE) configuration.
public struct AlwaysOnClusterMember: Sendable, Hashable, Identifiable {
    public var id: String { name }
    public var name: String
    public var type: String
    public var state: String
    public var quorumVotes: Int

    public init(name: String, type: String = "", state: String = "", quorumVotes: Int = 0) {
        self.name = name
        self.type = type
        self.state = state
        self.quorumVotes = quorumVotes
    }
}

public struct AlwaysOnClusterInfo: Sendable, Hashable {
    public var clusterName: String
    public var quorumType: String
    public var quorumState: String
    public var members: [AlwaysOnClusterMember]

    public init(clusterName: String = "", quorumType: String = "", quorumState: String = "",
                members: [AlwaysOnClusterMember] = []) {
        self.clusterName = clusterName
        self.quorumType = quorumType
        self.quorumState = quorumState
        self.members = members
    }

    public var isClustered: Bool { !clusterName.isEmpty }
}
