import SwiftUI
import UniformTypeIdentifiers
import SQLServerKit
import TDSKit

/// SSMS's Export Data task, narrowed to what is actually useful on a Mac: read a table
/// or a query and write it to a file in one of the formats the exporter supports.
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
    @State private var columns: [TDSColumn] = []
    @State private var rows: [[TDSValue]] = []
    @State private var preview = ""
    @State private var isBusy = false
    @State private var status: String?
    @State private var isError = false
    @State private var isExporting = false

    private var source: String {
        if let schema, let table { return "\(schema).\(table)" }
        return "query"
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
            await load()
        }
        .fileExporter(isPresented: $isExporting, document: document,
                      contentType: contentType,
                      defaultFilename: (table ?? "export")) { result in
            switch result {
            case .success(let url):
                status = "Written to \(url.lastPathComponent)."
                isError = false
            case .failure(let error):
                status = String(describing: error)
                isError = true
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
                Button { Task { await load() } } label: { Label("Run", systemImage: "play") }
                    .disabled(isBusy)
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
                Text(preview.isEmpty ? "Run the query to preview the export." : preview)
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
            Text("\(rows.count) rows · \(columns.count) columns")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(fullText(), forType: .string)
            }
            .disabled(rows.isEmpty)
            Button("Export…") { isExporting = true }
                .keyboardShortcut(.defaultAction)
                .disabled(rows.isEmpty)
            Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .padding(12)
    }

    private var contentType: UTType {
        switch format {
        case .csv: return .commaSeparatedText
        case .json: return .json
        case .xml: return .xml
        case .html: return .html
        case .xlsx: return UTType(filenameExtension: "xlsx") ?? .data
        default: return .plainText
        }
    }

    private var document: ResultsCSVDocument {
        ResultsCSVDocument(text: fullText())
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

    private func fullText() -> String {
        // xlsx is binary, so the text path offers CSV instead and the file exporter
        // writes the real workbook.
        let effective: ExportFormat = format == .xlsx ? .csv : format
        return (try? ResultExporter().string(columns: columns, rows: rows,
                                             format: effective, options: options)) ?? ""
    }

    private func refreshPreview() {
        guard !rows.isEmpty else {
            preview = ""
            return
        }
        let sample = Array(rows.prefix(50))
        let effective: ExportFormat = format == .xlsx ? .csv : format
        let text = (try? ResultExporter().string(columns: columns, rows: sample,
                                                 format: effective, options: options)) ?? ""
        preview = rows.count > sample.count
            ? text + "\n… \(rows.count - sample.count) more rows"
            : text
        if format == .xlsx {
            preview = "Excel workbooks are binary; the preview shows the same data as CSV.\n\n"
                + preview
        }
    }

    private func load() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let connection = try await server.session.openConnection(database: database)
            defer { Task { try? await connection.close() } }
            let result = try await connection.query(trimmed)
            guard let set = result.resultSets.first else {
                columns = []
                rows = []
                preview = ""
                isError = true
                status = "The query returned no result set."
                return
            }
            columns = set.columns
            rows = rowLimit > 0 ? Array(set.rows.prefix(rowLimit)) : set.rows
            isError = false
            status = "\(rows.count) rows read."
            refreshPreview()
        } catch {
            isError = true
            status = String(describing: error)
        }
    }
}
