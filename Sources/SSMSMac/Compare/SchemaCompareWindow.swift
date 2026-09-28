import SwiftUI
import AppKit
import SQLServerKit

/// The Schema Compare window: results grouped by outcome, the SQL differences of the
/// selected object underneath, and the project, compare, deploy and report commands in the
/// toolbar.
struct SchemaCompareWindow: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var settings: AppSettings
    @Environment(\.openWindow) private var openWindow
    let launch: CompareLaunch

    @StateObject private var model = SchemaCompareModel()
    @State private var configured = false

    var body: some View {
        VStack(spacing: 0) {
            if model.comparison == nil {
                emptyState
            } else {
                VSplitView {
                    resultsPane
                        .frame(minHeight: 180, idealHeight: 320)
                    detailPane
                        .frame(minHeight: 200)
                }
            }
            Divider()
            statusBar
        }
        .frame(minWidth: 980, minHeight: 620)
        .navigationTitle(model.title)
        .toolbar { toolbarContent }
        .sheet(isPresented: $model.showSetup) {
            SchemaCompareSetupSheet(model: model)
                .environmentObject(app)
        }
        .sheet(isPresented: $model.showDeployment) {
            SchemaDeploymentSheet(model: model)
                .environmentObject(app)
                .environmentObject(settings)
        }
        .onAppear {
            guard !configured else { return }
            configured = true
            model.configure(launch: launch, app: app)
        }
        .onDisappear { model.close() }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button {
                openWindow(id: "schema-compare", value: CompareLaunch())
            } label: {
                Label("New", systemImage: "doc.badge.plus")
            }
            .help("New schema comparison")
            Button {
                model.openProject()
            } label: {
                Label("Open", systemImage: "folder")
            }
            .help("Open a comparison project")
            Button {
                model.save(as: false)
            } label: {
                Label("Save", systemImage: "square.and.arrow.down")
            }
            .help("Save the comparison project")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                model.showSetup = true
            } label: {
                Label("Edit Project", systemImage: "slider.horizontal.3")
            }
            .help("Data sources, options, mappings and filters")
            Button {
                Task { await model.compare(app: app) }
            } label: {
                Label(model.comparison == nil ? "Compare" : "Refresh", systemImage: "arrow.triangle.2.circlepath")
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(!model.canCompare)
            .help("Compare now (⌘R)")
            Button {
                model.showDeployment = true
            } label: {
                Label("Deploy", systemImage: "arrow.right.doc.on.clipboard")
            }
            .disabled(model.comparison == nil || model.deploymentCount == 0 || model.isBusy)
            .help("Review, script and deploy the selected differences")
            Menu {
                ForEach(CompareReportFormat.allCases) { format in
                    Button(format.title) { model.exportReport(format) }
                }
            } label: {
                Label("Report", systemImage: "doc.richtext")
            }
            .disabled(model.comparison == nil)
            .help("Save a comparison report")
            Menu {
                Button("Save Source as Snapshot…") { model.saveSnapshot(ofSource: true) }
                Button("Save Target as Snapshot…") { model.saveSnapshot(ofSource: false) }
                Divider()
                Button("Save Source as Scripts Folder…") { model.saveScriptsFolder(ofSource: true) }
                Button("Save Target as Scripts Folder…") { model.saveScriptsFolder(ofSource: false) }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .disabled(model.comparison == nil)
            .help("Snapshots and scripts folders")
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Schema Compare", systemImage: "rectangle.split.2x1")
        } description: {
            Text("Compare two databases, snapshots or scripts folders, see every difference as SQL, "
                 + "and deploy the ones you choose.")
        } actions: {
            Button("Set Up Comparison…") { model.showSetup = true }
            if model.canCompare {
                Button("Compare Now") { Task { await model.compare(app: app) } }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Results

    private var resultsPane: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            columnHeader
            Divider()
            List(selection: $model.selectedID) {
                ForEach(model.groups) { group in
                    Section {
                        ForEach(group.items) { difference in
                            SchemaDifferenceRow(difference: difference,
                                                isSelected: selectionBinding(difference.id))
                                .tag(difference.id)
                                .contextMenu { rowMenu(difference) }
                        }
                    } header: {
                        groupHeader(group)
                    }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
        }
    }

    private var filterBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter objects", text: $model.search).textFieldStyle(.plain)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .frame(maxWidth: 260)

            ForEach(DifferenceStatus.allCases, id: \.self) { status in
                Toggle(isOn: statusBinding(status)) {
                    HStack(spacing: 4) {
                        DifferenceStatusLabel(status: status)
                        Text("\(status.shortTitle) (\(model.count(status)))")
                    }
                }
                .toggleStyle(.button)
                .controlSize(.small)
            }
            Spacer()
            Picker("Group by", selection: $model.grouping) {
                ForEach(SchemaCompareModel.Grouping.allCases) { grouping in
                    Text(grouping.rawValue).tag(grouping)
                }
            }
            .frame(width: 190)
            Button("Select All") { model.setSelected(model.visibleDifferences, true) }
                .controlSize(.small)
            Button("Select None") { model.setSelected(model.visibleDifferences, false) }
                .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private var columnHeader: some View {
        HStack(spacing: 8) {
            Text("").frame(width: 20)
            Text("").frame(width: 18)
            Text("Source: \(model.source.endpoint.displayName)")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("").frame(width: 26)
            Text("Target: \(model.target.endpoint.displayName)")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Type").frame(width: 150, alignment: .leading)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }

    private func groupHeader(_ group: SchemaCompareModel.Group) -> some View {
        HStack {
            Text("\(group.title) (\(group.items.count))")
            Spacer()
            Button("All") { model.setSelected(group.items, true) }.buttonStyle(.link)
            Button("None") { model.setSelected(group.items, false) }.buttonStyle(.link)
        }
    }

    @ViewBuilder
    private func rowMenu(_ difference: SchemaDifference) -> some View {
        if difference.status != .identical {
            Button(difference.isSelected ? "Exclude from Deployment" : "Include in Deployment") {
                model.setSelected(difference.id, !difference.isSelected)
            }
        }
        Button("Exclude from Comparison") { model.excludeFromComparison(difference) }
        Divider()
        Button("Copy Source Script") { copy(difference.sourceScript) }
            .disabled(difference.sourceScript.isEmpty)
        Button("Copy Target Script") { copy(difference.targetScript) }
            .disabled(difference.targetScript.isEmpty)
        Button("Open Source Script in Query Window") {
            app.openScript(difference.sourceScript, server: nil, database: nil,
                           title: "\(difference.displayName) (source).sql")
        }
        .disabled(difference.sourceScript.isEmpty)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func selectionBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { model.isSelected(id) }, set: { model.setSelected(id, $0) })
    }

    private func statusBinding(_ status: DifferenceStatus) -> Binding<Bool> {
        Binding(get: { model.visibleStatuses.contains(status) },
                set: { isOn in
                    if isOn { model.visibleStatuses.insert(status) } else { model.visibleStatuses.remove(status) }
                })
    }

    // MARK: - Detail

    @ViewBuilder
    private var detailPane: some View {
        if let difference = model.selectedDifference {
            VStack(spacing: 0) {
                SchemaDifferenceSummary(difference: difference)
                Divider()
                SQLDiffView(left: difference.sourceScript, right: difference.targetScript,
                            leftTitle: "Source · \(difference.sourceName.isEmpty ? "(does not exist)" : difference.sourceName)",
                            rightTitle: "Target · \(difference.targetName.isEmpty ? "(does not exist)" : difference.targetName)",
                            ignoreWhitespace: model.options.ignoreWhitespace, settings: settings)
            }
        } else {
            Text("Select an object to see its SQL differences.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Status

    private var statusBar: some View {
        HStack(spacing: 10) {
            if model.isBusy {
                ProgressView(value: model.progress).frame(width: 160)
                Text(model.progressText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            } else {
                CompareStatusLine(text: model.statusText, isError: model.statusIsError)
            }
            Spacer()
            if model.comparison != nil {
                Text("\(model.deploymentCount) selected for deployment")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

/// One line of the results list.
struct SchemaDifferenceRow: View {
    let difference: SchemaDifference
    @Binding var isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: $isSelected)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(difference.status == .identical)
                .frame(width: 20)
            Image(systemName: difference.type.iconName)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(difference.sourceName)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            DifferenceStatusLabel(status: difference.status)
                .frame(width: 26)
            Text(difference.targetName)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(difference.type.title)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 150, alignment: .leading)
        }
    }
}

/// What differs, in words, above the SQL.
struct SchemaDifferenceSummary: View {
    let difference: SchemaDifference
    @State private var expanded = true

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(difference.details.enumerated()), id: \.offset) { item in
                        Text("• " + item.element)
                            .font(.callout)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 110)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: difference.type.iconName)
                Text("\(difference.type.title) \(difference.displayName)").font(.headline)
                Text("— \(difference.status.shortTitle)")
                    .foregroundStyle(DifferenceStatusLabel.color(difference.status))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}
