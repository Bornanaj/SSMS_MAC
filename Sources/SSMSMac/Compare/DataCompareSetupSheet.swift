import SwiftUI
import SQLServerKit

/// "Edit project" for Data Compare: the two databases, options, which tables and views are
/// compared with which key and columns, WHERE filters, and schema (owner) mapping.
struct DataCompareSetupSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: DataCompareModel

    enum Page: String, CaseIterable, Identifiable {
        case sources = "Data Sources"
        case options = "Options"
        case tables = "Tables & Views"
        case ownerMapping = "Owner Mapping"
        var id: String { rawValue }
    }

    @State private var page: Page = .sources

    var body: some View {
        VStack(spacing: 0) {
            Picker("Page", selection: $page) {
                ForEach(Page.allCases) { page in
                    Text(page.rawValue).tag(page)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(12)
            Divider()
            Group {
                switch page {
                case .sources: sourcesPage
                case .options: DataOptionsEditor(options: $model.options)
                case .tables: DataTablesEditor(model: model)
                case .ownerMapping: ownerMappingPage
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(width: 960, height: 660)
        .onChange(of: page) { _, newPage in
            if newPage == .tables && model.mappings.isEmpty && model.canCompare {
                Task { await model.loadMappings(app: app) }
            }
        }
    }

    private var sourcesPage: some View {
        VStack(spacing: 18) {
            HStack(alignment: .top, spacing: 16) {
                CompareEndpointPicker(title: "Source", selection: model.source, pool: model.pool,
                                      allowedKinds: [.database])
                    .padding(14)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                VStack {
                    Spacer().frame(height: 40)
                    Button {
                        model.swap()
                    } label: {
                        Image(systemName: "arrow.left.arrow.right")
                    }
                    .help("Swap source and target")
                }
                CompareEndpointPicker(title: "Target", selection: model.target, pool: model.pool,
                                      allowedKinds: [.database])
                    .padding(14)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
            }
            Text("Rows are matched by each table's comparison key (the primary key, a unique index, or columns "
                 + "you choose). Deployment makes the target's rows match the source's.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer()
        }
        .padding(16)
    }

    private var ownerMappingPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            OwnerMappingEditor(mappings: Binding(
                get: { SchemaMappings(schemaMappings: model.schemaMappings) },
                set: { model.schemaMappings = $0.schemaMappings }))
            HStack {
                Text("Tables are paired again with the new mapping when you compare, or now:")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Re-map Tables") { Task { await model.loadMappings(app: app) } }
                    .disabled(!model.canCompare)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
        }
    }

    private var footer: some View {
        HStack {
            if model.isBusy {
                ProgressView().controlSize(.small)
                Text(model.progressText).font(.caption).foregroundStyle(.secondary)
            } else if !model.statusText.isEmpty {
                CompareStatusLine(text: model.statusText, isError: model.statusIsError)
            }
            Spacer()
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Compare Now") {
                dismiss()
                Task { await model.compare(app: app) }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!model.canCompare)
        }
        .padding(12)
    }
}

// MARK: - Options

struct DataOptionsEditor: View {
    @Binding var options: DataCompareOptions

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button("Reset to Defaults") { options = DataCompareOptions() }
            }
            .padding(10)
            Divider()
            ScrollView {
                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Comparison").font(.headline)
                        ForEach(DataCompareOptions.descriptors.filter { !$0.isDeployment }) { descriptor in
                            OptionToggleRow(title: descriptor.title, detail: descriptor.detail,
                                            isOn: binding(descriptor.keyPath))
                        }
                        numberRow("Float and real precision (decimal places, -1 = exact)",
                                  value: $options.floatDecimalPlaces, range: -1...15)
                        numberField("Rows kept per table and outcome", value: $options.maximumRowsKept)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Deployment").font(.headline)
                        ForEach(DataCompareOptions.descriptors.filter(\.isDeployment)) { descriptor in
                            OptionToggleRow(title: descriptor.title, detail: descriptor.detail,
                                            isOn: binding(descriptor.keyPath))
                        }
                        numberField("Rows per INSERT batch", value: $options.rowsPerBatch)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(14)
            }
        }
    }

    private func binding(_ keyPath: WritableKeyPath<DataCompareOptions, Bool>) -> Binding<Bool> {
        Binding(get: { options[keyPath: keyPath] }, set: { options[keyPath: keyPath] = $0 })
    }

    private func numberRow(_ title: String, value: Binding<Int>, range: ClosedRange<Int>) -> some View {
        Stepper(value: value, in: range) {
            Text("\(title): \(value.wrappedValue)")
        }
    }

    private func numberField(_ title: String, value: Binding<Int>) -> some View {
        HStack {
            Text(title)
            TextField("", value: Binding(get: { value.wrappedValue }, set: { value.wrappedValue = max(1, $0) }),
                      format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 100)
        }
    }
}

// MARK: - Tables and views

/// Pairs of tables with their key, columns and WHERE filters, plus the tables that have no
/// partner yet.
struct DataTablesEditor: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var model: DataCompareModel
    @State private var selectedID: String?
    @State private var search = ""

    private var visibleMappings: [DataTableMapping] {
        guard !search.isEmpty else { return model.mappings }
        return model.mappings.filter { $0.displayName.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        if model.mappings.isEmpty && model.unmatchedSource.isEmpty && model.unmatchedTarget.isEmpty {
            VStack(spacing: 12) {
                if model.isBusy {
                    ProgressView("Reading tables…")
                } else {
                    Text("Choose the source and target databases, then read their tables.")
                        .foregroundStyle(.secondary)
                    Button("Read Tables") { Task { await model.loadMappings(app: app) } }
                        .disabled(!model.canCompare)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            HSplitView {
                tableList
                    .frame(minWidth: 380, idealWidth: 460)
                detail
                    .frame(minWidth: 360)
            }
        }
    }

    // MARK: List

    private var tableList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField("Filter tables", text: $search).textFieldStyle(.roundedBorder)
                Button("All") { model.setAllIncluded(true) }.controlSize(.small)
                Button("None") { model.setAllIncluded(false) }.controlSize(.small)
                Button {
                    Task { await model.loadMappings(app: app) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Read the tables again")
                .disabled(!model.canCompare)
            }
            .padding(8)
            Divider()
            List(selection: $selectedID) {
                Section("Mapped (\(model.mappings.count))") {
                    ForEach(visibleMappings) { mapping in
                        DataMappingRow(mapping: mapping, isIncluded: Binding(
                            get: { model.mapping(mapping.id)?.isIncluded ?? false },
                            set: { model.setIncluded(mapping.id, $0) }))
                            .tag(mapping.id)
                    }
                }
                if !model.unmatchedSource.isEmpty {
                    Section("Only in source (\(model.unmatchedSource.count))") {
                        ForEach(model.unmatchedSource) { table in
                            unmatchedRow(table)
                        }
                    }
                }
                if !model.unmatchedTarget.isEmpty {
                    Section("Only in target (\(model.unmatchedTarget.count))") {
                        ForEach(model.unmatchedTarget) { table in
                            Label(table.qualifiedName, systemImage: table.isView ? "eye" : "tablecells")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
        }
    }

    private func unmatchedRow(_ table: DataTableInfo) -> some View {
        HStack {
            Label(table.qualifiedName, systemImage: table.isView ? "eye" : "tablecells")
            Spacer()
            Menu("Map to") {
                ForEach(model.unmatchedTarget) { other in
                    Button(other.qualifiedName) {
                        Task { await model.pair(source: table, with: other, app: app) }
                    }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(model.unmatchedTarget.isEmpty)
        }
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if let mapping = model.mapping(selectedID) {
            DataMappingDetail(model: model, mapping: mapping,
                              isExplicitPair: model.tablePairs[mapping.source.qualifiedName] != nil)
        } else {
            Text("Select a table to choose its comparison key, columns and filters.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct DataMappingRow: View {
    let mapping: DataTableMapping
    @Binding var isIncluded: Bool

    var body: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: $isIncluded)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(!mapping.hasKey)
            Image(systemName: mapping.source.isView ? "eye" : "tablecells")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(mapping.displayName).lineLimit(1).truncationMode(.middle)
                Text(mapping.keyDescription)
                    .font(.caption)
                    .foregroundStyle(mapping.hasKey ? Color.secondary : Color.orange)
                    .lineLimit(1)
            }
            Spacer()
            if !mapping.sourceWhere.isEmpty || !mapping.targetWhere.isEmpty {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .foregroundStyle(.secondary)
                    .help("Filtered with a WHERE clause")
            }
            Text("\(mapping.comparedColumns.count + mapping.keyColumns.count)/\(mapping.columns.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .help("Columns compared / columns in common")
        }
    }
}

/// Key, columns and filters of one table pair.
struct DataMappingDetail: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var model: DataCompareModel
    let mapping: DataTableMapping
    let isExplicitPair: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(mapping.displayName).font(.headline).lineLimit(1)
                Spacer()
                if isExplicitPair {
                    Button("Unmap") { Task { await model.unpair(mapping.id, app: app) } }
                        .controlSize(.small)
                }
            }
            keyPicker
            Text("Columns").font(.subheadline.weight(.semibold))
            columnTable
            whereFields
        }
        .padding(12)
    }

    private var keyPicker: some View {
        HStack {
            Text("Comparison key")
            Menu(mapping.keyDescription) {
                Button("Automatic") { model.useKey(nil, for: mapping.id) }
                if !mapping.source.keys.isEmpty {
                    Divider()
                    ForEach(mapping.source.keys, id: \.name) { key in
                        Button("\(key.title) (\(key.columns.joined(separator: ", ")))") {
                            model.useKey(key, for: mapping.id)
                        }
                    }
                }
            }
            .frame(maxWidth: 360)
            Spacer()
        }
        .help("Tick the key column boxes below to build a custom key from any columns.")
    }

    private var columnTable: some View {
        Table(mapping.columns) {
            TableColumn("Key") { column in
                Toggle("", isOn: Binding(
                    get: { column.isKey },
                    set: { model.setKeyColumn(column.sourceColumn, $0, for: mapping.id) }))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .disabled(column.source.isLargeObject || column.target.isLargeObject)
            }
            .width(34)
            TableColumn("Compare") { column in
                Toggle("", isOn: Binding(
                    get: { column.isIncluded },
                    set: { model.setColumnIncluded(column.id, $0, for: mapping.id) }))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .disabled(column.isKey)
            }
            .width(58)
            TableColumn("Source column") { column in
                Text(column.sourceColumn)
            }
            TableColumn("Target column") { column in
                Text(column.targetColumn)
            }
            TableColumn("Type") { column in
                DataColumnTypeLabel(column: column)
            }
        }
        .frame(minHeight: 200)
    }

    private var whereFields: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("WHERE clause").font(.subheadline.weight(.semibold))
            HStack {
                Text("Source").frame(width: 50, alignment: .leading)
                TextField("e.g. ModifiedDate >= '2024-01-01'", text: Binding(
                    get: { model.mapping(mapping.id)?.sourceWhere ?? "" },
                    set: { model.setWhere($0, source: true, for: mapping.id) }))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }
            HStack {
                Text("Target").frame(width: 50, alignment: .leading)
                TextField("Leave empty to use the source's", text: Binding(
                    get: { model.mapping(mapping.id)?.targetWhere ?? "" },
                    set: { model.setWhere($0, source: false, for: mapping.id) }))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }
            Text("Only rows matching the filter are compared and deployed.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct DataColumnTypeLabel: View {
    let column: DataColumnMapping

    var body: some View {
        HStack(spacing: 4) {
            if column.typesDiffer {
                Text("\(column.source.dataType) → \(column.target.dataType)")
                    .foregroundStyle(.orange)
            } else {
                Text(column.source.dataType).foregroundStyle(.secondary)
            }
            if column.source.isIdentity { tag("identity") }
            if column.source.isComputed { tag("computed") }
            if column.source.isTimestamp { tag("rowversion") }
        }
        .lineLimit(1)
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 4)
            .background(Color.secondary.opacity(0.18), in: Capsule())
    }
}
