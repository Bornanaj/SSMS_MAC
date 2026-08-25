import SwiftUI
import SQLServerKit

/// The equivalent of SSMS "Design": edit a table's columns and apply the changes as
/// ALTER statements, with the script shown before anything runs.
struct TableDesignerSheet: View {
    @Environment(\.dismiss) private var dismiss

    let server: ConnectedServer
    let database: String
    let schema: String
    let table: String

    @State private var original: TableDesign?
    @State private var edited: TableDesign?
    @State private var selection: DesignColumn.ID?
    @State private var errorText: String?
    @State private var statusText: String?
    @State private var isBusy = false
    @State private var pendingScript: String?

    private var columns: [DesignColumn] { edited?.columns ?? [] }

    private var selectedIndex: Int? {
        guard let selection else { return nil }
        return columns.firstIndex { $0.id == selection }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if edited == nil {
                loadingOrError
            } else {
                grid
                Divider()
                propertiesStrip
            }
            Divider()
            footer
        }
        .frame(width: 940, height: 620)
        .task { await load() }
        .sheet(isPresented: Binding(get: { pendingScript != nil },
                                    set: { if !$0 { pendingScript = nil } })) {
            if let script = pendingScript {
                scriptPreview(script)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "tablecells.badge.ellipsis").foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("Design Table").font(.headline)
                Text("\(database).\(schema).\(table)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if isBusy { ProgressView().controlSize(.small) }
        }
        .padding(12)
    }

    @ViewBuilder
    private var loadingOrError: some View {
        if let errorText {
            ContentUnavailableView("Could not open the designer",
                                   systemImage: "exclamationmark.triangle",
                                   description: Text(errorText))
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Column grid

    private var grid: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                gridHeader("", width: 26)
                gridHeader("Column Name", width: 200)
                gridHeader("Data Type", width: 170)
                gridHeader("Allow Nulls", width: 90)
                gridHeader("Default", width: 170)
                gridHeader("Identity", width: 80)
                gridHeader("PK", width: 44)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(columns.enumerated()), id: \.element.id) { index, column in
                        columnRow(index: index, column: column)
                    }
                }
            }

            Divider()

            HStack(spacing: 8) {
                Button {
                    addColumn()
                } label: {
                    Label("Add Column", systemImage: "plus")
                }
                Button(role: .destructive) {
                    removeSelected()
                } label: {
                    Label("Remove", systemImage: "minus")
                }
                .disabled(selectedIndex == nil)
                Spacer()
                Text("Reordering existing columns needs a table rebuild and is not applied.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }

    private func gridHeader(_ title: String, width: CGFloat) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .frame(width: width, alignment: .leading)
            .padding(.horizontal, 4)
    }

    @ViewBuilder
    private func columnRow(index: Int, column: DesignColumn) -> some View {
        let isSelected = selection == column.id
        let isChanged = hasChanged(column)

        HStack(spacing: 0) {
            Image(systemName: column.isNew ? "plus.circle.fill"
                  : isChanged ? "pencil.circle.fill" : "circle")
                .font(.system(size: 9))
                .foregroundStyle(column.isNew ? Color.green
                                 : isChanged ? Color.orange : Color.secondary.opacity(0.3))
                .frame(width: 26)

            TextField("", text: binding(index, \.name, default: ""), onCommit: {})
                .textFieldStyle(.plain)
                .frame(width: 200, alignment: .leading)
                .padding(.horizontal, 4)

            typePicker(index: index, column: column)
                .frame(width: 170, alignment: .leading)
                .padding(.horizontal, 4)

            Toggle("", isOn: binding(index, \.isNullable, default: true))
                .labelsHidden()
                .frame(width: 90, alignment: .leading)
                .padding(.horizontal, 4)

            TextField("", text: binding(index, \.defaultDefinition, default: ""))
                .textFieldStyle(.plain)
                .frame(width: 170, alignment: .leading)
                .padding(.horizontal, 4)

            Toggle("", isOn: binding(index, \.isIdentity, default: false))
                .labelsHidden()
                .disabled(!column.isNew)
                .frame(width: 80, alignment: .leading)
                .padding(.horizontal, 4)

            Toggle("", isOn: binding(index, \.isPrimaryKey, default: false))
                .labelsHidden()
                .frame(width: 44, alignment: .leading)
                .padding(.horizontal, 4)

            Spacer(minLength: 0)
        }
        .font(.system(size: 12))
        .frame(height: 26)
        .background(isSelected ? Color.accentColor.opacity(0.18)
                    : column.isNew ? Color.green.opacity(0.08)
                    : isChanged ? Color.orange.opacity(0.08) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { selection = column.id }
    }

    @ViewBuilder
    private func typePicker(index: Int, column: DesignColumn) -> some View {
        // A picker for the common shapes plus free text, because lengths and precisions
        // cannot be enumerated.
        HStack(spacing: 2) {
            TextField("", text: binding(index, \.typeName, default: ""))
                .textFieldStyle(.plain)
            Menu {
                ForEach(TableDesignService.dataTypes, id: \.self) { type in
                    Button(type) { update(index) { $0.typeName = type } }
                }
            } label: {
                Image(systemName: "chevron.down").font(.system(size: 8))
            }
            .menuStyle(.borderlessButton)
            .frame(width: 16)
        }
    }

    // MARK: - Properties strip

    @ViewBuilder
    private var propertiesStrip: some View {
        if let index = selectedIndex {
            let column = columns[index]
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    LabeledContent("Description") {
                        TextField("", text: binding(index, \.columnDescription, default: ""))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 260)
                    }
                    LabeledContent("Collation") {
                        TextField("database default", text: binding(index, \.collation, default: ""))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 260)
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    LabeledContent("Identity seed") {
                        TextField("1", text: binding(index, \.identitySeed, default: "1"))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 90)
                            .disabled(!column.isIdentity)
                    }
                    LabeledContent("Identity increment") {
                        TextField("1", text: binding(index, \.identityIncrement, default: "1"))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 90)
                            .disabled(!column.isIdentity)
                    }
                }
                Spacer()
            }
            .padding(12)
            .frame(height: 110)
        } else {
            Text("Select a column to edit its properties.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .frame(height: 110)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if let statusText {
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(errorText == nil ? Color.secondary : Color.red)
                    .lineLimit(2)
            }
            Spacer()
            Text("\(changeCount) pending change\(changeCount == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Revert") { Task { await load(force: true) } }
                .disabled(changeCount == 0 || isBusy)
            Button("Preview Script") { preview() }
                .disabled(changeCount == 0 || isBusy)
            Button("Save") { preview() }
                .keyboardShortcut(.defaultAction)
                .disabled(changeCount == 0 || isBusy)
            Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .padding(12)
    }

    @ViewBuilder
    private func scriptPreview(_ script: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Statements to run").font(.headline).padding(12)
            Divider()
            ScrollView {
                Text(script)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            Divider()
            HStack {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(script, forType: .string)
                }
                Spacer()
                Button("Cancel") { pendingScript = nil }.keyboardShortcut(.cancelAction)
                Button("Apply") {
                    pendingScript = nil
                    apply()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 720, height: 520)
    }

    // MARK: - Editing helpers

    private var changeCount: Int {
        guard let original, let edited else { return 0 }
        if original.columns.count != edited.columns.count {
            return abs(original.columns.count - edited.columns.count)
                + edited.columns.filter { hasChanged($0) }.count
        }
        return edited.columns.filter { hasChanged($0) }.count
    }

    private func hasChanged(_ column: DesignColumn) -> Bool {
        guard let original else { return column.isNew }
        if column.isNew { return true }
        guard let match = original.columns.first(where: { $0.id == column.id }) else { return true }
        return match != column
    }

    /// Writable key paths rather than getter closures: picking the field by comparing
    /// values would write to the wrong one whenever two fields happened to match.
    private func binding<Value>(_ index: Int,
                                _ keyPath: WritableKeyPath<DesignColumn, Value>,
                                default fallback: Value) -> Binding<Value> {
        Binding(
            get: {
                guard columns.indices.contains(index) else { return fallback }
                return columns[index][keyPath: keyPath]
            },
            set: { newValue in
                update(index) { column in column[keyPath: keyPath] = newValue }
            }
        )
    }

    private func update(_ index: Int, _ mutate: (inout DesignColumn) -> Void) {
        guard var design = edited, design.columns.indices.contains(index) else { return }
        mutate(&design.columns[index])
        edited = design
    }

    private func addColumn() {
        guard var design = edited else { return }
        var column = DesignColumn(id: UUID(), name: "Column\(design.columns.count + 1)",
                                  typeName: "nvarchar(50)", isNullable: true, isIdentity: false,
                                  identitySeed: "1", identityIncrement: "1",
                                  defaultDefinition: "", isPrimaryKey: false, collation: "",
                                  columnDescription: "", isNew: true, originalName: nil)
        column.isNew = true
        design.columns.append(column)
        edited = design
        selection = column.id
    }

    private func removeSelected() {
        guard var design = edited, let index = selectedIndex else { return }
        design.columns.remove(at: index)
        edited = design
        selection = nil
    }

    // MARK: - Loading and applying

    private func load(force: Bool = false) async {
        isBusy = true
        defer { isBusy = false }
        let service = TableDesignService(session: server.session)
        do {
            let design = try await service.load(database: database, schema: schema, table: table)
            original = design
            edited = design
            selection = design.columns.first?.id
            errorText = nil
            statusText = "\(design.columns.count) columns loaded."
        } catch {
            errorText = String(describing: error)
            statusText = errorText
        }
    }

    private func preview() {
        guard let original, let edited else { return }
        let service = TableDesignService(session: server.session)
        do {
            let script = try service.alterScript(database: database, original: original,
                                                 edited: edited)
            guard !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                statusText = "Nothing to apply."
                return
            }
            errorText = nil
            pendingScript = script
        } catch {
            errorText = String(describing: error)
            statusText = errorText
        }
    }

    private func apply() {
        guard let original, let edited else { return }
        isBusy = true
        Task {
            let service = TableDesignService(session: server.session)
            do {
                let count = try await service.apply(database: database, original: original,
                                                    edited: edited)
                errorText = nil
                statusText = "\(count) change\(count == 1 ? "" : "s") applied."
                await load(force: true)
            } catch {
                errorText = String(describing: error)
                statusText = errorText
            }
            isBusy = false
        }
    }
}
