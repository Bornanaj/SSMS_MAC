import SwiftUI
import AppKit
import SQLServerKit

/// The Data Compare window: one line per table with its row counts by outcome, and the rows
/// of the selected table underneath, filtered by outcome, each ticked for deployment.
struct DataCompareWindow: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var settings: AppSettings
    @Environment(\.openWindow) private var openWindow
    let launch: CompareLaunch

    @StateObject private var model = DataCompareModel()
    @State private var configured = false
    @State private var search = ""
    @State private var onlyDifferences = false

    var body: some View {
        VStack(spacing: 0) {
            if model.comparison == nil {
                emptyState
            } else {
                VSplitView {
                    tablesPane
                        .frame(minHeight: 160, idealHeight: 280)
                    rowsPane
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
            DataCompareSetupSheet(model: model)
                .environmentObject(app)
        }
        .sheet(isPresented: $model.showDeployment) {
            DataDeploymentSheet(model: model)
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
                openWindow(id: "data-compare", value: CompareLaunch())
            } label: {
                Label("New", systemImage: "doc.badge.plus")
            }
            .help("New data comparison")
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
            .help("Data sources, options, tables, keys and filters")
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
            .disabled(!model.hasDeployableDifferences || model.isBusy)
            .help("Review, script and deploy the selected rows")
            Menu {
                ForEach(CompareReportFormat.allCases) { format in
                    Button(format.title) { model.exportReport(format) }
                }
            } label: {
                Label("Report", systemImage: "doc.richtext")
            }
            .disabled(model.comparison == nil)
            .help("Save a comparison report")
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Data Compare", systemImage: "tablecells.badge.ellipsis")
        } description: {
            Text("Compare the rows of two databases table by table, see every difference, "
                 + "and synchronize the ones you choose.")
        } actions: {
            Button("Set Up Comparison…") { model.showSetup = true }
            if model.canCompare {
                Button("Compare Now") { Task { await model.compare(app: app) } }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Tables

    private var visibleTables: [DataTableResult] {
        var tables: [DataTableResult] = model.tables
        if onlyDifferences { tables = tables.filter { $0.hasDifferences || $0.error != nil } }
        if !search.isEmpty {
            tables = tables.filter { $0.mapping.displayName.localizedCaseInsensitiveContains(search) }
        }
        return tables
    }

    private var tablesPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Filter tables", text: $search).textFieldStyle(.plain)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .frame(maxWidth: 260)
                Toggle("Only tables with differences", isOn: $onlyDifferences)
                    .toggleStyle(.checkbox)
                Spacer()
                Button("Select All") { setVisibleSelected(true) }.controlSize(.small)
                Button("Select None") { setVisibleSelected(false) }.controlSize(.small)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            Divider()
            Table(visibleTables, selection: $model.selectedTableID) {
                TableColumn("") { table in
                    Toggle("", isOn: tableBinding(table.id))
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                        .disabled(!table.hasDifferences || table.error != nil)
                }
                .width(22)
                TableColumn("Table") { table in
                    DataTableNameCell(table: table)
                }
                .width(min: 180, ideal: 280)
                TableColumn("Comparison key") { table in
                    Text(table.mapping.keyDescription).foregroundStyle(.secondary).lineLimit(1)
                }
                .width(min: 100, ideal: 160)
                TableColumn("Different") { table in
                    DataCountCell(value: table.different, color: .orange)
                }
                .width(70)
                TableColumn("Only in source") { table in
                    DataCountCell(value: table.onlyInSource, color: .green)
                }
                .width(95)
                TableColumn("Only in target") { table in
                    DataCountCell(value: table.onlyInTarget, color: .red)
                }
                .width(95)
                TableColumn("Identical") { table in
                    DataCountCell(value: table.identical, color: .secondary)
                }
                .width(70)
                TableColumn("Rows (source / target)") { table in
                    Text("\(table.sourceRows) / \(table.targetRows)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .width(min: 110, ideal: 140)
            }
        }
    }

    private func tableBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { model.tables.first { $0.id == id }?.isSelected ?? false },
                set: { model.setTableSelected(id, $0) })
    }

    private func setVisibleSelected(_ value: Bool) {
        for table in visibleTables where table.hasDifferences { model.setTableSelected(table.id, value) }
    }

    // MARK: - Rows

    @ViewBuilder
    private var rowsPane: some View {
        if let table = model.selectedTable {
            VStack(spacing: 0) {
                rowsBar(table)
                Divider()
                if let error = table.error {
                    ScrollView {
                        Label(error, systemImage: "xmark.octagon.fill")
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                    }
                } else {
                    if !table.notes.isEmpty || table.isTruncated || table.comparedByChecksum {
                        notes(table)
                        Divider()
                    }
                    rowsContent(table)
                }
            }
        } else {
            Text("Select a table to see its rows.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func rowsBar(_ table: DataTableResult) -> some View {
        HStack(spacing: 10) {
            Picker("Rows", selection: $model.rowStatus) {
                ForEach(DataRowStatus.allCases, id: \.self) { status in
                    Text("\(status.title) (\(table.count(status)))").tag(status)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 560)
            if model.rowStatus == .different {
                Toggle("Only differing columns", isOn: $model.onlyDifferingColumns)
                    .toggleStyle(.checkbox)
            }
            Spacer()
            if model.rowStatus != .identical {
                Button("Select All") {
                    model.setRowsSelected(tableID: table.id, status: model.rowStatus, true)
                }
                .controlSize(.small)
                Button("Select None") {
                    model.setRowsSelected(tableID: table.id, status: model.rowStatus, false)
                }
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func notes(_ table: DataTableResult) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if table.comparedByChecksum {
                Label("Row count and checksum match, so the rows were not read.", systemImage: "number")
            }
            if table.isTruncated {
                Label("Only the first \(model.options.maximumRowsKept) rows of each kind are shown and deployable.",
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            ForEach(Array(table.notes.enumerated()), id: \.offset) { item in
                Label(item.element, systemImage: "info.circle")
            }
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func rowsContent(_ table: DataTableResult) -> some View {
        let shown: Int = table.rows.filter { $0.status == model.rowStatus }.count
        if shown == 0 {
            Text(emptyRowsText(table))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            DataRowsGrid(table: table, status: model.rowStatus, onlyDifferingColumns: model.onlyDifferingColumns,
                         version: model.rowVersion, font: settings.gridFont, nullText: settings.gridNullText) { rowID, value in
                model.setRowSelected(tableID: table.id, rowID: rowID, value)
            }
        }
    }

    private func emptyRowsText(_ table: DataTableResult) -> String {
        if model.rowStatus == .identical && table.identical > 0 && !model.options.keepIdenticalRows {
            return "Identical rows are not kept. Turn on “Show identical rows” in the options to browse them."
        }
        return "No rows are \(model.rowStatus.title.lowercased())."
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
            if let comparison = model.comparison {
                let selected: Int = comparison.tables.filter { $0.isSelected && $0.hasDifferences }.count
                Text("\(selected) table(s) selected for deployment")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

struct DataTableNameCell: View {
    let table: DataTableResult

    var body: some View {
        HStack(spacing: 6) {
            if table.error != nil {
                Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
            } else if table.hasDifferences {
                Image(systemName: "circle.fill").font(.system(size: 7)).foregroundStyle(.orange)
            } else {
                Image(systemName: "equal").foregroundStyle(.secondary)
            }
            Image(systemName: table.mapping.source.isView ? "eye" : "tablecells").foregroundStyle(.secondary)
            Text(table.mapping.displayName).lineLimit(1).truncationMode(.middle)
        }
    }
}

struct DataCountCell: View {
    let value: Int
    let color: Color

    var body: some View {
        Text("\(value)")
            .monospacedDigit()
            .fontWeight(value > 0 && color != .secondary ? .semibold : .regular)
            .foregroundStyle(value > 0 ? color : Color.secondary)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }
}
