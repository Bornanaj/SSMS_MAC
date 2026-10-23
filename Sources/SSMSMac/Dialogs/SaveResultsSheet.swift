import SwiftUI
import AppKit
import TDSKit
import SQLServerKit

/// SSMS's "Results to File", after the fact: pick a result set, a format and the
/// details, and write what is already on screen to disk.
///
/// SSMS decides before running a query; here the rows are already in memory, so the
/// choice can be made once the results are worth keeping — and no second execution is
/// needed to change format.
struct SaveResultsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var tab: QueryTab

    @State private var selectedResultID: UUID?
    @State private var format: ExportFormat = .csv
    @State private var includeHeaders = true
    @State private var delimiter = ","
    @State private var nullText = "NULL"
    @State private var tableName = "Results"
    @State private var allResultSets = false
    @State private var status: String?
    @State private var isError = false

    private var model: ResultSetModel? {
        guard let selectedResultID else { return tab.resultSets.first }
        return tab.resultSets.first { $0.id == selectedResultID }
    }

    private var rowCount: Int {
        allResultSets ? tab.resultSets.reduce(0) { $0 + $1.rowCount } : (model?.rowCount ?? 0)
    }

    var body: some View {
        VStack(spacing: 0) {
            SecurityHeader(icon: "square.and.arrow.down", title: "Save Results",
                           subtitle: "\(tab.displayTitle) · \(tab.database)", isBusy: false)
            Divider()
            if tab.resultSets.isEmpty {
                ContentUnavailableView("No results", systemImage: "tablecells",
                                       description: Text("Run a query that returns rows first."))
            } else {
                form
            }
            Divider()
            footer
        }
        .frame(width: 620, height: 520)
        .onAppear {
            selectedResultID = tab.resultSets.first?.id
            tableName = tab.database.isEmpty ? "Results" : "\(tab.database)_Results"
        }
    }

    private var form: some View {
        Form {
            Section("Source") {
                Picker("Result set", selection: $selectedResultID) {
                    ForEach(tab.resultSets) { result in
                        Text("Result set \(result.ordinal) — \(result.rowCount) rows")
                            .tag(UUID?.some(result.id))
                    }
                }
                .disabled(allResultSets)
                if tab.resultSets.count > 1 {
                    Toggle("Write every result set to one file", isOn: $allResultSets)
                }
                if model?.isTruncated == true {
                    Label("This grid stopped at the display limit, so the file will hold "
                          + "only the rows that were fetched.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section("Format") {
                Picker("Format", selection: $format) {
                    ForEach(ExportFormat.allCases) { Text($0.displayName).tag($0) }
                }
                if format != .xlsx {
                    Toggle("Include a header row", isOn: $includeHeaders)
                }
                if format == .csv {
                    TextField("Delimiter", text: $delimiter)
                }
                if format == .sqlInsert || format == .xlsx || format == .html {
                    TextField(format == .sqlInsert ? "Target table" : "Sheet or title",
                              text: $tableName)
                }
                if format == .csv || format == .tsv || format == .markdown || format == .html {
                    TextField("Text written for NULL", text: $nullText)
                }
            }

            Section {
                Text(summaryLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var summaryLine: String {
        let sets = allResultSets ? tab.resultSets.count : 1
        let plural = rowCount == 1 ? "" : "s"
        return "\(rowCount) row\(plural) from \(sets) result set"
            + (sets == 1 ? "" : "s") + " as \(format.displayName)."
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
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button("Save…") { save() }
                .keyboardShortcut(.defaultAction)
                .disabled(tab.resultSets.isEmpty)
        }
        .padding(12)
    }

    // MARK: - Writing

    private var options: ExportOptions {
        var options = ExportOptions()
        options.includeHeaders = includeHeaders
        options.delimiter = delimiter.isEmpty ? "," : delimiter
        options.nullText = nullText
        options.tableName = tableName.isEmpty ? "Results" : tableName
        return options
    }

    /// NSSavePanel rather than `fileExporter`, because XLSX is a zip the exporter has to
    /// write itself; a `FileDocument` would have to carry the bytes twice.
    private func save() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(defaultName).\(format.fileExtension)"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let exporter = ResultExporter()
            if allResultSets && tab.resultSets.count > 1 {
                guard !format.isBinary else {
                    // One sheet per result set is not something the writer does, and a
                    // concatenated zip is not a workbook.
                    throw SaveError.multipleSetsUnsupported
                }
                var blocks: [String] = []
                for result in tab.resultSets {
                    var perSet = options
                    perSet.tableName = "\(options.tableName)_\(result.ordinal)"
                    blocks.append(try exporter.string(columns: result.columns, rows: result.rows,
                                                      format: format, options: perSet))
                }
                let joined = blocks.joined(separator: format == .sqlInsert ? "\nGO\n" : "\n\n")
                try Data(joined.utf8).write(to: url, options: .atomic)
            } else {
                guard let model else { throw SaveError.noResultSet }
                try exporter.export(columns: model.columns, rows: model.rows,
                                    format: format, to: url, options: options)
            }
            isError = false
            status = "Saved \(rowCount) rows to \(url.lastPathComponent)."
            tab.statusMessage("Results saved to \(url.path).")
            dismiss()
        } catch {
            isError = true
            status = String(describing: error)
        }
    }

    private var defaultName: String {
        let base = tab.fileURL?.deletingPathExtension().lastPathComponent
            ?? tab.title.replacingOccurrences(of: ".sql", with: "")
        return base.isEmpty ? "results" : base
    }

    enum SaveError: Error, CustomStringConvertible {
        case noResultSet
        case multipleSetsUnsupported

        var description: String {
            switch self {
            case .noResultSet:
                return "There is no result set to write."
            case .multipleSetsUnsupported:
                return "An Excel workbook holds one result set. Save each one on its own, "
                    + "or pick a text format."
            }
        }
    }
}
