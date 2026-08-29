import SwiftUI
import SQLServerKit

/// The Activity Monitor: live sessions, waits, expensive queries and file IO.
struct ActivityMonitorView: View {
    @Environment(\.dismiss) private var dismiss
    let server: ConnectedServer

    @State private var sessions: [ActivitySession] = []
    @State private var waits: [WaitStatistic] = []
    @State private var queries: [ExpensiveQuery] = []
    @State private var fileIO: [DataFileIOStat] = []
    @State private var selectedTab = "sessions"
    @State private var includeSystem = false
    @State private var autoRefresh = true
    @State private var isLoading = false
    @State private var errorText: String?
    @State private var selectedSession: ActivitySession?
    @State private var refreshTask: Task<Void, Never>?

    /// Rebuilt from `sessions` rather than queried, so the tree can never disagree with
    /// the process list it came from.
    private var blockingRows: [BlockingRow] {
        BlockingChain.rows(from: BlockingChain.build(from: sessions))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Picker("", selection: $selectedTab) {
                Text("Processes").tag("sessions")
                Text("Blocking").tag("blocking")
                Text("Resource Waits").tag("waits")
                Text("Recent Expensive Queries").tag("queries")
                Text("Data File I/O").tag("io")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)

            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 1000, height: 620)
        .task { await refresh() }
        .onAppear { startAutoRefresh() }
        .onDisappear { refreshTask?.cancel() }
    }

    private var header: some View {
        HStack {
            Image(systemName: "waveform.path.ecg").foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("Activity Monitor").font(.headline)
                Text(server.displayName).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("Include system sessions", isOn: $includeSystem)
                .onChange(of: includeSystem) { _, _ in Task { await refresh() } }
            Toggle("Auto refresh", isOn: $autoRefresh)
                .onChange(of: autoRefresh) { _, on in
                    if on { startAutoRefresh() } else { refreshTask?.cancel() }
                }
            Button {
                Task { await refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(isLoading)
        }
        .padding(12)
    }

    @ViewBuilder
    private var content: some View {
        if let errorText {
            ContentUnavailableView("Could not read activity", systemImage: "exclamationmark.triangle",
                                   description: Text(errorText))
        } else {
            switch selectedTab {
            case "blocking": blockingTree
            case "waits": waitsTable
            case "queries": queriesTable
            case "io": ioTable
            default: sessionsTable
            }
        }
    }

    /// The blocking tree. Killing the head of a chain is usually the fix, so the head is
    /// called out and its statement is shown underneath.
    @ViewBuilder
    private var blockingTree: some View {
        if blockingRows.isEmpty {
            ContentUnavailableView("Nothing is blocked", systemImage: "checkmark.circle",
                                   description: Text(includeSystem
                                       ? "No session is waiting on another."
                                       : "No user session is waiting on another. Turn on "
                                         + "system sessions if a background task is suspect."))
        } else {
            VSplitView {
                Table(blockingRows, selection: Binding(
                    get: { selectedSession.map { Set([$0.id]) } ?? [] },
                    set: { ids in selectedSession = sessions.first { ids.contains($0.id) } }
                )) {
                    TableColumn("Chain") { row in
                        HStack(spacing: 4) {
                            Color.clear.frame(width: CGFloat(row.depth) * 16, height: 1)
                            Image(systemName: row.isHead ? "exclamationmark.triangle.fill"
                                  : "arrow.turn.down.right")
                                .font(.system(size: 10))
                                .foregroundStyle(row.isHead ? Color.orange : Color.secondary)
                            Text("\(row.session.sessionID)").monospacedDigit()
                        }
                    }.width(140)
                    TableColumn("Role") { row in
                        Text(row.isHead ? "Head of chain" : "Blocked")
                            .foregroundStyle(row.isHead ? Color.orange : Color.primary)
                    }.width(110)
                    TableColumn("Login") { Text($0.session.loginName) }.width(130)
                    TableColumn("Database") { Text($0.session.databaseName) }.width(110)
                    TableColumn("Wait") { Text($0.session.waitType).lineLimit(1) }.width(150)
                    TableColumn("Wait (ms)") {
                        Text("\($0.session.waitTimeMs)").monospacedDigit()
                    }.width(90)
                    TableColumn("Open txns") {
                        Text("\($0.session.openTransactionCount)").monospacedDigit()
                    }.width(80)
                    TableColumn("Host / application") { row in
                        Text([row.session.hostName, row.session.programName]
                            .filter { !$0.isEmpty }.joined(separator: " · "))
                            .lineLimit(1)
                    }.width(min: 140, ideal: 220)
                }
                .contextMenu(forSelectionType: Int.self) { ids in
                    if let id = ids.first {
                        Button("Kill Process \(id)", role: .destructive) { kill(id) }
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Statement").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    ScrollView {
                        Text(selectedSession?.sqlText
                             ?? "Select a session to see what it is running.")
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(8)
                .frame(minHeight: 90, idealHeight: 130)
            }
        }
    }

    private var sessionsTable: some View {
        VSplitView {
            Table(sessions, selection: Binding(
                get: { selectedSession.map { Set([$0.id]) } ?? [] },
                set: { ids in selectedSession = sessions.first { ids.contains($0.id) } }
            )) {
                TableColumn("SPID") { Text("\($0.sessionID)").monospacedDigit() }.width(52)
                TableColumn("Login", value: \.loginName).width(130)
                TableColumn("Database", value: \.databaseName).width(120)
                TableColumn("Status", value: \.status).width(80)
                TableColumn("Command", value: \.command).width(110)
                TableColumn("Blocked by") { session in
                    Text(session.isBlocked ? "\(session.blockingSessionID)" : "")
                        .foregroundStyle(session.isBlocked ? Color.red : Color.primary)
                        .monospacedDigit()
                }.width(80)
                TableColumn("Wait") { Text($0.waitType).lineLimit(1) }.width(140)
                TableColumn("CPU (ms)") { Text("\($0.cpuTimeMs)").monospacedDigit() }.width(80)
                TableColumn("Reads") { Text("\($0.logicalReads)").monospacedDigit() }.width(90)
                TableColumn("Host / application") { session in
                    Text([session.hostName, session.programName]
                        .filter { !$0.isEmpty }.joined(separator: " · "))
                        .lineLimit(1)
                }.width(220)
            }
            .contextMenu(forSelectionType: Int.self) { ids in
                if let id = ids.first {
                    Button("Kill Process \(id)", role: .destructive) { kill(id) }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Statement").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                ScrollView {
                    Text(selectedSession?.sqlText ?? "Select a process to see its current statement.")
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(8)
            .frame(minHeight: 90, idealHeight: 130)
        }
    }

    private var waitsTable: some View {
        Table(waits) {
            TableColumn("Wait type", value: \.waitType).width(240)
            TableColumn("Wait time (ms)") { Text("\($0.waitTimeMs)").monospacedDigit() }.width(120)
            TableColumn("Waiting tasks") { Text("\($0.waitingTasks)").monospacedDigit() }.width(110)
            TableColumn("Signal wait (ms)") { Text("\($0.signalWaitMs)").monospacedDigit() }.width(130)
            TableColumn("Share") { wait in
                HStack(spacing: 6) {
                    ProgressView(value: min(wait.percentage / 100, 1)).frame(width: 90)
                    Text(String(format: "%.1f%%", wait.percentage)).monospacedDigit()
                }
            }.width(170)
        }
    }

    private var queriesTable: some View {
        Table(queries) {
            TableColumn("Query") { Text($0.queryText).lineLimit(2) }.width(min: 260, ideal: 400)
            TableColumn("Executions") { Text("\($0.executionCount)").monospacedDigit() }.width(90)
            TableColumn("Avg CPU (ms)") { Text(String(format: "%.1f", $0.avgCpuMs)).monospacedDigit() }
                .width(110)
            TableColumn("Avg duration (ms)") {
                Text(String(format: "%.1f", $0.avgDurationMs)).monospacedDigit()
            }.width(130)
            TableColumn("Avg reads") {
                Text(String(format: "%.0f", $0.avgLogicalReads)).monospacedDigit()
            }.width(100)
            TableColumn("Database", value: \.databaseName).width(120)
        }
    }

    private var ioTable: some View {
        Table(fileIO) {
            TableColumn("Database", value: \.databaseName).width(150)
            TableColumn("File", value: \.fileName).width(140)
            TableColumn("Type", value: \.fileType).width(70)
            TableColumn("Size (MB)") { Text(String(format: "%.0f", $0.sizeMB)).monospacedDigit() }
                .width(90)
            TableColumn("Reads") { Text("\($0.numberOfReads)").monospacedDigit() }.width(100)
            TableColumn("Writes") { Text("\($0.numberOfWrites)").monospacedDigit() }.width(100)
            TableColumn("Read latency (ms)") {
                Text(String(format: "%.1f", $0.readLatencyMs)).monospacedDigit()
            }.width(130)
            TableColumn("Write latency (ms)") {
                Text(String(format: "%.1f", $0.writeLatencyMs)).monospacedDigit()
            }.width(130)
        }
    }

    private var footer: some View {
        HStack {
            if isLoading { ProgressView().controlSize(.small) }
            Text("\(sessions.count) processes")
                .font(.caption)
                .foregroundStyle(.secondary)
            if blockedCount > 0 {
                Text("· \(blockedCount) blocked")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if selectedTab == "blocking", let worst = worstOffender {
                Text("· head of the worst chain: spid \(worst.session.sessionID), "
                     + "holding up \(worst.descendantCount)")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Spacer()
            Button("Close") { dismiss() }.keyboardShortcut(.defaultAction)
        }
        .padding(12)
    }

    private var blockedCount: Int {
        sessions.filter { $0.isBlocked && $0.blockingSessionID != $0.sessionID }.count
    }

    /// The session an operator should look at first: the one holding up the most others.
    private var worstOffender: BlockingNode? {
        BlockingChain.worstOffender(in: BlockingChain.build(from: sessions))
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
        isLoading = true
        defer { isLoading = false }
        let monitor = ActivityMonitor(session: server.session)
        do {
            async let sessionsResult = monitor.sessions(includeSystem: includeSystem)
            async let waitsResult = monitor.waits(top: 25)
            async let queriesResult = monitor.expensiveQueries(top: 25)
            async let ioResult = monitor.fileIO()
            sessions = try await sessionsResult
            waits = try await waitsResult
            queries = try await queriesResult
            fileIO = try await ioResult
            errorText = nil
        } catch {
            errorText = String(describing: error)
        }
    }

    private func kill(_ sessionID: Int) {
        Task {
            let monitor = ActivityMonitor(session: server.session)
            do {
                try await monitor.killSession(sessionID)
                await refresh()
            } catch {
                errorText = String(describing: error)
            }
        }
    }
}
