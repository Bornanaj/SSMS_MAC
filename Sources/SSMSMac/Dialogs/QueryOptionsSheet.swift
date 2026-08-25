import SwiftUI
import SQLServerKit

/// Where a query tab sends its rows, mirroring SSMS's Results To Grid / Text / File.
enum QueryOutputMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case grid, text, file

    var id: String { rawValue }

    var title: String {
        switch self {
        case .grid: return "Results to Grid"
        case .text: return "Results to Text"
        case .file: return "Results to File"
        }
    }

    var iconName: String {
        switch self {
        case .grid: return "tablecells"
        case .text: return "text.alignleft"
        case .file: return "doc.text"
        }
    }
}

/// The Results page of Query Options. Persisted on its own because it describes how the
/// app renders rows, not how the server runs the batch.
struct QueryResultsPreferences: Codable, Hashable, Sendable {
    var outputMode: QueryOutputMode = .grid
    var maxCharactersPerColumn: Int = 256
    var includeColumnHeaders: Bool = true

    init() {}

    static let defaultsKey = "queryResultsPreferences"

    static func load(from defaults: UserDefaults = .standard) -> QueryResultsPreferences {
        guard let data = defaults.data(forKey: defaultsKey) else { return QueryResultsPreferences() }
        let decoded = try? JSONDecoder().decode(QueryResultsPreferences.self, from: data)
        return decoded ?? QueryResultsPreferences()
    }

    func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    /// Feeds the SQLServerKit formatter used by text and file output.
    var textStyle: TextResultFormatter.Style {
        var style = TextResultFormatter.Style()
        style.maxColumnWidth = max(1, maxCharactersPerColumn)
        style.printColumnHeaders = includeColumnHeaders
        return style
    }
}

/// SSMS's Query Options dialog: the SET block sent before each batch, plus how results
/// are presented. The generated script is always visible while editing.
struct QueryOptionsSheet: View {
    @Environment(\.dismiss) private var dismiss

    private enum Page: Hashable { case execution, results }

    private let onApply: (QuerySetOptions) -> Void

    @State private var options: QuerySetOptions
    @State private var results: QueryResultsPreferences
    @State private var page: Page = .execution

    init(options: QuerySetOptions, onApply: @escaping (QuerySetOptions) -> Void) {
        self.onApply = onApply
        _options = State(initialValue: options)
        _results = State(initialValue: QueryResultsPreferences.load())
    }

    private static let isolationLevels: [String] = [
        "READ UNCOMMITTED", "READ COMMITTED", "REPEATABLE READ", "SNAPSHOT", "SERIALIZABLE"
    ]

    private static let deadlockPriorities: [String] = ["LOW", "NORMAL", "HIGH"]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            TabView(selection: $page) {
                executionPage
                    .tabItem { Label("Execution", systemImage: "play") }
                    .tag(Page.execution)
                resultsPage
                    .tabItem { Label("Results", systemImage: "tablecells") }
                    .tag(Page.results)
            }
            .padding(10)
            Divider()
            preview
            Divider()
            footer
        }
        .frame(width: 640, height: 660)
    }

    // MARK: - Chrome

    private var header: some View {
        HStack {
            Image(systemName: "slider.horizontal.3").foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("Query Options").font(.headline)
                Text("Applied to the connection before each batch runs")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
    }

    private var footer: some View {
        HStack {
            Button("Reset to Defaults") { resetToDefaults() }
            Spacer()
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button("OK") { apply() }.keyboardShortcut(.defaultAction)
        }
        .padding(12)
    }

    private var preview: some View {
        let script: String = options.script
        return VStack(alignment: .leading, spacing: 4) {
            Text("Generated SET block")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            ScrollView {
                Text(script)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(height: 132)
            .background(Color(nsColor: .textBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.25)))
        }
        .padding(12)
    }

    // MARK: - Execution page

    private var executionPage: some View {
        Form {
            Section("ANSI") {
                Toggle("SET ANSI_NULLS", isOn: $options.ansiNulls)
                Toggle("SET ANSI_PADDING", isOn: $options.ansiPadding)
                Toggle("SET ANSI_WARNINGS", isOn: $options.ansiWarnings)
                Toggle("SET CONCAT_NULL_YIELDS_NULL", isOn: $options.concatNullYieldsNull)
                Toggle("SET QUOTED_IDENTIFIER", isOn: $options.quotedIdentifier)
            }
            Section("Advanced") {
                Toggle("SET ARITHABORT", isOn: $options.arithAbort)
                Toggle("SET NUMERIC_ROUNDABORT", isOn: $options.numericRoundAbort)
                Toggle("SET XACT_ABORT", isOn: $options.xactAbort)
                Toggle("SET NOCOUNT", isOn: $options.nocount)
                Text("NOCOUNT hides the \"rows affected\" messages, which speeds up loops "
                     + "that return many small batches.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Transactions") {
                Picker("Transaction isolation level", selection: $options.transactionIsolationLevel) {
                    ForEach(Self.isolationLevels, id: \.self) { level in
                        Text(level).tag(level)
                    }
                }
                Picker("Deadlock priority", selection: $options.deadlockPriority) {
                    ForEach(Self.deadlockPriorities, id: \.self) { priority in
                        Text(priority.capitalized).tag(priority)
                    }
                }
            }
            Section("Limits") {
                TextField("Lock timeout (milliseconds)",
                          value: $options.lockTimeoutMilliseconds, format: .number)
                Text("-1 waits forever, 0 fails immediately when a lock is held.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Maximum rows returned (SET ROWCOUNT)",
                          value: $options.rowCountLimit, format: .number)
                Text("0 returns every row. ROWCOUNT is ignored by INSERT, UPDATE and DELETE "
                     + "on SQL Server 2012 and later.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Results page

    private var resultsPage: some View {
        Form {
            Section("Output") {
                Picker("Display results in", selection: $results.outputMode) {
                    ForEach(QueryOutputMode.allCases) { mode in
                        Label(mode.title, systemImage: mode.iconName).tag(mode)
                    }
                }
                Text(outputModeExplanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Text and file output") {
                TextField("Maximum characters per column",
                          value: $results.maxCharactersPerColumn, format: .number)
                Text("Between 1 and 65535. Wider values are truncated, never wrapped.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Include column headers in the result set",
                       isOn: $results.includeColumnHeaders)
            }
        }
        .formStyle(.grouped)
    }

    private var outputModeExplanation: String {
        switch results.outputMode {
        case .grid: return "Rows appear in a sortable grid, one tab per result set."
        case .text: return "Rows are padded into fixed width columns, like SSMS text mode."
        case .file: return "The text rendering is written to a .rpt file after the batch finishes."
        }
    }

    // MARK: - Actions

    private func resetToDefaults() {
        options = QuerySetOptions()
        results = QueryResultsPreferences()
    }

    private func apply() {
        // Clamp here rather than while typing, so a half-entered number is not rewritten
        // under the cursor.
        options.lockTimeoutMilliseconds = max(-1, options.lockTimeoutMilliseconds)
        options.rowCountLimit = max(0, options.rowCountLimit)
        results.maxCharactersPerColumn = min(max(results.maxCharactersPerColumn, 1), 65_535)
        results.save()
        onApply(options)
        dismiss()
    }
}
