import SwiftUI
import SQLServerKit

/// "Edit project": data sources, comparison options, owner and object mappings, filters.
struct SchemaCompareSetupSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: SchemaCompareModel

    enum Page: String, CaseIterable, Identifiable {
        case sources = "Data Sources"
        case options = "Options"
        case ownerMapping = "Owner Mapping"
        case objectMapping = "Object Mapping"
        case filter = "Filter"
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
                case .options: SchemaOptionsEditor(options: $model.options)
                case .ownerMapping: OwnerMappingEditor(mappings: $model.mappings)
                case .objectMapping: ObjectMappingEditor(mappings: $model.mappings)
                case .filter: SchemaFilterEditor(filter: $model.filter)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(width: 860, height: 620)
    }

    private var sourcesPage: some View {
        VStack(spacing: 18) {
            HStack(alignment: .top, spacing: 16) {
                CompareEndpointPicker(title: "Source", selection: model.source, pool: model.pool)
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
                CompareEndpointPicker(title: "Target", selection: model.target, pool: model.pool)
                    .padding(14)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
            }
            Text("The deployment makes the target look like the source. A snapshot can only be compared "
                 + "against; a scripts folder target is updated file by file.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer()
        }
        .padding(16)
    }

    private var footer: some View {
        HStack {
            if !model.statusText.isEmpty {
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
            .disabled(!model.source.isComplete || !model.target.isComplete)
        }
        .padding(12)
    }
}

// MARK: - Options

struct SchemaOptionsEditor: View {
    @Binding var options: SchemaCompareOptions
    @State private var search = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Search options", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 280)
                Spacer()
                Button("Reset to Defaults") { options = SchemaCompareOptions() }
            }
            .padding(10)
            Divider()
            ScrollView {
                HStack(alignment: .top, spacing: 24) {
                    column(.behavior)
                    column(.ignore)
                }
                .padding(14)
            }
        }
    }

    private func column(_ group: SchemaCompareOptions.Group) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(group.rawValue).font(.headline)
            ForEach(descriptors(group)) { descriptor in
                OptionToggleRow(title: descriptor.title, detail: descriptor.detail,
                                isOn: binding(descriptor.keyPath))
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func descriptors(_ group: SchemaCompareOptions.Group) -> [SchemaCompareOptions.Descriptor] {
        let needle = search.lowercased()
        return SchemaCompareOptions.descriptors.filter { descriptor in
            descriptor.group == group
                && (needle.isEmpty || descriptor.title.lowercased().contains(needle)
                    || descriptor.detail.lowercased().contains(needle))
        }
    }

    private func binding(_ keyPath: WritableKeyPath<SchemaCompareOptions, Bool>) -> Binding<Bool> {
        Binding(get: { options[keyPath: keyPath] }, set: { options[keyPath: keyPath] = $0 })
    }
}

// MARK: - Owner mapping

struct OwnerMappingEditor: View {
    @Binding var mappings: SchemaMappings
    @State private var newSource = ""
    @State private var newTarget = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Objects in a source schema are compared with objects of the same name in the mapped target schema, "
                 + "and deployed into it.")
                .font(.callout).foregroundStyle(.secondary)
            List {
                ForEach($mappings.schemaMappings) { $mapping in
                    HStack {
                        TextField("Source schema", text: $mapping.source).textFieldStyle(.roundedBorder)
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        TextField("Target schema", text: $mapping.target).textFieldStyle(.roundedBorder)
                        Button {
                            mappings.schemaMappings.removeAll { $0.id == mapping.id }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            .listStyle(.bordered)
            HStack {
                TextField("Source schema", text: $newSource).textFieldStyle(.roundedBorder)
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                TextField("Target schema", text: $newTarget).textFieldStyle(.roundedBorder)
                Button("Add") {
                    mappings.schemaMappings.append(SchemaNameMapping(source: newSource, target: newTarget))
                    newSource = ""
                    newTarget = ""
                }
                .disabled(newSource.isEmpty || newTarget.isEmpty)
            }
        }
        .padding(14)
    }
}

// MARK: - Object and column mapping

struct ObjectMappingEditor: View {
    @Binding var mappings: SchemaMappings
    @State private var type: SchemaObjectType = .table
    @State private var sourceName = ""
    @State private var targetName = ""
    @State private var selectedMapping: UUID?
    @State private var columnSource = ""
    @State private var columnTarget = ""

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Object mapping").font(.headline)
                Text("Pair objects whose names differ, for example a renamed table. With “Rename mapped tables and "
                     + "columns” on, deployment renames the target instead of dropping it.")
                    .font(.caption).foregroundStyle(.secondary)
                List(selection: $selectedMapping) {
                    ForEach(mappings.objectMappings) { mapping in
                        HStack {
                            Image(systemName: mapping.source.type.iconName).foregroundStyle(.secondary)
                            Text(mapping.source.qualifiedName)
                            Image(systemName: "arrow.right").foregroundStyle(.secondary)
                            Text(mapping.target.qualifiedName)
                        }
                        .tag(mapping.id)
                        .contextMenu {
                            Button("Remove") { remove(mapping) }
                        }
                    }
                }
                .listStyle(.bordered)
                Picker("Type", selection: $type) {
                    ForEach(SchemaObjectType.allCases.filter(\.isSchemaScoped), id: \.self) { type in
                        Text(type.title).tag(type)
                    }
                }
                HStack {
                    TextField("schema.source", text: $sourceName).textFieldStyle(.roundedBorder)
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    TextField("schema.target", text: $targetName).textFieldStyle(.roundedBorder)
                    Button("Add") { addObjectMapping() }
                        .disabled(!sourceName.contains(".") || !targetName.contains("."))
                }
            }
            .frame(maxWidth: .infinity)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("Column mapping").font(.headline)
                if let mapping = currentMapping {
                    Text("Columns of \(mapping.source.qualifiedName) mapped to differently named columns of "
                         + "\(mapping.target.qualifiedName).")
                        .font(.caption).foregroundStyle(.secondary)
                    List {
                        ForEach(columnPairs(mapping), id: \.source) { pair in
                            HStack {
                                Text(pair.source)
                                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                                Text(pair.target)
                                Spacer()
                                Button {
                                    removeColumn(pair, mapping: mapping)
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                    .listStyle(.bordered)
                    HStack {
                        TextField("Source column", text: $columnSource).textFieldStyle(.roundedBorder)
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        TextField("Target column", text: $columnTarget).textFieldStyle(.roundedBorder)
                        Button("Add") { addColumn(mapping) }
                            .disabled(columnSource.isEmpty || columnTarget.isEmpty)
                    }
                } else {
                    Text("Select a table mapping on the left to map its columns. Tables with the same name are "
                         + "mapped automatically; add them on the left to map their columns.")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(14)
    }

    private var currentMapping: ObjectMapping? {
        guard let selectedMapping else { return nil }
        return mappings.objectMappings.first { $0.id == selectedMapping && $0.source.type == .table }
    }

    private func split(_ text: String) -> (String, String) {
        let parts = text.split(separator: ".", maxSplits: 1).map(String.init)
        return parts.count == 2 ? (parts[0], parts[1]) : ("dbo", text)
    }

    private func addObjectMapping() {
        let source = split(sourceName)
        let target = split(targetName)
        mappings.objectMappings.append(ObjectMapping(
            source: SchemaObjectKey(type: type, schema: source.0, name: source.1),
            target: SchemaObjectKey(type: type, schema: target.0, name: target.1)))
        sourceName = ""
        targetName = ""
    }

    private func remove(_ mapping: ObjectMapping) {
        mappings.objectMappings.removeAll { $0.id == mapping.id }
        mappings.columnMappings.removeAll { $0.source == mapping.source && $0.target == mapping.target }
    }

    private func columnPairs(_ mapping: ObjectMapping) -> [ColumnMappingPair] {
        mappings.columnMappings.filter { $0.source == mapping.source && $0.target == mapping.target }
            .flatMap(\.pairs)
    }

    private func addColumn(_ mapping: ObjectMapping) {
        let pair = ColumnMappingPair(source: columnSource, target: columnTarget)
        if let index = mappings.columnMappings.firstIndex(where: {
            $0.source == mapping.source && $0.target == mapping.target
        }) {
            mappings.columnMappings[index].pairs.append(pair)
        } else {
            mappings.columnMappings.append(ColumnMappingSet(source: mapping.source, target: mapping.target,
                                                            pairs: [pair]))
        }
        columnSource = ""
        columnTarget = ""
    }

    private func removeColumn(_ pair: ColumnMappingPair, mapping: ObjectMapping) {
        for index in mappings.columnMappings.indices
            where mappings.columnMappings[index].source == mapping.source
                && mappings.columnMappings[index].target == mapping.target {
            mappings.columnMappings[index].pairs.removeAll { $0 == pair }
        }
    }
}

// MARK: - Filter

struct SchemaFilterEditor: View {
    @Binding var filter: SchemaFilter

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Object types").font(.headline)
                HStack {
                    Button("All") { filter.excludedTypes = [] }.buttonStyle(.link)
                    Button("None") { filter.excludedTypes = Set(SchemaObjectType.allCases) }.buttonStyle(.link)
                }
                List {
                    ForEach(SchemaObjectType.allCases, id: \.self) { type in
                        Toggle(isOn: typeBinding(type)) {
                            Label(type.pluralTitle, systemImage: type.iconName)
                        }
                        .toggleStyle(.checkbox)
                    }
                }
                .listStyle(.bordered)
            }
            .frame(width: 250)
            VStack(alignment: .leading, spacing: 8) {
                Text("Rules").font(.headline)
                Text("An object is compared when an include rule for its type matches (or there are none) and no "
                     + "exclude rule matches. LIKE patterns use % and _ as in T-SQL.")
                    .font(.caption).foregroundStyle(.secondary)
                List {
                    ForEach($filter.rules) { $rule in
                        FilterRuleRow(rule: $rule) {
                            filter.rules.removeAll { $0.id == rule.id }
                        }
                    }
                }
                .listStyle(.bordered)
                Button {
                    filter.rules.append(SchemaFilterRule())
                } label: {
                    Label("Add Rule", systemImage: "plus")
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(14)
    }

    private func typeBinding(_ type: SchemaObjectType) -> Binding<Bool> {
        Binding(get: { !filter.excludedTypes.contains(type) },
                set: { isOn in
                    if isOn { filter.excludedTypes.remove(type) } else { filter.excludedTypes.insert(type) }
                })
    }
}

struct FilterRuleRow: View {
    @Binding var rule: SchemaFilterRule
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Toggle("", isOn: $rule.isEnabled).toggleStyle(.checkbox).labelsHidden()
            Picker("", selection: $rule.action) {
                Text("Include").tag(SchemaFilterRule.Action.include)
                Text("Exclude").tag(SchemaFilterRule.Action.exclude)
            }
            .labelsHidden()
            .frame(width: 90)
            Menu(typeTitle) {
                Button("Any object type") { rule.types = [] }
                Divider()
                ForEach(SchemaObjectType.allCases, id: \.self) { type in
                    Button {
                        if rule.types.contains(type) { rule.types.remove(type) } else { rule.types.insert(type) }
                    } label: {
                        if rule.types.contains(type) {
                            Label(type.pluralTitle, systemImage: "checkmark")
                        } else {
                            Text(type.pluralTitle)
                        }
                    }
                }
            }
            .frame(width: 150)
            Picker("", selection: $rule.field) {
                ForEach(SchemaFilterRule.Field.allCases, id: \.self) { field in
                    Text(field.title).tag(field)
                }
            }
            .labelsHidden()
            .frame(width: 110)
            Picker("", selection: $rule.op) {
                ForEach(SchemaFilterRule.Operator.allCases, id: \.self) { op in
                    Text(op.title).tag(op)
                }
            }
            .labelsHidden()
            .frame(width: 130)
            TextField("Value", text: $rule.value).textFieldStyle(.roundedBorder)
            Button(action: onRemove) {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
        }
    }

    private var typeTitle: String {
        if rule.types.isEmpty { return "Any type" }
        if rule.types.count == 1, let type = rule.types.first { return type.pluralTitle }
        return "\(rule.types.count) types"
    }
}
