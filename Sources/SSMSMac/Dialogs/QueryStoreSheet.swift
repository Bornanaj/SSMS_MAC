import SwiftUI
import AppKit
import SQLServerKit

/// The Query Store reports SSMS puts under a database's Query Store node.
struct QueryStoreSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    let server: ConnectedServer
    var initialDatabase: String?

    private enum Report: String, CaseIterable, Identifiable {
        case topConsumers, regressed, forcedPlans

        var id: String { rawValue }

        var title: String {
            switch self {
            case .topConsumers: return "Top Resource Consumers"
            case .regressed: return "Regressed Queries"
            case .forcedPlans: return "Queries With Forced Plans"
            }
        }
    }

    @State private var report: Report = .topConsumers
    @State private var database = ""
    @State private var databases: [String] = []
    @State private var metric: QueryStoreMetric = .duration
    @State private var hours = 24
    @State private var options: QueryStoreOptions?
    @State private var top: [QueryStoreQuery] = []
    @State private var regressed: [QueryStoreRegression] = []
    @State private var forced: [QueryStoreQuery] = []
    @State private var selection: String?
    @State private var isBusy = false
    @State private var status: String?
    @State private var isError = false

    var body: some View {
        VStack(spacing: 0) {
            SecurityHeader(icon: "chart.line.uptrend.xyaxis", title: "Query Store",
                           subtitle: database.isEmpty
                               ? server.displayName : "\(server.displayName) · \(database)",
                           isBusy: isBusy)
            Divider()
            settingsBar
            Divider()
            controls
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 1080, height: 700)
        .task {
            database = initialDatabase ?? server.serverInfo.currentDatabase
            await loadDatabases()
            await load()
        }
        .task(id: report) { await load() }
        .task(id: database) { await load() }
        .task(id: metric) { await load() }
        .task(id: hours) { await load() }
    }

    // MARK: Chrome

    @ViewBuilder
    private var settingsBar: some View {
        if let options {
            HStack(spacing: 12) {
                Label(options.isEnabled ? "Query Store: \(options.actualState)"
                        : "Query Store is off",
                      systemImage: options.isEnabled ? "checkmark.circle" : "xmark.circle")
                    .foregroundStyle(options.isEnabled ? Color.green : Color.orange)
                if options.isEnabled {
                    Text("Capture: \(options.captureMode)")
                    Text(String(format: "Storage: %.0f of %.0f MB",
                                options.currentStorageMB, options.maxStorageMB))
                    ProgressView(value: options.usedPercent / 100).frame(width: 80)
                    Text("Interval: \(options.intervalMinutes) min")
                    if options.actualState.uppercased() == "READ_ONLY" {
                        Text("read-only — usually a full store")
                            .foregroundStyle(.orange)
                    }
                }
                Spacer()
                stateMenu(options)
            }
            .font(.caption)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
        }
    }

    @ViewBuilder
    private func stateMenu(_ options: QueryStoreOptions) -> some View {
        if options.isEnabled {
            Menu("Manage") {
                Button("Set Read/Write") { Task { await setState("READ_WRITE") } }
                Button("Set Read Only") { Task { await setState("READ_ONLY") } }
                Button("Turn Off") { Task { await setState("OFF") } }
                Divider()
                Button("Clear All Data", role: .destructive) { Task { await clear() } }
                Divider()
                Button("Script the State Change") { scriptState("READ_WRITE") }
            }
            .frame(width: 100)
        } else {
            Button("Turn On") { Task { await setState("READ_WRITE") } }
        }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Picker("Report", selection: $report) {
                ForEach(Report.allCases) { Text($0.title).tag($0) }
            }
            .frame(width: 250)

            Picker("Database", selection: $database) {
                ForEach(databases, id: \.self) { Text($0).tag($0) }
            }
            .frame(width: 180)

            if report != .forcedPlans {
                Picker("Metric", selection: $metric) {
                    ForEach(QueryStoreMetric.allCases) { Text($0.title).tag($0) }
                }
                .frame(width: 190)
            }

            if report == .topConsumers {
                Picker("Window", selection: $hours) {
                    Text("Last hour").tag(1)
                    Text("Last 6 hours").tag(6)
                    Text("Last day").tag(24)
                    Text("Last week").tag(168)
                }
                .frame(width: 150)
            }

            Spacer()
            Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                .disabled(isBusy)
        }
        .padding(10)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if isBusy {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if isError {
            ContentUnavailableView("Query Store unavailable",
                                   systemImage: "exclamationmark.triangle",
                                   description: Text(status ?? ""))
        } else if options?.isEnabled != true {
            ContentUnavailableView("Query Store is off", systemImage: "chart.line.uptrend.xyaxis",
                                   description: Text("Turn it on above. It starts collecting "
                                                     + "immediately, but the reports stay empty "
                                                     + "until the first interval closes."))
        } else {
            switch report {
            case .regressed: regressedTable
            case .forcedPlans: VSplitView { forcedTable; queryPane }
            case .topConsumers: VSplitView { topTable; queryPane }
            }
        }
    }

    private var topTable: some View {
        Table(top, selection: Binding(
            get: { selection.map { Set([$0]) } ?? [] },
            set: { selection = $0.first }
        )) {
            TableColumn("Query") { Text("\($0.queryID)").monospacedDigit() }.width(60)
            TableColumn("Plan") { Text("\($0.planID)").monospacedDigit() }.width(55)
            TableColumn("Object", value: \.objectName).width(120)
            TableColumn("Total \(metric.title) (\(metric.unit))") { row in
                Text(String(format: "%.1f", row.metricTotal)).monospacedDigit()
            }.width(150)
            TableColumn("Executions") { Text("\($0.executionCount)").monospacedDigit() }.width(85)
            TableColumn("Avg duration (ms)") {
                Text(String(format: "%.2f", $0.avgDurationMs)).monospacedDigit()
            }.width(130)
            TableColumn("Avg CPU (ms)") {
                Text(String(format: "%.2f", $0.avgCPUMs)).monospacedDigit()
            }.width(110)
            TableColumn("Avg reads") {
                Text(String(format: "%.0f", $0.avgLogicalReads)).monospacedDigit()
            }.width(90)
            TableColumn("Plans") { row in
                Text(row.isPlanForced ? "\(row.planCount) (forced)" : "\(row.planCount)")
                    .foregroundStyle(row.isPlanForced ? Color.orange : Color.primary)
            }.width(90)
        }
    }

    private var regressedTable: some View {
        Table(regressed) {
            TableColumn("Query") { Text("\($0.queryID)").monospacedDigit() }.width(60)
            TableColumn("Object", value: \.objectName).width(130)
            TableColumn("Recent avg") {
                Text(String(format: "%.2f", $0.recentAverage)).monospacedDigit()
            }.width(105)
            TableColumn("Baseline avg") {
                Text(String(format: "%.2f", $0.baselineAverage)).monospacedDigit()
            }.width(110)
            TableColumn("Change") { row in
                Text(String(format: "+%.0f%%", row.changePercent))
                    .monospacedDigit()
                    .foregroundStyle(row.changePercent > 50 ? Color.red : Color.orange)
            }.width(85)
            TableColumn("Recent runs") { Text("\($0.recentExecutions)").monospacedDigit() }
                .width(95)
            TableColumn("Baseline runs") { Text("\($0.baselineExecutions)").monospacedDigit() }
                .width(105)
            TableColumn("Query text") { Text($0.queryText).lineLimit(2) }
                .width(min: 180, ideal: 320)
        }
    }

    private var forcedTable: some View {
        Table(forced, selection: Binding(
            get: { selection.map { Set([$0]) } ?? [] },
            set: { selection = $0.first }
        )) {
            TableColumn("Query") { Text("\($0.queryID)").monospacedDigit() }.width(60)
            TableColumn("Plan") { Text("\($0.planID)").monospacedDigit() }.width(55)
            TableColumn("Object / status", value: \.objectName).width(min: 160, ideal: 240)
            TableColumn("Last executed", value: \.lastExecutedAt).width(160)
            TableColumn("Query text") { Text($0.queryText).lineLimit(2) }
                .width(min: 180, ideal: 320)
        }
    }

    private var selected: QueryStoreQuery? {
        (top + forced).first { $0.id == selection }
    }

    private var queryPane: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("Query text").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
                if let entry = selected {
                    Button("Show Plan") { Task { await showPlan(entry) } }
                    Button("Open in Query Window") {
                        app.openScript(entry.queryText, server: server, database: database,
                                       title: "Query \(entry.queryID)")
                        dismiss()
                    }
                    Button(entry.isPlanForced ? "Unforce Plan" : "Force Plan") {
                        Task { await toggleForce(entry) }
                    }
                }
            }
            .font(.caption)
            ScrollView {
                Text(selected?.queryText ?? "Select a query to see its text.")
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(8)
        .frame(minHeight: 110, idealHeight: 170)
    }

    private var footer: some View {
        SecurityFooter(status: status ?? rowSummary, isError: isError) { dismiss() }
    }

    private var rowSummary: String {
        switch report {
        case .regressed:
            return "\(regressed.count) regressed quer\(regressed.count == 1 ? "y" : "ies")"
        case .forcedPlans:
            return "\(forced.count) forced plan\(forced.count == 1 ? "" : "s")"
        case .topConsumers:
            return "\(top.count) quer\(top.count == 1 ? "y" : "ies")"
        }
    }

    // MARK: Actions

    private func scriptState(_ state: String) {
        let azure = server.serverInfo.isAzureSQLDatabase
        guard let sql = try? QueryStoreService.setStateScript(database: database, state: state,
                                                             useCurrentDatabase: azure) else {
            return
        }
        app.activeSheet = .scriptPreview("Query Store on \(database)", sql + "\nGO\n")
    }

    /// Query Store keeps the plan long after the query stopped running, which is the only
    /// reason a finished query's plan can still be looked at.
    private func showPlan(_ entry: QueryStoreQuery) async {
        do {
            let xml = try await QueryStoreService(session: server.session)
                .planXML(database: database, planID: entry.planID)
            app.activeSheet = .executionPlan("Query \(entry.queryID), plan \(entry.planID)", xml)
        } catch {
            isError = true
            status = String(describing: error)
        }
    }

    private func toggleForce(_ entry: QueryStoreQuery) async {
        let service = QueryStoreService(session: server.session)
        await perform {
            if entry.isPlanForced {
                try await service.unforcePlan(database: database, queryID: entry.queryID,
                                              planID: entry.planID)
            } else {
                try await service.forcePlan(database: database, queryID: entry.queryID,
                                            planID: entry.planID)
            }
        }
    }

    private func setState(_ state: String) async {
        await perform {
            try await QueryStoreService(session: server.session)
                .setState(database: database, state: state)
        }
    }

    private func clear() async {
        await perform {
            try await QueryStoreService(session: server.session).clear(database: database)
        }
    }

    private func perform(_ work: () async throws -> Void) async {
        isBusy = true
        defer { isBusy = false }
        do {
            try await work()
            isError = false
            status = nil
        } catch {
            isError = true
            status = String(describing: error)
            return
        }
        await load()
    }

    // MARK: Loading

    private func loadDatabases() async {
        let sql = "SELECT name FROM sys.databases WHERE state_desc = 'ONLINE' "
            + "AND HAS_DBACCESS(name) = 1 AND database_id > 4 ORDER BY name"
        guard let response = try? await server.session.metadataQuery(sql) else { return }
        databases = (response.resultSets.first?.dictionaries() ?? []).map { $0.string("name") }
        if database.isEmpty || !databases.contains(database) {
            database = databases.first ?? database
        }
    }

    private func load() async {
        guard !database.isEmpty else { return }
        isBusy = true
        defer { isBusy = false }
        let service = QueryStoreService(session: server.session)
        do {
            options = try await service.options(database: database)
            guard options?.isEnabled == true else {
                top = []; regressed = []; forced = []
                isError = false
                status = nil
                return
            }
            switch report {
            case .topConsumers:
                top = try await service.topQueries(database: database, metric: metric,
                                                  hours: hours)
            case .regressed:
                regressed = try await service.regressedQueries(database: database, metric: metric)
            case .forcedPlans:
                forced = try await service.forcedPlans(database: database)
            }
            isError = false
            status = nil
        } catch {
            isError = true
            status = String(describing: error)
        }
    }
}
