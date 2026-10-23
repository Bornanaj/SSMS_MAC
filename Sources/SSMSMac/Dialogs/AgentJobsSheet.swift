import SwiftUI
import SQLServerKit

/// SQL Server Agent's Jobs node and its Job Activity Monitor in one window: what is
/// scheduled, what is running right now and on which step, what each job did last time,
/// and the controls to start (optionally at a chosen step), stop, enable and script it.
struct AgentJobsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let server: ConnectedServer

    private enum Detail: String, CaseIterable, Identifiable {
        case steps, schedules, history
        var id: String { rawValue }
        var title: String {
            switch self {
            case .steps: return "Steps"
            case .schedules: return "Schedules"
            case .history: return "History"
            }
        }
    }

    /// The Job Activity Monitor's status filter, same buckets SSMS offers.
    private enum StatusFilter: String, CaseIterable, Identifiable {
        case all, running, failed, idle, disabled, scheduled

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: return "All"
            case .running: return "Running"
            case .failed: return "Failed"
            case .idle: return "Idle"
            case .disabled: return "Disabled"
            case .scheduled: return "Scheduled"
            }
        }

        func matches(_ job: AgentJob) -> Bool {
            switch self {
            case .all: return true
            case .running: return job.isRunning
            case .failed: return job.lastRunOutcome == "Failed"
            case .idle: return !job.isRunning
            case .disabled: return !job.isEnabled
            case .scheduled: return job.isScheduled
            }
        }
    }

    @State private var jobs: [AgentJob] = []
    @State private var selection: String?
    @State private var detail: Detail = .steps
    @State private var steps: [AgentJobStep] = []
    @State private var schedules: [AgentJobSchedule] = []
    @State private var history: [AgentJobHistoryEntry] = []
    @State private var selectedStep: Int?
    @State private var selectedHistory: Int?
    @State private var search = ""
    @State private var statusFilter: StatusFilter = .all
    @State private var category: String = ""
    /// 0 means off. The Job Activity Monitor is only useful if it keeps up with the jobs.
    @State private var autoRefreshSeconds = 0
    @State private var isBusy = false
    @State private var status: String?
    @State private var isError = false
    @State private var agentRunning = true
    @State private var pendingScript: PendingScript?

    private var visible: [AgentJob] {
        jobs.filter { job in
            guard statusFilter.matches(job) else { return false }
            if !category.isEmpty,
               job.category.caseInsensitiveCompare(category) != .orderedSame { return false }
            guard !search.isEmpty else { return true }
            return job.name.localizedCaseInsensitiveContains(search)
                || job.category.localizedCaseInsensitiveContains(search)
                || job.owner.localizedCaseInsensitiveContains(search)
        }
    }

    private var categories: [String] {
        Array(Set(jobs.map(\.category).filter { !$0.isEmpty })).sorted()
    }

    private var selected: AgentJob? {
        guard let selection else { return nil }
        return jobs.first { $0.id == selection }
    }

    var body: some View {
        VStack(spacing: 0) {
            SecurityHeader(icon: "clock.badge.checkmark",
                           title: "SQL Server Agent — Job Activity",
                           subtitle: server.displayName, isBusy: isBusy)
            Divider()
            if !agentRunning {
                Label("SQL Server Agent is not running on this instance.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                Divider()
            }
            toolbar
            Divider()
            VSplitView {
                jobList.frame(minHeight: 180)
                detailPane.frame(minHeight: 180)
            }
            Divider()
            SecurityFooter(status: status, isError: isError) { dismiss() }
        }
        .frame(width: 1020, height: 680)
        .task { await load() }
        .task(id: selection) { await loadDetail() }
        .task(id: detail) { await loadDetail() }
        .task(id: autoRefreshSeconds) { await autoRefresh() }
        .sheet(item: $pendingScript) { pending in
            ScriptConfirmSheet(pending: pending) { script in
                await runScript(script)
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Menu {
                Button("Start Job") {
                    guard let job = selected else { return }
                    Task { await start(job) }
                }
                if !steps.isEmpty {
                    Menu("Start at Step") {
                        ForEach(steps) { step in
                            Button("\(step.stepID). \(step.name)") {
                                guard let job = selected else { return }
                                Task { await start(job, stepName: step.name) }
                            }
                        }
                    }
                }
            } label: { Label("Start", systemImage: "play.fill") }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(selected == nil || selected?.isRunning == true)

            Button {
                guard let job = selected else { return }
                Task { await stop(job) }
            } label: { Label("Stop", systemImage: "stop.fill") }
                .disabled(selected?.isRunning != true)

            Button {
                guard let job = selected else { return }
                Task { await toggleEnabled(job) }
            } label: {
                Label(selected?.isEnabled == true ? "Disable" : "Enable",
                      systemImage: selected?.isEnabled == true ? "pause.circle" : "play.circle")
            }
            .disabled(selected == nil)

            Divider().frame(height: 16)

            Button {
                guard let job = selected else { return }
                let service = AgentService(session: server.session)
                let script = service.scriptJob(job, steps: steps, schedules: schedules)
                pendingScript = PendingScript(title: "Script job as CREATE", script: script)
            } label: { Label("Script", systemImage: "doc.text") }
                .disabled(selected == nil)

            Button {
                guard let job = selected else { return }
                let service = AgentService(session: server.session)
                pendingScript = PendingScript(title: "Delete job",
                                              script: service.deleteJobScript(name: job.name),
                                              destructive: true)
            } label: { Label("Delete", systemImage: "trash") }
                .disabled(selected == nil)

            Spacer()

            Picker("", selection: $statusFilter) {
                ForEach(StatusFilter.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .fixedSize()

            Picker("", selection: $category) {
                Text("Every category").tag("")
                ForEach(categories, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .fixedSize()

            TextField("Search", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(width: 150)

            Menu {
                Picker("Refresh", selection: $autoRefreshSeconds) {
                    Text("Manual").tag(0)
                    Text("Every 5 seconds").tag(5)
                    Text("Every 10 seconds").tag(10)
                    Text("Every 30 seconds").tag(30)
                    Text("Every minute").tag(60)
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: autoRefreshSeconds == 0
                      ? "arrow.clockwise" : "arrow.clockwise.circle.fill")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Auto-refresh interval")

            Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
        }
        .padding(8)
    }

    private var jobList: some View {
        Table(visible, selection: $selection) {
            TableColumn("") { job in
                Image(systemName: job.outcomeSymbol)
                    .foregroundStyle(Self.outcomeColor(job.lastRunOutcome))
            }.width(24)

            TableColumn("Name") { job in
                HStack(spacing: 5) {
                    Text(job.name).lineLimit(1)
                    if job.isRunning {
                        ProgressView().controlSize(.mini)
                    }
                }
                .foregroundStyle(job.isEnabled ? Color.primary : Color.secondary)
            }.width(min: 160, ideal: 220)

            TableColumn("Status") { job in
                VStack(alignment: .leading, spacing: 0) {
                    Text(job.isRunning ? "Executing" : (job.isEnabled ? "Idle" : "Disabled"))
                        .foregroundStyle(job.isRunning ? Color.accentColor
                                         : (job.isEnabled ? Color.primary : Color.secondary))
                    if job.isRunning, !job.currentStepName.isEmpty {
                        Text(job.currentStepName).font(.caption2).foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }.width(min: 90, ideal: 130)
            TableColumn("Running for") { Text($0.runningForText).monospacedDigit() }.width(90)
            TableColumn("Category") { Text($0.category) }.width(120)
            TableColumn("Last run") { Text($0.lastRunAt) }.width(150)
            TableColumn("Duration") { Text($0.lastRunDuration).monospacedDigit() }.width(80)
            TableColumn("Outcome") { job in
                Text(job.lastRunOutcome)
                    .foregroundStyle(Self.outcomeColor(job.lastRunOutcome))
            }.width(100)
            TableColumn("Schedules") { Text($0.scheduleSummary).foregroundStyle(.secondary) }
                .width(min: 120, ideal: 170)
        }
    }

    private static func outcomeColor(_ outcome: String) -> Color {
        switch outcome {
        case "Succeeded": return .green
        case "Failed": return .red
        case "Cancelled": return .orange
        case "Retry": return .yellow
        default: return .secondary
        }
    }

    @ViewBuilder
    private var detailPane: some View {
        VStack(spacing: 0) {
            Picker("", selection: $detail) {
                ForEach(Detail.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)
            Divider()

            if selected == nil {
                ContentUnavailableView("Select a job", systemImage: "clock")
            } else {
                switch detail {
                case .steps: stepsTable
                case .schedules: schedulesTable
                case .history: historyTable
                }
            }
        }
    }

    private var stepsTable: some View {
        VSplitView {
            Table(steps, selection: $selectedStep) {
                TableColumn("#") { Text("\($0.stepID)").monospacedDigit() }.width(30)
                TableColumn("Step", value: \.name).width(min: 120, ideal: 180)
                TableColumn("Type", value: \.subsystem).width(100)
                TableColumn("Database", value: \.databaseName).width(110)
                TableColumn("On success", value: \.onSuccessAction).width(130)
                TableColumn("On failure", value: \.onFailAction).width(130)
                TableColumn("Last outcome") { step in
                    Text(step.lastRunOutcome)
                        .foregroundStyle(Self.outcomeColor(step.lastRunOutcome))
                }.width(110)
            }
            .frame(minHeight: 90)

            ScrollView {
                Text(steps.first { $0.stepID == selectedStep }?.command
                     ?? "Select a step to see its command.")
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(minHeight: 70)
            .background(Color(nsColor: .textBackgroundColor))
        }
    }

    private var schedulesTable: some View {
        Table(schedules) {
            TableColumn("Name", value: \.name).width(min: 120, ideal: 180)
            TableColumn("Enabled") { Text($0.isEnabled ? "Yes" : "No") }.width(70)
            TableColumn("Recurrence", value: \.summary).width(min: 200, ideal: 300)
            TableColumn("Next run", value: \.nextRunAt).width(160)
        }
    }

    private var historyTable: some View {
        VSplitView {
            Table(history, selection: $selectedHistory) {
                TableColumn("Run at", value: \.runAt).width(150)
                TableColumn("Step") { entry in
                    Text(entry.stepID == 0 ? "(job outcome)" : "\(entry.stepID). \(entry.stepName)")
                }.width(min: 120, ideal: 180)
                TableColumn("Outcome") { entry in
                    Text(entry.outcome).foregroundStyle(Self.outcomeColor(entry.outcome))
                }.width(100)
                TableColumn("Duration") { Text($0.duration).monospacedDigit() }.width(80)
                TableColumn("Retries") { Text("\($0.retriesAttempted)").monospacedDigit() }.width(60)
            }
            .frame(minHeight: 90)

            ScrollView {
                Text(history.first { $0.instanceID == selectedHistory }?.message
                     ?? "Select a history row to read its message.")
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(minHeight: 70)
            .background(Color(nsColor: .textBackgroundColor))
        }
    }

    // MARK: - Actions

    private func start(_ job: AgentJob, stepName: String? = nil) async {
        let where_ = stepName.map { " at step \($0)" } ?? ""
        await perform("Started \(job.name)\(where_).") {
            try await AgentService(session: server.session).startJob(name: job.name,
                                                                     stepName: stepName)
        }
    }

    private func stop(_ job: AgentJob) async {
        await perform("Stopped \(job.name).") {
            try await AgentService(session: server.session).stopJob(name: job.name)
        }
    }

    private func toggleEnabled(_ job: AgentJob) async {
        let verb = job.isEnabled ? "Disabled" : "Enabled"
        await perform("\(verb) \(job.name).") {
            try await AgentService(session: server.session)
                .setJobEnabled(name: job.name, enabled: !job.isEnabled)
        }
    }

    private func runScript(_ script: String) async {
        await perform("Applied.") {
            try await AgentService(session: server.session).execute(script)
        }
    }

    private func perform(_ successMessage: String, _ work: () async throws -> Void) async {
        isBusy = true
        defer { isBusy = false }
        do {
            try await work()
            isError = false
            status = successMessage
            await load()
        } catch {
            isError = true
            status = String(describing: error)
        }
    }

    private func load() async {
        isBusy = true
        defer { isBusy = false }
        let service = AgentService(session: server.session)
        agentRunning = await service.isAgentRunning()
        do {
            jobs = try await service.jobs()
            isError = false
            let running = jobs.filter(\.isRunning).count
            let failed = jobs.filter { $0.lastRunOutcome == "Failed" }.count
            var parts = ["\(jobs.count) jobs"]
            if visible.count != jobs.count { parts.append("\(visible.count) shown") }
            if running > 0 { parts.append("\(running) running") }
            if failed > 0 { parts.append("\(failed) failed last run") }
            status = parts.joined(separator: ", ") + "."
        } catch {
            isError = true
            status = String(describing: error)
            jobs = []
        }
    }

    private func loadDetail() async {
        guard let job = selected else {
            steps = []; schedules = []; history = []
            return
        }
        let service = AgentService(session: server.session)
        do {
            // Steps load whichever tab is showing: "Start at Step" needs them, and a
            // job's step list is a handful of rows.
            steps = try await service.steps(jobID: job.id)
            switch detail {
            case .steps: break
            case .schedules: schedules = try await service.schedules(jobID: job.id)
            case .history: history = try await service.history(jobID: job.id)
            }
            isError = false
        } catch {
            isError = true
            status = String(describing: error)
        }
    }

    /// Keeps the list current while it is open, the way the Job Activity Monitor does.
    /// The task is torn down when the interval changes or the sheet closes.
    private func autoRefresh() async {
        guard autoRefreshSeconds > 0 else { return }
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64(autoRefreshSeconds) * 1_000_000_000)
            guard !Task.isCancelled else { return }
            await load()
            await loadDetail()
        }
    }
}
