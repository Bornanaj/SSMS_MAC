import Foundation

/// One finding on the dashboard, equivalent to a row of the SSMS availability group
/// policy evaluation. Everything here is derived from state already read, so the panel
/// has an answer without a second round trip.
public struct AlwaysOnIssue: Sendable, Hashable, Identifiable {
    public enum Severity: Int, Sendable, Hashable, Comparable, CaseIterable {
        case information
        case warning
        case error

        public static func < (lhs: Severity, rhs: Severity) -> Bool {
            lhs.rawValue < rhs.rawValue
        }

        public var title: String {
            switch self {
            case .information: return "Information"
            case .warning: return "Warning"
            case .error: return "Critical"
            }
        }

        public var symbol: String {
            switch self {
            case .information: return "info.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .error: return "xmark.octagon.fill"
            }
        }
    }

    public var id: String
    public var severity: Severity
    /// The replica, database or group the finding is about.
    public var target: String
    public var message: String
    /// What to do about it, in one sentence.
    public var remedy: String

    public init(id: String, severity: Severity, target: String, message: String,
                remedy: String = "") {
        self.id = id
        self.severity = severity
        self.target = target
        self.message = message
        self.remedy = remedy
    }
}

/// Turns the Always On state into the findings the dashboard lists. Pure, so the rules
/// are pinned by the regression suite rather than by looking at a live cluster.
public enum AlwaysOnHealth {

    public struct Thresholds: Sendable, Hashable {
        /// Estimated data loss on an asynchronous secondary before it is called out.
        public var dataLossSeconds: Int
        /// Redo queue, in KB, before the secondary is called out as falling behind.
        public var redoQueueKB: Int64
        /// Log send queue, in KB, before the primary is called out as outrunning a secondary.
        public var logSendQueueKB: Int64

        public init(dataLossSeconds: Int = 60, redoQueueKB: Int64 = 102_400,
                    logSendQueueKB: Int64 = 102_400) {
            self.dataLossSeconds = dataLossSeconds
            self.redoQueueKB = redoQueueKB
            self.logSendQueueKB = logSendQueueKB
        }

        public static let `default` = Thresholds()
    }

    public static func evaluate(group: AvailabilityGroup,
                                replicas: [AvailabilityReplica],
                                databases: [AvailabilityDatabaseState],
                                listeners: [AvailabilityListener] = [],
                                thresholds: Thresholds = .default) -> [AlwaysOnIssue] {
        var issues: [AlwaysOnIssue] = []

        // MARK: Group

        let health = group.synchronizationHealth.uppercased()
        if health == "NOT_HEALTHY" {
            issues.append(AlwaysOnIssue(
                id: "group.health",
                severity: .error,
                target: group.name,
                message: "The availability group is not healthy.",
                remedy: "Work through the replica and database findings below."))
        } else if health == "PARTIALLY_HEALTHY" {
            issues.append(AlwaysOnIssue(
                id: "group.health",
                severity: .warning,
                target: group.name,
                message: "The availability group is only partially healthy.",
                remedy: "At least one replica or database is not in its target state."))
        }

        if group.primaryReplica.isEmpty {
            issues.append(AlwaysOnIssue(
                id: "group.noPrimary",
                severity: .error,
                target: group.name,
                message: "The group has no primary replica.",
                remedy: "The cluster is resolving, or quorum has been lost. "
                    + "Check the cluster before failing anything over."))
        }

        if listeners.isEmpty {
            issues.append(AlwaysOnIssue(
                id: "group.noListener",
                severity: .information,
                target: group.name,
                message: "The group has no listener.",
                remedy: "Clients have to be repointed by hand after a failover."))
        }

        // MARK: Replicas

        let synchronousSecondaries = replicas.filter {
            !$0.isPrimary && $0.availabilityMode == .synchronousCommit
        }
        if group.requiredSynchronizedSecondariesToCommit > synchronousSecondaries.count {
            issues.append(AlwaysOnIssue(
                id: "group.requiredSecondaries",
                severity: .error,
                target: group.name,
                message: "The group requires \(group.requiredSynchronizedSecondariesToCommit) "
                    + "synchronized secondaries but only \(synchronousSecondaries.count) "
                    + "synchronous replicas exist.",
                remedy: "Writes on the primary will block. Lower "
                    + "REQUIRED_SYNCHRONIZED_SECONDARIES_TO_COMMIT or add a synchronous replica."))
        }

        for replica in replicas {
            let role = replica.role.uppercased()
            if role == "RESOLVING" {
                issues.append(AlwaysOnIssue(
                    id: "replica.resolving.\(replica.serverName)",
                    severity: .error,
                    target: replica.serverName,
                    message: "The replica is in the RESOLVING role.",
                    remedy: "The cluster cannot place the group. Check quorum and the "
                        + "Windows cluster service before forcing a failover."))
            }

            if !replica.isPrimary && !replica.connectedState.isEmpty && !replica.isConnected {
                var message = "The replica is disconnected from the primary."
                if !replica.lastConnectError.isEmpty {
                    message += " Last error: \(replica.lastConnectError)"
                }
                issues.append(AlwaysOnIssue(
                    id: "replica.disconnected.\(replica.serverName)",
                    severity: .error,
                    target: replica.serverName,
                    message: message,
                    remedy: "Check the endpoint, the service account's CONNECT permission "
                        + "on it, and the firewall between the nodes."))
            }

            let replicaHealth = replica.synchronizationHealth.uppercased()
            if replicaHealth == "NOT_HEALTHY" {
                issues.append(AlwaysOnIssue(
                    id: "replica.health.\(replica.serverName)",
                    severity: .error,
                    target: replica.serverName,
                    message: "No database on this replica is in its target synchronization state.",
                    remedy: "Resume data movement, or re-seed the databases listed below."))
            } else if replicaHealth == "PARTIALLY_HEALTHY" {
                issues.append(AlwaysOnIssue(
                    id: "replica.health.\(replica.serverName)",
                    severity: .warning,
                    target: replica.serverName,
                    message: "Some databases on this replica are not in their target state."))
            }

            if !replica.operationalState.isEmpty,
               replica.operationalState.uppercased() == "PENDING",
               !replica.isPrimary {
                issues.append(AlwaysOnIssue(
                    id: "replica.pending.\(replica.serverName)",
                    severity: .warning,
                    target: replica.serverName,
                    message: "The replica has not finished joining the group.",
                    remedy: "Run ALTER AVAILABILITY GROUP … JOIN on that instance."))
            }

            if replica.failoverMode == .automatic,
               replica.availabilityMode != .synchronousCommit {
                issues.append(AlwaysOnIssue(
                    id: "replica.failoverMismatch.\(replica.serverName)",
                    severity: .warning,
                    target: replica.serverName,
                    message: "Automatic failover is configured on a replica that is not "
                        + "synchronous commit.",
                    remedy: "Automatic failover will never trigger. Set the replica to "
                        + "synchronous commit, or set failover to manual."))
            }
        }

        // MARK: Databases

        for database in databases {
            let target = "\(database.replicaServerName) · \(database.databaseName)"

            if database.isSuspended {
                let reason = database.suspendReason.isEmpty
                    ? "" : " Reason: \(database.suspendReason)."
                issues.append(AlwaysOnIssue(
                    id: "db.suspended.\(database.id)",
                    severity: .error,
                    target: target,
                    message: "Data movement is suspended.\(reason)",
                    remedy: "Resume data movement; the primary's log cannot be truncated "
                        + "while it stays suspended."))
                continue
            }

            if !database.isJoined {
                issues.append(AlwaysOnIssue(
                    id: "db.notJoined.\(database.id)",
                    severity: .warning,
                    target: target,
                    message: "The database has not been joined to the group on this replica.",
                    remedy: "Restore it WITH NORECOVERY and join it, or switch the replica "
                        + "to automatic seeding."))
                continue
            }

            guard !database.isPrimaryReplica else {
                if database.logSendQueueKB > thresholds.logSendQueueKB {
                    issues.append(AlwaysOnIssue(
                        id: "db.sendQueue.\(database.id)",
                        severity: .warning,
                        target: target,
                        message: "The log send queue is \(formatKB(database.logSendQueueKB)).",
                        remedy: "The primary is producing log faster than it can be sent."))
                }
                continue
            }

            let state = database.synchronizationState.uppercased()
            let replica = replicas.first {
                $0.serverName.caseInsensitiveCompare(database.replicaServerName) == .orderedSame
            }
            let isSynchronous = replica?.availabilityMode == .synchronousCommit

            if isSynchronous && state != "SYNCHRONIZED" {
                let described = database.synchronizationState.isEmpty
                    ? "not synchronized"
                    : database.synchronizationState.lowercased()
                issues.append(AlwaysOnIssue(
                    id: "db.notSynchronized.\(database.id)",
                    severity: .error,
                    target: target,
                    message: "A synchronous replica is \(described).",
                    remedy: "A planned failover here would be refused, and an automatic "
                        + "failover cannot happen until it is synchronized."))
            } else if !isSynchronous && state == "NOT SYNCHRONIZING" {
                issues.append(AlwaysOnIssue(
                    id: "db.notSynchronizing.\(database.id)",
                    severity: .error,
                    target: target,
                    message: "The database is not synchronizing.",
                    remedy: "Check the replica's connection and resume data movement."))
            }

            if replica?.failoverMode == .automatic && !database.isFailoverReady && isSynchronous {
                issues.append(AlwaysOnIssue(
                    id: "db.failoverNotReady.\(database.id)",
                    severity: .warning,
                    target: target,
                    message: "The automatic failover target is not ready to take over.",
                    remedy: "Until it is synchronized, a node failure means downtime, "
                        + "not a failover."))
            }

            let lag = database.estimatedSecondsBehind
            if lag < 0 {
                issues.append(AlwaysOnIssue(
                    id: "db.stalled.\(database.id)",
                    severity: .warning,
                    target: target,
                    message: "Log is queued but nothing is being sent.",
                    remedy: "Data movement looks stalled rather than slow."))
            } else if lag > thresholds.dataLossSeconds {
                issues.append(AlwaysOnIssue(
                    id: "db.dataLoss.\(database.id)",
                    severity: .warning,
                    target: target,
                    message: "Estimated data loss on failover is \(formatSeconds(lag)).",
                    remedy: "A forced failover now would lose roughly that much work."))
            }

            if database.redoQueueKB > thresholds.redoQueueKB {
                issues.append(AlwaysOnIssue(
                    id: "db.redoQueue.\(database.id)",
                    severity: .warning,
                    target: target,
                    message: "The redo queue is \(formatKB(database.redoQueueKB))"
                        + (database.estimatedRedoSeconds > 0
                           ? ", about \(formatSeconds(database.estimatedRedoSeconds)) of redo."
                           : "."),
                    remedy: "Failover to this replica would take that long to come online, "
                        + "and a readable secondary is serving stale rows."))
            }
        }

        return issues.sorted {
            if $0.severity != $1.severity { return $0.severity > $1.severity }
            return $0.id < $1.id
        }
    }

    /// The worst severity present, which is what the group's status light shows.
    public static func worstSeverity(_ issues: [AlwaysOnIssue]) -> AlwaysOnIssue.Severity? {
        issues.map(\.severity).max()
    }

    static func formatKB(_ kilobytes: Int64) -> String {
        if kilobytes >= 1_048_576 {
            return String(format: "%.1f GB", Double(kilobytes) / 1_048_576)
        }
        if kilobytes >= 1_024 {
            return String(format: "%.1f MB", Double(kilobytes) / 1_024)
        }
        return "\(kilobytes) KB"
    }

    static func formatSeconds(_ seconds: Int) -> String {
        if seconds >= 3600 {
            return String(format: "%d h %02d m", seconds / 3600, (seconds % 3600) / 60)
        }
        if seconds >= 60 {
            return String(format: "%d m %02d s", seconds / 60, seconds % 60)
        }
        return "\(seconds) s"
    }
}
