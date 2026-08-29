import SwiftUI
import SQLServerKit

/// Server Properties: the General, Memory, Processors, Security and Advanced pages.
struct ServerPropertiesView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    let server: ConnectedServer

    @State private var properties: ServerProperties?
    @State private var configurations: [ServerConfiguration] = []
    @State private var errorText: String?
    @State private var page = "general"
    @State private var configurationSelection: Int?
    @State private var draftValue = ""
    @State private var applyMessage: String?
    @State private var isApplying = false
    @State private var configurationFilter = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Picker("", selection: $page) {
                Text("General").tag("general")
                Text("Memory").tag("memory")
                Text("Processors").tag("processors")
                Text("Security").tag("security")
                Text("Advanced").tag("advanced")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 820, height: 600)
        .task { await load() }
    }

    private var header: some View {
        HStack {
            Image(systemName: "server.rack").foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("Server Properties").font(.headline)
                Text(server.displayName).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
    }

    @ViewBuilder
    private var content: some View {
        if let errorText {
            ContentUnavailableView("Could not read server properties",
                                   systemImage: "exclamationmark.triangle",
                                   description: Text(errorText))
        } else if let properties {
            switch page {
            case "memory": ScrollView { memoryPage(properties) }
            case "processors": ScrollView { processorsPage(properties) }
            case "security": ScrollView { securityPage(properties) }
            case "advanced": advancedPage
            default: ScrollView { generalPage(properties) }
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func generalPage(_ p: ServerProperties) -> some View {
        PropertyGrid(rows: [
            ("Name", p.name),
            ("Product", p.product),
            ("Version", p.friendlyVersion),
            ("Version number", p.version),
            ("Product level", p.productLevel),
            ("Edition", p.edition),
            ("Operating system host", p.machineName),
            ("Instance", p.instanceName.isEmpty ? "(default)" : p.instanceName),
            ("Server collation", p.collation),
            ("Language", p.language),
            ("Clustered", p.isClustered ? "True" : "False"),
            ("HADR enabled", p.isHadrEnabled ? "True" : "False"),
            ("Full-text installed", p.isFullTextInstalled ? "True" : "False"),
            ("Root directory", p.rootDirectory),
            ("Started", p.startTime),
            ("Uptime", p.uptimeText),
            ("Memory (host)", p.physicalMemoryMB > 0
                ? String(format: "%.1f GB", Double(p.physicalMemoryMB) / 1024) : ""),
            ("Processors", p.processorCount > 0 ? "\(p.processorCount)" : ""),
            ("Platform", p.virtualMachineType)
        ])
    }

    private func memoryPage(_ p: ServerProperties) -> some View {
        PropertyGrid(rows: [
            ("Minimum server memory", "\(p.minServerMemoryMB) MB"),
            ("Maximum server memory", p.maxServerMemoryMB >= 2_147_483_647
                ? "Unlimited (2147483647 MB)" : "\(p.maxServerMemoryMB) MB"),
            ("Host physical memory", p.physicalMemoryMB > 0 ? "\(p.physicalMemoryMB) MB" : ""),
            ("Optimize for ad hoc workloads", p.isOptimizeForAdHocWorkloads ? "True" : "False"),
            ("", ""),
            ("Change these on the Advanced page",
             "min server memory (MB) / max server memory (MB)")
        ])
    }

    private func processorsPage(_ p: ServerProperties) -> some View {
        PropertyGrid(rows: [
            ("Processors", "\(p.processorCount)"),
            ("Schedulers", "\(p.schedulerCount)"),
            ("Hyperthread ratio", "\(p.hyperthreadRatio)"),
            ("Sockets", p.socketCount > 0 ? "\(p.socketCount)" : ""),
            ("Max degree of parallelism", p.maxDegreeOfParallelism == 0
                ? "0 (all available processors)" : "\(p.maxDegreeOfParallelism)"),
            ("Cost threshold for parallelism", "\(p.costThresholdForParallelism)"),
            ("Max worker threads", p.maxWorkerThreads == 0
                ? "0 (automatic)" : "\(p.maxWorkerThreads)")
        ])
    }

    private func securityPage(_ p: ServerProperties) -> some View {
        PropertyGrid(rows: [
            ("Server authentication", p.authenticationMode),
            ("Login", server.serverInfo.loginName),
            ("Member of sysadmin", server.serverInfo.isSysadmin ? "Yes" : "No"),
            ("Remote admin connections", p.isRemoteAdminConnectionsEnabled ? "Enabled" : "Disabled"),
            ("Remote query timeout", "\(p.remoteQueryTimeoutSeconds) s"),
            ("User connection limit", p.userConnectionLimit == 0
                ? "0 (unlimited)" : "\(p.userConnectionLimit)"),
            ("Backup compression default", p.isBackupCompressionDefault ? "On" : "Off"),
            ("Default data path", p.defaultDataPath),
            ("Default log path", p.defaultLogPath),
            ("Default backup path", p.defaultBackupPath)
        ])
    }

    private var filteredConfigurations: [ServerConfiguration] {
        guard !configurationFilter.isEmpty else { return configurations }
        return configurations.filter {
            $0.name.localizedCaseInsensitiveContains(configurationFilter)
                || $0.configurationDescription.localizedCaseInsensitiveContains(configurationFilter)
        }
    }

    private var selectedConfiguration: ServerConfiguration? {
        configurations.first { $0.configurationID == configurationSelection }
    }

    private var advancedPage: some View {
        VSplitView {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .foregroundStyle(.secondary)
                    TextField("Filter options", text: $configurationFilter)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)

                Table(filteredConfigurations, selection: Binding(
                    get: { configurationSelection.map { Set([$0]) } ?? [] },
                    set: { ids in
                        configurationSelection = ids.first
                        draftValue = selectedConfiguration.map { "\($0.value)" } ?? ""
                        applyMessage = nil
                    }
                )) {
                    TableColumn("Option", value: \.name).width(min: 200, ideal: 260)
                    TableColumn("Configured") { Text("\($0.value)").monospacedDigit() }.width(100)
                    TableColumn("In use") { row in
                        Text("\(row.valueInUse)")
                            .monospacedDigit()
                            .foregroundStyle(row.isPending ? Color.orange : Color.primary)
                    }.width(100)
                    TableColumn("Range") { Text("\($0.minimum)–\($0.maximum)").font(.caption) }
                        .width(140)
                    TableColumn("Dynamic") { Text($0.isDynamic ? "Yes" : "Restart") }.width(70)
                }
            }
            .frame(minHeight: 220)

            configurationEditor
                .frame(minHeight: 140, idealHeight: 170)
        }
    }

    @ViewBuilder
    private var configurationEditor: some View {
        if let option = selectedConfiguration {
            VStack(alignment: .leading, spacing: 8) {
                Text(option.name).font(.headline)
                if !option.configurationDescription.isEmpty {
                    Text(option.configurationDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    TextField("Value", text: $draftValue)
                        .frame(width: 140)
                        .monospacedDigit()
                    Text("Allowed \(option.minimum)–\(option.maximum)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Script") { scriptChange(option) }
                        .disabled(Int64(draftValue) == nil)
                    Button("Apply") { Task { await apply(option) } }
                        .keyboardShortcut(.return)
                        .disabled(isApplying || Int64(draftValue) == nil)
                }
                if option.isAdvanced {
                    Label("Advanced option — the script turns on show advanced options first.",
                          systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let applyMessage {
                    Text(applyMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
        } else {
            ContentUnavailableView("No option selected", systemImage: "slider.horizontal.3",
                                   description: Text("Pick a configuration option to change it."))
        }
    }

    private var footer: some View {
        HStack {
            if isApplying { ProgressView().controlSize(.small) }
            Spacer()
            Button("Refresh") { Task { await load() } }
            Button("Close") { dismiss() }.keyboardShortcut(.defaultAction)
        }
        .padding(12)
    }

    private func scriptChange(_ option: ServerConfiguration) {
        guard let value = Int64(draftValue) else { return }
        let admin = ServerAdmin(session: server.session)
        app.activeSheet = .scriptPreview("sp_configure \(option.name)",
                                         admin.configurationScript(name: option.name, value: value))
    }

    private func apply(_ option: ServerConfiguration) async {
        guard let value = Int64(draftValue) else { return }
        isApplying = true
        defer { isApplying = false }
        do {
            let lines = try await ServerAdmin(session: server.session)
                .setConfiguration(name: option.name, value: value)
            applyMessage = lines.isEmpty ? "Applied." : lines.joined(separator: "\n")
            await load()
        } catch {
            applyMessage = String(describing: error)
        }
    }

    private func load() async {
        let admin = ServerAdmin(session: server.session)
        do {
            properties = try await admin.properties()
            configurations = (try? await admin.configurations()) ?? []
            errorText = nil
        } catch {
            errorText = String(describing: error)
        }
    }
}

/// The server dashboard: live counters, derived per-second rates and database sizes.
struct ServerDashboardView: View {
    @Environment(\.dismiss) private var dismiss
    let server: ConnectedServer

    @State private var snapshot: ServerSnapshot?
    @State private var rates = ServerRates()
    @State private var databases: [DatabaseSizeSummary] = []
    @State private var waits: [WaitStatistic] = []
    @State private var errorText: String?
    @State private var autoRefresh = true
    @State private var refreshTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 940, height: 640)
        .task { await refresh() }
        .onAppear { startAutoRefresh() }
        .onDisappear { refreshTask?.cancel() }
    }

    private var header: some View {
        HStack {
            Image(systemName: "gauge.with.dots.needle.bottom.50percent").foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("Server Dashboard").font(.headline)
                Text(server.displayName).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("Auto refresh", isOn: $autoRefresh)
                .onChange(of: autoRefresh) { _, on in
                    if on { startAutoRefresh() } else { refreshTask?.cancel() }
                }
            Button { Task { await refresh() } } label: { Image(systemName: "arrow.clockwise") }
        }
        .padding(12)
    }

    @ViewBuilder
    private var content: some View {
        if let errorText {
            ContentUnavailableView("Could not read the dashboard",
                                   systemImage: "exclamationmark.triangle",
                                   description: Text(errorText))
        } else if let snapshot {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    tileRow(snapshot)
                    section("Databases") {
                        Table(databases) {
                            TableColumn("Name", value: \.name).width(min: 140, ideal: 200)
                            TableColumn("State", value: \.state).width(90)
                            TableColumn("Recovery", value: \.recoveryModel).width(100)
                            TableColumn("Data (MB)") {
                                Text(String(format: "%.0f", $0.dataSizeMB)).monospacedDigit()
                            }.width(90)
                            TableColumn("Log (MB)") {
                                Text(String(format: "%.0f", $0.logSizeMB)).monospacedDigit()
                            }.width(90)
                            TableColumn("Last full backup") { row in
                                Text(row.lastFullBackup.isEmpty ? "None" : row.lastFullBackup)
                                    .foregroundStyle(row.lastFullBackup.isEmpty
                                                     ? Color.orange : Color.primary)
                            }.width(min: 130, ideal: 180)
                        }
                        .frame(height: 220)
                    }
                    section("Top waits") {
                        Table(waits) {
                            TableColumn("Wait type", value: \.waitType).width(min: 160, ideal: 240)
                            TableColumn("Wait time (ms)") {
                                Text("\($0.waitTimeMs)").monospacedDigit()
                            }.width(120)
                            TableColumn("Share") { wait in
                                HStack(spacing: 6) {
                                    ProgressView(value: min(wait.percentage / 100, 1))
                                        .frame(width: 80)
                                    Text(String(format: "%.1f%%", wait.percentage)).monospacedDigit()
                                }
                            }.width(160)
                        }
                        .frame(height: 180)
                    }
                }
                .padding(12)
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func tileRow(_ snapshot: ServerSnapshot) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4),
                  spacing: 10) {
            tile("Sessions", "\(snapshot.totalSessions)", "person.2")
            tile("Active requests", "\(snapshot.activeRequests)", "bolt")
            tile("Blocked", "\(snapshot.blockedRequests)", "hand.raised",
                 tint: snapshot.blockedRequests > 0 ? .orange : nil)
            tile("Connections", "\(snapshot.userConnections)", "cable.connector")
            tile("Batches/sec", String(format: "%.1f", rates.batchRequestsPerSecond), "speedometer")
            tile("Transactions/sec", String(format: "%.1f", rates.transactionsPerSecond),
                 "arrow.triangle.2.circlepath")
            tile("Compilations/sec", String(format: "%.1f", rates.compilationsPerSecond), "hammer")
            tile("Deadlocks/sec", String(format: "%.2f", rates.deadlocksPerSecond),
                 "exclamationmark.triangle",
                 tint: rates.deadlocksPerSecond > 0 ? .red : nil)
            tile("SQL CPU", String(format: "%.0f%%", snapshot.sqlProcessCPUPercent), "cpu")
            tile("Buffer cache hit", String(format: "%.1f%%", snapshot.bufferCacheHitRatioPercent),
                 "memorychip")
            tile("Page life expectancy", "\(snapshot.pageLifeExpectancySeconds) s", "clock")
            tile("Server memory", String(format: "%.0f MB", snapshot.totalServerMemoryMB),
                 "square.stack.3d.up")
        }
    }

    private func tile(_ title: String, _ value: String, _ symbol: String,
                      tint: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.caption)
                Text(title).font(.caption).lineLimit(1)
            }
            .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.monospacedDigit())
                .foregroundStyle(tint ?? .primary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }

    private var footer: some View {
        HStack {
            if let snapshot {
                Text("Updated \(snapshot.capturedAt.formatted(date: .omitted, time: .standard))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Close") { dismiss() }.keyboardShortcut(.defaultAction)
        }
        .padding(12)
    }

    private func startAutoRefresh() {
        refreshTask?.cancel()
        guard autoRefresh else { return }
        refreshTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled else { return }
                await refresh()
            }
        }
    }

    private func refresh() async {
        let diagnostics = ServerDiagnostics(session: server.session)
        let monitor = ActivityMonitor(session: server.session)
        do {
            let fresh = try await diagnostics.snapshot()
            // Cumulative counters only become rates once there are two readings.
            if let earlier = snapshot {
                rates = ServerRates.between(earlier, fresh)
            }
            snapshot = fresh
            databases = (try? await diagnostics.databaseSizes()) ?? []
            waits = (try? await monitor.waits(top: 12)) ?? []
            errorText = nil
        } catch {
            errorText = String(describing: error)
        }
    }
}
