import SwiftUI
import AppKit
import SQLServerKit

/// What a plan sheet is opened with: the plan, and the connection whose credentials the
/// other instances inherit.
struct ScriptPlanLaunch: Identifiable {
    let id = UUID()
    var plan: ScriptPlan
    var server: ConnectedServer
}

/// Runs a multi-instance plan one step at a time.
///
/// Each step names the instance it belongs to, and nothing runs until that instance is
/// connected — in this window, alongside the others. The user can run the next step,
/// run the rest, skip a step or edit its statement before it goes anywhere. That is
/// what makes a real failover possible from here: the `FAILOVER` runs on the replica
/// taking over, not on whichever node this window happens to be attached to.
struct ScriptPlanSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    let launch: ScriptPlanLaunch

    @State private var plan: ScriptPlan
    @StateObject private var broker: ReplicaConnectionBroker
    @State private var selectedStepID: UUID?
    @State private var isRunning = false
    @State private var runAll = false
    @State private var status: String?
    @State private var isError = false
    @State private var editedScript = ""
    @State private var confirmRunAll = false

    init(launch: ScriptPlanLaunch, app: AppState, templatePassword: String) {
        self.launch = launch
        _plan = State(initialValue: launch.plan)
        _broker = StateObject(wrappedValue: ReplicaConnectionBroker(
            app: app,
            template: launch.server.profile,
            templatePassword: templatePassword,
            instances: launch.plan.instances))
    }

    private var selectedStep: ScriptStep? {
        guard let selectedStepID else { return plan.steps.first }
        return plan.steps.first { $0.id == selectedStepID }
    }

    private var nextStep: ScriptStep? {
        plan.nextRunnableIndex().map { plan.steps[$0] }
    }

    var body: some View {
        VStack(spacing: 0) {
            SecurityHeader(icon: "list.number", title: plan.title,
                           subtitle: plan.summary, isBusy: isRunning)
            Divider()
            connections
            Divider()
            toolbar
            Divider()
            VSplitView {
                stepTable.frame(minHeight: 200)
                detail.frame(minHeight: 180)
            }
            Divider()
            footer
        }
        .frame(width: 1040, height: 720)
        .onAppear { selectedStepID = plan.steps.first?.id }
        .onChange(of: selectedStepID) { _, _ in
            editedScript = selectedStep?.script ?? ""
        }
        .task { editedScript = plan.steps.first?.script ?? "" }
        .confirmationDialog("Run every remaining step?",
                            isPresented: $confirmRunAll, titleVisibility: .visible) {
            Button("Run \(remainingCount) steps", role: .destructive) {
                Task { await runRemaining() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Each step runs on its own instance, in order, stopping at the first "
                 + "failure.")
        }
    }

    private var remainingCount: Int {
        plan.steps.filter { plan.state(of: $0) == .pending }.count
    }

    // MARK: - Connections

    private var connections: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Instances this plan touches")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Connect All") { Task { await broker.connectAll() } }
                    .disabled(broker.allConnected || isRunning)
            }
            ForEach(broker.targets) { target in
                HStack(spacing: 8) {
                    Circle()
                        .fill(color(for: target.state))
                        .frame(width: 8, height: 8)
                    Text(target.instance)
                        .font(.caption.weight(.medium))
                        .frame(minWidth: 140, alignment: .leading)

                    TextField("Address", text: binding(for: target, field: .address))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 160)
                        .disabled(target.state.isUsable)

                    TextField("Login", text: binding(for: target, field: .username))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 110)
                        .disabled(target.state.isUsable)

                    SecureField("Password", text: binding(for: target, field: .password))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                        .disabled(target.state.isUsable)

                    Text(target.state.label)
                        .font(.caption)
                        .foregroundStyle(target.state.isUsable ? Color.green : Color.secondary)

                    if !target.state.detail.isEmpty {
                        Text(target.state.detail)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .lineLimit(1)
                            .help(target.state.detail)
                    }

                    Spacer()
                    if !target.state.isUsable {
                        Button("Connect") {
                            Task { await broker.connect(instance: target.instance) }
                        }
                        .disabled(isRunning)
                    }
                }
            }
        }
        .padding(10)
    }

    private func color(for state: ReplicaConnectionBroker.State) -> Color {
        switch state {
        case .connected, .reused: return .green
        case .connecting: return .yellow
        case .failed: return .red
        case .notConnected: return .secondary
        }
    }

    private enum TargetField { case address, username, password }

    /// The fields edit the broker's own copy, which is the one `connect` reads.
    private func binding(for target: ReplicaConnectionBroker.Target,
                         field: TargetField) -> Binding<String> {
        Binding(
            get: {
                guard let current = broker.targets.first(where: { $0.id == target.id })
                else { return "" }
                switch field {
                case .address: return current.address
                case .username: return current.username
                case .password: return current.password
                }
            },
            set: { newValue in
                switch field {
                case .address: broker.setAddress(newValue, for: target.instance)
                case .username: broker.setUsername(newValue, for: target.instance)
                case .password: broker.setPassword(newValue, for: target.instance)
                }
            })
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button {
                Task { await runNext() }
            } label: {
                Label(nextStep.map { "Run Step \(index(of: $0) + 1)" } ?? "Run Next Step",
                      systemImage: "play.fill")
            }
            .disabled(nextStep == nil || isRunning)

            Button {
                confirmRunAll = true
            } label: { Label("Run Remaining", systemImage: "forward.fill") }
                .disabled(nextStep == nil || isRunning)

            Button {
                guard let step = nextStep else { return }
                plan.record(ScriptStepOutcome(state: .skipped, message: "Skipped."), for: step)
            } label: { Label("Skip", systemImage: "forward.end") }
                .disabled(nextStep == nil || isRunning)

            Divider().frame(height: 16)

            Button {
                plan.reset()
                status = nil
            } label: { Label("Reset", systemImage: "arrow.uturn.backward") }
                .disabled(isRunning || plan.outcomes.isEmpty)

            Button {
                copyWholePlan()
            } label: { Label("Copy Script", systemImage: "doc.on.doc") }

            Spacer()
            Text(plan.statusLine).font(.caption).foregroundStyle(.secondary)
            ProgressView(value: plan.progress).frame(width: 90)
        }
        .padding(8)
    }

    private func index(of step: ScriptStep) -> Int {
        plan.steps.firstIndex { $0.id == step.id } ?? 0
    }

    // MARK: - Steps

    private var stepTable: some View {
        Table(plan.steps, selection: $selectedStepID) {
            TableColumn("#") { step in
                Text("\(index(of: step) + 1)").monospacedDigit()
            }.width(30)

            TableColumn("") { step in
                Image(systemName: symbol(plan.state(of: step)))
                    .foregroundStyle(color(plan.state(of: step)))
            }.width(24)

            TableColumn("Step") { step in
                VStack(alignment: .leading, spacing: 1) {
                    Text(step.title).lineLimit(1)
                    if !step.detail.isEmpty {
                        Text(step.detail).font(.caption2).foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }.width(min: 200, ideal: 320)

            TableColumn("Instance") { step in
                HStack(spacing: 5) {
                    Circle()
                        .fill(color(for: broker.state(for: step.instance)))
                        .frame(width: 7, height: 7)
                    Text(step.instance).lineLimit(1)
                }
            }.width(min: 120, ideal: 170)

            TableColumn("Result") { step in
                Text(resultText(step))
                    .foregroundStyle(plan.state(of: step) == .failed ? Color.red : Color.secondary)
                    .lineLimit(1)
            }.width(min: 140, ideal: 240)

            TableColumn("Elapsed") { step in
                Text(plan.outcome(of: step).map { String(format: "%.2f s", $0.elapsed) } ?? "")
                    .monospacedDigit()
            }.width(80)
        }
    }

    private func resultText(_ step: ScriptStep) -> String {
        guard let outcome = plan.outcome(of: step) else { return "" }
        if !outcome.value.isEmpty { return outcome.value }
        return outcome.message
    }

    private func symbol(_ state: ScriptStepState) -> String {
        switch state {
        case .pending: return "circle"
        case .running: return "circle.dotted"
        case .succeeded: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .skipped: return "minus.circle"
        }
    }

    private func color(_ state: ScriptStepState) -> Color {
        switch state {
        case .pending: return .secondary
        case .running: return .accentColor
        case .succeeded: return .green
        case .failed: return .red
        case .skipped: return .orange
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let step = selectedStep {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Text(step.title).font(.caption.weight(.medium))
                    Text("on \(step.instance) · \(step.database)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if step.isReadOnly {
                        Text("read-only").font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Run This Step") {
                        Task { await run(step: step, scriptOverride: editedScript) }
                    }
                    .disabled(isRunning || plan.state(of: step) == .running)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                Divider()
                HSplitView {
                    TextEditor(text: $editedScript)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minWidth: 320)
                    outcomePane(step).frame(minWidth: 240)
                }
            }
        } else {
            ContentUnavailableView("No step selected", systemImage: "list.number")
        }
    }

    @ViewBuilder
    private func outcomePane(_ step: ScriptStep) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                if let outcome = plan.outcome(of: step) {
                    Label(outcome.state.rawValue.capitalized,
                          systemImage: symbol(outcome.state))
                        .foregroundStyle(color(outcome.state))
                        .font(.caption.weight(.medium))
                    if !outcome.message.isEmpty {
                        Text(outcome.message)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    ForEach(Array(outcome.serverMessages.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                } else {
                    Text(step.detail.isEmpty ? "This step has not run yet." : step.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var footer: some View {
        HStack {
            if let status {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(isError ? Color.red : Color.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Button("Close") {
                Task {
                    await broker.closeOwnedSessions()
                    dismiss()
                }
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding(12)
    }

    // MARK: - Running

    private func runNext() async {
        guard let step = nextStep else { return }
        await run(step: step, scriptOverride: step.id == selectedStepID ? editedScript : nil)
    }

    private func runRemaining() async {
        runAll = true
        defer { runAll = false }
        while let step = nextStep, !Task.isCancelled {
            await run(step: step, scriptOverride: nil)
            if plan.state(of: step) == .failed && !step.continuesOnFailure { break }
        }
    }

    /// Connects the step's instance if it is not connected yet, then runs it there.
    private func run(step: ScriptStep, scriptOverride: String?) async {
        isRunning = true
        defer { isRunning = false }

        if broker.session(for: step.instance) == nil {
            guard await broker.connect(instance: step.instance) else {
                isError = true
                status = "Cannot reach \(step.instance): "
                    + broker.state(for: step.instance).detail
                plan.record(ScriptStepOutcome(state: .failed,
                                              message: "Not connected to \(step.instance)."),
                            for: step)
                return
            }
        }
        guard let session = broker.session(for: step.instance) else { return }

        var target = step
        if let scriptOverride, !scriptOverride.isEmpty { target.script = scriptOverride }
        plan.record(ScriptStepOutcome(state: .running), for: step)
        let outcome = await ScriptStepRunner.run(target, on: session)
        plan.record(outcome, for: step)

        isError = outcome.state == .failed
        status = "\(step.title): \(outcome.message)"
        if outcome.state == .succeeded, let next = nextStep, !runAll {
            selectedStepID = next.id
            editedScript = next.script
        }
    }

    private func copyWholePlan() {
        var blocks: [String] = ["-- \(plan.title): \(plan.summary)"]
        for (number, step) in plan.steps.enumerated() {
            blocks.append("""

            -- Step \(number + 1) — on \(step.instance) (\(step.database))
            -- \(step.title)\(step.detail.isEmpty ? "" : "\n-- \(step.detail)")
            \(step.script)
            GO
            """)
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(blocks.joined(separator: "\n"), forType: .string)
        isError = false
        status = "The whole plan was copied, with each step's target instance noted."
    }
}
