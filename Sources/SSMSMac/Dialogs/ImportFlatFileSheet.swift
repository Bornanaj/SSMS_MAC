import SwiftUI
import UniformTypeIdentifiers
import SQLServerKit

/// Import Flat File wizard: pick a file, review the inferred schema, then load it.
struct ImportFlatFileSheet: View {
    @Environment(\.dismiss) private var dismiss
    let server: ConnectedServer
    let database: String

    @State private var fileURL: URL?
    @State private var preview: ImportPreview?
    @State private var schema = "dbo"
    @State private var tableName = ""
    @State private var createTable = true
    @State private var truncateFirst = false
    @State private var isRunning = false
    @State private var progress: Double = 0
    @State private var rowsDone = 0
    @State private var statusText: String?
    @State private var isError = false
    @State private var showFileImporter = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            fileRow
            Divider()
            if let preview {
                configuration(preview)
                Divider()
                previewTable(preview)
            } else {
                ContentUnavailableView("No file selected", systemImage: "doc.badge.plus",
                                       description: Text("Choose a CSV or delimited text file."))
            }
            Divider()
            footer
        }
        .frame(width: 900, height: 620)
        .fileImporter(isPresented: $showFileImporter,
                      allowedContentTypes: [.commaSeparatedText, .tabSeparatedText, .plainText, .text],
                      allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                fileURL = url
                loadPreview(url)
            case .failure(let error):
                statusText = String(describing: error)
                isError = true
            }
        }
    }

    private var header: some View {
        HStack {
            Image(systemName: "square.and.arrow.down.on.square").foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("Import Flat File").font(.headline)
                Text("\(server.displayName) · \(database)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
    }

    private var fileRow: some View {
        HStack(spacing: 8) {
            Text(fileURL?.path ?? "No file selected")
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(fileURL == nil ? .secondary : .primary)
            Spacer()
            Button("Choose File…") { showFileImporter = true }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func configuration(_ preview: ImportPreview) -> some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("Schema") {
                    TextField("dbo", text: $schema).textFieldStyle(.roundedBorder).frame(width: 140)
                }
                LabeledContent("Table") {
                    TextField("target table", text: $tableName)
                        .textFieldStyle(.roundedBorder).frame(width: 220)
                }
                Toggle("Create the table", isOn: $createTable)
                Toggle("Truncate before loading", isOn: $truncateFirst)
                    .disabled(createTable)
            }
            VStack(alignment: .leading, spacing: 4) {
                detail("Delimiter", displayDelimiter(preview.detectedDelimiter))
                detail("Header row", preview.hasHeaderRow ? "Yes" : "No")
                detail("Encoding", preview.encodingName)
                detail("Columns", "\(preview.columns.count)")
                detail("Estimated rows", "\(preview.estimatedRowCount)")
            }
            Spacer()
        }
        .padding(12)
    }

    private func detail(_ label: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(label).foregroundStyle(.secondary)
            Text(value)
        }
        .font(.caption)
    }

    private func displayDelimiter(_ value: String) -> String {
        switch value {
        case "\t": return "Tab"
        case ",": return "Comma"
        case ";": return "Semicolon"
        case "|": return "Pipe"
        default: return value
        }
    }

    @ViewBuilder
    private func previewTable(_ preview: ImportPreview) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Column mapping")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 6)

            Table(Binding(
                get: { self.preview?.columns ?? [] },
                set: { self.preview?.columns = $0 }
            )) {
                TableColumn("Include") { $mapping in
                    Toggle("", isOn: $mapping.include).labelsHidden()
                }.width(60)
                TableColumn("Source") { $mapping in Text(mapping.sourceName) }.width(180)
                TableColumn("Target column") { $mapping in
                    TextField("", text: $mapping.targetName).textFieldStyle(.roundedBorder)
                }.width(180)
                TableColumn("SQL type") { $mapping in
                    TextField("", text: $mapping.sqlType).textFieldStyle(.roundedBorder)
                }.width(150)
                TableColumn("Nullable") { $mapping in
                    Toggle("", isOn: $mapping.isNullable).labelsHidden()
                }.width(70)
            }
        }
    }

    private var footer: some View {
        HStack {
            if isRunning {
                ProgressView(value: progress).frame(width: 140)
                Text("\(rowsDone) rows").font(.caption).monospacedDigit()
            }
            if let statusText {
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(isError ? Color.red : Color.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button("Import") { runImport() }
                .keyboardShortcut(.defaultAction)
                .disabled(preview == nil || tableName.isEmpty || isRunning)
        }
        .padding(12)
    }

    private func loadPreview(_ url: URL) {
        do {
            let importer = FlatFileImporter(session: server.session)
            let result = try importer.preview(url: url, sampleRows: 50)
            preview = result
            if tableName.isEmpty {
                tableName = url.deletingPathExtension().lastPathComponent
            }
            statusText = "Detected \(result.columns.count) columns."
            isError = false
        } catch {
            statusText = String(describing: error)
            isError = true
        }
    }

    private func runImport() {
        guard let url = fileURL, let preview else { return }
        isRunning = true
        progress = 0
        rowsDone = 0
        statusText = "Importing…"
        isError = false

        let importer = FlatFileImporter(session: server.session)
        let targetSchema = schema
        let targetTable = tableName
        let shouldCreate = createTable
        let shouldTruncate = truncateFirst

        Task {
            do {
                let count = try await importer.importFile(
                    url: url, database: database, schema: targetSchema, table: targetTable,
                    preview: preview, createTable: shouldCreate, truncateFirst: shouldTruncate,
                    batchSize: 500
                ) { fraction, done in
                    Task { @MainActor in
                        progress = fraction
                        rowsDone = done
                    }
                }
                statusText = "Imported \(count) rows into \(targetSchema).\(targetTable)."
            } catch {
                statusText = String(describing: error)
                isError = true
            }
            isRunning = false
        }
    }
}
