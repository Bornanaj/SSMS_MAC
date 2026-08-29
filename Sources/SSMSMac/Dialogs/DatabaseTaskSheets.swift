import SwiftUI
import AppKit
import SQLServerKit

/// New Database: the General page of the SSMS dialog, plus Script.
struct NewDatabaseSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    let server: ConnectedServer

    @State private var options = NewDatabaseOptions()
    @State private var collations: [String] = []
    @State private var useDefaultPaths = true
    @State private var isWorking = false
    @State private var errorText: String?

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "New Database", subtitle: server.displayName, symbol: "cylinder.split.1x2")
            Divider()
            Form {
                Section("General") {
                    TextField("Database name", text: $options.name)
                    TextField("Owner (blank = the current login)", text: $options.owner)
                    Picker("Collation", selection: $options.collation) {
                        Text("<server default>").tag("")
                        ForEach(collations, id: \.self) { Text($0).tag($0) }
                    }
                    Picker("Recovery model", selection: $options.recoveryModel) {
                        Text("<model default>").tag("")
                        Text("Full").tag("FULL")
                        Text("Simple").tag("SIMPLE")
                        Text("Bulk-logged").tag("BULK_LOGGED")
                    }
                    Picker("Compatibility level", selection: $options.compatibilityLevel) {
                        Text("<model default>").tag(0)
                        ForEach([100, 110, 120, 130, 140, 150, 160, 170], id: \.self) { level in
                            Text("\(level)").tag(level)
                        }
                    }
                }

                Section("Files") {
                    Toggle("Let SQL Server choose the file paths", isOn: $useDefaultPaths)
                    if !useDefaultPaths {
                        TextField("Data logical name", text: $options.dataFileName,
                                  prompt: Text(options.effectiveDataFileName))
                        TextField("Data file path (server side)", text: $options.dataFilePath)
                        HStack {
                            TextField("Size (MB)", value: $options.dataFileSizeMB, format: .number)
                            TextField("Growth (MB)", value: $options.dataFileGrowthMB, format: .number)
                            TextField("Max (MB, 0 = unlimited)",
                                      value: $options.dataFileMaxSizeMB, format: .number)
                        }
                        Divider()
                        TextField("Log logical name", text: $options.logFileName,
                                  prompt: Text(options.effectiveLogFileName))
                        TextField("Log file path (server side)", text: $options.logFilePath)
                        HStack {
                            TextField("Size (MB)", value: $options.logFileSizeMB, format: .number)
                            TextField("Growth (MB)", value: $options.logFileGrowthMB, format: .number)
                            TextField("Max (MB, 0 = unlimited)",
                                      value: $options.logFileMaxSizeMB, format: .number)
                        }
                        Text("These paths are read by the server, not by this Mac.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)

            if let errorText {
                SheetError(text: errorText)
            }
            Divider()
            HStack {
                Button("Script") { script() }
                    .disabled(options.name.isEmpty)
                Spacer()
                if isWorking { ProgressView().controlSize(.small) }
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create") { Task { await create() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(options.name.isEmpty || isWorking)
            }
            .padding(12)
        }
        .frame(width: 640, height: 560)
        .task { await loadCollations() }
    }

    private var effectiveOptions: NewDatabaseOptions {
        guard useDefaultPaths else { return options }
        var copy = options
        copy.dataFilePath = ""
        copy.logFilePath = ""
        return copy
    }

    private func script() {
        do {
            let sql = try ObjectAdmin.createDatabaseScript(effectiveOptions)
            app.activeSheet = .scriptPreview("Create Database", sql)
        } catch {
            errorText = String(describing: error)
        }
    }

    private func create() async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await ObjectAdmin(session: server.session).createDatabase(effectiveOptions)
            app.statusMessage = "Created database \(options.name)."
            await refreshDatabasesFolder(server: server, app: app)
            dismiss()
        } catch {
            errorText = String(describing: error)
        }
    }

    private func loadCollations() async {
        collations = (try? await ObjectAdmin(session: server.session).collations()) ?? []
    }
}

/// Attach Database: pick the .mdf plus any secondary files.
struct AttachDatabaseSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    let server: ConnectedServer

    @State private var databaseName = ""
    @State private var files: [AttachFile] = []
    @State private var pathDraft = ""
    @State private var isWorking = false
    @State private var errorText: String?

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "Attach Database", subtitle: server.displayName,
                        symbol: "externaldrive.badge.plus")
            Divider()
            Form {
                Section("Database") {
                    TextField("Attach as", text: $databaseName)
                    Text("The paths below are on the server's file system.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Files") {
                    HStack {
                        TextField("Full path to .mdf / .ndf / .ldf", text: $pathDraft)
                            .onSubmit { addPath() }
                        Button("Add") { addPath() }
                            .disabled(pathDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    if files.isEmpty {
                        Text("Add at least the primary data file.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(files) { file in
                            HStack {
                                Image(systemName: "doc")
                                Text(file.path).lineLimit(1).truncationMode(.head)
                                Spacer()
                                Button {
                                    files.removeAll { $0.path == file.path }
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)

            if let errorText { SheetError(text: errorText) }
            Divider()
            HStack {
                Button("Script") { script() }.disabled(!canAttach)
                Spacer()
                if isWorking { ProgressView().controlSize(.small) }
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Attach") { Task { await attach() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canAttach || isWorking)
            }
            .padding(12)
        }
        .frame(width: 620, height: 480)
    }

    private var canAttach: Bool {
        !databaseName.trimmingCharacters(in: .whitespaces).isEmpty && !files.isEmpty
    }

    private func addPath() {
        let trimmed = pathDraft.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !files.contains(where: { $0.path == trimmed }) else { return }
        files.append(AttachFile(path: trimmed))
        // Attaching almost always starts from the .mdf, so its base name is a good guess.
        if databaseName.isEmpty, trimmed.lowercased().hasSuffix(".mdf") {
            databaseName = (trimmed as NSString).lastPathComponent
                .replacingOccurrences(of: ".mdf", with: "", options: .caseInsensitive)
        }
        pathDraft = ""
    }

    private func script() {
        do {
            let sql = try ObjectAdmin.attachScript(database: databaseName, files: files)
            app.activeSheet = .scriptPreview("Attach Database", sql)
        } catch {
            errorText = String(describing: error)
        }
    }

    private func attach() async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await ObjectAdmin(session: server.session).attach(database: databaseName, files: files)
            app.statusMessage = "Attached \(databaseName)."
            await refreshDatabasesFolder(server: server, app: app)
            dismiss()
        } catch {
            errorText = String(describing: error)
        }
    }
}

/// Detach Database, with the drop-connections and update-statistics options.
struct DetachDatabaseSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    let server: ConnectedServer
    let database: String

    @State private var dropConnections = true
    @State private var updateStatistics = false
    @State private var isWorking = false
    @State private var errorText: String?

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "Detach Database", subtitle: database,
                        symbol: "eject")
            Divider()
            Form {
                Section {
                    Toggle("Drop existing connections", isOn: $dropConnections)
                    Toggle("Update statistics before detaching", isOn: $updateStatistics)
                } footer: {
                    Text("A detached database stays on disk. Reattach it with Databases → "
                         + "Attach, using the same files.")
                        .font(.caption)
                }
            }
            .formStyle(.grouped)

            if let errorText { SheetError(text: errorText) }
            Divider()
            HStack {
                Button("Script") {
                    app.activeSheet = .scriptPreview(
                        "Detach \(database)",
                        ObjectAdmin.detachScript(database: database,
                                                 dropConnections: dropConnections,
                                                 updateStatistics: updateStatistics))
                }
                Spacer()
                if isWorking { ProgressView().controlSize(.small) }
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Detach") { Task { await detach() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isWorking)
            }
            .padding(12)
        }
        .frame(width: 560, height: 330)
    }

    private func detach() async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await ObjectAdmin(session: server.session)
                .detach(database: database, dropConnections: dropConnections,
                        updateStatistics: updateStatistics)
            app.statusMessage = "Detached \(database)."
            await refreshDatabasesFolder(server: server, app: app)
            dismiss()
        } catch {
            errorText = String(describing: error)
        }
    }
}

/// Shrink Database / Shrink Files, with the space report SSMS shows above the controls.
struct ShrinkDatabaseSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    let server: ConnectedServer
    let database: String

    @State private var properties: DatabaseProperties?
    @State private var scope = "database"
    @State private var selectedFile: String = ""
    @State private var mode: ObjectAdmin.ShrinkMode = .reorganize
    @State private var targetPercent = 10
    @State private var targetMB = 0
    @State private var output: [String] = []
    @State private var isWorking = false
    @State private var errorText: String?

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "Shrink", subtitle: database, symbol: "arrow.down.right.and.arrow.up.left")
            Divider()
            Picker("", selection: $scope) {
                Text("Database").tag("database")
                Text("Files").tag("files")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)
            Divider()

            if let properties {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        spaceReport(properties)
                        if scope == "database" {
                            databaseControls
                        } else {
                            fileControls(properties)
                        }
                        if !output.isEmpty {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Output").font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                ForEach(Array(output.enumerated()), id: \.offset) { _, line in
                                    Text(line)
                                        .font(.system(.caption, design: .monospaced))
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if let errorText {
                SheetError(text: errorText)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider()
            HStack {
                Button("Script") { script() }
                Spacer()
                if isWorking { ProgressView().controlSize(.small) }
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Shrink") { Task { await shrink() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isWorking || (scope == "files" && selectedFile.isEmpty))
            }
            .padding(12)
        }
        .frame(width: 680, height: 580)
        .task { await load() }
    }

    private func spaceReport(_ p: DatabaseProperties) -> some View {
        PropertyGrid(rows: [
            ("Database size", String(format: "%.2f MB", p.sizeMB)),
            ("Available free space", String(format: "%.2f MB", p.spaceAvailableMB)),
            ("Files", "\(p.files.count)"),
            ("Recovery model", p.recoveryModel)
        ])
        .background(Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 8))
    }

    private var databaseControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Shrink the whole database").font(.headline)
            Stepper("Leave \(targetPercent)% free space after shrinking",
                    value: $targetPercent, in: 0...99)
            Text("DBCC SHRINKDATABASE moves pages to the front of each file. It fragments "
                 + "indexes, so plan a rebuild afterwards.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func fileControls(_ p: DatabaseProperties) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Shrink a single file").font(.headline)
            Picker("File", selection: $selectedFile) {
                Text("<choose>").tag("")
                ForEach(p.files) { file in
                    Text("\(file.name) — \(file.type), \(Int(file.sizeMB)) MB").tag(file.name)
                }
            }
            Picker("Action", selection: $mode) {
                ForEach(ObjectAdmin.ShrinkMode.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            if mode == .reorganize {
                TextField("Target size (MB, 0 = as small as possible)",
                          value: $targetMB, format: .number)
            }
        }
    }

    private func script() {
        if scope == "database" {
            let percent = min(max(targetPercent, 0), 99)
            app.activeSheet = .scriptPreview(
                "Shrink \(database)",
                "USE \(SQLIdentifier.quote(database));\nGO\n"
                    + "DBCC SHRINKDATABASE (\(SQLIdentifier.literal(database)), \(percent));\nGO\n")
        } else {
            guard !selectedFile.isEmpty else { return }
            app.activeSheet = .scriptPreview(
                "Shrink \(selectedFile)",
                "USE \(SQLIdentifier.quote(database));\nGO\n"
                    + ObjectAdmin.shrinkFileScript(logicalName: selectedFile,
                                                   targetMB: targetMB, mode: mode) + "\nGO\n")
        }
    }

    private func shrink() async {
        isWorking = true
        defer { isWorking = false }
        output = []
        do {
            if scope == "database" {
                try await DatabaseAdmin(session: server.session)
                    .shrinkDatabase(database, targetPercent: targetPercent)
                output = ["DBCC SHRINKDATABASE completed for '\(database)'."]
            } else {
                output = try await ObjectAdmin(session: server.session)
                    .shrinkFile(database: database, logicalName: selectedFile,
                                targetMB: targetMB, mode: mode)
            }
            await load()
        } catch {
            errorText = String(describing: error)
            output = [String(describing: error)]
        }
    }

    private func load() async {
        do {
            properties = try await DatabaseAdmin(session: server.session)
                .properties(database: database)
            errorText = nil
        } catch {
            errorText = String(describing: error)
        }
    }
}

// MARK: - Shared sheet chrome

/// The title bar every task sheet uses, so they all look the same.
struct SheetHeader: View {
    let title: String
    let subtitle: String
    let symbol: String

    var body: some View {
        HStack {
            Image(systemName: symbol).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.headline)
                if !subtitle.isEmpty {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(12)
    }
}

struct SheetError: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            Text(text)
                .font(.caption)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.red.opacity(0.08))
    }
}

/// After creating, attaching or detaching, the Databases folder is stale.
@MainActor
func refreshDatabasesFolder(server: ConnectedServer, app: AppState) async {
    let root = app.explorer.roots.first { $0.id.hasPrefix(server.id.uuidString) }
    guard let root else { return }
    for child in app.explorer.children(of: root) where child.folder == .databases {
        await app.explorer.refresh(child)
        return
    }
    await app.explorer.refresh(root)
}
