import SwiftUI
import AppKit
import TDSKit
import SQLServerKit

/// Query Options: the per-window SET options, row limits and results destination.
struct QueryOptionsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var tab: QueryTab

    private let isolationLevels = ["READ UNCOMMITTED", "READ COMMITTED", "REPEATABLE READ",
                                   "SNAPSHOT", "SERIALIZABLE"]
    private let deadlockPriorities = ["LOW", "NORMAL", "HIGH"]

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "Query Options", subtitle: tab.displayTitle, symbol: "slider.horizontal.3")
            Divider()
            Form {
                Section("Execution") {
                    TextField("Row count limit (0 = all rows)",
                              value: $tab.setOptions.rowCountLimit, format: .number)
                    TextField("Maximum rows kept in the grid (0 = all)",
                              value: $tab.maxRows, format: .number)
                    TextField("Execution timeout in seconds (0 = none)",
                              value: $tab.timeoutSeconds, format: .number)
                    Picker("Transaction isolation level",
                           selection: $tab.setOptions.transactionIsolationLevel) {
                        ForEach(isolationLevels, id: \.self) { Text($0.capitalized).tag($0) }
                    }
                    TextField("LOCK_TIMEOUT in milliseconds (-1 = wait forever)",
                              value: $tab.setOptions.lockTimeoutMilliseconds, format: .number)
                    Picker("DEADLOCK_PRIORITY", selection: $tab.setOptions.deadlockPriority) {
                        ForEach(deadlockPriorities, id: \.self) { Text($0.capitalized).tag($0) }
                    }
                }

                Section("ANSI") {
                    Toggle("SET ANSI_NULLS", isOn: $tab.setOptions.ansiNulls)
                    Toggle("SET ANSI_PADDING", isOn: $tab.setOptions.ansiPadding)
                    Toggle("SET ANSI_WARNINGS", isOn: $tab.setOptions.ansiWarnings)
                    Toggle("SET ARITHABORT", isOn: $tab.setOptions.arithAbort)
                    Toggle("SET CONCAT_NULL_YIELDS_NULL",
                           isOn: $tab.setOptions.concatNullYieldsNull)
                    Toggle("SET QUOTED_IDENTIFIER", isOn: $tab.setOptions.quotedIdentifier)
                    Toggle("SET NUMERIC_ROUNDABORT", isOn: $tab.setOptions.numericRoundAbort)
                    Toggle("SET XACT_ABORT", isOn: $tab.setOptions.xactAbort)
                    Toggle("SET NOCOUNT", isOn: $tab.setOptions.nocount)
                }

                Section("Results") {
                    Picker("Results to", selection: $tab.resultsDestination) {
                        ForEach(ResultsDestination.allCases) { Text($0.title).tag($0) }
                    }
                    Toggle("Include actual execution plan", isOn: $tab.includeActualPlan)
                    Toggle("Display estimated execution plan", isOn: $tab.includeEstimatedPlan)
                    Toggle("Include client statistics", isOn: $tab.includeClientStatistics)
                    TextField("Text results: maximum characters per column",
                              value: $tab.textResultOptions.maxColumnWidth,
                              format: .number)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Button("Reset to Defaults") {
                    tab.setOptions = QuerySetOptions()
                }
                Spacer()
                Button("Copy SET Script") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(tab.setOptions.script, forType: .string)
                }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 620, height: 640)
    }
}

/// Specify Values for Template Parameters — SSMS's ⌘⇧M dialog.
struct TemplateParametersSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var tab: QueryTab

    @State private var parameters: [TemplateParameter] = []

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "Specify Values for Template Parameters",
                        subtitle: tab.displayTitle, symbol: "curlybraces")
            Divider()

            if parameters.isEmpty {
                ContentUnavailableView("No parameters", systemImage: "curlybraces",
                                       description: Text("This script has no "
                                           + "<name, type, value> placeholders."))
            } else {
                List {
                    ForEach($parameters) { $parameter in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(parameter.name).font(.body)
                                Text(parameter.dataType.isEmpty ? "—" : parameter.dataType)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(width: 220, alignment: .leading)
                            TextField("Value", text: $parameter.value)
                                .textFieldStyle(.roundedBorder)
                        }
                        .padding(.vertical, 2)
                    }
                }
                .listStyle(.inset)
            }

            Divider()
            HStack {
                Text("\(parameters.count) parameter\(parameters.count == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("OK") { substitute() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(parameters.isEmpty)
            }
            .padding(12)
        }
        .frame(width: 700, height: 460)
        .onAppear { parameters = TemplateParameters.parse(tab.text) }
    }

    private func substitute() {
        tab.text = TemplateParameters.substitute(tab.text, with: parameters)
        dismiss()
    }
}

/// Go To Line — ⌘G.
struct GoToLineSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var tab: QueryTab

    @State private var lineText = ""

    private var lineCount: Int {
        max(1, tab.text.components(separatedBy: "\n").count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Go To Line").font(.headline)
            HStack(spacing: 8) {
                TextField("Line number", text: $lineText)
                    .frame(width: 110)
                    .onSubmit { go() }
                Text("1 – \(lineCount)").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Go") { go() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(Int(lineText) == nil)
            }
        }
        .padding(16)
        .frame(width: 340)
        .onAppear { lineText = "\(tab.caretLine)" }
    }

    private func go() {
        guard let line = Int(lineText) else { return }
        tab.moveCaret(toLine: min(max(1, line), lineCount))
        dismiss()
    }
}

// MARK: - Multi-server query

/// What one server produced for a multi-server run.
struct MultiServerOutcome: Identifiable, Sendable {
    let id: UUID
    var serverName: String
    var database: String
    var columns: [TDSColumn]
    var rows: [[TDSValue]]
    var messages: [String]
    var elapsed: TimeInterval
    var errorText: String?

    var rowCount: Int { rows.count }
    var succeeded: Bool { errorText == nil }
}

/// Runs one script against several connected servers, one after another.
///
/// SSMS runs registered-server groups in parallel and unions the grids. Sequential
/// execution is used here because each server needs its own connection and a fan-out of
/// a heavy query across a dozen instances is rarely what anyone wants by accident.
@MainActor
final class MultiServerQueryModel: ObservableObject {
    @Published var outcomes: [MultiServerOutcome] = []
    @Published var isRunning = false
    @Published var currentServer = ""

    private var task: Task<Void, Never>?

    func run(script: String, servers: [ConnectedServer], database: String?) {
        cancel()
        outcomes = []
        isRunning = true
        let batches = BatchSplitter.split(script)
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        task = Task { [weak self] in
            for server in servers {
                if Task.isCancelled { break }
                await MainActor.run { self?.currentServer = server.displayName }
                let outcome = await MultiServerQueryModel.run(batches: batches,
                                                              on: server,
                                                              database: database)
                await MainActor.run { self?.outcomes.append(outcome) }
            }
            await MainActor.run {
                self?.isRunning = false
                self?.currentServer = ""
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        isRunning = false
    }

    private static func run(batches: [String],
                            on server: ConnectedServer,
                            database: String?) async -> MultiServerOutcome {
        let started = Date()
        var outcome = MultiServerOutcome(id: server.id,
                                        serverName: server.displayName,
                                        database: database ?? "",
                                        columns: [],
                                        rows: [],
                                        messages: [],
                                        elapsed: 0,
                                        errorText: nil)
        do {
            let connection = try await server.session.openConnection(database: database)
            outcome.database = connection.database
            do {
                for batch in batches {
                    let result = try await connection.query(batch)
                    if let set = result.resultSets.first, outcome.columns.isEmpty {
                        outcome.columns = set.columns
                    }
                    for set in result.resultSets {
                        outcome.rows.append(contentsOf: set.rows)
                    }
                    outcome.messages += result.messages.map(\.text)
                    if let failure = result.errors.first {
                        outcome.errorText = failure.text
                        break
                    }
                    let affected = result.totalRowsAffected
                    if affected > 0 && result.resultSets.isEmpty {
                        outcome.messages.append(
                            "(\(affected) row\(affected == 1 ? "" : "s") affected)")
                    }
                }
                try? await connection.close()
            } catch {
                try? await connection.close()
                throw error
            }
        } catch {
            outcome.errorText = String(describing: error)
        }
        outcome.elapsed = Date().timeIntervalSince(started)
        return outcome
    }

    /// The union of every server's rows with a leading Server Name column, which is what
    /// SSMS's multi-server results look like.
    var mergedColumns: [TDSColumn] {
        guard let first = outcomes.first(where: { !$0.columns.isEmpty }) else { return [] }
        let serverColumn = TDSColumn(index: 0, name: "Server Name",
                                    typeInfo: TDSTypeInfo(dataType: .nVarChar, length: 256))
        return [serverColumn] + first.columns.enumerated().map { offset, column in
            var copy = column
            copy.index = offset + 1
            return copy
        }
    }

    var mergedRows: [[TDSValue]] {
        outcomes.flatMap { outcome in
            outcome.rows.map { [TDSValue.string(outcome.serverName)] + $0 }
        }
    }
}

/// Multi-server query: pick servers, run the front tab's script on each.
struct MultiServerQuerySheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var tab: QueryTab

    @StateObject private var model = MultiServerQueryModel()
    @State private var selected: Set<UUID> = []
    @State private var useTabDatabase = true
    @State private var databaseOverride = ""
    @State private var view = "summary"

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "Multi-Server Query", subtitle: tab.displayTitle,
                        symbol: "square.stack.3d.up")
            Divider()
            serverPicker
            Divider()
            Picker("", selection: $view) {
                Text("Summary").tag("summary")
                Text("Merged results").tag("merged")
                Text("Text").tag("text")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 940, height: 660)
        .onAppear {
            selected = Set(app.servers.map(\.id))
        }
        .onDisappear { model.cancel() }
    }

    private var serverPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text("Run on").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
                Toggle("Use each window's own database", isOn: $useTabDatabase)
                    .font(.caption)
                if !useTabDatabase {
                    TextField("Database", text: $databaseOverride)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 160)
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(app.servers) { server in
                        Toggle(isOn: Binding(
                            get: { selected.contains(server.id) },
                            set: { on in
                                if on { selected.insert(server.id) } else { selected.remove(server.id) }
                            }
                        )) {
                            Text(server.displayName).lineLimit(1)
                        }
                        .toggleStyle(.checkbox)
                    }
                }
            }
        }
        .padding(10)
    }

    @ViewBuilder
    private var content: some View {
        switch view {
        case "merged":
            if model.mergedRows.isEmpty {
                ContentUnavailableView("No rows", systemImage: "tablecells",
                                       description: Text("Run the script to merge results."))
            } else {
                MergedResultsTable(columns: model.mergedColumns, rows: model.mergedRows,
                                   nullText: app.settings.gridNullText)
            }
        case "text":
            ScrollView {
                Text(textReport)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
        default:
            Table(model.outcomes) {
                TableColumn("") { outcome in
                    Image(systemName: outcome.succeeded ? "checkmark.circle" : "xmark.octagon.fill")
                        .foregroundStyle(outcome.succeeded ? Color.green : Color.red)
                }.width(24)
                TableColumn("Server", value: \.serverName).width(min: 140, ideal: 200)
                TableColumn("Database", value: \.database).width(140)
                TableColumn("Rows") { Text("\($0.rowCount)").monospacedDigit() }.width(70)
                TableColumn("Elapsed") {
                    Text(String(format: "%.3f s", $0.elapsed)).monospacedDigit()
                }.width(90)
                TableColumn("Message") { outcome in
                    Text(outcome.errorText ?? outcome.messages.joined(separator: " · "))
                        .foregroundStyle(outcome.succeeded ? Color.primary : Color.red)
                        .lineLimit(2)
                }.width(min: 180, ideal: 320)
            }
        }
    }

    private var textReport: String {
        let formatter = TextResultFormatter(options: app.settings.textResultOptions)
        var out = ""
        for outcome in model.outcomes {
            out += "-- \(outcome.serverName) [\(outcome.database)]"
            out += String(format: "  (%.3f s)\n", outcome.elapsed)
            if let error = outcome.errorText {
                out += "Error: \(error)\n\n"
                continue
            }
            out += formatter.format(columns: outcome.columns, rows: outcome.rows)
            for message in outcome.messages { out += message + "\n" }
            out += "\n"
        }
        return out.isEmpty ? "Run the script to see output." : out
    }

    private var runSummary: String {
        let failures = model.outcomes.filter { !$0.succeeded }.count
        var text = "\(model.outcomes.count) server(s), \(model.mergedRows.count) row(s)"
        if failures > 0 { text += ", \(failures) failed" }
        return text
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if model.isRunning {
                ProgressView().controlSize(.small)
                Text("Running on \(model.currentServer)…")
                    .font(.caption).foregroundStyle(.secondary)
            } else if !model.outcomes.isEmpty {
                Text(runSummary)
                    .font(.caption)
                    .foregroundStyle(model.outcomes.contains { !$0.succeeded }
                                     ? Color.red : Color.secondary)
            }
            Spacer()
            Button("Copy Merged CSV") { copyMerged() }
                .disabled(model.mergedRows.isEmpty)
            if model.isRunning {
                Button("Stop") { model.cancel() }
            } else {
                Button("Run") { run() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected.isEmpty)
            }
            Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .padding(12)
    }

    private func run() {
        let servers = app.servers.filter { selected.contains($0.id) }
        let database: String? = useTabDatabase
            ? (tab.database.isEmpty ? nil : tab.database)
            : (databaseOverride.isEmpty ? nil : databaseOverride)
        model.run(script: tab.textToExecute, servers: servers, database: database)
    }

    private func copyMerged() {
        var options = ExportOptions()
        options.includeHeaders = true
        options.lineEnding = "\n"
        options.nullText = app.settings.gridNullText
        let text = (try? ResultExporter().string(columns: model.mergedColumns,
                                                 rows: model.mergedRows,
                                                 format: .csv, options: options)) ?? ""
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// A lightweight grid for ad-hoc result sets that never came from a query window.
struct MergedResultsTable: View {
    let columns: [TDSColumn]
    let rows: [[TDSValue]]
    let nullText: String

    private struct Row: Identifiable {
        let id: Int
        let cells: [String]
    }

    private var tableRows: [Row] {
        rows.enumerated().map { index, row in
            Row(id: index, cells: columns.indices.map { column in
                column < row.count ? row[column].displayString(nullText: nullText) : nullText
            })
        }
    }

    var body: some View {
        // A Table needs its columns known at compile time, so wide ad-hoc result sets are
        // rendered as a scrolling monospaced grid instead.
        ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                        Text(column.name)
                            .font(.system(.caption, design: .monospaced).weight(.semibold))
                            .frame(width: 160, alignment: .leading)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 4)
                    }
                }
                .background(Color(nsColor: .controlBackgroundColor))
                Divider()
                ForEach(tableRows) { row in
                    HStack(spacing: 0) {
                        ForEach(Array(row.cells.enumerated()), id: \.offset) { _, cell in
                            Text(cell)
                                .font(.system(.caption, design: .monospaced))
                                .lineLimit(1)
                                .frame(width: 160, alignment: .leading)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                        }
                    }
                    .background(row.id.isMultiple(of: 2)
                                ? Color.clear : Color.primary.opacity(0.03))
                }
            }
        }
        .textSelection(.enabled)
    }
}
