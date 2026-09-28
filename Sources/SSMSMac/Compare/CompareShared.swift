import SwiftUI
import AppKit
import UniformTypeIdentifiers
import TDSKit
import SQLServerKit

// MARK: - Launch

/// What a compare window opens with. The token makes every "New Comparison" a new window,
/// because a window group reuses the window whose value is equal.
struct CompareLaunch: Codable, Hashable {
    var token = UUID()
    var serverID: UUID?
    var database: String?
    var projectPath: String?
}

// MARK: - Sessions

/// Sessions a compare window uses. Servers already connected in the main window are
/// borrowed; saved connections are opened here with their keychain password and closed
/// when the window goes away.
@MainActor
final class CompareSessionPool {
    private var owned: [UUID: SQLServerSession] = [:]

    func session(for endpoint: CompareEndpoint, app: AppState) async throws -> SQLServerSession {
        guard let profile = endpoint.connection else {
            throw SQLServerError.invalidProfile("Choose a server.")
        }
        if let server = app.server(id: profile.id) { return server.session }
        if let server = app.servers.first(where: {
            $0.profile.server.caseInsensitiveCompare(profile.server) == .orderedSame
                && $0.profile.username.caseInsensitiveCompare(profile.username) == .orderedSame
        }) {
            return server.session
        }
        if let existing = owned[profile.id], !(await existing.isClosed) { return existing }
        let password = await app.connections.password(for: profile)
        if profile.authentication.needsPassword && (password ?? "").isEmpty {
            throw SQLServerError.invalidProfile(
                "No saved password for \(profile.displayName). Connect to it from File → Connect to Server first.")
        }
        let session = try await SQLServerSession.connect(profile: profile, password: password)
        owned[profile.id] = session
        return session
    }

    func closeAll() {
        let sessions = Array(owned.values)
        owned.removeAll()
        Task {
            for session in sessions { await session.close() }
        }
    }
}

// MARK: - Endpoint selection

/// Editable state behind one side of a comparison.
@MainActor
final class EndpointSelection: ObservableObject {
    @Published var kind: CompareEndpoint.Kind
    @Published var profile: ConnectionProfile?
    @Published var database: String
    @Published var path: String
    @Published var databases: [String] = []
    @Published var isLoadingDatabases = false
    @Published var loadError: String?

    init(_ endpoint: CompareEndpoint = CompareEndpoint()) {
        kind = endpoint.kind
        profile = endpoint.connection
        database = endpoint.database
        path = endpoint.path
    }

    var endpoint: CompareEndpoint {
        CompareEndpoint(kind: kind, connection: kind == .database ? profile : nil,
                        database: kind == .database ? database : "", path: kind == .database ? "" : path)
    }

    func apply(_ endpoint: CompareEndpoint) {
        kind = endpoint.kind
        profile = endpoint.connection
        database = endpoint.database
        path = endpoint.path
    }

    var isComplete: Bool { endpoint.isComplete }

    func loadDatabases(app: AppState, pool: CompareSessionPool) async {
        guard kind == .database, profile != nil else { return }
        isLoadingDatabases = true
        loadError = nil
        defer { isLoadingDatabases = false }
        do {
            let session = try await pool.session(for: endpoint, app: app)
            let result = try await session.metadataQuery(
                "SELECT name FROM sys.databases WHERE HAS_DBACCESS(name) = 1 AND state = 0 ORDER BY name")
            databases = (result.resultSets.first?.dictionaries() ?? []).map { $0.string("name") }
        } catch {
            loadError = String(describing: error)
            databases = []
        }
    }
}

/// Server, database, snapshot or folder picker for one side of a comparison.
struct CompareEndpointPicker: View {
    @EnvironmentObject var app: AppState
    let title: String
    @ObservedObject var selection: EndpointSelection
    let pool: CompareSessionPool
    var allowedKinds: [CompareEndpoint.Kind] = CompareEndpoint.Kind.allCases

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            if allowedKinds.count > 1 {
                Picker("Type", selection: $selection.kind) {
                    ForEach(allowedKinds, id: \.self) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            switch selection.kind {
            case .database:
                databaseFields
            case .snapshot:
                pathField(placeholder: "Snapshot file (.\(SchemaSnapshotFile.fileExtension))", directory: false)
            case .scriptsFolder:
                pathField(placeholder: "Scripts folder", directory: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var databaseFields: some View {
        Menu {
            if !app.servers.isEmpty {
                Section("Connected") {
                    ForEach(app.servers) { server in
                        Button(server.displayName) { choose(server.profile) }
                    }
                }
            }
            if !app.connections.profiles.isEmpty {
                Section("Saved connections") {
                    ForEach(app.connections.profiles) { profile in
                        Button(profile.displayName) { choose(profile) }
                    }
                }
            }
        } label: {
            Label(selection.profile?.displayName ?? "Choose a server", systemImage: "server.rack")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        HStack {
            if selection.databases.isEmpty {
                TextField("Database", text: $selection.database)
                    .textFieldStyle(.roundedBorder)
            } else {
                Picker("Database", selection: $selection.database) {
                    if !selection.databases.contains(selection.database) {
                        Text(selection.database.isEmpty ? "Choose…" : selection.database).tag(selection.database)
                    }
                    ForEach(selection.databases, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .labelsHidden()
            }
            if selection.isLoadingDatabases {
                ProgressView().controlSize(.small)
            } else {
                Button {
                    Task { await selection.loadDatabases(app: app, pool: pool) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Reload the database list")
                .disabled(selection.profile == nil)
            }
        }
        if let error = selection.loadError {
            Text(error).font(.caption).foregroundStyle(.red).lineLimit(3)
        }
    }

    private func pathField(placeholder: String, directory: Bool) -> some View {
        HStack {
            TextField(placeholder, text: $selection.path)
                .textFieldStyle(.roundedBorder)
            Button("Choose…") {
                if let url = CompareFilePanels.open(directory: directory,
                                                    types: directory ? [] : [CompareFilePanels.snapshotType]) {
                    selection.path = url.path
                }
            }
        }
    }

    private func choose(_ profile: ConnectionProfile) {
        selection.profile = profile
        if selection.database.isEmpty { selection.database = profile.database }
        Task { await selection.loadDatabases(app: app, pool: pool) }
    }
}

// MARK: - File panels

enum CompareFilePanels {
    static let snapshotType = UTType(filenameExtension: SchemaSnapshotFile.fileExtension, conformingTo: .json) ?? .json
    static let schemaProjectType = UTType(filenameExtension: "scmp", conformingTo: .json) ?? .json
    static let dataProjectType = UTType(filenameExtension: "dcmp", conformingTo: .json) ?? .json
    static let sqlType = UTType(filenameExtension: "sql", conformingTo: .plainText) ?? .plainText

    @MainActor
    static func open(directory: Bool, types: [UTType]) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = directory
        panel.canChooseFiles = !directory
        panel.canCreateDirectories = directory
        panel.allowsMultipleSelection = false
        if !types.isEmpty { panel.allowedContentTypes = types }
        return panel.runModal() == .OK ? panel.url : nil
    }

    @MainActor
    static func save(name: String, types: [UTType]) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.canCreateDirectories = true
        if !types.isEmpty { panel.allowedContentTypes = types }
        return panel.runModal() == .OK ? panel.url : nil
    }

    @MainActor
    static func chooseFolder(prompt: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = prompt
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func reportType(_ format: CompareReportFormat) -> UTType {
        switch format {
        case .html: return .html
        case .xml: return .xml
        case .json: return .json
        case .csv: return .commaSeparatedText
        case .excel: return UTType(filenameExtension: "xlsx") ?? .data
        }
    }
}

// MARK: - Script text

/// Read-only, syntax-coloured T-SQL for script previews.
struct ScriptTextView: NSViewRepresentable {
    let text: String
    @ObservedObject var settings: AppSettings

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.hasHorizontalScroller = true
        if let textView = scrollView.documentView as? NSTextView {
            textView.isEditable = false
            textView.isSelectable = true
            textView.isRichText = false
            textView.usesFindBar = true
            textView.isIncrementalSearchingEnabled = true
            textView.textContainerInset = NSSize(width: 6, height: 6)
            textView.textContainer?.widthTracksTextView = false
            textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                           height: CGFloat.greatestFiniteMagnitude)
            textView.isHorizontallyResizable = true
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        let palette = Theme.palette(for: textView.effectiveAppearance)
        if context.coordinator.shown != text || context.coordinator.palette != palette.background {
            context.coordinator.shown = text
            context.coordinator.palette = palette.background
            textView.backgroundColor = palette.background
            textView.string = text
            if let storage = textView.textStorage, (text as NSString).length < 2_000_000 {
                SQLHighlighter(palette: palette, font: settings.editorFont).highlight(storage)
            } else {
                textView.font = settings.editorFont
                textView.textColor = palette.plain
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var shown: String?
        var palette: NSColor?
    }
}

// MARK: - Small views

struct DifferenceStatusLabel: View {
    let status: DifferenceStatus

    var body: some View {
        Text(status.symbol)
            .font(.system(.body, design: .monospaced).weight(.bold))
            .foregroundStyle(DifferenceStatusLabel.color(status))
            .help(status.shortTitle)
    }

    static func color(_ status: DifferenceStatus) -> Color {
        switch status {
        case .different: return .orange
        case .onlyInSource: return .green
        case .onlyInTarget: return .red
        case .identical: return .secondary
        }
    }
}

struct SeverityIcon: View {
    let severity: DeploymentWarningSeverity

    var body: some View {
        switch severity {
        case .high:
            Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(.red)
        case .medium:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .low:
            Image(systemName: "info.circle.fill").foregroundStyle(.blue)
        }
    }
}

/// A toggle row for an option descriptor with its explanation underneath.
struct OptionToggleRow: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                if !detail.isEmpty {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .toggleStyle(.checkbox)
    }
}

/// Status line text with an optional error tint.
struct CompareStatusLine: View {
    let text: String
    let isError: Bool

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(isError ? Color.red : Color.secondary)
            .lineLimit(2)
            .textSelection(.enabled)
    }
}
