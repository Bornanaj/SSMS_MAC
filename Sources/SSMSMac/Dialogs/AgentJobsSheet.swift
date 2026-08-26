import SwiftUI
import SQLServerKit

/// The SQL Server Agent > Jobs node: what is scheduled, what it did last time, and the
/// controls to start, stop and enable it.
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

    @State private var jobs: [AgentJob] = []
    @State private var selection: String?
    @State private var detail: Detail = .steps
    @State private var steps: [AgentJobStep] = []
    @State private var schedules: [AgentJobSchedule] = []
    @State private var history: [AgentJobHistoryEntry] = []
    @State private var selectedStep: Int?
    @State private var selectedHistory: Int?
    @State private var search = ""
    @State private var isBusy = false
    @State private var status: String?
    @State private var isError = false
    @State private var agentRunning = true
    @State private var pendingScript: PendingScript?

    private var visible: [AgentJob] {
        guard !search.isEmpty else { return jobs }
        return jobs.filter {
            $0.name.localizedCaseInsensitiveContains(search)
                || $0.category.localizedCaseInsensitiveContains(search)
        }
    }

    private var selected: AgentJob? {
        guard let selection else { return nil }
        return jobs.first { $0.id == selection }
    }

    var body: some View {
        VStack(spacing: 0) {
            SecurityHeader(icon: "clock.badge.checkmark", title: "SQL Server Agent Jobs",
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
        .sheet(item: $pendingScript) { pending in
            ScriptConfirmSheet(pending: pending) { script in
                await runScript(script)
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button {
                guard let job = selected else { return }
                Task { await start(job) }
            } label: { Label("Start", systemImage: "play.fill") }
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
            TextField("Search", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)
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

            TableColumn("Enabled") { Text($0.isEnabled ? "Yes" : "No") }.width(70)
            TableColumn("Category") { Text($0.category) }.width(130)
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

    private func start(_ job: AgentJob) async {
        await perform("Started \(job.name).") {
            try await AgentService(session: server.session).startJob(name: job.name)
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
            status = running > 0
                ? "\(jobs.count) jobs, \(running) running."
                : "\(jobs.count) jobs."
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
            switch detail {
            case .steps: steps = try await service.steps(jobID: job.id)
            case .schedules: schedules = try await service.schedules(jobID: job.id)
            case .history: history = try await service.history(jobID: job.id)
            }
            isError = false
        } catch {
            isError = true
            status = String(describing: error)
        }
    }
}
