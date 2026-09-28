import SwiftUI
import AppKit
import SQLServerKit

/// The deployment wizard: review what will change (with the dependencies pulled in), read
/// the warnings, look at the script, then save it, open it, or deploy it now.
struct SchemaDeploymentSheet: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: SchemaCompareModel

    enum Step: Int, CaseIterable, Identifiable {
        case review
        case warnings
        case script
        case deploy
        var id: Int { rawValue }
        var title: String {
            switch self {
            case .review: return "Review"
            case .warnings: return "Warnings"
            case .script: return "Script"
            case .deploy: return "Deploy"
            }
        }
    }

    @State private var step: Step = .review
    @State private var plan: DeploymentPlan?
    @StateObject private var runner = DeploymentRunState()
    @State private var confirmed = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                switch step {
                case .review: reviewPage
                case .warnings: warningsPage
                case .script: scriptPage
                case .deploy: deployPage
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(width: 920, height: 640)
        .onAppear { rebuild() }
    }

    private func rebuild() {
        plan = model.plan()
    }

    // MARK: - Chrome

    private var header: some View {
        HStack(spacing: 18) {
            ForEach(Step.allCases) { item in
                HStack(spacing: 6) {
                    Text("\(item.rawValue + 1)")
                        .font(.caption.weight(.bold))
                        .frame(width: 20, height: 20)
                        .background(item == step ? Color.accentColor : Color.secondary.opacity(0.25), in: Circle())
                        .foregroundStyle(item == step ? Color.white : Color.primary)
                    Text(item.title).fontWeight(item == step ? .semibold : .regular)
                }
                .onTapGesture { if !runner.isRunning { step = item } }
            }
            Spacer()
            Text("\(model.source.endpoint.displayName) → \(model.target.endpoint.displayName)")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(12)
    }

    private var footer: some View {
        HStack {
            if let plan {
                Text("\(plan.actions.count) action(s), \(plan.warnings.count) warning(s)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(runner.isRunning)
            if step != .review {
                Button("Back") { step = Step(rawValue: step.rawValue - 1) ?? .review }
                    .disabled(runner.isRunning)
            }
            if step != .deploy {
                Button("Next") { step = Step(rawValue: step.rawValue + 1) ?? .deploy }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
    }

    // MARK: - Review

    private var reviewPage: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle("Include dependencies", isOn: Binding(
                    get: { model.options.includeDependencies },
                    set: { model.options.includeDependencies = $0; rebuild() }))
                Toggle("Drop and create instead of ALTER", isOn: Binding(
                    get: { model.options.dropAndCreateInsteadOfAlter },
                    set: { model.options.dropAndCreateInsteadOfAlter = $0; rebuild() }))
                Toggle("Transactions", isOn: Binding(
                    get: { !model.options.doNotUseTransactions },
                    set: { model.options.doNotUseTransactions = !$0; rebuild() }))
                Spacer()
            }
            .toggleStyle(.checkbox)
            if let plan, !plan.dependencies.isEmpty {
                Label("\(plan.dependencies.count) object(s) were added because the selection depends on them.",
                      systemImage: "link")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Table(plan?.actions ?? []) {
                TableColumn("Action") { action in
                    Text(action.kind.title)
                        .foregroundStyle(action.kind == .drop ? Color.red : Color.primary)
                }
                .width(min: 110, ideal: 140, max: 180)
                TableColumn("Object") { action in
                    Label(action.key.qualifiedName, systemImage: action.key.type.iconName)
                }
                TableColumn("Type") { action in
                    Text(action.key.type.title).foregroundStyle(.secondary)
                }
                .width(min: 100, ideal: 140, max: 180)
                TableColumn("Notes") { action in
                    HStack {
                        if action.isDependency {
                            Text("dependency").font(.caption).padding(.horizontal, 5)
                                .background(Color.accentColor.opacity(0.18), in: Capsule())
                        }
                        Text(action.detail).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }
        }
        .padding(12)
    }

    // MARK: - Warnings

    private var warningsPage: some View {
        Group {
            if let plan, !plan.warnings.isEmpty {
                List(plan.warnings) { warning in
                    HStack(alignment: .top, spacing: 8) {
                        SeverityIcon(severity: warning.severity)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(warning.object).fontWeight(.semibold)
                            Text(warning.message).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Text(warning.severity.title).font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            } else {
                ContentUnavailableView("No warnings", systemImage: "checkmark.shield",
                                       description: Text("Nothing in this deployment is expected to lose data."))
            }
        }
    }

    // MARK: - Script

    private var scriptPage: some View {
        VStack(spacing: 0) {
            ScriptTextView(text: plan?.script ?? "", settings: settings)
            Divider()
            HStack {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(plan?.script ?? "", forType: .string)
                }
                Button("Save Script…") { saveScript() }
                Button("Open in Query Window") { openInQueryWindow() }
                Spacer()
            }
            .padding(10)
        }
    }

    private func saveScript() {
        guard let script = plan?.script,
              let url = CompareFilePanels.save(name: "Deployment.sql", types: [CompareFilePanels.sqlType]) else { return }
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            model.report("Deployment script saved to \(url.path).")
        } catch {
            model.report(String(describing: error), isError: true)
        }
    }

    private func openInQueryWindow() {
        guard let script = plan?.script else { return }
        let endpoint = model.target.endpoint
        let server = app.servers.first { $0.profile.id == endpoint.connection?.id }
        app.openScript(script, server: server, database: endpoint.kind == .database ? endpoint.database : nil,
                       title: "Deployment.sql")
        NSApp.activate()
    }

    // MARK: - Deploy

    private var deployPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch model.target.endpoint.kind {
            case .snapshot:
                Label("A snapshot cannot be deployed to. Save the script and run it against a database instead.",
                      systemImage: "exclamationmark.triangle")
            case .scriptsFolder:
                Text("The selected objects will be written to the scripts folder: created, updated or deleted "
                     + "one file per object.")
                Button("Update Scripts Folder") { updateFolder() }
                    .disabled(runner.isRunning)
                messages
            case .database:
                deployDatabase
            }
            Spacer(minLength: 0)
        }
        .padding(16)
    }

    @ViewBuilder
    private var deployDatabase: some View {
        let highRisk = plan?.warnings.contains { $0.severity == .high } ?? false
        Text("Deploy to \(model.target.endpoint.displayName). The script runs in a transaction and stops at the first "
             + "error, rolling back what it did.")
        if highRisk {
            Label("This deployment has high-severity warnings: data may be lost.", systemImage: "exclamationmark.octagon.fill")
                .foregroundStyle(.red)
        }
        Toggle("I have backed up the target database, or do not need to", isOn: $confirmed)
            .toggleStyle(.checkbox)
        HStack {
            Button("Deploy Now") { deploy() }
                .disabled(!confirmed || runner.isRunning || plan == nil)
            if runner.isRunning {
                ProgressView(value: runner.fraction).frame(width: 200)
                Text(runner.current).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        messages
        if runner.finished && runner.succeeded {
            HStack {
                Label("Deployment succeeded.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Button("Refresh Comparison") {
                    dismiss()
                    Task { await model.compare(app: app) }
                }
            }
        }
    }

    private var messages: some View {
        ScrollView {
            Text(runner.log.joined(separator: "\n"))
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        .frame(minHeight: 220)
    }

    private func deploy() {
        guard let plan else { return }
        runner.begin()
        let state = runner
        Task {
            do {
                let outcome = try await model.deploy(plan, app: app) { done, total, text in
                    Task { @MainActor in state.update(done: done, total: total, text: text) }
                }
                state.finish(outcome)
            } catch {
                state.fail(String(describing: error))
            }
        }
    }

    private func updateFolder() {
        runner.begin()
        do {
            let changes = try model.deployToScriptsFolder()
            runner.log = changes.isEmpty ? ["Nothing to change."] : changes
            runner.finished = true
            runner.succeeded = true
            runner.isRunning = false
        } catch {
            runner.fail(String(describing: error))
        }
    }
}

/// Progress and output of a deployment, shared by the schema and data wizards.
@MainActor
final class DeploymentRunState: ObservableObject {
    @Published var isRunning = false
    @Published var fraction: Double = 0
    @Published var current = ""
    @Published var log: [String] = []
    @Published var finished = false
    @Published var succeeded = false

    func begin() {
        isRunning = true
        finished = false
        succeeded = false
        fraction = 0
        current = ""
        log = []
    }

    func update(done: Int, total: Int, text: String) {
        fraction = total > 0 ? Double(done) / Double(total) : 0
        current = text
    }

    func finish(_ outcome: ScriptRunner.Outcome) {
        isRunning = false
        finished = true
        succeeded = outcome.succeeded
        fraction = 1
        log = outcome.messages
        if let error = outcome.error {
            log.append("")
            log.append("FAILED: \(error)")
            if let batch = outcome.failedBatch { log.append(String(batch.prefix(4000))) }
        } else {
            log.append("")
            log.append("Completed \(outcome.batchesRun) batches in \(String(format: "%.1f", outcome.duration)) s.")
        }
    }

    func fail(_ message: String) {
        isRunning = false
        finished = true
        succeeded = false
        log.append("FAILED: \(message)")
    }
}
