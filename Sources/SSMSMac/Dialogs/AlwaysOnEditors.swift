import SwiftUI
import SQLServerKit

// MARK: - Replica properties

/// The availability replica properties page: everything `MODIFY REPLICA` can change.
/// Only the options that were actually touched end up in the script.
struct AvailabilityReplicaSheet: View {
    @Environment(\.dismiss) private var dismiss
    let group: String
    let replica: AvailabilityReplica
    var onScript: (String) -> Void

    @State private var availabilityMode: AvailabilityMode
    @State private var failoverMode: FailoverMode
    @State private var seedingMode: SeedingMode
    @State private var primaryConnections: PrimaryRoleConnections
    @State private var secondaryConnections: SecondaryRoleConnections
    @State private var backupPriority: Int
    @State private var sessionTimeout: Int
    @State private var readOnlyRoutingURL: String
    @State private var error: String?

    init(group: String, replica: AvailabilityReplica, onScript: @escaping (String) -> Void) {
        self.group = group
        self.replica = replica
        self.onScript = onScript
        _availabilityMode = State(initialValue: replica.availabilityMode)
        _failoverMode = State(initialValue: replica.failoverMode)
        _seedingMode = State(initialValue: replica.seedingMode)
        _primaryConnections = State(initialValue: replica.primaryRoleConnections)
        _secondaryConnections = State(initialValue: replica.secondaryRoleConnections)
        _backupPriority = State(initialValue: replica.backupPriority)
        _sessionTimeout = State(initialValue: replica.sessionTimeout)
        _readOnlyRoutingURL = State(initialValue: replica.readOnlyRoutingURL)
    }

    var body: some View {
        VStack(spacing: 0) {
            SecurityHeader(icon: "externaldrive.connected.to.line.below",
                           title: "Replica \(replica.serverName)",
                           subtitle: "Availability group \(group)", isBusy: false)
            Divider()
            Form {
                Section("Availability") {
                    Picker("Availability mode", selection: $availabilityMode) {
                        ForEach(AvailabilityMode.allCases) { Text($0.displayName).tag($0) }
                    }
                    Picker("Failover mode", selection: $failoverMode) {
                        ForEach(FailoverMode.allCases) { Text($0.displayName).tag($0) }
                    }
                    if failoverMode == .automatic && availabilityMode != .synchronousCommit {
                        Label("Automatic failover needs synchronous commit.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    Picker("Seeding mode", selection: $seedingMode) {
                        ForEach(SeedingMode.allCases) { Text($0.displayName).tag($0) }
                    }
                }
                Section("Connections") {
                    Picker("In the primary role", selection: $primaryConnections) {
                        ForEach(PrimaryRoleConnections.allCases) { Text($0.displayName).tag($0) }
                    }
                    Picker("Readable secondary", selection: $secondaryConnections) {
                        ForEach(SecondaryRoleConnections.allCases) { Text($0.displayName).tag($0) }
                    }
                    TextField("Read-only routing URL", text: $readOnlyRoutingURL,
                              prompt: Text("TCP://node2.contoso.com:1433"))
                }
                Section("Operational") {
                    HStack {
                        Text("Backup priority")
                        Slider(value: Binding(
                            get: { Double(backupPriority) },
                            set: { backupPriority = Int($0.rounded()) }
                        ), in: 0...100, step: 1)
                        Text("\(backupPriority)").monospacedDigit().frame(width: 34)
                    }
                    HStack {
                        Text("Session timeout")
                        TextField("", value: $sessionTimeout, format: .number)
                            .frame(width: 70)
                        Text("seconds").foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                if let error {
                    Text(error).font(.caption).foregroundStyle(.red).lineLimit(2)
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Script") { apply() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 620, height: 620)
    }

    private func apply() {
        var change = AvailabilityGroupScripts.ReplicaChange()
        if availabilityMode != replica.availabilityMode { change.availabilityMode = availabilityMode }
        if failoverMode != replica.failoverMode { change.failoverMode = failoverMode }
        if seedingMode != replica.seedingMode { change.seedingMode = seedingMode }
        if primaryConnections != replica.primaryRoleConnections {
            change.primaryRoleConnections = primaryConnections
        }
        if secondaryConnections != replica.secondaryRoleConnections {
            change.secondaryRoleConnections = secondaryConnections
        }
        if backupPriority != replica.backupPriority { change.backupPriority = backupPriority }
        if sessionTimeout != replica.sessionTimeout { change.sessionTimeoutSeconds = sessionTimeout }
        if readOnlyRoutingURL != replica.readOnlyRoutingURL {
            change.readOnlyRoutingURL = readOnlyRoutingURL
        }
        // The engine checks the pair too, but it is friendlier to catch it here.
        if failoverMode == .automatic && availabilityMode != .synchronousCommit {
            error = "Automatic failover requires synchronous commit on this replica."
            return
        }
        do {
            let script = try AvailabilityGroupScripts.modifyReplica(
                group: group, replicaServerName: replica.serverName, change: change)
            onScript(script)
            dismiss()
        } catch {
            self.error = String(describing: error)
        }
    }
}

// MARK: - Group properties

struct AvailabilityGroupPropertiesSheet: View {
    @Environment(\.dismiss) private var dismiss
    let group: AvailabilityGroup
    var onScript: (String) -> Void

    @State private var backupPreference: BackupPreference
    @State private var failureConditionLevel: Int
    @State private var healthCheckTimeout: Int
    @State private var databaseLevelHealthDetection: Bool
    @State private var requiredSecondaries: Int
    @State private var error: String?

    init(group: AvailabilityGroup, onScript: @escaping (String) -> Void) {
        self.group = group
        self.onScript = onScript
        _backupPreference = State(initialValue: group.automatedBackupPreference)
        _failureConditionLevel = State(initialValue: group.failureConditionLevel)
        _healthCheckTimeout = State(initialValue: group.healthCheckTimeout)
        _databaseLevelHealthDetection = State(initialValue: group.databaseLevelHealthDetection)
        _requiredSecondaries = State(
            initialValue: group.requiredSynchronizedSecondariesToCommit)
    }

    var body: some View {
        VStack(spacing: 0) {
            SecurityHeader(icon: "arrow.triangle.2.circlepath",
                           title: "Availability group \(group.name)",
                           subtitle: group.primaryReplica.isEmpty
                           ? "no primary" : "primary: \(group.primaryReplica)",
                           isBusy: false)
            Divider()
            Form {
                Section("Backups") {
                    Picker("Automated backup preference", selection: $backupPreference) {
                        ForEach(BackupPreference.allCases) { Text($0.displayName).tag($0) }
                    }
                }
                Section("Failure detection") {
                    Picker("Failure condition level", selection: $failureConditionLevel) {
                        Text("1 — server down").tag(1)
                        Text("2 — server unresponsive").tag(2)
                        Text("3 — critical server error").tag(3)
                        Text("4 — moderate server error").tag(4)
                        Text("5 — any qualified failure").tag(5)
                    }
                    HStack {
                        Text("Health check timeout")
                        TextField("", value: $healthCheckTimeout, format: .number)
                            .frame(width: 90)
                        Text("milliseconds").foregroundStyle(.secondary)
                    }
                    Toggle("Database level health detection (DB_FAILOVER)",
                           isOn: $databaseLevelHealthDetection)
                }
                Section("Commit") {
                    HStack {
                        Text("Required synchronized secondaries")
                        TextField("", value: $requiredSecondaries, format: .number)
                            .frame(width: 60)
                    }
                    Text("Writes on the primary wait for this many synchronized secondaries. "
                         + "Setting it higher than the number of synchronous replicas stops "
                         + "writes altogether.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                if let error {
                    Text(error).font(.caption).foregroundStyle(.red).lineLimit(2)
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Script") { apply() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 620, height: 560)
    }

    private func apply() {
        var change = AvailabilityGroupScripts.GroupChange()
        if backupPreference != group.automatedBackupPreference {
            change.automatedBackupPreference = backupPreference
        }
        if failureConditionLevel != group.failureConditionLevel {
            change.failureConditionLevel = failureConditionLevel
        }
        if healthCheckTimeout != group.healthCheckTimeout {
            change.healthCheckTimeoutMilliseconds = healthCheckTimeout
        }
        if databaseLevelHealthDetection != group.databaseLevelHealthDetection {
            change.databaseLevelHealthDetection = databaseLevelHealthDetection
        }
        if requiredSecondaries != group.requiredSynchronizedSecondariesToCommit {
            change.requiredSynchronizedSecondariesToCommit = requiredSecondaries
        }
        do {
            onScript(try AvailabilityGroupScripts.modifyGroup(group: group.name, change: change))
            dismiss()
        } catch {
            self.error = String(describing: error)
        }
    }
}

// MARK: - Add database

struct AvailabilityAddDatabaseSheet: View {
    @Environment(\.dismiss) private var dismiss
    let server: ConnectedServer
    let group: AvailabilityGroup
    let replicas: [AvailabilityReplica]
    /// The databases the user picked. Adding them spans the primary and every
    /// secondary, so the dashboard turns this into a plan rather than one script.
    var onDatabases: ([String]) -> Void

    @State private var candidates: [AvailabilityCandidateDatabase] = []
    @State private var selection: Set<String> = []
    @State private var isLoading = true
    @State private var error: String?

    private var secondaries: [AvailabilityReplica] {
        replicas.filter { !$0.isPrimary }
    }

    private var usesAutomaticSeeding: Bool {
        !secondaries.isEmpty && secondaries.allSatisfy { $0.seedingMode == .automatic }
    }

    var body: some View {
        VStack(spacing: 0) {
            SecurityHeader(icon: "cylinder.split.1x2",
                           title: "Add databases to \(group.name)",
                           subtitle: server.displayName, isBusy: isLoading)
            Divider()
            Table(candidates, selection: $selection) {
                TableColumn("Database") { Text($0.name) }.width(min: 150, ideal: 220)
                TableColumn("Recovery model") { Text($0.recoveryModel.capitalized) }.width(130)
                TableColumn("Status") { candidate in
                    Text(candidate.isReady ? "Ready" : candidate.blocker)
                        .foregroundStyle(candidate.isReady ? Color.green : Color.orange)
                }.width(min: 160, ideal: 220)
            }
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Text(usesAutomaticSeeding
                     ? "Every secondary seeds automatically, so the databases are created there "
                        + "for you. The grant that allows it is on the Tasks menu."
                     : "At least one secondary seeds manually: restore a full and a log backup "
                        + "there WITH NORECOVERY, then join the database.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let error {
                    Text(error).font(.caption).foregroundStyle(.red).lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            Divider()
            HStack {
                Text("\(selection.count) selected").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Script") { apply() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selection.isEmpty)
            }
            .padding(12)
        }
        .frame(width: 720, height: 560)
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            candidates = try await AvailabilityGroupService(session: server.session)
                .candidateDatabases()
        } catch {
            self.error = String(describing: error)
        }
    }

    private func apply() {
        let names = candidates.filter { selection.contains($0.id) }.map(\.name)
        let notReady = candidates.filter { selection.contains($0.id) && !$0.isReady }
        guard notReady.isEmpty else {
            // The engine's error for this is "database is not in the full recovery
            // model", three statements into a plan. Better to say it here.
            error = "\(notReady.map(\.name).joined(separator: ", ")): "
                + "a database joins a group only in the full recovery model and after a "
                + "full backup."
            return
        }
        guard !names.isEmpty else {
            error = "Select at least one database."
            return
        }
        onDatabases(names)
        dismiss()
    }
}

// MARK: - Add replica

struct AvailabilityAddReplicaSheet: View {
    @Environment(\.dismiss) private var dismiss
    let group: AvailabilityGroup
    /// The replica to add. The ADD runs on the primary and the JOIN on the new
    /// secondary, so the dashboard turns this into a two-instance plan.
    var onReplica: (AvailabilityReplica) -> Void

    @State private var serverName = ""
    @State private var endpointURL = ""
    @State private var availabilityMode: AvailabilityMode = .synchronousCommit
    @State private var failoverMode: FailoverMode = .manual
    @State private var seedingMode: SeedingMode = .automatic
    @State private var secondaryConnections: SecondaryRoleConnections = .no
    @State private var backupPriority = 50
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            SecurityHeader(icon: "plus.rectangle.on.folder",
                           title: "Add replica to \(group.name)",
                           subtitle: "Runs on the primary, \(group.primaryReplica)",
                           isBusy: false)
            Divider()
            Form {
                Section("Instance") {
                    TextField("Server instance", text: $serverName,
                              prompt: Text("NODE2\\SQL2022"))
                        .onChange(of: serverName) { _, newValue in
                            // The endpoint is conventional, so offer it rather than
                            // making it one more thing to type.
                            if endpointURL.isEmpty || endpointURL.hasPrefix("TCP://") {
                                let host = newValue.split(separator: "\\").first.map(String.init)
                                    ?? newValue
                                endpointURL = host.isEmpty ? "" : "TCP://\(host):5022"
                            }
                        }
                    TextField("Endpoint URL", text: $endpointURL,
                              prompt: Text("TCP://node2.contoso.com:5022"))
                }
                Section("Availability") {
                    Picker("Availability mode", selection: $availabilityMode) {
                        ForEach(AvailabilityMode.allCases) { Text($0.displayName).tag($0) }
                    }
                    Picker("Failover mode", selection: $failoverMode) {
                        ForEach(FailoverMode.allCases) { Text($0.displayName).tag($0) }
                    }
                    Picker("Seeding mode", selection: $seedingMode) {
                        ForEach(SeedingMode.allCases) { Text($0.displayName).tag($0) }
                    }
                    Picker("Readable secondary", selection: $secondaryConnections) {
                        ForEach(SecondaryRoleConnections.allCases) { Text($0.displayName).tag($0) }
                    }
                    HStack {
                        Text("Backup priority")
                        TextField("", value: $backupPriority, format: .number).frame(width: 60)
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                if let error {
                    Text(error).font(.caption).foregroundStyle(.red).lineLimit(2)
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Script") { apply() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(serverName.isEmpty || endpointURL.isEmpty)
            }
            .padding(12)
        }
        .frame(width: 620, height: 560)
    }

    private func apply() {
        if failoverMode == .automatic && availabilityMode != .synchronousCommit {
            error = "Automatic failover requires synchronous commit on this replica."
            return
        }
        let replica = AvailabilityReplica(
            groupName: group.name,
            serverName: serverName,
            endpointURL: endpointURL,
            availabilityMode: availabilityMode,
            failoverMode: failoverMode,
            seedingMode: seedingMode,
            secondaryRoleConnections: secondaryConnections,
            backupPriority: backupPriority)
        onReplica(replica)
        dismiss()
    }
}

// MARK: - Listener

struct AvailabilityListenerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let group: String
    let existing: AvailabilityListener?
    var onScript: (String) -> Void

    @State private var name: String
    @State private var port: Int
    @State private var useDHCP: Bool
    @State private var address = ""
    @State private var subnetMask = ""
    @State private var error: String?

    init(group: String, existing: AvailabilityListener?, onScript: @escaping (String) -> Void) {
        self.group = group
        self.existing = existing
        self.onScript = onScript
        _name = State(initialValue: existing?.dnsName ?? "")
        _port = State(initialValue: existing?.port ?? 1433)
        _useDHCP = State(initialValue: existing?.addresses.first?.isDHCP ?? false)
    }

    var body: some View {
        VStack(spacing: 0) {
            SecurityHeader(icon: "antenna.radiowaves.left.and.right",
                           title: existing == nil ? "Add listener" : "Listener \(name)",
                           subtitle: "Availability group \(group)", isBusy: false)
            Divider()
            Form {
                Section("Listener") {
                    TextField("DNS name", text: $name, prompt: Text("ag-listener"))
                        .disabled(existing != nil)
                    HStack {
                        Text("Port")
                        TextField("", value: $port, format: .number).frame(width: 80)
                    }
                }
                Section(existing == nil ? "Network" : "Add an address") {
                    Toggle("Obtain an address from DHCP", isOn: $useDHCP)
                        .disabled(existing != nil)
                    TextField("IP address", text: $address, prompt: Text("10.0.0.25"))
                    TextField("Subnet mask", text: $subnetMask, prompt: Text("255.255.255.0"))
                    if existing != nil {
                        Text("A listener already exists: this sheet changes its port, and "
                             + "adds an address when one is filled in. One address per subnet "
                             + "is what a multi-subnet cluster needs.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                if let error {
                    Text(error).font(.caption).foregroundStyle(.red).lineLimit(2)
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Script") { apply() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.isEmpty)
            }
            .padding(12)
        }
        .frame(width: 620, height: 520)
    }

    private func apply() {
        do {
            if let existing {
                var parts: [String] = []
                if port != existing.port {
                    parts.append(try AvailabilityGroupScripts.modifyListenerPort(
                        group: group, listenerName: existing.dnsName, port: port))
                }
                if !address.isEmpty {
                    parts.append(try AvailabilityGroupScripts.addListenerIP(
                        group: group, listenerName: existing.dnsName,
                        address: AvailabilityListenerIP(address: address,
                                                        subnetMask: subnetMask)))
                }
                guard !parts.isEmpty else {
                    error = "Nothing was changed on this listener."
                    return
                }
                onScript(parts.joined(separator: "\n"))
            } else {
                var addresses: [AvailabilityListenerIP] = []
                if !address.isEmpty {
                    addresses.append(AvailabilityListenerIP(address: address,
                                                            subnetMask: subnetMask,
                                                            isDHCP: useDHCP))
                }
                onScript(try AvailabilityGroupScripts.addListener(group: group,
                                                                  listenerName: name,
                                                                  port: port,
                                                                  addresses: addresses))
            }
            dismiss()
        } catch {
            self.error = String(describing: error)
        }
    }
}
