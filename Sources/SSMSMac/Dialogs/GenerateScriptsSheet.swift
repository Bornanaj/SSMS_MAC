import SwiftUI
import AppKit
import SQLServerKit

/// Generation state lives in a `@MainActor` class rather than in `@State` so the
/// progress callback — which the scripter invokes from its own task — has something
/// `Sendable` to write into.
@MainActor
final class ScriptGenerationModel: ObservableObject {
    @Published var progress: ScriptProjectProgress?
    @Published var result: ScriptProjectResult?
    @Published var errorText: String?
    @Published var isGenerating = false

    private var task: Task<Void, Never>?

    func run(project: ScriptProject,
             database: String,
             objects: [ScriptableObject],
             options: ScriptProjectOptions) {
        cancel()
        result = nil
        errorText = nil
        isGenerating = true
        progress = ScriptProjectProgress(completed: 0, total: objects.count, currentObject: "")

        task = Task { [weak self] in
            do {
                let outcome = try await project.generate(
                    database: database,
                    objects: objects,
                    options: options,
                    onProgress: { [weak self] update in
                        Task { @MainActor in self?.progress = update }
                    })
                await MainActor.run {
                    self?.result = outcome
                    self?.isGenerating = false
                }
            } catch {
                // Cancelling is not a failure; the scripter throws to unwind.
                let cancelled = Task.isCancelled
                await MainActor.run {
                    if !cancelled { self?.errorText = String(describing: error) }
                    self?.isGenerating = false
                }
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        isGenerating = false
    }
}

/// Generate Scripts: choose objects, choose options, then send the script to a new query
/// window, the clipboard or a file.
struct GenerateScriptsSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    let server: ConnectedServer
    let database: String

    @StateObject private var generation = ScriptGenerationModel()
    @State private var objects: [ScriptableObject] = []
    @State private var selection: Set<String> = []
    @State private var expandedGroups: Set<String> = []
    @State private var filter = ""
    @State private var options = ScriptProjectOptions()
    @State private var page = "objects"
    @State private var isLoading = false
    @State private var errorText: String?

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "Generate Scripts", subtitle: "\(server.displayName) · \(database)",
                        symbol: "doc.text.below.ecg")
            Divider()
            Picker("", selection: $page) {
                Text("Objects").tag("objects")
                Text("Options").tag("options")
                Text("Output").tag("output")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 840, height: 640)
        .task { await load() }
        .onDisappear { generation.cancel() }
    }

    // MARK: Pages

    @ViewBuilder
    private var content: some View {
        switch page {
        case "options": optionsPage
        case "output": outputPage
        default: objectsPage
        }
    }

    private var groupedObjects: [(title: String, objects: [ScriptableObject])] {
        let matching = filter.isEmpty
            ? objects
            : objects.filter { $0.qualifiedName.localizedCaseInsensitiveContains(filter) }
        var groups: [String: [ScriptableObject]] = [:]
        for object in matching { groups[object.groupTitle, default: []].append(object) }
        // Group order follows the script order so the picker reads like the output.
        let order = matching.reduce(into: [String: Int]()) { partial, object in
            let rank = ScriptableObjectOrder.rank(object)
            partial[object.groupTitle] = min(partial[object.groupTitle] ?? rank, rank)
        }
        return groups
            .map { (title: $0.key, objects: $0.value.sorted { $0.qualifiedName < $1.qualifiedName }) }
            .sorted { (order[$0.title] ?? 99, $0.title) < (order[$1.title] ?? 99, $1.title) }
    }

    private var objectsPage: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal.decrease.circle").foregroundStyle(.secondary)
                TextField("Filter objects", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                Button("Select All") { selection = Set(objects.map(\.id)) }
                Button("Select None") { selection.removeAll() }
                Button("Tables Only") {
                    selection = Set(objects.filter { $0.kind == .table }.map(\.id))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()

            if isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if objects.isEmpty {
                ContentUnavailableView("No scriptable objects", systemImage: "tray",
                                       description: Text(errorText
                                           ?? "This database has no user objects."))
            } else {
                List {
                    ForEach(groupedObjects, id: \.title) { group in
                        Section {
                            if expandedGroups.contains(group.title) {
                                ForEach(group.objects) { object in
                                    objectRow(object)
                                }
                            }
                        } header: {
                            groupHeader(group)
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private func groupHeader(_ group: (title: String, objects: [ScriptableObject])) -> some View {
        let ids = Set(group.objects.map(\.id))
        let selectedCount = ids.intersection(selection).count
        return HStack(spacing: 6) {
            Button {
                if expandedGroups.contains(group.title) {
                    expandedGroups.remove(group.title)
                } else {
                    expandedGroups.insert(group.title)
                }
            } label: {
                Image(systemName: expandedGroups.contains(group.title)
                      ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
            }
            .buttonStyle(.plain)

            Toggle(isOn: Binding(
                get: { selectedCount == ids.count && !ids.isEmpty },
                set: { on in
                    if on { selection.formUnion(ids) } else { selection.subtract(ids) }
                }
            )) {
                Text("\(group.title) (\(selectedCount)/\(group.objects.count))")
            }
            .toggleStyle(.checkbox)
            Spacer()
        }
    }

    private func objectRow(_ object: ScriptableObject) -> some View {
        Toggle(isOn: Binding(
            get: { selection.contains(object.id) },
            set: { on in
                if on { selection.insert(object.id) } else { selection.remove(object.id) }
            }
        )) {
            HStack(spacing: 6) {
                Text(object.qualifiedName)
                if !object.createDate.isEmpty {
                    Text(object.createDate).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .toggleStyle(.checkbox)
        .padding(.leading, 16)
    }

    private var optionsPage: some View {
        Form {
            Section("Script contents") {
                Toggle("Include CREATE DATABASE", isOn: $options.includeDatabaseCreate)
                Toggle("Include USE [\(database)]", isOn: $options.includeUseStatement)
                Toggle("Script DROP and CREATE", isOn: $options.dropAndCreate)
                Toggle("Include a comment banner per object", isOn: $options.includeObjectBanners)
            }
            Section("Per-object options") {
                Toggle("Descriptive headers", isOn: $options.scriptOptions.includeDescriptiveHeader)
                Toggle("SET ANSI_NULLS / QUOTED_IDENTIFIER header",
                       isOn: $options.scriptOptions.includeSetOptionsHeader)
                Toggle("IF NOT EXISTS guards", isOn: $options.scriptOptions.includeIfNotExists)
                Toggle("Schema-qualify names", isOn: $options.scriptOptions.schemaQualify)
                Toggle("Indexes", isOn: $options.scriptOptions.scriptIndexes)
                Toggle("Triggers", isOn: $options.scriptOptions.scriptTriggers)
                Toggle("Foreign keys", isOn: $options.scriptOptions.scriptForeignKeys)
                Toggle("Check constraints", isOn: $options.scriptOptions.scriptCheckConstraints)
                Toggle("Defaults", isOn: $options.scriptOptions.scriptDefaults)
                Toggle("Primary keys", isOn: $options.scriptOptions.scriptPrimaryKey)
                Toggle("Collations", isOn: $options.scriptOptions.scriptCollation)
                Toggle("Identity", isOn: $options.scriptOptions.scriptIdentity)
                Toggle("Extended properties", isOn: $options.scriptOptions.scriptExtendedProperties)
            }
            Section {
                Toggle("Script table data as INSERT statements", isOn: $options.includeData)
                if options.includeData {
                    TextField("Maximum rows per table",
                              value: $options.maxDataRowsPerTable, format: .number)
                }
            } footer: {
                Text("Data scripting reads every selected table. On a large table this is slow "
                     + "and the row cap applies per table, silently truncating anything larger.")
                    .font(.caption)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var outputPage: some View {
        if let result = generation.result {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Label("\(result.scriptedCount) object(s) scripted", systemImage: "checkmark.circle")
                        .foregroundStyle(.green)
                    if !result.failures.isEmpty {
                        Label("\(result.failures.count) failed", systemImage: "xmark.circle")
                            .foregroundStyle(.red)
                    }
                    Spacer()
                    Text("\(result.sql.count) characters")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .font(.caption)
                .padding(10)
                Divider()

                if !result.failures.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(result.failures.enumerated()), id: \.offset) { _, failure in
                                Text("\(failure.object): \(failure.reason)")
                                    .font(.caption)
                                    .foregroundStyle(.red)
                                    .textSelection(.enabled)
                            }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 110)
                    Divider()
                }

                ScrollView {
                    Text(result.sql)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
            }
        } else if generation.isGenerating {
            VStack(spacing: 10) {
                ProgressView(value: generation.progress?.fraction ?? 0)
                    .frame(width: 320)
                Text(generation.progress?.currentObject ?? "Starting…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(generation.progress?.completed ?? 0) of \(generation.progress?.total ?? 0)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button("Cancel") { generation.cancel() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let failure = generation.errorText {
            SheetError(text: failure)
        } else {
            ContentUnavailableView("Nothing generated yet", systemImage: "doc.text",
                                   description: Text("Choose objects, then press Generate."))
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Text("\(selection.count) of \(objects.count) selected")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            if let result = generation.result {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(result.sql, forType: .string)
                }
                Button("Save to File…") { save(result.sql) }
                Button("Open in New Query Window") {
                    app.openScript(result.sql, server: server, database: database,
                                   title: "\(database) script")
                    dismiss()
                }
            }
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button("Generate") { generate() }
                .keyboardShortcut(.defaultAction)
                .disabled(selection.isEmpty || generation.isGenerating)
        }
        .padding(12)
    }

    // MARK: Actions

    private func generate() {
        let chosen = objects.filter { selection.contains($0.id) }
        guard !chosen.isEmpty else { return }
        page = "output"
        generation.run(project: ScriptProject(session: server.session),
                       database: database,
                       objects: chosen,
                       options: options)
    }

    private func save(_ sql: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.allowsOtherFileTypes = true
        panel.nameFieldStringValue = "\(database).sql"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                do {
                    try sql.write(to: url, atomically: true, encoding: .utf8)
                    app.statusMessage = "Script written to \(url.lastPathComponent)."
                } catch {
                    errorText = String(describing: error)
                }
            }
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            objects = try await ScriptProject(session: server.session)
                .discover(database: database,
                          includeSystemObjects: false)
            selection = Set(objects.map(\.id))
            expandedGroups = Set(objects.map(\.groupTitle))
            errorText = nil
        } catch {
            errorText = String(describing: error)
        }
    }
}

/// Group ordering for the picker, kept next to the sheet because it is presentation only.
enum ScriptableObjectOrder {
    static func rank(_ object: ScriptableObject) -> Int {
        switch object.kind {
        case .schema: return 0
        case .userDefinedDataType: return 1
        case .userDefinedTableType: return 2
        case .sequence: return 3
        case .table: return 4
        case .view: return 5
        case .storedProcedure: return 6
        case .scalarFunction: return 7
        case .tableValuedFunction: return 8
        case .aggregateFunction: return 9
        case .synonym: return 10
        case .trigger: return 11
        default: return 12
        }
    }
}
