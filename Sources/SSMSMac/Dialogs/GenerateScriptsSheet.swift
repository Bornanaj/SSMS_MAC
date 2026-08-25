import SwiftUI
import AppKit
import UniformTypeIdentifiers
import SQLServerKit

/// Generate Scripts: pick objects on the left, scripting options on the right,
/// then produce one runnable script for the whole selection.
struct GenerateScriptsSheet: View {
    @Environment(\.dismiss) private var dismiss

    let server: ConnectedServer
    let database: String

    @StateObject private var progressModel = ScriptProgressModel()

    @State private var objects: [ScriptableObject] = []
    @State private var search = ""
    @State private var options = ScriptOptions()
    @State private var script = ""
    @State private var isLoading = false
    @State private var statusText: String?
    @State private var isError = false
    @State private var showExporter = false

    init(server: ConnectedServer, database: String) {
        self.server = server
        self.database = database
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                objectPane
                Divider()
                optionsPane
            }
            .frame(height: 330)
            Divider()
            outputPane
            Divider()
            footer
        }
        .frame(width: 1000, height: 740)
        .task { await loadObjects() }
        .fileExporter(isPresented: $showExporter,
                      document: GeneratedScriptDocument(text: script),
                      contentType: GeneratedScriptDocument.sqlType,
                      defaultFilename: "\(database)_script") { result in
            switch result {
            case .success(let url):
                statusText = "Saved to \(url.path)."
                isError = false
            case .failure(let error):
                statusText = String(describing: error)
                isError = true
            }
        }
    }

    // MARK: - Header and footer

    private var header: some View {
        HStack {
            Image(systemName: "doc.text.below.ecg").foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("Generate Scripts").font(.headline)
                Text("\(server.displayName) · \(database)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(selectedCount) of \(objects.count) selected")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
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
            if isLoading { ProgressView().controlSize(.small) }
            Button("Copy") { copyScript() }
                .disabled(script.isEmpty)
            Button("Save to File…") { showExporter = true }
                .disabled(script.isEmpty)
            Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            Button("Generate") { generate() }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedCount == 0 || progressModel.isRunning)
        }
        .padding(12)
    }

    // MARK: - Object picker

    private var objectPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter objects", text: $search)
                    .textFieldStyle(.plain)
                if !search.isEmpty {
                    Button {
                        search = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                Divider().frame(height: 14)
                Button("All") { setSelection(true, in: visibleObjects) }
                    .buttonStyle(.link)
                Button("None") { setSelection(false, in: visibleObjects) }
                    .buttonStyle(.link)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)

            Divider()

            if groups.isEmpty {
                emptyObjectList
            } else {
                List {
                    ForEach(groups) { group in
                        Section {
                            ForEach(group.objects) { object in
                                objectRow(object)
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

    private var emptyObjectList: some View {
        VStack(spacing: 6) {
            Spacer()
            Text(isLoading ? "Loading objects…"
                 : objects.isEmpty ? "This database has no scriptable user objects."
                 : "No object matches the filter.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func groupHeader(_ group: ScriptObjectGroup) -> some View {
        HStack {
            Text("\(group.title) (\(group.objects.count))")
            Spacer()
            Button("All") { setSelection(true, in: group.objects) }
                .buttonStyle(.link)
            Button("None") { setSelection(false, in: group.objects) }
                .buttonStyle(.link)
        }
    }

    private func objectRow(_ object: ScriptableObject) -> some View {
        Toggle(isOn: selectionBinding(object)) {
            HStack(spacing: 6) {
                Image(systemName: ScriptableObject.iconName(for: object.kind))
                    .foregroundStyle(.secondary)
                    .frame(width: 15)
                Text(object.qualifiedName).lineLimit(1).truncationMode(.middle)
            }
        }
        .toggleStyle(.checkbox)
    }

    // MARK: - Options

    private var optionsPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                optionGroup("General") {
                    Toggle("Include descriptive headers", isOn: $options.includeDescriptiveHeader)
                    Toggle("Include SET options header", isOn: $options.includeSetOptionsHeader)
                    Toggle("Check for object existence", isOn: $options.includeIfNotExists)
                    Toggle("Script DROP before CREATE", isOn: $options.includeDropIfExists)
                    Toggle("Schema qualify names", isOn: $options.schemaQualify)
                }
                optionGroup("Table detail") {
                    Toggle("Primary keys", isOn: $options.scriptPrimaryKey)
                    Toggle("Indexes", isOn: $options.scriptIndexes)
                    Toggle("Foreign keys", isOn: $options.scriptForeignKeys)
                    Toggle("Check constraints", isOn: $options.scriptCheckConstraints)
                    Toggle("Defaults", isOn: $options.scriptDefaults)
                    Toggle("Triggers", isOn: $options.scriptTriggers)
                }
                optionGroup("Columns") {
                    Toggle("IDENTITY", isOn: $options.scriptIdentity)
                    Toggle("COLLATE", isOn: $options.scriptCollation)
                    Toggle("Extended properties", isOn: $options.scriptExtendedProperties)
                }
            }
            .padding(12)
        }
        .frame(width: 290)
    }

    private func optionGroup<Content: View>(_ title: String,
                                            @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Output

    private var outputPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            if progressModel.isRunning {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: progressModel.value)
                        .progressViewStyle(.linear)
                    Text(progressModel.label.isEmpty
                         ? "Preparing…"
                         : "Scripting \(progressModel.label)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(14)
                Spacer(minLength: 0)
            } else if script.isEmpty {
                Spacer(minLength: 0)
                Text("Choose objects, then press Generate.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer(minLength: 0)
            } else {
                ScrollView([.vertical, .horizontal]) {
                    Text(script)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Color(nsColor: .textBackgroundColor))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Derived state

    private var selectedCount: Int {
        objects.reduce(into: 0) { total, object in
            if object.isSelected { total += 1 }
        }
    }

    private var visibleObjects: [ScriptableObject] {
        let needle: String = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return objects }
        return objects.filter { object in
            object.name.lowercased().contains(needle)
                || object.schema.lowercased().contains(needle)
        }
    }

    private var groups: [ScriptObjectGroup] {
        var buckets: [ObjectNodeKind: [ScriptableObject]] = [:]
        for object in visibleObjects {
            buckets[object.kind, default: []].append(object)
        }
        let order: [ObjectNodeKind] = [.schema, .table, .externalTable, .view,
                                       .storedProcedure, .scalarFunction,
                                       .tableValuedFunction, .aggregateFunction]
        var result: [ScriptObjectGroup] = []
        for kind in order {
            guard let items = buckets[kind], !items.isEmpty else { continue }
            let title: String = ScriptableObject.pluralTitle(for: kind)
            result.append(ScriptObjectGroup(kind: kind, title: title, objects: items))
        }
        return result
    }

    private func selectionBinding(_ object: ScriptableObject) -> Binding<Bool> {
        Binding(
            get: {
                guard let index = objects.firstIndex(where: { $0.id == object.id }) else {
                    return false
                }
                return objects[index].isSelected
            },
            set: { newValue in
                guard let index = objects.firstIndex(where: { $0.id == object.id }) else { return }
                objects[index].isSelected = newValue
            })
    }

    private func setSelection(_ value: Bool, in targets: [ScriptableObject]) {
        let ids: Set<String> = Set(targets.map(\.id))
        for index in objects.indices where ids.contains(objects[index].id) {
            objects[index].isSelected = value
        }
    }

    // MARK: - Work

    private func loadObjects() async {
        isLoading = true
        defer { isLoading = false }
        let generator = ScriptBatchGenerator(session: server.session)
        do {
            objects = try await generator.objects(in: database)
            statusText = "\(objects.count) scriptable object(s) found."
            isError = false
        } catch {
            objects = []
            statusText = String(describing: error)
            isError = true
        }
    }

    private func generate() {
        let selected: [ScriptableObject] = objects.filter(\.isSelected)
        guard !selected.isEmpty else { return }

        let generator = ScriptBatchGenerator(session: server.session)
        let chosenOptions: ScriptOptions = options
        let targetDatabase: String = database
        let model: ScriptProgressModel = progressModel

        script = ""
        statusText = nil
        isError = false
        model.begin()

        Task {
            do {
                let text: String = try await generator.script(
                    database: targetDatabase,
                    objects: selected,
                    options: chosenOptions,
                    progress: { value, label in
                        Task { @MainActor in model.update(value: value, label: label) }
                    })
                script = text
                statusText = "Scripted \(selected.count) object(s)."
                isError = false
            } catch {
                statusText = String(describing: error)
                isError = true
            }
            model.finish()
        }
    }

    private func copyScript() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(script, forType: .string)
        statusText = "Script copied to the clipboard."
        isError = false
    }
}

// MARK: - Supporting types

/// One kind-section of the object picker.
private struct ScriptObjectGroup: Identifiable {
    var kind: ObjectNodeKind
    var title: String
    var objects: [ScriptableObject]

    var id: String { kind.rawValue }
}

/// Progress lives in its own main-actor object so the generator's `@Sendable`
/// callback has something safe to capture.
@MainActor
private final class ScriptProgressModel: ObservableObject {
    @Published var value: Double = 0
    @Published var label: String = ""
    @Published var isRunning: Bool = false

    func begin() {
        value = 0
        label = ""
        isRunning = true
    }

    func update(value: Double, label: String) {
        self.value = min(max(value, 0), 1)
        self.label = label
    }

    func finish() {
        isRunning = false
        value = 1
    }
}

/// Wraps the generated text so `fileExporter` can write it as a .sql file.
struct GeneratedScriptDocument: FileDocument {
    static let sqlType: UTType = UTType(filenameExtension: "sql", conformingTo: .plainText)
        ?? .plainText
    static var readableContentTypes: [UTType] { [GeneratedScriptDocument.sqlType, .plainText] }

    var text: String

    init(text: String) { self.text = text }

    init(configuration: ReadConfiguration) throws {
        let data: Data = configuration.file.regularFileContents ?? Data()
        text = String(data: data, encoding: .utf8) ?? ""
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
