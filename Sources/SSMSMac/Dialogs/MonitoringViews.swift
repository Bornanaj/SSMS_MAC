import SwiftUI
import AppKit
import SQLServerKit

/// The SQL Server Logs viewer from the Management folder.
struct ServerLogView: View {
    @Environment(\.dismiss) private var dismiss
    let server: ConnectedServer

    @State private var kind: ServerLogKind = .sqlServer
    @State private var archives: [ServerLogArchive] = []
    @State private var archive = 0
    @State private var searchDraft = ""
    @State private var search = ""
    @State private var entries: [ServerLogEntry] = []
    @State private var selection: Int?
    @State private var isLoading = false
    @State private var errorText: String?

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "SQL Server Logs", subtitle: server.displayName,
                        symbol: "doc.plaintext")
            Divider()
            controls
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 980, height: 640)
        .task { await load() }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Picker("Log", selection: $kind) {
                ForEach(ServerLogKind.allCases) { Text($0.title).tag($0) }
            }
            .frame(width: 220)
            .onChange(of: kind) { _, _ in Task { await reloadArchives() } }

            Picker("File", selection: $archive) {
                ForEach(archives) { Text($0.title).tag($0.archiveNumber) }
            }
            .frame(width: 170)
            .onChange(of: archive) { _, _ in Task { await load() } }

            TextField("Filter text (server side)", text: $searchDraft)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    search = searchDraft
                    Task { await load() }
                }

            Button {
                Task { await load() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(isLoading)
        }
        .padding(10)
    }

    @ViewBuilder
    private var content: some View {
        if let errorText {
            ContentUnavailableView("Could not read the log", systemImage: "exclamationmark.triangle",
                                   description: Text(errorText))
        } else if isLoading && entries.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VSplitView {
                Table(entries, selection: Binding(
                    get: { selection.map { Set([$0]) } ?? [] },
                    set: { selection = $0.first }
                )) {
                    TableColumn("") { entry in
                        Image(systemName: symbol(entry.severity))
                            .foregroundStyle(tint(entry.severity))
                    }.width(24)
                    TableColumn("Date", value: \.date).width(160)
                    TableColumn("Source", value: \.source).width(110)
                    TableColumn("Message") { Text($0.message).lineLimit(1) }
                        .width(min: 260, ideal: 520)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Message").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    ScrollView {
                        Text(selectedEntry?.message ?? "Select a line to see the full message.")
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(8)
                .frame(minHeight: 80, idealHeight: 120)
            }
        }
    }

    private var selectedEntry: ServerLogEntry? {
        entries.first { $0.id == selection }
    }

    private var errorCount: Int {
        entries.filter { $0.severity == .error }.count
    }

    private var footer: some View {
        HStack {
            if isLoading { ProgressView().controlSize(.small) }
            Text("\(entries.count) line\(entries.count == 1 ? "" : "s")")
                .font(.caption).foregroundStyle(.secondary)
            if errorCount > 0 {
                Text("· \(errorCount) error\(errorCount == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(.red)
            }
            Spacer()
            Button("Copy Selected") {
                guard let entry = selectedEntry else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(
                    "\(entry.date)\t\(entry.source)\t\(entry.message)", forType: .string)
            }
            .disabled(selection == nil)
            Button("Recycle Log") { Task { await cycle() } }
                .disabled(kind != .sqlServer)
            Button("Close") { dismiss() }.keyboardShortcut(.defaultAction)
        }
        .padding(12)
    }

    private func symbol(_ severity: ServerLogEntry.Severity) -> String {
        switch severity {
        case .error: return "xmark.octagon.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .information: return "info.circle"
        }
    }

    private func tint(_ severity: ServerLogEntry.Severity) -> Color {
        switch severity {
        case .error: return .red
        case .warning: return .orange
        case .information: return .secondary
        }
    }

    private func reloadArchives() async {
        let diagnostics = ServerDiagnostics(session: server.session)
        archives = (try? await diagnostics.logArchives(kind: kind))
            ?? [ServerLogArchive(archiveNumber: 0)]
        archive = archives.first?.archiveNumber ?? 0
        await load()
    }

    private func cycle() async {
        do {
            try await ServerDiagnostics(session: server.session).cycleErrorLog()
            await reloadArchives()
        } catch {
            errorText = String(describing: error)
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let diagnostics = ServerDiagnostics(session: server.session)
            if archives.isEmpty {
                archives = (try? await diagnostics.logArchives(kind: kind))
                    ?? [ServerLogArchive(archiveNumber: 0)]
            }
            entries = try await diagnostics.errorLog(kind: kind, archive: archive, search: search)
            errorText = nil
        } catch {
            errorText = String(describing: error)
            entries = []
        }
    }
}

/// SQL Server Agent job list, with a job's steps, schedules and history.
struct AgentJobView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    let server: ConnectedServer
    /// The job to select on open; empty means "no particular job".
    let initialJobID: String

    @State private var jobs: [AgentJobSummary] = []
    @State private var selectedJobID: String?
    @State private var steps: [AgentJobStep] = []
    @State private var selectedStepID: Int?
    @State private var schedules: [AgentJobSchedule] = []
    @State private var historyEntries: [AgentJobHistoryEntry] = []
    @State private var detailPage = "steps"
    @State private var agentRunning: Bool?
    @State private var isLoading = false
    @State private var isWorking = false
    @State private var errorText: String?

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "SQL Server Agent Jobs", subtitle: server.displayName,
                        symbol: "clock.badge.checkmark")
            Divider()
            if let agentRunning, !agentRunning {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("SQL Server Agent does not appear to be running. Jobs are listed but "
                         + "will not start.")
                        .font(.caption)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.orange.opacity(0.10))
                Divider()
            }
            content
            Divider()
            footer
        }
        .frame(width: 1000, height: 660)
        .task { await load() }
    }

    private var selectedJob: AgentJobSummary? {
        jobs.first { $0.jobID == selectedJobID }
    }

    @ViewBuilder
    private var content: some View {
        if let errorText {
            ContentUnavailableView("Could not read Agent jobs",
                                   systemImage: "exclamationmark.triangle",
                                   description: Text(errorText))
        } else if isLoading && jobs.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if jobs.isEmpty {
            ContentUnavailableView("No jobs", systemImage: "clock",
                                   description: Text("This instance has no Agent jobs."))
        } else {
            VSplitView {
                jobTable.frame(minHeight: 200)
                detailPane.frame(minHeight: 200, idealHeight: 280)
            }
        }
    }

    private var jobTable: some View {
        Table(jobs, selection: Binding(
            get: { selectedJobID.map { Set([$0]) } ?? [] },
            set: { ids in
                selectedJobID = ids.first
                Task { await loadDetail() }
            }
        )) {
            TableColumn("") { job in
                Image(systemName: job.isRunning ? "play.circle.fill"
                      : (job.isEnabled ? "circle" : "slash.circle"))
                    .foregroundStyle(job.isRunning ? Color.green
                                     : (job.isEnabled ? Color.secondary : Color.orange))
            }.width(24)
            TableColumn("Name", value: \.name).width(min: 160, ideal: 240)
            TableColumn("Enabled") { Text($0.isEnabled ? "Yes" : "No") }.width(70)
            TableColumn("Last run", value: \.lastRunDate).width(160)
            TableColumn("Outcome") { job in
                Text(job.lastRunOutcome.isEmpty ? "—" : job.lastRunOutcome)
                    .foregroundStyle(job.lastRunFailed ? Color.red : Color.primary)
            }.width(100)
            TableColumn("Duration") {
                Text(AgentScheduleFormatter.durationText(seconds: $0.lastRunDurationSeconds))
                    .monospacedDigit()
            }.width(90)
            TableColumn("Next run", value: \.nextRunDate).width(160)
            TableColumn("Category", value: \.category).width(120)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first, let job = jobs.first(where: { $0.jobID == id }) {
                Button("Start Job") { Task { await start(job) } }
                Button("Stop Job") { Task { await stop(job) } }
                Divider()
                Button(job.isEnabled ? "Disable" : "Enable") {
                    Task { await setEnabled(job, enabled: !job.isEnabled) }
                }
                Divider()
                Button("Script Job as CREATE To") { Task { await script(job) } }
            }
        }
    }

    private var detailPane: some View {
        VStack(spacing: 0) {
            Picker("", selection: $detailPage) {
                Text("Steps").tag("steps")
                Text("Schedules").tag("schedules")
                Text("History").tag("history")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)
            Divider()

            if selectedJob == nil {
                ContentUnavailableView("No job selected", systemImage: "hand.tap",
                                       description: Text("Pick a job to see its detail."))
            } else {
                switch detailPage {
                case "schedules": schedulesTable
                case "history": historyTable
                default: stepsTable
                }
            }
        }
    }

    private var stepsTable: some View {
        Table(steps, selection: Binding(
            get: { selectedStepID.map { Set([$0]) } ?? [] },
            set: { selectedStepID = $0.first }
        )) {
            TableColumn("#") { Text("\($0.stepID)").monospacedDigit() }.width(30)
            TableColumn("Name", value: \.name).width(min: 130, ideal: 180)
            TableColumn("Type", value: \.subsystem).width(90)
            TableColumn("Database", value: \.databaseName).width(110)
            TableColumn("On success", value: \.onSuccessAction).width(130)
            TableColumn("On failure", value: \.onFailAction).width(130)
            TableColumn("Command") { Text($0.command).lineLimit(1) }.width(min: 160, ideal: 260)
        }
        .contextMenu(forSelectionType: Int.self) { ids in
            if let id = ids.first, let step = steps.first(where: { $0.stepID == id }) {
                Button("Open Command in a Query Window") {
                    app.openScript(step.command, server: server,
                                   database: step.databaseName.isEmpty ? nil : step.databaseName,
                                   title: step.name)
                    dismiss()
                }
            }
        }
    }

    private var schedulesTable: some View {
        Table(schedules) {
            TableColumn("Name", value: \.name).width(min: 130, ideal: 200)
            TableColumn("Enabled") { Text($0.isEnabled ? "Yes" : "No") }.width(70)
            TableColumn("Schedule", value: \.scheduleDescription).width(min: 240, ideal: 420)
            TableColumn("Starting", value: \.nextRunDate).width(110)
        }
    }

    private var historyTable: some View {
        Table(historyEntries) {
            TableColumn("") { entry in
                Image(systemName: entry.failed ? "xmark.octagon.fill" : "checkmark.circle")
                    .foregroundStyle(entry.failed ? Color.red : Color.green)
            }.width(24)
            TableColumn("Run", value: \.runDate).width(160)
            TableColumn("Step") { entry in
                Text(entry.isJobOutcome ? "(job)" : "\(entry.stepID) \(entry.stepName)")
            }.width(150)
            TableColumn("Outcome", value: \.outcome).width(90)
            TableColumn("Duration") {
                Text(AgentScheduleFormatter.durationText(seconds: $0.durationSeconds))
                    .monospacedDigit()
            }.width(90)
            TableColumn("Message") { Text($0.message).lineLimit(2) }.width(min: 200, ideal: 380)
        }
    }

    private var footer: some View {
        HStack {
            if isLoading || isWorking { ProgressView().controlSize(.small) }
            Text("\(jobs.count) job\(jobs.count == 1 ? "" : "s")")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            if let job = selectedJob {
                Button("Start") { Task { await start(job) } }.disabled(isWorking)
                Button("Stop") { Task { await stop(job) } }.disabled(isWorking)
            }
            Button("Refresh") { Task { await load() } }
            Button("Close") { dismiss() }.keyboardShortcut(.defaultAction)
        }
        .padding(12)
    }

    // MARK: Actions

    private func start(_ job: AgentJobSummary) async {
        await perform { try await AgentJobAdmin(session: server.session).start(jobID: job.jobID) }
    }

    private func stop(_ job: AgentJobSummary) async {
        await perform { try await AgentJobAdmin(session: server.session).stop(jobID: job.jobID) }
    }

    private func setEnabled(_ job: AgentJobSummary, enabled: Bool) async {
        await perform {
            try await AgentJobAdmin(session: server.session)
                .setEnabled(jobID: job.jobID, enabled: enabled)
        }
    }

    private func script(_ job: AgentJobSummary) async {
        do {
            let sql = try await AgentJobAdmin(session: server.session).createScript(jobID: job.jobID)
            app.activeSheet = .scriptPreview("Job \(job.name)", sql)
        } catch {
            errorText = String(describing: error)
        }
    }

    private func perform(_ work: () async throws -> Void) async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await work()
            errorText = nil
            await load()
        } catch {
            errorText = String(describing: error)
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        let admin = AgentJobAdmin(session: server.session)
        do {
            jobs = try await admin.jobs()
            agentRunning = try? await admin.isAgentRunning()
            if selectedJobID == nil {
                // Opening from a tree node preselects that job; opening from the menu just
                // lands on the first one.
                let requested = jobs.first {
                    $0.jobID.caseInsensitiveCompare(initialJobID) == .orderedSame
                }
                selectedJobID = requested?.jobID ?? jobs.first?.jobID
            }
            await loadDetail()
            errorText = nil
        } catch {
            errorText = String(describing: error)
        }
    }

    private func loadDetail() async {
        guard let jobID = selectedJobID else {
            steps = []; schedules = []; historyEntries = []
            return
        }
        let admin = AgentJobAdmin(session: server.session)
        steps = (try? await admin.steps(jobID: jobID)) ?? []
        schedules = (try? await admin.schedules(jobID: jobID)) ?? []
        historyEntries = (try? await admin.history(jobID: jobID)) ?? []
    }
}

/// The Query Store reports: top consumers, regressed queries and forced plans.
struct QueryStoreView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    let server: ConnectedServer
    let database: String

    @State private var options: QueryStoreOptions?
    @State private var report = "top"
    @State private var metric: QueryStoreMetric = .duration
    @State private var hours = 24
    @State private var top: [QueryStoreEntry] = []
    @State private var regressed: [QueryStoreRegression] = []
    @State private var forced: [QueryStoreEntry] = []
    @State private var selectedQueryID: String?
    @State private var isLoading = false
    @State private var errorText: String?

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "Query Store", subtitle: "\(server.displayName) · \(database)",
                        symbol: "chart.line.uptrend.xyaxis")
            Divider()
            configurationBar
            Divider()
            controls
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 1020, height: 680)
        .task { await load() }
    }

    @ViewBuilder
    private var configurationBar: some View {
        if let options {
            HStack(spacing: 12) {
                Label(options.isEnabled ? "Query Store: \(options.actualState)" : "Query Store is off",
                      systemImage: options.isEnabled ? "checkmark.circle" : "xmark.circle")
                    .foregroundStyle(options.isEnabled ? Color.green : Color.orange)
                if options.isEnabled {
                    Text("Capture: \(options.captureMode)")
                    Text(String(format: "Storage: %.0f of %.0f MB",
                                options.currentStorageSizeMB, options.maxStorageSizeMB))
                    ProgressView(value: options.usedPercent / 100).frame(width: 90)
                    Text("Interval: \(options.intervalLengthMinutes) min")
                }
                Spacer()
                if !options.isEnabled {
                    Button("Turn On") { Task { await setState("READ_WRITE") } }
                } else {
                    Menu("Manage") {
                        Button("Set Read/Write") { Task { await setState("READ_WRITE") } }
                        Button("Set Read Only") { Task { await setState("READ_ONLY") } }
                        Button("Turn Off") { Task { await setState("OFF") } }
                        Divider()
                        Button("Purge All Data") { Task { await purge() } }
                    }
                    .frame(width: 110)
                }
            }
            .font(.caption)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
        }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Picker("Report", selection: $report) {
                Text("Top Resource Consumers").tag("top")
                Text("Regressed Queries").tag("regressed")
                Text("Forced Plans").tag("forced")
            }
            .frame(width: 240)
            .onChange(of: report) { _, _ in Task { await load() } }

            if report != "forced" {
                Picker("Metric", selection: $metric) {
                    ForEach(QueryStoreMetric.allCases) { Text($0.title).tag($0) }
                }
                .frame(width: 200)
                .onChange(of: metric) { _, _ in Task { await load() } }

                Picker("Window", selection: $hours) {
                    Text("Last hour").tag(1)
                    Text("Last 6 hours").tag(6)
                    Text("Last day").tag(24)
                    Text("Last week").tag(168)
                }
                .frame(width: 150)
                .onChange(of: hours) { _, _ in Task { await load() } }
            }

            Spacer()
            Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                .disabled(isLoading)
        }
        .padding(10)
    }

    @ViewBuilder
    private var content: some View {
        if let errorText {
            ContentUnavailableView("Query Store unavailable",
                                   systemImage: "exclamationmark.triangle",
                                   description: Text(errorText))
        } else if isLoading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            switch report {
            case "regressed": regressedTable
            case "forced": forcedTable
            default: topTable
            }
        }
    }

    private var topTable: some View {
        VSplitView {
            Table(top, selection: Binding(
                get: { selectedQueryID.map { Set([$0]) } ?? [] },
                set: { selectedQueryID = $0.first }
            )) {
                TableColumn("Query") { Text("\($0.queryID)").monospacedDigit() }.width(70)
                TableColumn("Plan") { Text("\($0.planID)").monospacedDigit() }.width(60)
                TableColumn("Object", value: \.objectName).width(120)
                TableColumn("\(metric.title) total") { entry in
                    Text(String(format: "%.1f", entry.metricTotal)).monospacedDigit()
                }.width(120)
                TableColumn("Executions") { Text("\($0.executionCount)").monospacedDigit() }
                    .width(90)
                TableColumn("Avg duration (ms)") {
                    Text(String(format: "%.2f", $0.avgDurationMs)).monospacedDigit()
                }.width(130)
                TableColumn("Avg CPU (ms)") {
                    Text(String(format: "%.2f", $0.avgCPUMs)).monospacedDigit()
                }.width(110)
                TableColumn("Forced") { Text($0.isPlanForced ? "Yes" : "") }.width(60)
                TableColumn("Plans") { Text("\($0.planCount)").monospacedDigit() }.width(50)
            }
            queryTextPane
        }
    }

    private var regressedTable: some View {
        Table(regressed) {
            TableColumn("Query") { Text("\($0.queryID)").monospacedDigit() }.width(70)
            TableColumn("Object", value: \.objectName).width(130)
            TableColumn("Recent avg") {
                Text(String(format: "%.2f", $0.recentAverage)).monospacedDigit()
            }.width(110)
            TableColumn("Baseline avg") {
                Text(String(format: "%.2f", $0.baselineAverage)).monospacedDigit()
            }.width(110)
            TableColumn("Change") { row in
                Text(String(format: "+%.0f%%", row.changePercent))
                    .monospacedDigit()
                    .foregroundStyle(row.changePercent > 50 ? Color.red : Color.orange)
            }.width(90)
            TableColumn("Recent runs") { Text("\($0.recentExecutions)").monospacedDigit() }.width(90)
            TableColumn("Query text") { Text($0.queryText).lineLimit(2) }
                .width(min: 200, ideal: 340)
        }
    }

    private var forcedTable: some View {
        Table(forced, selection: Binding(
            get: { selectedQueryID.map { Set([$0]) } ?? [] },
            set: { selectedQueryID = $0.first }
        )) {
            TableColumn("Query") { Text("\($0.queryID)").monospacedDigit() }.width(70)
            TableColumn("Plan") { Text("\($0.planID)").monospacedDigit() }.width(60)
            TableColumn("Object", value: \.objectName).width(140)
            TableColumn("Last execution", value: \.lastExecutionTime).width(160)
            TableColumn("Query text") { Text($0.queryText).lineLimit(2) }
                .width(min: 200, ideal: 380)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first, let entry = forced.first(where: { $0.id == id }) {
                Button("Unforce Plan") { Task { await unforce(entry) } }
            }
        }
    }

    private var selectedEntry: QueryStoreEntry? {
        (top + forced).first { $0.id == selectedQueryID }
    }

    private var queryTextPane: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Query text").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
                if let entry = selectedEntry {
                    Button("Show Plan") { Task { await showPlan(entry) } }
                        .font(.caption)
                    Button("Open in Query Window") {
                        app.openScript(entry.queryText, server: server, database: database,
                                       title: "Query \(entry.queryID)")
                        dismiss()
                    }
                    .font(.caption)
                    Button(entry.isPlanForced ? "Unforce Plan" : "Force Plan") {
                        Task {
                            if entry.isPlanForced {
                                await unforce(entry)
                            } else {
                                await force(entry)
                            }
                        }
                    }
                    .font(.caption)
                }
            }
            ScrollView {
                Text(selectedEntry?.queryText ?? "Select a query to see its text.")
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(8)
        .frame(minHeight: 110, idealHeight: 160)
    }

    private var footer: some View {
        HStack {
            Text(rowCountText).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Close") { dismiss() }.keyboardShortcut(.defaultAction)
        }
        .padding(12)
    }

    private var rowCountText: String {
        switch report {
        case "regressed": return "\(regressed.count) regressed quer\(regressed.count == 1 ? "y" : "ies")"
        case "forced": return "\(forced.count) forced plan\(forced.count == 1 ? "" : "s")"
        default: return "\(top.count) quer\(top.count == 1 ? "y" : "ies")"
        }
    }

    // MARK: Actions

    /// Query Store keeps the plan long after the query stopped running, so this is the
    /// only place a finished query's plan can still be looked at.
    private func showPlan(_ entry: QueryStoreEntry) async {
        do {
            let xml = try await QueryStoreReports(session: server.session)
                .planXML(database: database, planID: entry.planID)
            app.activeSheet = .executionPlan("Query \(entry.queryID), plan \(entry.planID)", xml)
        } catch {
            errorText = String(describing: error)
        }
    }

    private func force(_ entry: QueryStoreEntry) async {
        await perform {
            try await QueryStoreReports(session: server.session)
                .forcePlan(database: database, queryID: entry.queryID, planID: entry.planID)
        }
    }

    private func unforce(_ entry: QueryStoreEntry) async {
        await perform {
            try await QueryStoreReports(session: server.session)
                .unforcePlan(database: database, queryID: entry.queryID, planID: entry.planID)
        }
    }

    private func setState(_ state: String) async {
        await perform {
            try await QueryStoreReports(session: server.session)
                .setState(database: database, state: state)
        }
    }

    private func purge() async {
        await perform {
            try await QueryStoreReports(session: server.session).purge(database: database)
        }
    }

    private func perform(_ work: () async throws -> Void) async {
        do {
            try await work()
            errorText = nil
            await load()
        } catch {
            errorText = String(describing: error)
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        let reports = QueryStoreReports(session: server.session)
        do {
            options = try await reports.options(database: database)
            guard options?.isEnabled == true else {
                top = []; regressed = []; forced = []
                errorText = nil
                return
            }
            switch report {
            case "regressed":
                regressed = try await reports.regressedQueries(database: database, metric: metric)
            case "forced":
                forced = try await reports.forcedPlans(database: database)
            default:
                top = try await reports.topQueries(database: database, metric: metric, hours: hours)
            }
            errorText = nil
        } catch {
            errorText = String(describing: error)
        }
    }
}
