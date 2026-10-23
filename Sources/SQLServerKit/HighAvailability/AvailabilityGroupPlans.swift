import Foundation

/// Turns an availability group operation into the sequence of statements it really is,
/// each against the instance that can actually run it.
///
/// This is what the SSMS failover wizard does under its three pages: a failover is not
/// one statement on the connection you happen to have open — it is a check on the
/// replica taking over, the `FAILOVER` on that same replica, a confirmation that the
/// role moved, and, after a forced failover, a resume on every replica that was left
/// suspended.
public enum AvailabilityGroupPlans {

    // MARK: - Failover

    public static func failover(group: AvailabilityGroup,
                                target: AvailabilityReplica,
                                replicas: [AvailabilityReplica],
                                databases: [AvailabilityDatabaseState],
                                allowDataLoss: Bool) throws -> ScriptPlan {
        guard !target.isPrimary else {
            throw SQLServerError.invalidProfile(
                "\(target.serverName) is already the primary replica.")
        }
        guard !target.serverName.isEmpty else {
            throw SQLServerError.invalidProfile("The target replica has no name.")
        }
        if !allowDataLoss && target.availabilityMode != .synchronousCommit {
            throw SQLServerError.invalidProfile(
                "A planned failover needs a synchronous-commit replica. "
                    + "\(target.serverName) is \(target.availabilityMode.displayName.lowercased()), "
                    + "so only a forced failover is possible, and it loses whatever has "
                    + "not reached it.")
        }

        let quoted = SQLIdentifier.quote(group.name)
        var steps: [ScriptStep] = []

        steps.append(ScriptStep(
            title: "Check what \(target.serverName) holds",
            instance: target.serverName,
            script: """
            SELECT STUFF((SELECT N', ' + drs.database_name + N' ' + drs.state
                          FROM (SELECT dcs.database_name,
                                       ISNULL(s.synchronization_state_desc, N'UNKNOWN') AS state
                                FROM sys.dm_hadr_database_replica_cluster_states AS dcs
                                JOIN sys.availability_replicas AS ar
                                  ON ar.replica_id = dcs.replica_id
                                JOIN sys.availability_groups AS ag
                                  ON ag.group_id = ar.group_id
                                LEFT JOIN sys.dm_hadr_database_replica_states AS s
                                  ON s.group_database_id = dcs.group_database_id
                                 AND s.replica_id = dcs.replica_id
                                WHERE ag.name = \(SQLIdentifier.literal(group.name))
                                  AND ISNULL(s.is_local, 0) = 1) AS drs
                          FOR XML PATH(N''), TYPE).value(N'.', N'nvarchar(max)'), 1, 2, N'')
                   AS [State];
            """,
            detail: "A synchronized replica fails over without data loss; "
                + "anything else does not.",
            continuesOnFailure: true,
            isReadOnly: true))

        steps.append(ScriptStep(
            title: allowDataLoss
                ? "Force the failover to \(target.serverName)"
                : "Fail over to \(target.serverName)",
            instance: target.serverName,
            script: allowDataLoss
                ? "ALTER AVAILABILITY GROUP \(quoted) FORCE_FAILOVER_ALLOW_DATA_LOSS;"
                : "ALTER AVAILABILITY GROUP \(quoted) FAILOVER;",
            detail: allowDataLoss
                ? "Runs on the replica taking over. Whatever has not reached it is lost."
                : "Runs on the replica taking over — the engine refuses it anywhere else."))

        steps.append(ScriptStep(
            title: "Confirm the role moved",
            instance: target.serverName,
            script: """
            SELECT ars.role_desc AS [Role]
            FROM sys.dm_hadr_availability_replica_states AS ars
            JOIN sys.availability_groups AS ag ON ag.group_id = ars.group_id
            WHERE ag.name = \(SQLIdentifier.literal(group.name)) AND ars.is_local = 1;
            """,
            detail: "PRIMARY here means the failover went through.",
            isReadOnly: true))

        if allowDataLoss {
            // A forced failover leaves every other replica suspended: the engine will
            // not resume data movement on its own, because it cannot know whether the
            // rows it holds are the ones that were lost.
            let others = replicas.filter {
                !$0.serverName.isEmpty
                    && $0.serverName.caseInsensitiveCompare(target.serverName) != .orderedSame
            }
            let names = Array(Set(databases.map(\.databaseName))).sorted()
            for replica in others where !names.isEmpty {
                let resume = try names
                    .map { try AvailabilityGroupScripts.resumeDataMovement(database: $0) }
                    .joined(separator: "\n")
                steps.append(ScriptStep(
                    title: "Resume data movement on \(replica.serverName)",
                    instance: replica.serverName,
                    script: resume,
                    detail: "A forced failover suspends every other replica. Until each "
                        + "one resumes, the new primary's log cannot be truncated.",
                    continuesOnFailure: true))
            }
        }

        let summary = allowDataLoss
            ? "Forced failover of \(group.name) to \(target.serverName). "
                + "Data that never reached that replica is lost."
            : "Planned failover of \(group.name) from "
                + "\(group.primaryReplica.isEmpty ? "the current primary" : group.primaryReplica) "
                + "to \(target.serverName)."

        return ScriptPlan(title: allowDataLoss ? "Forced failover" : "Failover",
                          summary: summary,
                          steps: steps)
    }

    // MARK: - Replicas

    public static func addReplica(group: AvailabilityGroup,
                                  replica: AvailabilityReplica,
                                  supportsSeeding: Bool) throws -> ScriptPlan {
        guard !group.primaryReplica.isEmpty else {
            throw SQLServerError.invalidProfile(
                "The group has no primary replica to add this one from.")
        }
        var steps: [ScriptStep] = [
            ScriptStep(
                title: "Add \(replica.serverName) to \(group.name)",
                instance: group.primaryReplica,
                script: try AvailabilityGroupScripts.addReplica(group: group.name,
                                                                replica: replica,
                                                                supportsSeeding: supportsSeeding),
                detail: "Runs on the primary, which owns the group's configuration."),
            ScriptStep(
                title: "Join the group on \(replica.serverName)",
                instance: replica.serverName,
                script: try AvailabilityGroupScripts.joinGroupOnSecondary(
                    group: group.name, clusterType: group.clusterTypeDescription),
                detail: "The new secondary joins, and is granted the permission "
                    + "automatic seeding needs to create databases.")
        ]

        if replica.seedingMode == .manual {
            steps.append(ScriptStep(
                title: "Restore the databases on \(replica.serverName)",
                instance: replica.serverName,
                script: "-- Manual seeding: restore a full and a log backup of each "
                    + "database\n-- WITH NORECOVERY here, then join each one:\n"
                    + "-- ALTER DATABASE [YourDatabase] SET HADR AVAILABILITY GROUP = "
                    + "\(SQLIdentifier.quote(group.name));",
                detail: "This replica seeds manually, so the databases have to be "
                    + "restored before they can join.",
                continuesOnFailure: true,
                isReadOnly: true))
        }

        steps.append(ScriptStep(
            title: "Confirm the replica joined",
            instance: group.primaryReplica,
            script: """
            SELECT ISNULL(ars.join_state_desc, N'NOT JOINED') AS [Join state]
            FROM sys.availability_replicas AS ar
            JOIN sys.availability_groups AS ag ON ag.group_id = ar.group_id
            LEFT JOIN sys.dm_hadr_availability_replica_cluster_states AS ars
                   ON ars.replica_id = ar.replica_id
            WHERE ag.name = \(SQLIdentifier.literal(group.name))
              AND ar.replica_server_name = \(SQLIdentifier.literal(replica.serverName));
            """,
            detail: "JOINED_STANDALONE means the replica is in the group.",
            isReadOnly: true))

        return ScriptPlan(title: "Add replica",
                          summary: "Adds \(replica.serverName) to \(group.name) and joins it, "
                            + "across both instances.",
                          steps: steps)
    }

    // MARK: - Databases

    public static func addDatabases(group: AvailabilityGroup,
                                    databases: [String],
                                    replicas: [AvailabilityReplica]) throws -> ScriptPlan {
        guard !databases.isEmpty else {
            throw SQLServerError.invalidProfile("Select at least one database to add.")
        }
        guard !group.primaryReplica.isEmpty else {
            throw SQLServerError.invalidProfile("The group has no primary replica.")
        }

        var steps: [ScriptStep] = [
            ScriptStep(
                title: "Add \(list(databases)) to \(group.name)",
                instance: group.primaryReplica,
                script: try AvailabilityGroupScripts.addDatabases(group: group.name,
                                                                  databases: databases),
                detail: "Runs on the primary. Each database has to be in the full "
                    + "recovery model with a backup already taken.")
        ]

        for replica in replicas where !replica.isPrimary && !replica.serverName.isEmpty {
            if replica.seedingMode == .automatic {
                steps.append(ScriptStep(
                    title: "Watch the seeding on \(replica.serverName)",
                    instance: replica.serverName,
                    script: """
                    SELECT COUNT(*) AS [Databases on this replica]
                    FROM sys.dm_hadr_database_replica_states AS drs
                    JOIN sys.availability_groups AS ag ON ag.group_id = drs.group_id
                    WHERE ag.name = \(SQLIdentifier.literal(group.name)) AND drs.is_local = 1;

                    SELECT s.local_database_name AS [Database],
                           s.internal_state_desc AS [Seeding state],
                           CAST(s.transferred_size_bytes * 100.0
                                / NULLIF(s.database_size_bytes, 0) AS decimal(5, 1)) AS [Percent]
                    FROM sys.dm_hadr_physical_seeding_stats AS s;
                    """,
                    detail: "Automatic seeding copies the databases over; this reports "
                        + "how far it has got.",
                    continuesOnFailure: true,
                    isReadOnly: true))
            } else {
                let joins = try databases
                    .map { try AvailabilityGroupScripts.joinDatabaseOnSecondary(group: group.name,
                                                                                database: $0) }
                    .joined(separator: "\n")
                steps.append(ScriptStep(
                    title: "Join the databases on \(replica.serverName)",
                    instance: replica.serverName,
                    script: "-- Restore each database here WITH NORECOVERY first.\n" + joins,
                    detail: "This replica seeds manually, so each database joins by hand "
                        + "once it has been restored.",
                    continuesOnFailure: true))
            }
        }

        return ScriptPlan(title: "Add databases",
                          summary: "Adds \(list(databases)) to \(group.name) and brings "
                            + "them up on every secondary.",
                          steps: steps)
    }

    // MARK: - Data movement

    public static func resumeEverywhere(group: AvailabilityGroup,
                                        databases: [AvailabilityDatabaseState]) throws -> ScriptPlan {
        let suspended = databases.filter { $0.isSuspended && !$0.replicaServerName.isEmpty }
        guard !suspended.isEmpty else {
            throw SQLServerError.invalidProfile("No database in this group is suspended.")
        }
        var byReplica: [String: [String]] = [:]
        for database in suspended {
            byReplica[database.replicaServerName, default: []].append(database.databaseName)
        }

        let steps = try byReplica.keys.sorted().map { replica -> ScriptStep in
            let names = (byReplica[replica] ?? []).sorted()
            return ScriptStep(
                title: "Resume \(list(names)) on \(replica)",
                instance: replica,
                script: try names
                    .map { try AvailabilityGroupScripts.resumeDataMovement(database: $0) }
                    .joined(separator: "\n"),
                detail: "Data movement resumes on the replica that is suspended, not on "
                    + "the primary.",
                continuesOnFailure: true)
        }

        return ScriptPlan(title: "Resume data movement",
                          summary: "Resumes every suspended database in \(group.name), "
                            + "on each replica that holds one.",
                          steps: steps)
    }

    private static func list(_ names: [String]) -> String {
        if names.count == 1 { return names[0] }
        if names.count <= 3 { return names.joined(separator: ", ") }
        return "\(names.count) databases"
    }
}
