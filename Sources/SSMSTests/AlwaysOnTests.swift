import Foundation
import TDSKit
import SQLServerKit

/// Offline checks for Always On: the statements the dashboard builds, and the findings
/// it draws from replica and database state. No cluster is involved.
func runAlwaysOnTests(_ t: TestRunner) {

    // MARK: - Failover

    t.suite("always on failover scripts") {
        t.equal(try? AvailabilityGroupScripts.failover(group: "AG-Sales"),
                "ALTER AVAILABILITY GROUP [AG-Sales] FAILOVER;", "planned failover")
        t.equal(try? AvailabilityGroupScripts.forcedFailover(group: "AG-Sales"),
                "ALTER AVAILABILITY GROUP [AG-Sales] FORCE_FAILOVER_ALLOW_DATA_LOSS;",
                "forced failover")
        t.equal(try? AvailabilityGroupScripts.failover(group: "we]rd"),
                "ALTER AVAILABILITY GROUP [we]]rd] FAILOVER;",
                "the group name goes through the identifier quoter")
        t.expect((try? AvailabilityGroupScripts.failover(group: "  ")) == nil,
                 "an empty group name is refused")

        let script = (try? AvailabilityGroupScripts.failoverScript(
            group: "AG", targetReplica: "NODE2", allowDataLoss: false)) ?? ""
        t.expect(script.contains("Run this on NODE2"),
                 "the script names the replica it has to run on", script)
    }

    t.suite("always on data movement scripts") {
        t.equal(try? AvailabilityGroupScripts.suspendDataMovement(database: "Sales"),
                "ALTER DATABASE [Sales] SET HADR SUSPEND;", "suspend")
        t.equal(try? AvailabilityGroupScripts.resumeDataMovement(database: "Sales"),
                "ALTER DATABASE [Sales] SET HADR RESUME;", "resume")
        t.equal(try? AvailabilityGroupScripts.joinDatabaseOnSecondary(group: "AG",
                                                                     database: "Sales"),
                "ALTER DATABASE [Sales] SET HADR AVAILABILITY GROUP = [AG];",
                "join on the secondary")
        t.equal(try? AvailabilityGroupScripts.removeDatabaseOnSecondary(database: "Sales"),
                "ALTER DATABASE [Sales] SET HADR OFF;", "leave the group on the secondary")
        t.equal(try? AvailabilityGroupScripts.addDatabases(group: "AG",
                                                           databases: ["Sales", "Orders"]),
                "ALTER AVAILABILITY GROUP [AG] ADD DATABASE [Sales], [Orders];",
                "add several databases in one statement")
        t.expect((try? AvailabilityGroupScripts.addDatabases(group: "AG", databases: [])) == nil,
                 "adding no database is refused")
    }

    // MARK: - Replicas

    t.suite("always on replica scripts") {
        var change = AvailabilityGroupScripts.ReplicaChange(
            availabilityMode: .synchronousCommit,
            failoverMode: .automatic,
            backupPriority: 70)
        let script = (try? AvailabilityGroupScripts.modifyReplica(
            group: "AG", replicaServerName: "NODE2", change: change)) ?? ""
        let statements = script.components(separatedBy: "ALTER AVAILABILITY GROUP").count - 1
        t.equal(statements, 3, "one ALTER per option, the way SSMS scripts it")
        t.expect(script.contains("MODIFY REPLICA ON N'NODE2' WITH (AVAILABILITY_MODE = "
                                 + "SYNCHRONOUS_COMMIT)"),
                 "availability mode statement", script)
        t.expect(script.contains("(BACKUP_PRIORITY = 70)"), "backup priority statement")

        change = AvailabilityGroupScripts.ReplicaChange(availabilityMode: .asynchronousCommit,
                                                        failoverMode: .automatic)
        t.expect((try? AvailabilityGroupScripts.modifyReplica(
            group: "AG", replicaServerName: "NODE2", change: change)) == nil,
                 "automatic failover on an asynchronous replica is refused")

        change = AvailabilityGroupScripts.ReplicaChange(backupPriority: 200)
        t.expect((try? AvailabilityGroupScripts.modifyReplica(
            group: "AG", replicaServerName: "NODE2", change: change)) == nil,
                 "a backup priority above 100 is refused")

        change = AvailabilityGroupScripts.ReplicaChange(sessionTimeoutSeconds: 2)
        t.expect((try? AvailabilityGroupScripts.modifyReplica(
            group: "AG", replicaServerName: "NODE2", change: change)) == nil,
                 "a session timeout below five seconds is refused")

        change = AvailabilityGroupScripts.ReplicaChange(readOnlyRoutingList: ["NODE2", "NODE3"])
        let routing = (try? AvailabilityGroupScripts.modifyReplica(
            group: "AG", replicaServerName: "NODE1", change: change)) ?? ""
        t.expect(routing.contains("READ_ONLY_ROUTING_LIST = (N'NODE2', N'NODE3')"),
                 "read-only routing list", routing)

        change = AvailabilityGroupScripts.ReplicaChange(readOnlyRoutingList: [])
        let cleared = (try? AvailabilityGroupScripts.modifyReplica(
            group: "AG", replicaServerName: "NODE1", change: change)) ?? ""
        t.expect(cleared.contains("READ_ONLY_ROUTING_LIST = NONE"),
                 "an empty routing list clears it", cleared)

        t.expect((try? AvailabilityGroupScripts.modifyReplica(
            group: "AG", replicaServerName: "NODE2",
            change: AvailabilityGroupScripts.ReplicaChange())) == nil,
                 "a change that changes nothing is refused")

        let replica = AvailabilityReplica(serverName: "NODE3",
                                          endpointURL: "TCP://node3:5022",
                                          availabilityMode: .synchronousCommit,
                                          failoverMode: .automatic,
                                          seedingMode: .automatic,
                                          secondaryRoleConnections: .readOnly)
        let added = (try? AvailabilityGroupScripts.addReplica(group: "AG",
                                                              replica: replica)) ?? ""
        t.expect(added.contains("ADD REPLICA ON N'NODE3'"), "add replica", added)
        t.expect(added.contains("SEEDING_MODE = AUTOMATIC"), "seeding mode is included")
        t.expect(added.contains("SECONDARY_ROLE (ALLOW_CONNECTIONS = READ_ONLY)"),
                 "readable secondary")

        let noSeeding = (try? AvailabilityGroupScripts.addReplica(group: "AG", replica: replica,
                                                                  supportsSeeding: false)) ?? ""
        t.expect(!noSeeding.contains("SEEDING_MODE"),
                 "seeding is left out for an engine that predates it")

        var broken = replica
        broken.endpointURL = ""
        t.expect((try? AvailabilityGroupScripts.addReplica(group: "AG", replica: broken)) == nil,
                 "a replica without an endpoint URL is refused")

        t.equal(try? AvailabilityGroupScripts.removeReplica(group: "AG",
                                                            replicaServerName: "NODE3"),
                "ALTER AVAILABILITY GROUP [AG] REMOVE REPLICA ON N'NODE3';", "remove replica")
        t.equal(try? AvailabilityGroupScripts.grantCreateAnyDatabase(group: "AG", granted: true),
                "ALTER AVAILABILITY GROUP [AG] GRANT CREATE ANY DATABASE;", "seeding grant")

        let joined = (try? AvailabilityGroupScripts.joinGroupOnSecondary(
            group: "AG", clusterType: "NONE")) ?? ""
        t.expect(joined.contains("JOIN WITH (CLUSTER_TYPE = NONE)"),
                 "a clusterless group names its cluster type when joining", joined)
        let wsfc = (try? AvailabilityGroupScripts.joinGroupOnSecondary(
            group: "AG", clusterType: "WSFC")) ?? ""
        t.expect(wsfc.contains("ALTER AVAILABILITY GROUP [AG] JOIN;"),
                 "a WSFC group joins without the clause", wsfc)
    }

    // MARK: - Listeners and group options

    t.suite("always on listener scripts") {
        let dhcp = (try? AvailabilityGroupScripts.addListener(
            group: "AG", listenerName: "ag-listener", port: 1433, addresses: [])) ?? ""
        t.expect(dhcp.contains("ADD LISTENER N'ag-listener'") && dhcp.contains("WITH DHCP")
                 && dhcp.contains("PORT = 1433"), "DHCP listener", dhcp)

        let statics = [AvailabilityListenerIP(address: "10.0.0.25", subnetMask: "255.255.255.0"),
                       AvailabilityListenerIP(address: "10.1.0.25", subnetMask: "255.255.255.0")]
        let fixed = (try? AvailabilityGroupScripts.addListener(
            group: "AG", listenerName: "ag-listener", port: 1500, addresses: statics)) ?? ""
        t.expect(fixed.contains("WITH IP ((N'10.0.0.25', N'255.255.255.0'), "
                                + "(N'10.1.0.25', N'255.255.255.0'))"),
                 "multi-subnet listener", fixed)

        t.expect((try? AvailabilityGroupScripts.addListener(
            group: "AG", listenerName: "ag", port: 70000, addresses: [])) == nil,
                 "an impossible port is refused")
        t.expect((try? AvailabilityGroupScripts.addListener(
            group: "AG", listenerName: "ag", port: 1433,
            addresses: [AvailabilityListenerIP(address: "10.0.0.25")])) == nil,
                 "a static address without a subnet mask is refused")

        t.expect(((try? AvailabilityGroupScripts.modifyListenerPort(
            group: "AG", listenerName: "ag", port: 1500)) ?? "").contains("(PORT = 1500)"),
                 "listener port change")
        t.equal(try? AvailabilityGroupScripts.removeListener(group: "AG", listenerName: "ag"),
                "ALTER AVAILABILITY GROUP [AG] REMOVE LISTENER N'ag';", "remove listener")
    }

    t.suite("always on group options") {
        var change = AvailabilityGroupScripts.GroupChange(automatedBackupPreference: .secondaryOnly,
                                                          databaseLevelHealthDetection: true)
        let script = (try? AvailabilityGroupScripts.modifyGroup(group: "AG",
                                                                change: change)) ?? ""
        t.expect(script.contains("SET (AUTOMATED_BACKUP_PREFERENCE = SECONDARY_ONLY)"),
                 "backup preference", script)
        t.expect(script.contains("SET (DB_FAILOVER = ON)"), "database level health detection")

        change = AvailabilityGroupScripts.GroupChange(healthCheckTimeoutMilliseconds: 10000)
        t.expect((try? AvailabilityGroupScripts.modifyGroup(group: "AG", change: change)) == nil,
                 "a health check timeout below the engine's floor is refused")

        change = AvailabilityGroupScripts.GroupChange(failureConditionLevel: 9)
        t.expect((try? AvailabilityGroupScripts.modifyGroup(group: "AG", change: change)) == nil,
                 "a failure condition level outside 1-5 is refused")

        t.equal(try? AvailabilityGroupScripts.dropGroup(group: "AG"),
                "DROP AVAILABILITY GROUP [AG];", "drop group")
    }

    t.suite("always on script as create") {
        var group = AvailabilityGroup(name: "AG-Sales",
                                      primaryReplica: "NODE1",
                                      clusterTypeDescription: "WSFC",
                                      automatedBackupPreference: .secondary,
                                      failureConditionLevel: 3,
                                      healthCheckTimeout: 30000,
                                      databaseLevelHealthDetection: true,
                                      requiredSynchronizedSecondariesToCommit: 1)
        let replicas = [
            AvailabilityReplica(serverName: "NODE1", endpointURL: "TCP://node1:5022",
                                availabilityMode: .synchronousCommit, failoverMode: .automatic,
                                seedingMode: .automatic),
            AvailabilityReplica(serverName: "NODE2", endpointURL: "TCP://node2:5022",
                                availabilityMode: .synchronousCommit, failoverMode: .automatic,
                                seedingMode: .automatic, secondaryRoleConnections: .readOnly)
        ]
        let listener = AvailabilityListener(
            dnsName: "ag-listener", port: 1433,
            addresses: [AvailabilityListenerIP(address: "10.0.0.25",
                                               subnetMask: "255.255.255.0")])

        let modern = (try? AvailabilityGroupScripts.createGroup(
            group, replicas: replicas, databases: ["Sales"], listener: listener,
            supportsClusterType: true)) ?? ""
        t.expect(modern.hasPrefix("CREATE AVAILABILITY GROUP [AG-Sales]"), "create header", modern)
        t.expect(modern.contains("FOR DATABASE [Sales]"), "database list")
        t.expect(modern.contains("REPLICA ON") && modern.contains("N'NODE2' WITH ("),
                 "replica blocks")
        t.expect(modern.contains("CLUSTER_TYPE = WSFC"), "cluster type on a modern engine")
        t.expect(modern.contains("REQUIRED_SYNCHRONIZED_SECONDARIES_TO_COMMIT = 1"),
                 "required synchronized secondaries")
        t.expect(modern.contains("LISTENER N'ag-listener'"), "listener clause")
        t.expect(modern.hasSuffix(";\nGO"), "scripts end with a batch separator")

        group.clusterTypeDescription = ""
        let legacy = (try? AvailabilityGroupScripts.createGroup(
            group, replicas: replicas, databases: ["Sales"], listener: nil,
            supportsClusterType: false)) ?? ""
        t.expect(!legacy.contains("CLUSTER_TYPE") && !legacy.contains("SEEDING_MODE"),
                 "2012-era script leaves out what that engine has no syntax for", legacy)
        t.expect(!legacy.contains("LISTENER"), "no listener clause when there is no listener")
    }

    // MARK: - Health

    t.suite("always on health") {
        let group = AvailabilityGroup(name: "AG", primaryReplica: "NODE1",
                                      synchronizationHealth: "HEALTHY",
                                      isLocalPrimary: true)
        let primary = AvailabilityReplica(serverName: "NODE1", role: "PRIMARY",
                                          availabilityMode: .synchronousCommit,
                                          failoverMode: .automatic,
                                          connectedState: "CONNECTED",
                                          synchronizationHealth: "HEALTHY")
        var secondary = AvailabilityReplica(serverName: "NODE2", role: "SECONDARY",
                                            availabilityMode: .synchronousCommit,
                                            failoverMode: .automatic,
                                            connectedState: "CONNECTED",
                                            synchronizationHealth: "HEALTHY")
        let primaryDatabase = AvailabilityDatabaseState(
            databaseName: "Sales", replicaServerName: "NODE1", isPrimaryReplica: true,
            synchronizationState: "SYNCHRONIZED", synchronizationHealth: "HEALTHY",
            isFailoverReady: true)
        var secondaryDatabase = AvailabilityDatabaseState(
            databaseName: "Sales", replicaServerName: "NODE2",
            synchronizationState: "SYNCHRONIZED", synchronizationHealth: "HEALTHY",
            isFailoverReady: true)
        let listener = AvailabilityListener(dnsName: "ag-listener")

        var issues = AlwaysOnHealth.evaluate(group: group, replicas: [primary, secondary],
                                             databases: [primaryDatabase, secondaryDatabase],
                                             listeners: [listener])
        t.expect(issues.isEmpty, "a healthy group reports nothing",
                 issues.map(\.message).joined(separator: " | "))

        // Suspended data movement is the finding that matters most: the primary's log
        // cannot be truncated while it lasts.
        secondaryDatabase.isSuspended = true
        secondaryDatabase.suspendReason = "SUSPEND_FROM_USER"
        issues = AlwaysOnHealth.evaluate(group: group, replicas: [primary, secondary],
                                         databases: [primaryDatabase, secondaryDatabase],
                                         listeners: [listener])
        t.equal(issues.first?.severity, .error, "suspended movement is critical")
        t.expect(issues.first?.message.contains("suspended") == true, "suspension is named",
                 issues.first?.message ?? "none")

        // A synchronous secondary that is not synchronized blocks a planned failover.
        secondaryDatabase.isSuspended = false
        secondaryDatabase.synchronizationState = "SYNCHRONIZING"
        secondaryDatabase.isFailoverReady = false
        issues = AlwaysOnHealth.evaluate(group: group, replicas: [primary, secondary],
                                         databases: [primaryDatabase, secondaryDatabase],
                                         listeners: [listener])
        t.expect(issues.contains { $0.id.hasPrefix("db.notSynchronized") },
                 "an unsynchronized synchronous replica is reported")
        t.expect(issues.contains { $0.id.hasPrefix("db.failoverNotReady") },
                 "the automatic failover target is reported as not ready")

        // On an asynchronous replica the same state is normal; the lag is what counts.
        secondary.availabilityMode = .asynchronousCommit
        secondary.failoverMode = .manual
        secondaryDatabase.synchronizationState = "SYNCHRONIZING"
        secondaryDatabase.logSendQueueKB = 600_000
        secondaryDatabase.logSendRateKBps = 1_000
        issues = AlwaysOnHealth.evaluate(group: group, replicas: [primary, secondary],
                                         databases: [primaryDatabase, secondaryDatabase],
                                         listeners: [listener])
        t.expect(!issues.contains { $0.id.hasPrefix("db.notSynchronized") },
                 "an asynchronous replica is not expected to be synchronized")
        t.expect(issues.contains { $0.id.hasPrefix("db.dataLoss") },
                 "ten minutes of send queue is reported as data loss",
                 issues.map(\.id).joined(separator: ", "))
        t.equal(secondaryDatabase.estimatedSecondsBehind, 600,
                "queue divided by rate is the estimate")

        // A disconnected replica outranks everything else in the list.
        secondary.connectedState = "DISCONNECTED"
        secondary.lastConnectError = "No such host is known."
        issues = AlwaysOnHealth.evaluate(group: group, replicas: [primary, secondary],
                                         databases: [primaryDatabase, secondaryDatabase],
                                         listeners: [listener])
        t.equal(AlwaysOnHealth.worstSeverity(issues), .error, "disconnection is critical")
        t.expect(issues.first?.severity == .error, "findings are sorted worst first")

        // Mis-set failover mode is caught even while everything is otherwise healthy.
        let mismatched = AvailabilityReplica(serverName: "NODE3", role: "SECONDARY",
                                             availabilityMode: .asynchronousCommit,
                                             failoverMode: .automatic,
                                             connectedState: "CONNECTED",
                                             synchronizationHealth: "HEALTHY")
        issues = AlwaysOnHealth.evaluate(group: group, replicas: [primary, mismatched],
                                         databases: [primaryDatabase], listeners: [listener])
        t.expect(issues.contains { $0.id.hasPrefix("replica.failoverMismatch") },
                 "automatic failover on an asynchronous replica is reported")

        // No listener is worth saying once, but it is not a failure.
        issues = AlwaysOnHealth.evaluate(group: group, replicas: [primary, secondary],
                                         databases: [primaryDatabase], listeners: [])
        t.expect(issues.contains { $0.id == "group.noListener" && $0.severity == .information },
                 "a group without a listener is informational")

        // More required synchronized secondaries than exist stops writes dead.
        var strict = group
        strict.requiredSynchronizedSecondariesToCommit = 2
        issues = AlwaysOnHealth.evaluate(group: strict, replicas: [primary],
                                         databases: [primaryDatabase], listeners: [listener])
        t.expect(issues.contains { $0.id == "group.requiredSecondaries" },
                 "an unreachable commit requirement is reported")
    }

    t.suite("always on candidate databases") {
        let ready = AvailabilityCandidateDatabase(name: "Sales", recoveryModel: "FULL",
                                                  hasLogBackup: true)
        t.expect(ready.isReady, "full recovery plus a backup is ready")
        t.equal(ready.blocker, "", "nothing blocks it")

        let simple = AvailabilityCandidateDatabase(name: "Scratch", recoveryModel: "SIMPLE",
                                                   hasLogBackup: true)
        t.expect(!simple.isReady, "a simple recovery database cannot join")
        t.equal(simple.blocker, "Not in the full recovery model", "and says why")

        let unbacked = AvailabilityCandidateDatabase(name: "New", recoveryModel: "FULL",
                                                     hasLogBackup: false)
        t.equal(unbacked.blocker, "No full backup has been taken", "backup prerequisite")
    }
}
