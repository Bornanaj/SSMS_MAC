import SwiftUI
import AppKit
import SQLServerKit
import TDSKit

/// SSMS's Export Data task, narrowed to what is actually useful on a Mac: read a table
/// or a query and write it to a file in one of the formats the exporter supports.
///
/// Nothing runs until asked. Preview streams the first rows and then stops the server,
/// and Export runs the query in full only once a file has been chosen, so opening the
/// sheet on a large table costs nothing.
struct ExportDataSheet: View {
    @Environment(\.dismiss) private var dismiss
    let server: ConnectedServer
    let database: String
    /// Pre-filled when launched from a table; otherwise the user writes the query.
    var schema: String?
    var table: String?

    @State private var query = ""
    @State private var format: ExportFormat = .csv
    @State private var includeHeaders = true
    @State private var delimiter = ","
    @State private var nullText = ""
    @State private var rowLimit = 0
    @State private var previewColumns: [TDSColumn] = []
    @State private var previewRows: [[TDSValue]] = []
    @State private var preview = ""
    @State private var isBusy = false
    @State private var status: String?
    @State private var isError = false
    /// The connection a preview or an export is streaming from, so Stop can reach it.
    @State private var activeConnection: TDSConnection?
    /// Stop was pressed during the read in flight. The server answers an attention
    /// with an ordinary DONE, so the token stream cannot tell a stop from the end.
    @State private var userStopped = false
    @StateObject private var progress = StreamProgress()

    private let previewLimit = 50

    private var source: String {
        if let schema, let table { return "\(schema).\(table)" }
        return "query"
    }

    private var hasQuery: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            SecurityHeader(icon: "square.and.arrow.up", title: "Export Data",
                           subtitle: "\(server.displayName) · \(database) · \(source)",
                           isBusy: isBusy)
            Divider()
            VSplitView {
                sourcePane.frame(minHeight: 150)
                previewPane.frame(minHeight: 200)
            }
            Divider()
            footer
        }
        .frame(width: 900, height: 660)
        .task {
            if let schema, let table {
                query = "SELECT *\n  FROM \(SQLIdentifier.quote(schema: schema, name: table));"
            } else if query.isEmpty {
                query = "SELECT TOP (1000) *\n  FROM "
            }
        }
    }

    private var sourcePane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Source query").font(.caption.weight(.medium))
                Spacer()
                LabeledContent("Row limit") {
                    TextField("0 = all", value: $rowLimit, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                }
                Button {
                    Task { await runPreview() }
                } label: {
                    Label("Preview", systemImage: "eye")
                }
                .disabled(isBusy || !hasQuery)
                .help("Read the first \(previewLimit) rows the query returns")
                Button {
                    userStopped = true
                    activeConnection?.cancel()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .disabled(!isBusy)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            TextEditor(text: $query)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .background(Color(nsColor: .textBackgroundColor))
        }
    }

    private var previewPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Picker("Format", selection: $format) {
                    ForEach(ExportFormat.allCases) { Text($0.displayName).tag($0) }
                }
                .frame(width: 220)

                if format == .csv || format == .tsv {
                    LabeledContent("Delimiter") {
                        TextField("", text: $delimiter)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 44)
                    }
                }
                Toggle("Headers", isOn: $includeHeaders)
                LabeledContent("NULL as") {
                    TextField("empty", text: $nullText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                }
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .onChange(of: format) { _, _ in refreshPreview() }
            .onChange(of: includeHeaders) { _, _ in refreshPreview() }
            .onChange(of: delimiter) { _, _ in refreshPreview() }
            .onChange(of: nullText) { _, _ in refreshPreview() }

            Divider()

            ScrollView([.horizontal, .vertical]) {
                Text(preview.isEmpty
                     ? "Preview reads the first \(previewLimit) rows; Export… runs the query and writes the file."
                     : preview)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
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
            if isBusy, progress.rowsRead > 0 {
                Text("\(progress.rowsRead) rows read…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if !previewColumns.isEmpty {
                Text("Preview: \(previewRows.count) rows · \(previewColumns.count) columns")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Copy Preview") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(previewText(rows: previewRows), forType: .string)
            }
            .disabled(previewRows.isEmpty)
            Button("Export…") { export() }
                .keyboardShortcut(.defaultAction)
                .disabled(isBusy || !hasQuery)
            Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .padding(12)
    }

    private var options: ExportOptions {
        var options = ExportOptions()
        options.includeHeaders = includeHeaders
        options.delimiter = format == .tsv ? "\t" : (delimiter.isEmpty ? "," : delimiter)
        options.nullText = nullText
        options.tableName = table.map { SQLIdentifier.quote(schema: schema ?? "dbo", name: $0) }
            ?? "[dbo].[Export]"
        return options
    }

    private var defaultName: String {
        table ?? "export"
    }

    // MARK: - Preview

    /// The rows in the chosen text format. XLSX is binary, so its preview is the same
    /// data as CSV.
    private func previewText(rows: [[TDSValue]]) -> String {
        let effective: ExportFormat = format == .xlsx ? .csv : format
        return (try? ResultExporter().string(columns: previewColumns, rows: rows,
                                             format: effective, options: options)) ?? ""
    }

    private func refreshPreview() {
        guard !previewColumns.isEmpty else {
            preview = ""
            return
        }
        var text = previewText(rows: previewRows)
        if previewRows.count >= previewLimit {
            text += "\n… the preview stops after \(previewLimit) rows; Export… writes every row."
        }
        if format == .xlsx {
            text = "Excel workbooks are binary; the preview shows the same data as CSV.\n\n" + text
        }
        preview = text
    }

    private func runPreview() async {
        isBusy = true
        defer { isBusy = false }
        do {
            let result = try await read(limit: previewLimit)
            previewColumns = result.columns
            previewRows = result.rows
            isError = false
            status = result.stoppedByUser
                ? "Preview stopped after \(result.rows.count) rows."
                : "Preview read \(result.rows.count) row\(result.rows.count == 1 ? "" : "s")."
            refreshPreview()
        } catch {
            previewColumns = []
            previewRows = []
            preview = ""
            isError = true
            status = String(describing: error)
        }
    }

    // MARK: - Export

    /// NSSavePanel rather than `fileExporter`, because XLSX is a zip the exporter has
    /// to write itself, and the query only runs once there is a file to write to.
    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(defaultName).\(format.fileExtension)"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await write(to: url) }
    }

    private func write(to url: URL) async {
        isBusy = true
        defer { isBusy = false }
        do {
            let result = try await read(limit: max(0, rowLimit))
            guard !result.stoppedByUser else {
                isError = true
                status = "Export stopped; nothing was written."
                return
            }
            try ResultExporter().export(columns: result.columns, rows: result.rows,
                                        format: format, to: url, options: options)
            isError = false
            let count = result.rows.count
            status = "Wrote \(count) row\(count == 1 ? "" : "s") to \(url.lastPathComponent)."
        } catch {
            isError = true
            status = String(describing: error)
        }
    }

    // MARK: - Reading

    private struct ReadResult {
        var columns: [TDSColumn]
        var rows: [[TDSValue]]
        var stoppedByUser: Bool
    }

    /// Streams the query's first result set on a connection of its own. With a limit,
    /// the server is told to stop as soon as that many rows are in hand, so neither a
    /// preview nor a capped export reads the whole table.
    private func read(limit: Int) async throws -> ReadResult {
        let sql = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sql.isEmpty else { throw ExportError.emptyQuery }

        progress.rowsRead = 0
        userStopped = false
        let connection = try await server.session.openConnection(database: database)
        activeConnection = connection
        defer {
            activeConnection = nil
            Task { try? await connection.close() }
        }

        let progress = self.progress
        let collector = StreamedResultCollector(limit: limit, stop: { connection.cancel() },
                                                onProgress: { count in
            Task { @MainActor in progress.rowsRead = count }
        })
        try await connection.execute(sql) { event in collector.consume(event) }
        let output = collector.finish()

        if let fatal = output.errors.first(where: { $0.severity >= 11 }) {
            throw TDSError.server(fatal)
        }
        guard let columns = output.columns else { throw ExportError.noResultSet }
        // A stop the collector asked for itself (the limit was reached) is a complete
        // read; only a Stop that cut the read short counts as the user's.
        return ReadResult(columns: columns, rows: output.rows,
                          stoppedByUser: userStopped && !output.stopRequested)
    }

    enum ExportError: Error, CustomStringConvertible {
        case emptyQuery
        case noResultSet

        var description: String {
            switch self {
            case .emptyQuery: return "Write the query to export first."
            case .noResultSet: return "The query returned no result set."
            }
        }
    }
}

/// Row count of the read in flight, published for the footer.
@MainActor
final class StreamProgress: ObservableObject {
    @Published var rowsRead = 0
}

/// Gathers the first result set of a streamed batch as it arrives on the event loop.
/// Once `limit` rows are in hand (or a second result set starts) it asks the server to
/// stop, so a preview of a large table costs a few packets rather than the whole table.
final class StreamedResultCollector: @unchecked Sendable {
    struct Output {
        var columns: [TDSColumn]?
        var rows: [[TDSValue]]
        var errors: [TDSServerMessage]
        /// The collector itself asked the server to stop, so what it holds is all it
        /// was ever going to keep.
        var stopRequested: Bool
    }

    private let lock = NSLock()
    private let limit: Int
    private let stop: @Sendable () -> Void
    private let onProgress: @Sendable (Int) -> Void
    private var output = Output(columns: nil, rows: [], errors: [], stopRequested: false)
    private var firstSetFinished = false

    /// `limit` 0 means every row.
    init(limit: Int, stop: @escaping @Sendable () -> Void,
         onProgress: @escaping @Sendable (Int) -> Void) {
        self.limit = limit
        self.stop = stop
        self.onProgress = onProgress
    }

    func consume(_ event: TDSStreamEvent) {
        var shouldStop = false
        var reportedCount: Int?
        lock.withLock {
            switch event {
            case .columns(let columns):
                if output.columns == nil {
                    output.columns = columns
                } else if !firstSetFinished {
                    firstSetFinished = true
                    shouldStop = requestStopLocked()
                } else {
                    shouldStop = requestStopLocked()
                }
            case .row(let values):
                guard output.columns != nil, !firstSetFinished else { return }
                if limit > 0 && output.rows.count >= limit { return }
                output.rows.append(values)
                if output.rows.count % 2000 == 0 { reportedCount = output.rows.count }
                if limit > 0 && output.rows.count == limit {
                    shouldStop = requestStopLocked()
                }
            case .done, .doneProc, .doneInProc:
                if output.columns != nil { firstSetFinished = true }
            case .error(let message):
                output.errors.append(message)
            default:
                break
            }
        }
        // Called outside the lock: the stop hops to the event loop and the progress
        // callback hops to the main actor, and neither should wait on this collector.
        if shouldStop { stop() }
        if let reportedCount { onProgress(reportedCount) }
    }

    private func requestStopLocked() -> Bool {
        guard !output.stopRequested else { return false }
        output.stopRequested = true
        return true
    }

    func finish() -> Output {
        lock.withLock { output }
    }
}
