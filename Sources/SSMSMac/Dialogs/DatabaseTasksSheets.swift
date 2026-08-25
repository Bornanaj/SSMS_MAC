import AppKit
import SwiftUI
import SQLServerKit

// MARK: - Detach

/// Database > Tasks > Detach. The database is unregistered from the server while its
/// files stay on disk, so the file list is shown: those paths are what Attach needs later.
struct DetachDatabaseSheet: View {
    @Environment(\.dismiss) private var dismiss

    let server: ConnectedServer
    let database: String

    @State private var dropConnections = true
    @State private var updateStatistics = false
    @State private var files: [AttachableFile] = []
    @State private var script = ""
    @State private var statusText: String?
    @State private var isError = false
    @State private var isRunning = false
    @State private var isLoadingFiles = false
    @State private var isConfirming = false
    @State private var didDetach = false

    var body: some View {
        VStack(spacing: 0) {
            TaskSheetHeader(icon: "eject", title: "Detach Database",
                            subtitle: "\(server.displayName) · \(database)")
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Detaching removes \(database) from the server. The data and log files "
                         + "are left on the server's disk, and the database can be brought back "
                         + "with Attach.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Toggle("Drop existing connections (SINGLE_USER WITH ROLLBACK IMMEDIATE)",
                           isOn: $dropConnections)
                    Toggle("Update statistics before detaching", isOn: $updateStatistics)

                    filesSection
                    TaskScriptBox(script: script, height: 130)
                }
                .padding(14)
            }
            Divider()
            footer
        }
        .frame(width: 660, height: 620)
        .onAppear {
            refreshScript()
            Task { await loadFiles() }
        }
        .onChange(of: dropConnections) { _, _ in refreshScript() }
        .onChange(of: updateStatistics) { _, _ in refreshScript() }
        .confirmationDialog("Detach \(database)?", isPresented: $isConfirming,
                            titleVisibility: .visible) {
            Button("Detach Database", role: .destructive) { runDetach() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("The database disappears from \(server.displayName) until someone attaches its "
                 + "files again. Open sessions in it are terminated when Drop existing "
                 + "connections is on.")
        }
    }

    @ViewBuilder
    private var filesSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("Files that will stay on disk")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                if isLoadingFiles { ProgressView().controlSize(.small) }
                Spacer()
                Button("Copy Paths") { copyPaths() }
                    .buttonStyle(.link)
                    .disabled(files.isEmpty)
            }
            if files.isEmpty {
                Text(isLoadingFiles ? "Reading sys.master_files…"
                                    : "No files were reported for this database.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(files) { file in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(file.logicalName)
                                .font(.caption.weight(.medium))
                                .frame(width: 130, alignment: .leading)
                            Text(file.type.title)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: 70, alignment: .leading)
                            Text(file.path)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 0)
                        }
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .textBackgroundColor),
                            in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private var footer: some View {
        HStack {
            if let statusText {
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(isError ? Color.red : Color.secondary)
                    .lineLimit(2)
            }
            Spacer()
            if isRunning { ProgressView().controlSize(.small) }
            Button(didDetach ? "Close" : "Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Detach") { isConfirming = true }
                .keyboardShortcut(.defaultAction)
                .disabled(isRunning || didDetach)
        }
        .padding(12)
    }

    private func refreshScript() {
        let tasks = DatabaseTasks(session: server.session)
        script = tasks.detachScript(database: database,
                                    dropConnections: dropConnections,
                                    updateStatistics: updateStatistics)
    }

    private func loadFiles() async {
        isLoadingFiles = true
        defer { isLoadingFiles = false }
        do {
            files = try await DatabaseTasks(session: server.session).filesFor(database: database)
        } catch {
            statusText = String(describing: error)
            isError = true
        }
    }

    private func copyPaths() {
        let text: String = files.map(\.path).joined(separator: "\n")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        statusText = "Copied \(files.count) path(s) to the clipboard."
        isError = false
    }

    private func runDetach() {
        isRunning = true
        isError = false
        statusText = "Detaching \(database)…"
        Task {
            let tasks = DatabaseTasks(session: server.session)
            do {
                try await tasks.detach(database: database,
                                       dropConnections: dropConnections,
                                       updateStatistics: updateStatistics)
                statusText = "\(database) was detached. Refresh Object Explorer to see it go."
                didDetach = true
            } catch {
                statusText = String(describing: error)
                isError = true
            }
            isRunning = false
        }
    }
}

// MARK: - Attach

/// Database > Tasks > Attach. Paths are typed rather than browsed: the engine opens the
/// files, so anything this Mac can see is irrelevant unless it is also the server.
struct AttachDatabaseSheet: View {
    @Environment(\.dismiss) private var dismiss

    let server: ConnectedServer

    @State private var databaseName = ""
    @State private var rows: [AttachFileRow] = []
    @State private var newPath = ""
    @State private var newKind: AttachableFile.Kind = .data
    @State private var script = ""
    @State private var statusText: String?
    @State private var isError = false
    @State private var isRunning = false
    @State private var isConfirming = false
    @State private var didAttach = false

    var body: some View {
        VStack(spacing: 0) {
            TaskSheetHeader(icon: "square.and.arrow.down", title: "Attach Database",
                            subtitle: server.displayName)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    LabeledContent("Attach as") {
                        TextField("database name", text: $databaseName)
                            .textFieldStyle(.roundedBorder)
                    }

                    Text("SQL Server opens these files itself, so the paths must be valid on the "
                         + "server's filesystem. There is nothing to browse from this Mac — type "
                         + "the path as the server sees it, for example "
                         + "/var/opt/mssql/data/AdventureWorks.mdf.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    addFileRow
                    fileTable
                    TaskScriptBox(script: script, height: 140)
                }
                .padding(14)
            }
            Divider()
            footer
        }
        .frame(width: 700, height: 640)
        .onAppear { refreshScript() }
        .onChange(of: databaseName) { _, _ in refreshScript() }
        .onChange(of: rows) { _, _ in refreshScript() }
        .onChange(of: newPath) { _, path in guessKind(from: path) }
        .confirmationDialog("Attach \(displayName)?", isPresented: $isConfirming,
                            titleVisibility: .visible) {
            Button("Attach Database", role: .destructive) { runAttach() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("CREATE DATABASE ... FOR ATTACH opens the listed files in place and can "
                 + "upgrade them to this server's version, which cannot be undone.")
        }
    }

    private var displayName: String {
        databaseName.isEmpty ? "database" : databaseName
    }

    private var addFileRow: some View {
        HStack(spacing: 8) {
            TextField("/var/opt/mssql/data/Example.mdf", text: $newPath)
                .textFieldStyle(.roundedBorder)
            Picker("", selection: $newKind) {
                ForEach(AttachableFile.Kind.allCases, id: \.self) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            .labelsHidden()
            .frame(width: 130)
            Button("Add File") { addFile() }
                .disabled(newPath.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    @ViewBuilder
    private var fileTable: some View {
        if rows.isEmpty {
            Text("No files yet. The primary data file (.mdf) is required; add the log file too "
                 + "unless you want the server to build a new one.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(rows) { row in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(row.path)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 4)
                        Text(row.kind.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 80, alignment: .leading)
                        Button("Remove") { remove(row) }
                            .buttonStyle(.link)
                    }
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .textBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private var footer: some View {
        HStack {
            if let statusText {
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(isError ? Color.red : Color.secondary)
                    .lineLimit(2)
            }
            Spacer()
            if isRunning { ProgressView().controlSize(.small) }
            Button(didAttach ? "Close" : "Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Attach") { isConfirming = true }
                .keyboardShortcut(.defaultAction)
                .disabled(isRunning || didAttach || rows.isEmpty || databaseName.isEmpty)
        }
        .padding(12)
    }

    private var attachableFiles: [AttachableFile] {
        rows.map { row in
            AttachableFile(path: row.path, type: row.kind, logicalName: row.logicalName)
        }
    }

    private func addFile() {
        let path = newPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return }
        rows.append(AttachFileRow(path: path, kind: newKind, logicalName: ""))
        if databaseName.isEmpty, newKind == .data {
            // SSMS proposes the primary file's own name, which is right far more often than not.
            let base: String = (path as NSString).lastPathComponent
            databaseName = (base as NSString).deletingPathExtension
        }
        newPath = ""
        statusText = nil
        isError = false
    }

    private func remove(_ row: AttachFileRow) {
        rows.removeAll { $0.id == row.id }
    }

    /// The extension is the only hint available before the server has seen the file.
    private func guessKind(from path: String) {
        let suffix: String = (path as NSString).pathExtension.lowercased()
        switch suffix {
        case "ldf": newKind = .log
        case "mdf", "ndf": newKind = .data
        default: break
        }
    }

    private func refreshScript() {
        let tasks = DatabaseTasks(session: server.session)
        script = tasks.attachScript(databaseName: databaseName, files: attachableFiles)
    }

    private func runAttach() {
        isRunning = true
        isError = false
        statusText = "Attaching \(databaseName)…"
        Task {
            let tasks = DatabaseTasks(session: server.session)
            do {
                try await tasks.attach(databaseName: databaseName, files: attachableFiles)
                statusText = "\(databaseName) was attached."
                didAttach = true
            } catch {
                statusText = String(describing: error)
                isError = true
            }
            isRunning = false
        }
    }
}

/// Rows carry their own identity so two blank or duplicated paths stay editable.
private struct AttachFileRow: Identifiable, Hashable {
    let id = UUID()
    var path: String
    var kind: AttachableFile.Kind
    var logicalName: String
}

// MARK: - Shrink

private enum ShrinkTarget: String, CaseIterable, Identifiable {
    case database
    case file

    var id: String { rawValue }

    var title: String {
        switch self {
        case .database: return "Whole database"
        case .file: return "Single file"
        }
    }
}

/// Database > Tasks > Shrink. Shrinking moves pages around and fragments indexes, so the
/// script is always shown and confirmed before it runs.
struct ShrinkDatabaseSheet: View {
    @Environment(\.dismiss) private var dismiss

    let server: ConnectedServer
    let database: String

    @State private var target: ShrinkTarget = .database
    @State private var targetPercent = 10
    @State private var releaseSpace = false
    @State private var files: [AttachableFile] = []
    @State private var selectedFile = ""
    @State private var targetMB = 0
    @State private var script = ""
    @State private var output: [String] = []
    @State private var statusText: String?
    @State private var isError = false
    @State private var isRunning = false
    @State private var isLoadingFiles = false
    @State private var isConfirming = false

    var body: some View {
        VStack(spacing: 0) {
            TaskSheetHeader(icon: "arrow.down.right.and.arrow.up.left", title: "Shrink",
                            subtitle: "\(server.displayName) · \(database)")
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Shrink", selection: $target) {
                        ForEach(ShrinkTarget.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    if target == .database {
                        databaseOptions
                    } else {
                        fileOptions
                    }

                    Text("Shrinking rewrites pages and leaves indexes fragmented. SSMS only "
                         + "recommends it after a one-off deletion, never on a schedule.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    TaskScriptBox(script: script, height: 110)
                    TaskOutputBox(lines: output)
                }
                .padding(14)
            }
            Divider()
            footer
        }
        .frame(width: 660, height: 640)
        .onAppear { refreshScript() }
        .task { await loadFiles() }
        .onChange(of: target) { _, _ in refreshScript() }
        .onChange(of: targetPercent) { _, _ in refreshScript() }
        .onChange(of: releaseSpace) { _, _ in refreshScript() }
        .onChange(of: selectedFile) { _, _ in refreshScript() }
        .onChange(of: targetMB) { _, _ in refreshScript() }
        .confirmationDialog("Run this shrink on \(database)?", isPresented: $isConfirming,
                            titleVisibility: .visible) {
            Button("Shrink", role: .destructive) { runShrink() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("The operation holds locks while it moves pages and can take a long time on a "
                 + "large database.")
        }
    }

    @ViewBuilder
    private var databaseOptions: some View {
        Toggle("Release unused space only (TRUNCATEONLY, no page movement)", isOn: $releaseSpace)
        LabeledContent("Free space to leave after shrinking") {
            HStack(spacing: 8) {
                Stepper(value: $targetPercent, in: 0...99) {
                    Text("\(targetPercent)%").monospacedDigit()
                }
                .disabled(releaseSpace)
                if releaseSpace {
                    Text("ignored by TRUNCATEONLY")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var fileOptions: some View {
        LabeledContent("File") {
            HStack(spacing: 8) {
                Picker("", selection: $selectedFile) {
                    if files.isEmpty { Text("no files loaded").tag("") }
                    ForEach(files) { file in
                        Text("\(file.logicalName) (\(file.type.title))").tag(file.logicalName)
                    }
                }
                .labelsHidden()
                if isLoadingFiles { ProgressView().controlSize(.small) }
            }
        }
        LabeledContent("Target size") {
            HStack(spacing: 8) {
                TextField("MB", value: $targetMB, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
                Text("MB, 0 shrinks as far as the data allows")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var footer: some View {
        HStack {
            if let statusText {
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(isError ? Color.red : Color.secondary)
                    .lineLimit(2)
            }
            Spacer()
            if isRunning { ProgressView().controlSize(.small) }
            Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            Button("Shrink") { isConfirming = true }
                .keyboardShortcut(.defaultAction)
                .disabled(isRunning || (target == .file && selectedFile.isEmpty))
        }
        .padding(12)
    }

    private func refreshScript() {
        let tasks = DatabaseTasks(session: server.session)
        switch target {
        case .database:
            script = tasks.shrinkDatabaseScript(database,
                                                targetPercent: targetPercent,
                                                releaseSpace: releaseSpace)
        case .file:
            guard !selectedFile.isEmpty else {
                script = "-- Choose a file to shrink.\n"
                return
            }
            script = tasks.shrinkFileScript(database: database,
                                            logicalName: selectedFile,
                                            targetMB: targetMB)
        }
    }

    private func loadFiles() async {
        isLoadingFiles = true
        defer { isLoadingFiles = false }
        do {
            let loaded = try await DatabaseTasks(session: server.session).filesFor(database: database)
            files = loaded
            if selectedFile.isEmpty, let first = loaded.first {
                selectedFile = first.logicalName
            }
        } catch {
            statusText = String(describing: error)
            isError = true
        }
    }

    private func runShrink() {
        isRunning = true
        isError = false
        output = []
        statusText = "Shrinking…"
        let text = script
        Task {
            let tasks = DatabaseTasks(session: server.session)
            do {
                let lines = try await tasks.runScript(text, database: database)
                output = lines
                statusText = lines.isEmpty ? "Shrink completed."
                                           : "Shrink completed with \(lines.count) message(s)."
            } catch {
                statusText = String(describing: error)
                isError = true
            }
            isRunning = false
        }
    }
}

// MARK: - Disk usage

/// Database > Reports > Disk Usage, in the shape SSMS shows it: the sp_spaceused summary
/// plus how full each file currently is.
struct DiskUsageSheet: View {
    @Environment(\.dismiss) private var dismiss

    let server: ConnectedServer
    let database: String

    @State private var rows: [DiskUsageRow] = []
    @State private var statusText: String?
    @State private var isError = false
    @State private var isLoading = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TaskSheetHeader(icon: "internaldrive", title: "Disk Usage",
                                subtitle: "\(server.displayName) · \(database)")
                Spacer()
                Button { Task { await load() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(isLoading)
                .padding(.trailing, 12)
            }
            Divider()

            Table(rows) {
                TableColumn("Measure") { row in
                    Text(row.name)
                }
                .width(min: 160, ideal: 240)
                TableColumn("Value") { row in
                    Text(row.value).monospacedDigit().textSelection(.enabled)
                }
                .width(min: 160, ideal: 260)
            }

            Divider()
            HStack {
                if let statusText {
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(isError ? Color.red : Color.secondary)
                        .lineLimit(2)
                }
                Spacer()
                if isLoading { ProgressView().controlSize(.small) }
                Button("Copy Report") { copyReport() }
                    .disabled(rows.isEmpty)
                Button("Close") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 620, height: 520)
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let pairs = try await DatabaseTasks(session: server.session).diskUsage(database: database)
            rows = pairs.map { DiskUsageRow(name: $0.name, value: $0.value) }
            statusText = "Read at \(Self.timestampFormatter.string(from: Date()))."
            isError = false
        } catch {
            statusText = String(describing: error)
            isError = true
        }
    }

    private func copyReport() {
        let text: String = rows.map { "\($0.name)\t\($0.value)" }.joined(separator: "\n")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        statusText = "Report copied to the clipboard."
        isError = false
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()
}

private struct DiskUsageRow: Identifiable, Hashable {
    let id = UUID()
    var name: String
    var value: String
}

// MARK: - Shared pieces

private struct TaskSheetHeader: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack {
            Image(systemName: icon).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
    }
}

private struct TaskScriptBox: View {
    let script: String
    let height: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Script").font(.caption.weight(.medium)).foregroundStyle(.secondary)
            ScrollView {
                Text(script)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(height: height)
            .background(Color(nsColor: .textBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 6))
        }
    }
}

private struct TaskOutputBox: View {
    let lines: [String]

    var body: some View {
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Server messages").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(8)
                }
                .frame(height: 110)
                .background(Color(nsColor: .textBackgroundColor),
                            in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }
}
