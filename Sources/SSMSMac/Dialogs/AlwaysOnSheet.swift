import SwiftUI
import SQLServerKit

/// The Always On dashboard: the availability groups on this instance, their replicas,
/// databases, listeners and cluster, plus every action SSMS offers on them.
///
/// Nothing here runs straight away. Each action builds a script, the script is shown,
/// and the user runs it — failing a production group over is not a thing to do on a
/// mis-click.
struct AlwaysOnSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    let server: ConnectedServer
    var initialGroup: String?

    /// The password of the connection this dashboard was opened on. The replicas of a
    /// group usually share a login, so it is what the other instances are dialled with
    /// until the plan window is told otherwise.
    @State private var templatePassword = ""

    enum Detail: String, CaseIterable, Identifiable {
        case replicas, databases, listeners, cluster, issues
        var id: String { rawValue }
        var title: String {
            switch self {
            case .replicas: return "Replicas"
            case .databases: return "Databases"
            case .listeners: return "Listeners"
            case .cluster: return "Cluster"
            case .issues: return "Health"
            }
        }
    }

    @State private var groups: [AvailabilityGroup] = []
    @State private var selectedGroupName: String?
    @State private var replicas: [AvailabilityReplica] = []
    @State private var databases: [AvailabilityDatabaseState] = []
    @State private var listeners: [AvailabilityListener] = []
    @State private var cluster = AlwaysOnClusterInfo()
    @State private var issues: [AlwaysOnIssue] = []

    @State private var detail: Detail = .replicas
    @State private var selectedReplicaID: String?
    @State private var selectedDatabaseID: String?
    @State private var selectedListenerID: String?

    @State private var isBusy = false
    @State private var status: String?
    @State private var isError = false
    @State private var unavailable: String?

    @State private var pendingScript: PendingScript?
    @State private var pendingPlan: ScriptPlanLaunch?
    @State private var replicaEditor: AvailabilityReplica?
    @State private var showGroupProperties = false
    @State private var showAddDatabase = false
    @State private var showAddReplica = false
    @State private var listenerEditor: ListenerEditorTarget?

    private var group: AvailabilityGroup? {
        guard let selectedGroupName else { return groups.first }
        return groups.first { $0.name == selectedGroupName }
    }

    private var selectedReplica: AvailabilityReplica? {
        replicas.first { $0.id == selectedReplicaID }
    }

    private var selectedDatabase: AvailabilityDatabaseState? {
        databases.first { $0.id == selectedDatabaseID }
    }

    private var selectedListener: AvailabilityListener? {
        listeners.first { $0.id == selectedListenerID }
    }

    var body: some View {
        VStack(spacing: 0) {
            SecurityHeader(icon: "arrow.triangle.2.circlepath",
                           title: "Always On High Availability",
                           subtitle: server.displayName, isBusy: isBusy)
            Divider()
            if let unavailable {
                Label(unavailable, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                Divider()
            }
            toolbar
            Divider()
            HSplitView {
                groupList
                    .frame(minWidth: 220, idealWidth: 260, maxWidth: 360)
                VStack(spacing: 0) {
                    summary
                    Divider()
                    detailPane
                }
                .frame(minWidth: 620)
            }
            Divider()
            SecurityFooter(status: status, isError: isError) { dismiss() }
        }
        .frame(width: 1120, height: 720)
        .task { await load() }
        .task { await loadTemplatePassword() }
        .task(id: selectedGroupName) { await loadDetail() }
        .sheet(item: $pendingScript) { pending in
            ScriptConfirmSheet(pending: pending) { script in await runScript(script) }
        }
        .sheet(item: $pendingPlan) { launch in
            ScriptPlanSheet(launch: launch, app: app, templatePassword: templatePassword)
                .environmentObject(app)
        }
        .sheet(item: $replicaEditor) { replica in
            AvailabilityReplicaSheet(group: group?.name ?? "", replica: replica) { script in
                pendingScript = PendingScript(title: "Modify replica \(replica.serverName)",
                                              script: script)
            }
        }
        .sheet(isPresented: $showGroupProperties) {
            if let group {
                AvailabilityGroupPropertiesSheet(group: group) { script in
                    pendingScript = PendingScript(title: "Availability group properties",
                                                  script: script)
                }
            }
        }
        .sheet(isPresented: $showAddDatabase) {
            if let group {
                AvailabilityAddDatabaseSheet(server: server, group: group,
                                             replicas: replicas) { names in
                    startAddDatabases(names)
                }
            }
        }
        .sheet(isPresented: $showAddReplica) {
            if let group {
                AvailabilityAddReplicaSheet(group: group) { replica in
                    startAddReplica(replica)
                }
            }
        }
        .sheet(item: $listenerEditor) { target in
            AvailabilityListenerSheet(group: target.group, existing: target.listener) { script in
                pendingScript = PendingScript(title: target.listener == nil
                                              ? "Add listener" : "Modify listener",
                                              script: script)
            }
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            Menu {
                Button("Planned Failover…") { failover(allowDataLoss: false) }
                    .disabled(!canFailover)
                Button("Forced Failover (allow data loss)…") { failover(allowDataLoss: true) }
                    .disabled(selectedReplica == nil || selectedReplica?.isPrimary == true)
            } label: {
                Label("Failover", systemImage: "arrow.left.arrow.right")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(group == nil)

            Button {
                guard let database = selectedDatabase else { return }
                let script: String
                if database.isSuspended {
                    script = (try? AvailabilityGroupScripts.resumeDataMovement(
                        database: database.databaseName)) ?? ""
                } else {
                    script = (try? AvailabilityGroupScripts.suspendDataMovement(
                        database: database.databaseName)) ?? ""
                }
                pendingScript = PendingScript(
                    title: database.isSuspended ? "Resume data movement" : "Suspend data movement",
                    script: runHereNote(replica: database.replicaServerName) + script,
                    destructive: !database.isSuspended)
            } label: {
                Label(selectedDatabase?.isSuspended == true ? "Resume" : "Suspend",
                      systemImage: selectedDatabase?.isSuspended == true
                      ? "play.circle" : "pause.circle")
            }
            .disabled(selectedDatabase == nil)

            Divider().frame(height: 16)

            Menu {
                Button("Add Database…") { showAddDatabase = true }
                Button("Remove Database…") { removeDatabase() }
                    .disabled(selectedDatabase == nil)
                Divider()
                Button("Add Replica…") { showAddReplica = true }
                Button("Replica Properties…") { replicaEditor = selectedReplica }
                    .disabled(selectedReplica == nil)
                Button("Remove Replica…") { removeReplica() }
                    .disabled(selectedReplica == nil || selectedReplica?.isPrimary == true)
                Divider()
                Button("Add Listener…") {
                    guard let group else { return }
                    listenerEditor = ListenerEditorTarget(group: group.name, listener: nil)
                }
                Button("Listener Properties…") {
                    guard let group, let listener = selectedListener else { return }
                    listenerEditor = ListenerEditorTarget(group: group.name, listener: listener)
                }
                .disabled(selectedListener == nil)
                Button("Remove Listener…") { removeListener() }
                    .disabled(selectedListener == nil)
                Divider()
                Button("Resume Data Movement Everywhere…") { resumeEverywhere() }
                    .disabled(!databases.contains { $0.isSuspended })
                Divider()
                Button("Grant CREATE ANY DATABASE…") { grantSeedingPermission(true) }
                Button("Deny CREATE ANY DATABASE…") { grantSeedingPermission(false) }
            } label: {
                Label("Tasks", systemImage: "wrench.and.screwdriver")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(group == nil)

            Button("Properties…") { showGroupProperties = true }
                .disabled(group == nil)

            Button {
                scriptGroupAsCreate()
            } label: { Label("Script", systemImage: "doc.text") }
                .disabled(group == nil)

            Spacer()
            Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
        }
        .padding(8)
    }

    /// A planned failover runs on the secondary that is taking over, and only a
    /// synchronous, synchronized one can take over without data loss.
    private var canFailover: Bool {
        guard let replica = selectedReplica, !replica.isPrimary else { return false }
        return replica.availabilityMode == .synchronousCommit
    }

    // MARK: - Panes

    private var groupList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Availability groups")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.top, 8)
            List(selection: $selectedGroupName) {
                ForEach(groups) { entry in
                    HStack(spacing: 6) {
                        Image(systemName: entry.isHealthy
                              ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(entry.isHealthy ? Color.green : Color.orange)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.name).lineLimit(1)
                            Text(entry.primaryReplica.isEmpty
                                 ? "no primary" : "primary: \(entry.primaryReplica)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .tag(entry.name)
                }
            }
            .listStyle(.sidebar)
        }
    }

    @ViewBuilder
    private var summary: some View {
        if let group {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 14) {
                    summaryItem("Primary", group.primaryReplica.isEmpty
                                ? "—" : group.primaryReplica)
                    summaryItem("Health", group.synchronizationHealth.isEmpty
                                ? "—" : humanized(group.synchronizationHealth))
                    summaryItem("Cluster", group.clusterTypeDescription.isEmpty
                                ? "—" : group.clusterTypeDescription)
                    summaryItem("Replicas", "\(group.replicaCount)")
                    summaryItem("Databases", "\(group.databaseCount)")
                    summaryItem("Backups", group.automatedBackupPreference.displayName)
                    Spacer()
                }
                if !group.listenerSummary.isEmpty {
                    Text("Listener: \(group.listenerSummary)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(10)
        } else {
            Text("No availability group on this instance.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
    }

    private func summaryItem(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption.weight(.medium)).lineLimit(1)
        }
    }

    private var detailPane: some View {
        VStack(spacing: 0) {
            Picker("", selection: $detail) {
                ForEach(Detail.allCases) { item in
                    if item == .issues && !issues.isEmpty {
                        Text("\(item.title) (\(issues.count))").tag(item)
                    } else {
                        Text(item.title).tag(item)
                    }
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)
            Divider()
            switch detail {
            case .replicas: replicaTable
            case .databases: databaseTable
            case .listeners: listenerTable
            case .cluster: clusterPane
            case .issues: issuePane
            }
        }
    }

    private var replicaTable: some View {
        Table(replicas, selection: $selectedReplicaID) {
            TableColumn("Replica") { replica in
                HStack(spacing: 5) {
                    Image(systemName: replica.isPrimary ? "star.fill" : "circle")
                        .font(.caption2)
                        .foregroundStyle(replica.isPrimary ? Color.accentColor : Color.secondary)
                    Text(replica.serverName).lineLimit(1)
                    if replica.isLocal {
                        Text("local").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }.width(min: 150, ideal: 200)
            TableColumn("Role") { Text($0.role.isEmpty ? "—" : $0.role.capitalized) }.width(90)
            TableColumn("Availability mode") { Text($0.availabilityMode.displayName) }.width(150)
            TableColumn("Failover mode") { Text($0.failoverMode.displayName) }.width(110)
            TableColumn("Seeding") { Text($0.seedingMode.displayName) }.width(150)
            TableColumn("Readable") { Text($0.secondaryRoleConnections.displayName) }.width(140)
            TableColumn("Connection") { replica in
                Text(replica.connectedState.isEmpty ? "—" : humanized(replica.connectedState))
                    .foregroundStyle(replica.isConnected || replica.isPrimary
                                     ? Color.primary : Color.red)
            }.width(110)
            TableColumn("Synchronization") { replica in
                Text(replica.synchronizationHealth.isEmpty
                     ? "—" : humanized(replica.synchronizationHealth))
                    .foregroundStyle(Self.healthColor(replica.synchronizationHealth))
            }.width(130)
        }
    }

    private var databaseTable: some View {
        Table(databases, selection: $selectedDatabaseID) {
            TableColumn("Database") { state in
                HStack(spacing: 5) {
                    Text(state.databaseName).lineLimit(1)
                    if state.isSuspended {
                        Image(systemName: "pause.circle.fill").foregroundStyle(.orange)
                    }
                }
            }.width(min: 130, ideal: 180)
            TableColumn("Replica") { Text($0.replicaServerName).lineLimit(1) }
                .width(min: 120, ideal: 170)
            TableColumn("Role") { Text($0.isPrimaryReplica ? "Primary" : "Secondary") }.width(80)
            TableColumn("State") { state in
                Text(state.synchronizationState.isEmpty
                     ? "—" : humanized(state.synchronizationState))
                    .foregroundStyle(Self.healthColor(state.synchronizationHealth))
            }.width(130)
            TableColumn("Send queue") { Text(AlwaysOnFormat.kb($0.logSendQueueKB)) }.width(100)
            TableColumn("Redo queue") { Text(AlwaysOnFormat.kb($0.redoQueueKB)) }.width(100)
            TableColumn("Est. data loss") { state in
                Text(state.isPrimaryReplica ? "—"
                     : AlwaysOnFormat.seconds(state.estimatedSecondsBehind))
            }.width(110)
            TableColumn("Last commit") { Text($0.lastCommitTime).monospacedDigit() }.width(150)
        }
    }

    private var listenerTable: some View {
        VSplitView {
            Table(listeners, selection: $selectedListenerID) {
                TableColumn("Listener") { Text($0.dnsName) }.width(min: 150, ideal: 220)
                TableColumn("Port") { Text("\($0.port)").monospacedDigit() }.width(70)
                TableColumn("Addresses") { listener in
                    Text(listener.addresses.isEmpty
                         ? listener.ipConfiguration
                         : listener.addresses.map(\.address).joined(separator: ", "))
                        .lineLimit(1)
                }.width(min: 180, ideal: 300)
            }
            .frame(minHeight: 120)

            Table(selectedListener?.addresses ?? []) {
                TableColumn("IP address") { Text($0.address) }.width(160)
                TableColumn("Subnet mask") { Text($0.subnetMask) }.width(160)
                TableColumn("Assignment") { Text($0.isDHCP ? "DHCP" : "Static") }.width(100)
                TableColumn("State") { Text($0.state) }.width(120)
            }
            .frame(minHeight: 90)
        }
    }

    @ViewBuilder
    private var clusterPane: some View {
        if cluster.isClustered {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 14) {
                    summaryItem("Cluster", cluster.clusterName)
                    summaryItem("Quorum model", humanized(cluster.quorumType))
                    summaryItem("Quorum state", humanized(cluster.quorumState))
                    Spacer()
                }
                .padding(10)
                Divider()
                Table(cluster.members) {
                    TableColumn("Member") { Text($0.name) }.width(min: 150, ideal: 220)
                    TableColumn("Type") { Text(humanized($0.type)) }.width(150)
                    TableColumn("State") { member in
                        Text(humanized(member.state))
                            .foregroundStyle(member.state.uppercased() == "UP"
                                             ? Color.primary : Color.red)
                    }.width(110)
                    TableColumn("Quorum votes") { Text("\($0.quorumVotes)").monospacedDigit() }
                        .width(110)
                }
            }
        } else {
            ContentUnavailableView(
                "No Windows cluster",
                systemImage: "square.stack.3d.up.slash",
                description: Text("This instance reports no WSFC membership. "
                                  + "A CLUSTER_TYPE = NONE or EXTERNAL group is managed "
                                  + "outside SQL Server."))
        }
    }

    @ViewBuilder
    private var issuePane: some View {
        if issues.isEmpty {
            ContentUnavailableView("Healthy", systemImage: "checkmark.seal",
                                   description: Text("Every replica and database is in its "
                                                     + "target state."))
        } else {
            Table(issues) {
                TableColumn("") { issue in
                    Image(systemName: issue.severity.symbol)
                        .foregroundStyle(Self.severityColor(issue.severity))
                }.width(24)
                TableColumn("Target") { Text($0.target).lineLimit(1) }.width(min: 140, ideal: 200)
                TableColumn("Finding") { Text($0.message) }.width(min: 220, ideal: 360)
                TableColumn("What it means") { Text($0.remedy).foregroundStyle(.secondary) }
                    .width(min: 200, ideal: 320)
            }
        }
    }

    private static func healthColor(_ health: String) -> Color {
        switch health.uppercased() {
        case "HEALTHY": return .primary
        case "PARTIALLY_HEALTHY": return .orange
        case "NOT_HEALTHY": return .red
        default: return .secondary
        }
    }

    private static func severityColor(_ severity: AlwaysOnIssue.Severity) -> Color {
        switch severity {
        case .information: return .secondary
        case .warning: return .orange
        case .error: return .red
        }
    }

    private func humanized(_ raw: String) -> String {
        raw.split(whereSeparator: { $0 == "_" })
            .map { $0.count <= 2 ? String($0) : String($0).capitalized }
            .joined(separator: " ")
    }

    // MARK: - Actions

    /// Builds the failover as a plan and opens the step runner, which connects to the
    /// replica taking over and runs the statement there — the only instance that can
    /// carry it out.
    private func failover(allowDataLoss: Bool) {
        guard let group, let replica = selectedReplica else { return }
        do {
            let plan = try AvailabilityGroupPlans.failover(group: group,
                                                           target: replica,
                                                           replicas: replicas,
                                                           databases: databases,
                                                           allowDataLoss: allowDataLoss)
            pendingPlan = ScriptPlanLaunch(plan: plan, server: server)
        } catch {
            isError = true
            status = String(describing: error)
        }
    }

    /// Everything a plan touches beyond this connection needs credentials; the ones
    /// this dashboard was opened with are the starting point.
    private func loadTemplatePassword() async {
        guard templatePassword.isEmpty else { return }
        templatePassword = await app.connections.password(for: server.profile) ?? ""
    }

    /// Adding a replica spans two instances: the ADD on the primary and the JOIN on the
    /// new secondary. The plan carries both, and the runner connects to each.
    private func startAddReplica(_ replica: AvailabilityReplica) {
        guard let group else { return }
        do {
            let plan = try AvailabilityGroupPlans.addReplica(
                group: group, replica: replica,
                supportsSeeding: server.serverInfo.majorVersion >= 14)
            pendingPlan = ScriptPlanLaunch(plan: plan, server: server)
        } catch {
            isError = true
            status = String(describing: error)
        }
    }

    private func startAddDatabases(_ names: [String]) {
        guard let group else { return }
        do {
            let plan = try AvailabilityGroupPlans.addDatabases(group: group, databases: names,
                                                               replicas: replicas)
            pendingPlan = ScriptPlanLaunch(plan: plan, server: server)
        } catch {
            isError = true
            status = String(describing: error)
        }
    }

    /// Resuming is per replica, so a group with several suspended databases on several
    /// replicas is a plan rather than one statement.
    private func resumeEverywhere() {
        guard let group else { return }
        do {
            let plan = try AvailabilityGroupPlans.resumeEverywhere(group: group,
                                                                   databases: databases)
            pendingPlan = ScriptPlanLaunch(plan: plan, server: server)
        } catch {
            isError = true
            status = String(describing: error)
        }
    }

    private func removeDatabase() {
        guard let group, let database = selectedDatabase else { return }
        let onPrimary = (try? AvailabilityGroupScripts.removeDatabase(
            group: group.name, database: database.databaseName)) ?? ""
        let onSecondary = (try? AvailabilityGroupScripts.removeDatabaseOnSecondary(
            database: database.databaseName)) ?? ""
        let script = """
        -- On the primary, which drops the database out of the group everywhere:
        \(onPrimary)

        -- Or, on this secondary only, which leaves it restoring and out of the group:
        -- \(onSecondary)
        """
        pendingScript = PendingScript(title: "Remove \(database.databaseName) from \(group.name)",
                                      script: script, destructive: true)
    }

    private func removeReplica() {
        guard let group, let replica = selectedReplica else { return }
        guard let script = try? AvailabilityGroupScripts.removeReplica(
            group: group.name, replicaServerName: replica.serverName) else { return }
        pendingScript = PendingScript(
            title: "Remove replica \(replica.serverName)",
            script: runHereNote(replica: group.primaryReplica) + script,
            destructive: true)
    }

    private func removeListener() {
        guard let group, let listener = selectedListener else { return }
        guard let script = try? AvailabilityGroupScripts.removeListener(
            group: group.name, listenerName: listener.dnsName) else { return }
        pendingScript = PendingScript(title: "Remove listener \(listener.dnsName)",
                                      script: script, destructive: true)
    }

    private func grantSeedingPermission(_ granted: Bool) {
        guard let group else { return }
        guard let script = try? AvailabilityGroupScripts.grantCreateAnyDatabase(
            group: group.name, granted: granted) else { return }
        pendingScript = PendingScript(
            title: granted ? "Grant CREATE ANY DATABASE" : "Deny CREATE ANY DATABASE",
            script: "-- Run this on every secondary that seeds automatically.\n" + script)
    }

    private func scriptGroupAsCreate() {
        guard let group else { return }
        let databaseNames = Array(Set(databases.map(\.databaseName))).sorted()
        let supportsModern = server.serverInfo.majorVersion >= 14
        guard let script = try? AvailabilityGroupScripts.createGroup(
            group, replicas: replicas, databases: databaseNames,
            listener: listeners.first, supportsClusterType: supportsModern) else { return }
        pendingScript = PendingScript(title: "Script availability group as CREATE",
                                      script: script)
    }

    /// Several statements only work where the group is hosted; say so in the script.
    private func runHereNote(replica: String) -> String {
        guard !replica.isEmpty,
              replica.caseInsensitiveCompare(server.serverInfo.serverName) != .orderedSame
        else { return "" }
        return "-- Run this on \(replica); this session is connected to "
            + "\(server.serverInfo.serverName).\n"
    }

    // MARK: - Loading

    private func runScript(_ script: String) async {
        isBusy = true
        defer { isBusy = false }
        do {
            try await AvailabilityGroupService(session: server.session).execute(script)
            isError = false
            status = "Applied."
            await load()
        } catch {
            isError = true
            status = String(describing: error)
        }
    }

    private func load() async {
        isBusy = true
        defer { isBusy = false }
        let service = AvailabilityGroupService(session: server.session)
        let state = await service.availability()
        unavailable = state.reason.isEmpty ? nil : state.reason
        guard state.supported, state.enabled else {
            groups = []; replicas = []; databases = []; listeners = []; issues = []
            return
        }
        do {
            groups = try await service.groups()
            if selectedGroupName == nil || !groups.contains(where: { $0.name == selectedGroupName }) {
                selectedGroupName = initialGroup.flatMap { name in
                    groups.first { $0.name == name }?.name
                } ?? groups.first?.name
            }
            isError = false
            status = groups.isEmpty
                ? "No availability group on this instance."
                : "\(groups.count) availability group(s)."
            await loadDetail()
        } catch {
            isError = true
            status = String(describing: error)
            groups = []
        }
    }

    private func loadDetail() async {
        guard let group else {
            replicas = []; databases = []; listeners = []; issues = []
            return
        }
        isBusy = true
        defer { isBusy = false }
        let service = AvailabilityGroupService(session: server.session)
        do {
            replicas = try await service.replicas(group: group.name)
            databases = try await service.databases(group: group.name)
            listeners = try await service.listeners(group: group.name)
            cluster = (try? await service.cluster()) ?? AlwaysOnClusterInfo()
            issues = AlwaysOnHealth.evaluate(group: group, replicas: replicas,
                                             databases: databases, listeners: listeners)
            isError = false
            if let worst = AlwaysOnHealth.worstSeverity(issues) {
                status = "\(issues.count) finding(s), worst: \(worst.title.lowercased())."
            } else {
                status = "\(group.name) is healthy."
            }
        } catch {
            isError = true
            status = String(describing: error)
        }
    }
}

/// Which listener an editor sheet is about; `nil` means a new one.
struct ListenerEditorTarget: Identifiable {
    let id = UUID()
    var group: String
    var listener: AvailabilityListener?
}

/// Shared number formatting for the dashboard's queue and lag columns.
enum AlwaysOnFormat {
    static func kb(_ kilobytes: Int64) -> String {
        if kilobytes <= 0 { return "—" }
        if kilobytes >= 1_048_576 {
            return String(format: "%.1f GB", Double(kilobytes) / 1_048_576)
        }
        if kilobytes >= 1_024 {
            return String(format: "%.1f MB", Double(kilobytes) / 1_024)
        }
        return "\(kilobytes) KB"
    }

    static func seconds(_ value: Int) -> String {
        if value < 0 { return "stalled" }
        if value == 0 { return "none" }
        if value >= 3600 { return String(format: "%d h %02d m", value / 3600, (value % 3600) / 60) }
        if value >= 60 { return String(format: "%d m %02d s", value / 60, value % 60) }
        return "\(value) s"
    }
}
