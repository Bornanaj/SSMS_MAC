import SwiftUI
import SQLServerKit

/// Back Up Database. The generated T-SQL is always shown before anything runs.
struct BackupSheet: View {
    @Environment(\.dismiss) private var dismiss
    let server: ConnectedServer
    let database: String

    @State private var kind: BackupRequest.Kind = .full
    @State private var path = ""
    @State private var compression = true
    @State private var checksum = true
    @State private var copyOnly = false
    @State private var initialize = false
    @State private var verify = false
    @State private var name = ""
    @State private var script = ""
    @State private var isRunning = false
    @State private var statusText: String?
    @State private var isError = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    LabeledContent("Backup type") {
                        Picker("", selection: $kind) {
                            Text("Full").tag(BackupRequest.Kind.full)
                            Text("Differential").tag(BackupRequest.Kind.differential)
                            Text("Transaction Log").tag(BackupRequest.Kind.log)
                        }
                        .labelsHidden()
                    }
                    LabeledContent("Destination") {
                        TextField("/var/opt/mssql/backup/\(database).bak", text: $path)
                            .textFieldStyle(.roundedBorder)
                    }
                    Text("The path is on the server's filesystem, not this Mac.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    LabeledContent("Media set name") {
                        TextField("optional", text: $name).textFieldStyle(.roundedBorder)
                    }

                    Toggle("Compress backup", isOn: $compression)
                    Toggle("Perform checksum before writing", isOn: $checksum)
                    Toggle("Copy-only backup", isOn: $copyOnly)
                    Toggle("Overwrite all existing backup sets (INIT)", isOn: $initialize)
                    Toggle("Verify backup when finished", isOn: $verify)

                    if !script.isEmpty {
                        Text("Script").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        Text(script)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(nsColor: .textBackgroundColor),
                                        in: RoundedRectangle(cornerRadius: 6))
                    }
                }
                .padding(14)
            }
            Divider()
            footer
        }
        .frame(width: 620, height: 560)
        .onAppear {
            path = "/var/opt/mssql/data/\(database)_\(Int(Date().timeIntervalSince1970)).bak"
            Task { await refreshScript() }
        }
        .onChange(of: kind) { _, _ in Task { await refreshScript() } }
        .onChange(of: path) { _, _ in Task { await refreshScript() } }
    }

    private var header: some View {
        HStack {
            Image(systemName: "externaldrive.badge.timemachine").foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("Back Up Database").font(.headline)
                Text("\(server.displayName) · \(database)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
    }

    private var footer: some View {
        HStack {
            if let statusText {
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(isError ? Color.red : Color.green)
                    .lineLimit(2)
            }
            Spacer()
            if isRunning { ProgressView().controlSize(.small) }
            Button("Script") { Task { await refreshScript() } }
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button("Back Up") { runBackup() }
                .keyboardShortcut(.defaultAction)
                .disabled(isRunning || path.isEmpty)
        }
        .padding(12)
    }

    private var request: BackupRequest {
        BackupRequest(database: database, kind: kind, path: path, compression: compression,
                      checksum: checksum, copyOnly: copyOnly, initialize: initialize,
                      name: name, backupDescription: "", verify: verify)
    }

    private func refreshScript() async {
        do {
            script = try await DatabaseAdmin(session: server.session).backupScript(request)
            isError = false
        } catch {
            script = ""
            statusText = String(describing: error)
            isError = true
        }
    }

    private func runBackup() {
        isRunning = true
        statusText = "Backing up…"
        isError = false
        Task {
            do {
                try await DatabaseAdmin(session: server.session).performBackup(request)
                statusText = "Backup completed."
            } catch {
                statusText = String(describing: error)
                isError = true
            }
            isRunning = false
        }
    }
}

/// Restore Database, driven by RESTORE HEADERONLY / FILELISTONLY.
struct RestoreSheet: View {
    @Environment(\.dismiss) private var dismiss
    let server: ConnectedServer

    @State private var path = ""
    @State private var targetDatabase = ""
    @State private var replace = false
    @State private var headers: [RestoreHeaderInfo] = []
    @State private var files: [RestoreFileInfo] = []
    @State private var script = ""
    @State private var statusText: String?
    @State private var isError = false
    @State private var isLoading = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "arrow.counterclockwise.circle").foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Restore Database").font(.headline)
                    Text(server.displayName).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(12)
            Divider()

            VStack(alignment: .leading, spacing: 10) {
                LabeledContent("Backup file (server path)") {
                    HStack {
                        TextField("/var/opt/mssql/data/backup.bak", text: $path)
                            .textFieldStyle(.roundedBorder)
                        Button("Read") { Task { await readHeader() } }
                            .disabled(path.isEmpty || isLoading)
                    }
                }
                LabeledContent("Restore as") {
                    TextField("target database", text: $targetDatabase)
                        .textFieldStyle(.roundedBorder)
                }
                Toggle("Overwrite the existing database (WITH REPLACE)", isOn: $replace)
            }
            .padding(14)

            Divider()

            if !headers.isEmpty {
                Table(headers) {
                    TableColumn("Pos") { Text("\($0.position)").monospacedDigit() }.width(44)
                    TableColumn("Name", value: \.backupName).width(160)
                    TableColumn("Type", value: \.backupType).width(90)
                    TableColumn("Database", value: \.databaseName).width(130)
                    TableColumn("Finished", value: \.backupFinishDate).width(160)
                    TableColumn("Size") { header in
                        Text(ByteCountFormatter.string(fromByteCount: header.backupSizeBytes,
                                                       countStyle: .file))
                    }.width(100)
                }
                .frame(height: 130)
                Divider()
            }

            if !files.isEmpty {
                Table(files) {
                    TableColumn("Logical name", value: \.logicalName).width(150)
                    TableColumn("Type", value: \.type).width(70)
                    TableColumn("Size (MB)") { Text(String(format: "%.0f", $0.sizeMB)) }.width(90)
                    TableColumn("Original path") { Text($0.physicalName).lineLimit(1) }
                        .width(min: 160, ideal: 280)
                }
                .frame(height: 120)
                Divider()
            }

            if !script.isEmpty {
                ScrollView {
                    Text(script)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(height: 110)
                Divider()
            }

            HStack {
                if let statusText {
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(isError ? Color.red : Color.secondary)
                        .lineLimit(2)
                }
                Spacer()
                if isLoading { ProgressView().controlSize(.small) }
                Button("Generate Script") { generateScript() }
                    .disabled(path.isEmpty || targetDatabase.isEmpty)
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .frame(width: 800, height: 640)
    }

    private func readHeader() async {
        isLoading = true
        defer { isLoading = false }
        let admin = DatabaseAdmin(session: server.session)
        do {
            headers = try await admin.readBackupHeader(path: path)
            files = try await admin.readBackupFileList(path: path)
            if targetDatabase.isEmpty { targetDatabase = headers.first?.databaseName ?? "" }
            statusText = "Read \(headers.count) backup set(s)."
            isError = false
        } catch {
            statusText = String(describing: error)
            isError = true
        }
    }

    private func generateScript() {
        let admin = DatabaseAdmin(session: server.session)
        let moves = files.map { (logical: $0.logicalName, physical: $0.physicalName) }
        script = admin.restoreScript(database: targetDatabase, fromPath: path,
                                     replace: replace, moveFiles: moves)
        statusText = "Review the script, then run it in a query window."
        isError = false
    }
}

/// Index maintenance: fragmentation report with rebuild / reorganize actions.
struct IndexMaintenanceView: View {
    @Environment(\.dismiss) private var dismiss
    let server: ConnectedServer
    let database: String

    @State private var rows: [IndexFragmentation] = []
    @State private var isLoading = false
    @State private var statusText: String?
    @State private var selection: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "wrench.and.screwdriver").foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Index Maintenance").font(.headline)
                    Text("\(server.displayName) · \(database)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await load() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(isLoading)
            }
            .padding(12)
            Divider()

            Table(rows, selection: $selection) {
                TableColumn("Schema", value: \.schema).width(90)
                TableColumn("Table", value: \.table).width(170)
                TableColumn("Index", value: \.indexName).width(190)
                TableColumn("Type", value: \.indexType).width(120)
                TableColumn("Fragmentation") { row in
                    HStack(spacing: 6) {
                        ProgressView(value: min(row.fragmentationPercent / 100, 1))
                            .frame(width: 80)
                        Text(String(format: "%.1f%%", row.fragmentationPercent)).monospacedDigit()
                    }
                }.width(160)
                TableColumn("Pages") { Text("\($0.pageCount)").monospacedDigit() }.width(80)
                TableColumn("Recommendation") { row in
                    Text(row.recommendation)
                        .foregroundStyle(row.recommendation == "REBUILD" ? Color.orange
                                         : row.recommendation == "REORGANIZE" ? Color.yellow
                                         : Color.secondary)
                }.width(130)
            }

            Divider()
            HStack {
                if let statusText { Text(statusText).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if isLoading { ProgressView().controlSize(.small) }
                Button("Reorganize Selected") { act(rebuild: false) }
                    .disabled(selection.isEmpty || isLoading)
                Button("Rebuild Selected") { act(rebuild: true) }
                    .disabled(selection.isEmpty || isLoading)
                Button("Close") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 940, height: 580)
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            rows = try await DatabaseAdmin(session: server.session)
                .indexFragmentation(database: database)
            statusText = "\(rows.count) indexes analysed."
        } catch {
            statusText = String(describing: error)
        }
    }

    private func act(rebuild: Bool) {
        let targets = rows.filter { selection.contains($0.id) }
        guard !targets.isEmpty else { return }
        isLoading = true
        Task {
            let admin = DatabaseAdmin(session: server.session)
            var done = 0
            for target in targets {
                do {
                    if rebuild {
                        try await admin.rebuildIndexes(database: database, schema: target.schema,
                                                       table: target.table, online: false)
                    } else {
                        try await admin.reorganizeIndex(database: database, schema: target.schema,
                                                        table: target.table, index: target.indexName)
                    }
                    done += 1
                } catch {
                    statusText = String(describing: error)
                }
            }
            statusText = "\(done) of \(targets.count) index operations completed."
            isLoading = false
            await load()
        }
    }
}
