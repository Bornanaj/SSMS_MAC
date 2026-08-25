import SwiftUI
import UniformTypeIdentifiers
import TDSKit
import SQLServerKit

/// The bottom half of a query window: results, messages, plan and statistics.
struct ResultsPaneView: View {
    @ObservedObject var tab: QueryTab
    @ObservedObject var settings: AppSettings
    var onJumpToLine: (Int) -> Void

    @State private var exportTarget: ResultSetModel?
    @State private var preferences = QueryResultsPreferences.load()

    private var outputMode: QueryOutputMode {
        settings.resultsOutputMode == "text" ? .text : .grid
    }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            content
        }
        .background(Color(nsColor: .textBackgroundColor))
        .fileExporter(isPresented: Binding(
            get: { exportTarget != nil },
            set: { if !$0 { exportTarget = nil } }
        ), document: exportDocument, contentType: .commaSeparatedText, defaultFilename: "results") { _ in
            exportTarget = nil
        }
    }

    private var exportDocument: ResultsCSVDocument {
        guard let model = exportTarget else { return ResultsCSVDocument(text: "") }
        let exporter = ResultExporter()
        var options = ExportOptions()
        options.includeHeaders = true
        let text = (try? exporter.string(columns: model.columns, rows: model.rows,
                                         format: .csv, options: options)) ?? ""
        return ResultsCSVDocument(text: text)
    }

    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(ResultsPaneTab.allCases) { paneTab in
                let isEnabled = enabled(paneTab)
                Button {
                    tab.selectedPaneTab = paneTab
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: paneTab.symbol)
                        Text(paneTab.title)
                        if paneTab == .messages, tab.messages.contains(where: { $0.kind == .error }) {
                            Circle().fill(Color.red).frame(width: 6, height: 6)
                        }
                    }
                    .font(.caption)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(tab.selectedPaneTab == paneTab
                                ? Color.accentColor.opacity(0.18) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .disabled(!isEnabled)
                .opacity(isEnabled ? 1 : 0.4)
            }

            Spacer()

            if let summary = tab.summary {
                Text(statusLine(summary))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Menu {
                Picker("Output", selection: $settings.resultsOutputMode) {
                    Text("Results to Grid").tag("grid")
                    Text("Results to Text").tag("text")
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: outputMode == .text ? "text.alignleft" : "tablecells")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Switch between grid and text output")

            Button {
                tab.showResultsPane = false
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.plain)
            .help("Hide the results pane")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func enabled(_ paneTab: ResultsPaneTab) -> Bool {
        switch paneTab {
        case .results: return true
        case .messages: return true
        case .executionPlan: return tab.executionPlanXML != nil
        case .clientStatistics: return tab.summary != nil
        }
    }

    private func statusLine(_ summary: QueryExecutionSummary) -> String {
        let rows = summary.totalRows
        let seconds = String(format: "%.3f s", summary.elapsed)
        return "\(rows) row\(rows == 1 ? "" : "s") · \(seconds)"
    }

    @ViewBuilder
    private var content: some View {
        switch tab.selectedPaneTab {
        case .results where outputMode == .text:
            textResults

        case .results:
            if tab.resultSets.isEmpty {
                ContentUnavailableView(tab.isExecuting ? "Running…" : "No results",
                                       systemImage: "tablecells",
                                       description: Text(tab.isExecuting
                                                         ? "Waiting for the server."
                                                         : "Execute a query to see rows here."))
            } else if tab.resultSets.count == 1, let model = tab.resultSets[0] as ResultSetModel? {
                resultSection(model, showHeader: false)
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(tab.resultSets) { model in
                            resultSection(model, showHeader: true)
                                .frame(height: 260)
                        }
                    }
                    .padding(8)
                }
            }

        case .messages:
            MessagesView(messages: tab.messages, onSelectLine: onJumpToLine)

        case .executionPlan:
            if let xml = tab.executionPlanXML {
                ExecutionPlanView(xml: xml)
            } else {
                ContentUnavailableView("No execution plan", systemImage: "chart.xyaxis.line")
            }

        case .clientStatistics:
            clientStatistics
        }
    }

    /// SSMS's "Results to Text": every result set rendered as fixed-width columns in
    /// one scrollable document, the way sqlcmd prints them.
    @ViewBuilder
    private var textResults: some View {
        if tab.resultSets.isEmpty && tab.messages.isEmpty {
            ContentUnavailableView(tab.isExecuting ? "Running…" : "No results",
                                   systemImage: "text.alignleft",
                                   description: Text("Execute a query to see output here."))
        } else {
            ScrollView([.vertical, .horizontal]) {
                Text(textOutput)
                    .font(.system(size: settings.gridFontSize, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
    }

    private var textOutput: String {
        let formatter = TextResultFormatter(style: preferences.textStyle)
        var blocks: [String] = []
        for model in tab.resultSets {
            blocks.append(formatter.format(columns: model.columns, rows: model.rows))
            blocks.append(formatter.rowsAffected(Int64(model.rowCount)))
        }
        for message in tab.messages where message.kind == .info {
            blocks.append(message.text)
        }
        for message in tab.messages where message.kind == .error {
            blocks.append(message.displayText)
        }
        return blocks.joined(separator: "\n")
    }

    @ViewBuilder
    private func resultSection(_ model: ResultSetModel, showHeader: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if showHeader {
                HStack {
                    Text("Result set \(model.ordinal)")
                        .font(.caption.weight(.medium))
                    Text(model.summaryText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        exportTarget = model
                    } label: {
                        Label("Save as CSV", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
            }
            ResultGridView(model: model, settings: settings) { _ in }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: showHeader ? 6 : 0))
    }

    @ViewBuilder
    private var clientStatistics: some View {
        if let summary = tab.summary {
            ScrollView {
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                    statRow("Client execution time", String(format: "%.3f s", summary.elapsed))
                    statRow("Rows returned", "\(summary.totalRows)")
                    statRow("Rows affected", "\(summary.rowsAffected)")
                    statRow("Result sets", "\(summary.statistics.resultSets)")
                    statRow("Batches", "\(summary.batchCount)")
                    statRow("Server round trips", "\(summary.statistics.serverRoundtrips)")
                    statRow("Errors", "\(summary.errorCount)")
                    statRow("Cancelled", summary.cancelled ? "Yes" : "No")
                    statRow("Started", summary.startedAt.formatted(date: .omitted, time: .standard))
                    statRow("Finished", summary.finishedAt.formatted(date: .omitted, time: .standard))
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ContentUnavailableView("No statistics", systemImage: "chart.bar")
        }
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).font(.system(.body, design: .monospaced))
        }
    }
}

/// Minimal document wrapper so `fileExporter` can save a CSV.
struct ResultsCSVDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText, .plainText] }
    var text: String

    init(text: String) { self.text = text }

    init(configuration: ReadConfiguration) throws {
        let data = configuration.file.regularFileContents ?? Data()
        text = String(data: data, encoding: .utf8) ?? ""
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
