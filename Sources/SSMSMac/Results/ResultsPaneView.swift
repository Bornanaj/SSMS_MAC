import SwiftUI
import UniformTypeIdentifiers
import TDSKit
import SQLServerKit

/// The bottom half of a query window: results, messages, plan and statistics.
struct ResultsPaneView: View {
    @ObservedObject var tab: QueryTab
    @ObservedObject var settings: AppSettings
    var onJumpToLine: (Int) -> Void
    /// Opens the Save Results dialog; the pane itself owns no sheet state.
    var onSaveResults: () -> Void

    /// One source for the mode: the Query menu, the pane's own menu and Query Options
    /// all read and write `AppSettings.resultsOutputMode`.
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

            Button {
                onSaveResults()
            } label: {
                Image(systemName: "square.and.arrow.down")
            }
            .buttonStyle(.plain)
            .disabled(tab.resultSets.isEmpty)
            .help("Save results to a file")

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
        case .liveStatistics: return tab.includeLiveStatistics
            || !tab.liveSnapshot.isEmpty || tab.liveStatisticsMessage != nil
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

        case .liveStatistics:
            LiveQueryStatsView(tab: tab)

        case .clientStatistics:
            clientStatistics
        }
    }

    /// SSMS's "Results to Text": every result set rendered as fixed-width columns in
    /// one scrollable document, the way sqlcmd prints them. The text is formatted by
    /// the tab once per run; the view only displays it.
    @ViewBuilder
    private var textResults: some View {
        if tab.isExecuting {
            ContentUnavailableView("Running…", systemImage: "text.alignleft",
                                   description: Text("The output appears when the batch finishes."))
        } else if tab.textOutput.isEmpty {
            ContentUnavailableView("No results", systemImage: "text.alignleft",
                                   description: Text("Execute a query to see output here."))
        } else {
            PlainTextOutputView(text: tab.textOutput, font: settings.gridFont)
        }
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
                        onSaveResults()
                    } label: {
                        Label("Save Results As…", systemImage: "square.and.arrow.down")
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

/// A read-only, selectable NSTextView for large plain-text output. A SwiftUI `Text`
/// lays the whole string out as one glyph run on every update, which stalls on a few
/// hundred thousand rows; the text view lays out only what is on screen.
struct PlainTextOutputView: NSViewRepresentable {
    var text: String
    var font: NSFont

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = []
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.size = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                              height: CGFloat.greatestFiniteMagnitude)
        scrollView.documentView = textView
        apply(to: textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        apply(to: textView)
    }

    private func apply(to textView: NSTextView) {
        // Comparing first keeps a keystroke in the editor from re-laying the output.
        if textView.font != font {
            textView.font = font
            textView.typingAttributes = [.font: font, .foregroundColor: NSColor.textColor]
        }
        if textView.string != text {
            textView.string = text
            textView.textStorage?.addAttributes([.font: font, .foregroundColor: NSColor.textColor],
                                                range: NSRange(location: 0, length: (text as NSString).length))
        }
        textView.minSize = textView.enclosingScrollView?.contentSize ?? .zero
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
