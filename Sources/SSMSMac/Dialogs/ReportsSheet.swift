import SwiftUI
import UniformTypeIdentifiers
import SQLServerKit

/// SSMS's Reports > Standard Reports, as one browser: pick a report on the left, read
/// it on the right, export it if it is worth keeping.
struct ReportsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let server: ConnectedServer
    var initialDatabase: String?

    @State private var selection: ServerReportKind?
    @State private var database: String = ""
    @State private var databases: [String] = []
    @State private var result: ReportResult?
    @State private var isBusy = false
    @State private var status: String?
    @State private var isError = false
    @State private var search = ""
    @State private var isExporting = false

    private var available: [ServerReportKind] {
        let info = server.serverInfo
        return ServerReportKind.allCases.filter { kind in
            guard kind.isAvailable(on: info) else { return false }
            guard !search.isEmpty else { return true }
            return kind.title.localizedCaseInsensitiveContains(search)
                || kind.summary.localizedCaseInsensitiveContains(search)
        }
    }

    private var grouped: [(category: String, kinds: [ServerReportKind])] {
        let byCategory = Dictionary(grouping: available, by: \.category)
        return byCategory.keys.sorted().map { ($0, byCategory[$0] ?? []) }
    }

    var body: some View {
        VStack(spacing: 0) {
            SecurityHeader(icon: "chart.bar.doc.horizontal", title: "Reports",
                           subtitle: server.displayName, isBusy: isBusy)
            Divider()
            HSplitView {
                sidebar.frame(minWidth: 260, idealWidth: 290, maxWidth: 380)
                reportPane.frame(minWidth: 520)
            }
            Divider()
            footer
        }
        .frame(width: 1100, height: 700)
        .task {
            database = initialDatabase ?? server.serverInfo.currentDatabase
            await loadDatabases()
        }
        .task(id: selection) { await run() }
        .task(id: database) { if selection?.scope == .database { await run() } }
        .fileExporter(isPresented: $isExporting, document: exportDocument,
                      contentType: .commaSeparatedText,
                      defaultFilename: selection?.title ?? "report") { _ in }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            TextField("Search reports", text: $search)
                .textFieldStyle(.roundedBorder)
                .padding(8)
            Divider()
            List(selection: $selection) {
                ForEach(grouped, id: \.category) { group in
                    Section(group.category) {
                        ForEach(group.kinds) { kind in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(kind.title).lineLimit(1)
                                Text(kind.summary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            .tag(kind)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
        }
    }

    @ViewBuilder
    private var reportPane: some View {
        VStack(spacing: 0) {
            if let selection {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(selection.title).font(.headline)
                        Text(selection.summary).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if selection.scope == .database {
                        Picker("Database", selection: $database) {
                            ForEach(databases, id: \.self) { Text($0).tag($0) }
                        }
                        .frame(width: 200)
                    }
                    Button { Task { await run() } } label: { Image(systemName: "arrow.clockwise") }
                        .disabled(isBusy)
                }
                .padding(10)
                Divider()
            }

            if isBusy {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if selection == nil {
                ContentUnavailableView("Choose a report", systemImage: "chart.bar.doc.horizontal",
                                       description: Text("Reports read from the dynamic "
                                                         + "management views and msdb."))
            } else if let result, !result.isEmpty {
                ReportTableView(result: result)
            } else if isError {
                ContentUnavailableView("Report failed", systemImage: "exclamationmark.triangle",
                                       description: Text(status ?? ""))
            } else {
                ContentUnavailableView("No rows", systemImage: "tray",
                                       description: Text("This report returned nothing."))
            }
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
            Button("Copy") {
                guard let result else { return }
                let header = result.columns.joined(separator: "\t")
                let body = result.rows.map { $0.joined(separator: "\t") }.joined(separator: "\n")
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(header + "\n" + body, forType: .string)
            }
            .disabled(result?.isEmpty ?? true)
            Button("Export CSV…") { isExporting = true }
                .disabled(result?.isEmpty ?? true)
            Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .padding(12)
    }

    private var exportDocument: ResultsCSVDocument {
        guard let result else { return ResultsCSVDocument(text: "") }
        func escape(_ value: String) -> String {
            let needsQuotes = value.contains(",") || value.contains("\"")
                || value.contains("\n") || value.contains("\r")
            guard needsQuotes else { return value }
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        var lines = [result.columns.map(escape).joined(separator: ",")]
        lines.append(contentsOf: result.rows.map { $0.map(escape).joined(separator: ",") })
        return ResultsCSVDocument(text: lines.joined(separator: "\n"))
    }

    private func loadDatabases() async {
        do {
            let sql = "SELECT name FROM sys.databases WHERE state_desc = 'ONLINE' "
                + "AND HAS_DBACCESS(name) = 1 ORDER BY name"
            let response = try await server.session.metadataQuery(sql)
            databases = (response.resultSets.first?.dictionaries() ?? []).map { $0.string("name") }
            if database.isEmpty || !databases.contains(database) {
                database = databases.first ?? "master"
            }
        } catch {
            databases = []
        }
    }

    private func run() async {
        guard let selection else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let reports = ServerReports(session: server.session)
            let target = selection.scope == .database ? database : nil
            let value = try await reports.run(selection, database: target)
            result = value
            isError = false
            status = value.isEmpty ? "No rows." : "\(value.rows.count) rows."
        } catch {
            result = nil
            isError = true
            status = String(describing: error)
        }
    }
}

/// A plain scrollable grid. Reports have arbitrary column counts, which SwiftUI's
/// `Table` cannot express without a static column list.
struct ReportTableView: View {
    let result: ReportResult

    private var widths: [CGFloat] {
        result.columns.enumerated().map { index, name in
            // Measure the header and a sample of the rows rather than every row, which
            // would be O(rows x columns) on every layout pass.
            let sample = result.rows.prefix(200).compactMap { row -> Int? in
                index < row.count ? row[index].count : nil
            }
            let widest = max(name.count, sample.max() ?? 0)
            return CGFloat(min(max(widest, 6), 60)) * 7.4 + 18
        }
    }

    var body: some View {
        let columnWidths = widths
        ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    ForEach(Array(result.rows.enumerated()), id: \.offset) { rowIndex, row in
                        HStack(spacing: 0) {
                            ForEach(Array(row.enumerated()), id: \.offset) { columnIndex, value in
                                Text(value)
                                    .font(.system(size: 11, design: .monospaced))
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .frame(width: columnWidths.indices.contains(columnIndex)
                                           ? columnWidths[columnIndex] : 120,
                                           alignment: result.numericColumns.contains(columnIndex)
                                           ? .trailing : .leading)
                                    .padding(.horizontal, 4)
                            }
                        }
                        .padding(.vertical, 2)
                        .background(rowIndex.isMultiple(of: 2)
                                    ? Color.clear : Color.secondary.opacity(0.06))
                    }
                } header: {
                    HStack(spacing: 0) {
                        ForEach(Array(result.columns.enumerated()), id: \.offset) { index, name in
                            Text(name)
                                .font(.system(size: 11, weight: .semibold))
                                .lineLimit(1)
                                .frame(width: columnWidths.indices.contains(index)
                                       ? columnWidths[index] : 120,
                                       alignment: result.numericColumns.contains(index)
                                       ? .trailing : .leading)
                                .padding(.horizontal, 4)
                        }
                    }
                    .padding(.vertical, 5)
                    .background(.regularMaterial)
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}
