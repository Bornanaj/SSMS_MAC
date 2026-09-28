import SwiftUI
import AppKit
import SQLServerKit

/// The synchronization wizard: what each table will get (inserts, updates, deletes), the
/// warnings, the script, then save it, open it, or run it against the target.
struct DataDeploymentSheet: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: DataCompareModel

    enum Step: Int, CaseIterable, Identifiable {
        case summary
        case warnings
        case script
        case deploy
        var id: Int { rawValue }
        var title: String {
            switch self {
            case .summary: return "Summary"
            case .warnings: return "Warnings"
            case .script: return "Script"
            case .deploy: return "Deploy"
            }
        }
    }

    @State private var step: Step = .summary
    @State private var plan: DataSyncPlan?
    @StateObject private var runner = DeploymentRunState()
    @State private var confirmed = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                switch step {
                case .summary: summaryPage
                case .warnings: warningsPage
                case .script: scriptPage
                case .deploy: deployPage
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(width: 900, height: 620)
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
                Text(totals(plan)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(runner.isRunning)
            if step != .summary {
                Button("Back") { step = Step(rawValue: step.rawValue - 1) ?? .summary }
                    .disabled(runner.isRunning)
            }
            if step != .deploy {
                Button("Next") { step = Step(rawValue: step.rawValue + 1) ?? .deploy }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
    }

    private func totals(_ plan: DataSyncPlan) -> String {
        var parts: [String] = []
        parts.append("\(plan.totalInserts) insert(s)")
        parts.append("\(plan.totalUpdates) update(s)")
        parts.append("\(plan.totalDeletes) delete(s)")
        return parts.joined(separator: ", ") + " in \(plan.tables.count) table(s)"
    }

    // MARK: - Summary

    private var summaryPage: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                optionToggle("Insert", \.deployInserts)
                optionToggle("Update", \.deployUpdates)
                optionToggle("Delete", \.deployDeletes)
                Divider().frame(height: 16)
                optionToggle("Disable foreign keys", \.disableForeignKeys)
                optionToggle("Disable triggers", \.disableDMLTriggers)
                optionToggle("Reseed identities", \.reseedIdentityColumns)
                optionToggle("Transaction", \.doNotUseTransactions, inverted: true)
                Spacer()
            }
            .toggleStyle(.checkbox)
            if let plan, plan.isEmpty {
                ContentUnavailableView("Nothing to deploy", systemImage: "checkmark.circle",
                                       description: Text("No selected rows need to change in the target."))
            } else {
                Table(plan?.tables ?? []) {
                    TableColumn("Table") { item in
                        Label(item.table, systemImage: "tablecells")
                    }
                    TableColumn("Inserts") { item in
                        countText(item.inserts, color: .green)
                    }
                    .width(80)
                    TableColumn("Updates") { item in
                        countText(item.updates, color: .orange)
                    }
                    .width(80)
                    TableColumn("Deletes") { item in
                        countText(item.deletes, color: .red)
                    }
                    .width(80)
                }
            }
        }
        .padding(12)
    }

    private func countText(_ value: Int, color: Color) -> some View {
        Text("\(value)")
            .monospacedDigit()
            .foregroundStyle(value > 0 ? color : Color.secondary)
    }

    private func optionToggle(_ title: String, _ keyPath: WritableKeyPath<DataCompareOptions, Bool>,
                              inverted: Bool = false) -> some View {
        Toggle(title, isOn: Binding(
            get: { model.options[keyPath: keyPath] != inverted },
            set: { value in
                model.options[keyPath: keyPath] = value != inverted
                rebuild()
            }))
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
                                       description: Text("Nothing unusual was found in this synchronization."))
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
                if let plan {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(plan.script.utf8.count), countStyle: .file))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(10)
        }
    }

    private func saveScript() {
        guard let script = plan?.script,
              let url = CompareFilePanels.save(name: "Synchronization.sql", types: [CompareFilePanels.sqlType])
        else { return }
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            model.report("Synchronization script saved to \(url.path).")
        } catch {
            model.report(String(describing: error), isError: true)
        }
    }

    private func openInQueryWindow() {
        guard let script = plan?.script else { return }
        let endpoint = model.target.endpoint
        let server = app.servers.first { $0.profile.id == endpoint.connection?.id }
        app.openScript(script, server: server, database: endpoint.database, title: "Synchronization.sql")
        NSApp.activate()
    }

    // MARK: - Deploy

    private var deployPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            let highRisk = plan?.warnings.contains { $0.severity == .high } ?? false
            Text(deployDescription)
            if highRisk {
                Label("This synchronization has high-severity warnings.", systemImage: "exclamationmark.octagon.fill")
                    .foregroundStyle(.red)
            }
            Toggle("I have backed up the target database, or do not need to", isOn: $confirmed)
                .toggleStyle(.checkbox)
            HStack {
                Button("Deploy Now") { deploy() }
                    .disabled(!confirmed || runner.isRunning || plan == nil || plan?.isEmpty == true)
                if runner.isRunning {
                    ProgressView(value: runner.fraction).frame(width: 200)
                    Text(runner.current).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            ScrollView {
                Text(runner.log.joined(separator: "\n"))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .frame(minHeight: 220)
            if runner.finished && runner.succeeded {
                HStack {
                    Label("Synchronization succeeded.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    Button("Refresh Comparison") {
                        dismiss()
                        Task { await model.compare(app: app) }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
    }

    private var deployDescription: String {
        var text: String = "Synchronize \(model.target.endpoint.displayName)."
        if model.options.doNotUseTransactions {
            text += " The script runs without a transaction: statements that succeed before an error stay applied."
        } else {
            text += " The script runs in a transaction and rolls back everything on the first error."
        }
        return text
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
}
