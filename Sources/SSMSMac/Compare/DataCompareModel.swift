import SwiftUI
import AppKit
import Combine
import TDSKit
import SQLServerKit

/// Everything behind one Data Compare window.
@MainActor
final class DataCompareModel: ObservableObject {
    let source = EndpointSelection()
    let target = EndpointSelection()
    let pool = CompareSessionPool()

    @Published var options = DataCompareOptions() {
        didSet {
            if Self.columnDefaultsChanged(oldValue, options) { remapColumns() }
        }
    }
    @Published var schemaMappings: [SchemaNameMapping] = []
    @Published var tablePairs: [String: String] = [:]
    @Published var mappings: [DataTableMapping] = []
    @Published var unmatchedSource: [DataTableInfo] = []
    @Published var unmatchedTarget: [DataTableInfo] = []
    @Published private(set) var targetForeignKeys: [DataForeignKeyInfo] = []
    @Published private(set) var comparison: DataComparison?
    @Published var selectedTableID: String?
    @Published var rowStatus: DataRowStatus = .different
    @Published var onlyDifferingColumns = true
    /// Bumped when row ticks change so the grid knows to redraw.
    @Published private(set) var rowVersion = 0

    @Published private(set) var isBusy = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var progressText = ""
    @Published var statusText = ""
    @Published var statusIsError = false
    @Published var projectURL: URL?
    @Published var showSetup = true
    @Published var showDeployment = false

    /// Per-table choices from an opened project, applied once the catalog is read.
    private var savedTables: [DataTableSettings] = []
    private var mappedFor: String = ""
    private var forwarding: [AnyCancellable] = []

    init() {
        forwarding.append(source.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() })
        forwarding.append(target.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() })
    }

    func configure(launch: CompareLaunch, app: AppState) {
        if let path = launch.projectPath {
            open(url: URL(fileURLWithPath: path))
            showSetup = false
            return
        }
        if let serverID = launch.serverID, let server = app.server(id: serverID) {
            source.profile = server.profile
            source.database = launch.database ?? server.serverInfo.currentDatabase
            target.profile = server.profile
            Task {
                await source.loadDatabases(app: app, pool: pool)
                await target.loadDatabases(app: app, pool: pool)
            }
        }
    }

    var canCompare: Bool { source.isComplete && target.isComplete && !isBusy }

    var title: String {
        if let projectURL { return projectURL.deletingPathExtension().lastPathComponent }
        if source.isComplete && target.isComplete {
            return "\(source.endpoint.displayName) → \(target.endpoint.displayName)"
        }
        return "Data Compare"
    }

    private var endpointsSignature: String {
        var parts: [String] = [source.endpoint.displayName, target.endpoint.displayName]
        for mapping in schemaMappings { parts.append(mapping.source + "=" + mapping.target) }
        for key in tablePairs.keys.sorted() { parts.append(key + ">" + (tablePairs[key] ?? "")) }
        parts.append(options.includeViews ? "views" : "tables")
        return parts.joined(separator: "|")
    }

    func swap() {
        let left = source.endpoint
        let leftDatabases = source.databases
        source.apply(target.endpoint)
        target.apply(left)
        source.databases = target.databases
        target.databases = leftDatabases
        schemaMappings = schemaMappings.map { SchemaNameMapping(id: $0.id, source: $0.target, target: $0.source) }
        var pairs: [String: String] = [:]
        for (key, value) in tablePairs { pairs[value] = key }
        tablePairs = pairs
        mappings = []
        comparison = nil
        mappedFor = ""
    }

    // MARK: - Mapping

    func loadMappings(app: AppState) async {
        guard source.isComplete, target.isComplete else { return }
        isBusy = true
        statusIsError = false
        progressText = "Reading tables"
        defer { isBusy = false }
        do {
            let previous = mappings.map { DataTableSettings(mapping: $0) }
            let sourceSession = try await pool.session(for: source.endpoint, app: app)
            let targetSession = try await pool.session(for: target.endpoint, app: app)
            let sourceCatalog = try await DataCompareCatalog(session: sourceSession)
                .read(database: source.endpoint.database, includeViews: options.includeViews)
            let targetCatalog = try await DataCompareCatalog(session: targetSession)
                .read(database: target.endpoint.database, includeViews: options.includeViews)
            var result = DataCompareMapper.map(source: sourceCatalog.tables, target: targetCatalog.tables,
                                               schemaMappings: schemaMappings, tablePairs: tablePairs,
                                               options: options)
            DataCompareMapper.apply(savedTables.isEmpty ? previous : savedTables, to: &result.mappings)
            savedTables = []
            mappings = result.mappings
            unmatchedSource = result.unmatchedSource
            unmatchedTarget = result.unmatchedTarget
            targetForeignKeys = targetCatalog.foreignKeys
            mappedFor = endpointsSignature
            let keyless: Int = mappings.filter { !$0.hasKey }.count
            var parts: [String] = ["\(mappings.count) table(s) mapped"]
            if keyless > 0 { parts.append("\(keyless) without a comparison key") }
            if !unmatchedSource.isEmpty { parts.append("\(unmatchedSource.count) only in source") }
            if !unmatchedTarget.isEmpty { parts.append("\(unmatchedTarget.count) only in target") }
            statusText = parts.joined(separator: ", ")
        } catch {
            statusText = String(describing: error)
            statusIsError = true
        }
    }

    func pair(source table: DataTableInfo, with other: DataTableInfo, app: AppState) async {
        tablePairs[table.qualifiedName] = other.qualifiedName
        await loadMappings(app: app)
    }

    func setIncluded(_ id: String, _ value: Bool) {
        guard let index = mappings.firstIndex(where: { $0.id == id }) else { return }
        mappings[index].isIncluded = value && mappings[index].hasKey
    }

    func setAllIncluded(_ value: Bool) {
        for index in mappings.indices { mappings[index].isIncluded = value && mappings[index].hasKey }
    }

    func mapping(_ id: String?) -> DataTableMapping? {
        guard let id else { return nil }
        return mappings.first { $0.id == id }
    }

    /// Use one of the source table's keys, or nil to go back to the automatic choice.
    func useKey(_ key: DataKeyInfo?, for id: String) {
        guard let index = mappings.firstIndex(where: { $0.id == id }) else { return }
        if let key {
            DataCompareMapper.useKey(&mappings[index], key: key)
        } else {
            DataCompareMapper.chooseKey(&mappings[index])
        }
        if !mappings[index].hasKey { mappings[index].isIncluded = false }
    }

    /// Adds or removes one column from a custom comparison key.
    func setKeyColumn(_ column: String, _ isKey: Bool, for id: String) {
        guard let index = mappings.firstIndex(where: { $0.id == id }) else { return }
        var names: [String] = mappings[index].keyColumns.map(\.sourceColumn)
        if isKey {
            if !names.contains(where: { $0.caseInsensitiveCompare(column) == .orderedSame }) { names.append(column) }
        } else {
            names.removeAll { $0.caseInsensitiveCompare(column) == .orderedSame }
        }
        DataCompareMapper.setCustomKey(&mappings[index], columns: names)
        if !mappings[index].hasKey { mappings[index].isIncluded = false }
    }

    func setColumnIncluded(_ columnID: String, _ value: Bool, for id: String) {
        guard let index = mappings.firstIndex(where: { $0.id == id }),
              let column = mappings[index].columns.firstIndex(where: { $0.id == columnID }),
              !mappings[index].columns[column].isKey else { return }
        mappings[index].columns[column].isIncluded = value
    }

    func setWhere(_ text: String, source: Bool, for id: String) {
        guard let index = mappings.firstIndex(where: { $0.id == id }) else { return }
        if source {
            mappings[index].sourceWhere = text
        } else {
            mappings[index].targetWhere = text
        }
    }

    func unpair(_ id: String, app: AppState) async {
        guard let mapping = mapping(id) else { return }
        tablePairs.removeValue(forKey: mapping.source.qualifiedName)
        await loadMappings(app: app)
    }

    private static func columnDefaultsChanged(_ old: DataCompareOptions, _ new: DataCompareOptions) -> Bool {
        old.includeTimestampColumns != new.includeTimestampColumns
            || old.includeIdentityColumns != new.includeIdentityColumns
            || old.includeComputedColumns != new.includeComputedColumns
            || old.ignoreLargeObjects != new.ignoreLargeObjects
    }

    /// Options that decide which columns are compared by default were changed: pair the
    /// columns again, keeping each table's key, filters and inclusion.
    private func remapColumns() {
        for index in mappings.indices {
            let keys: [String] = mappings[index].keyColumns.map(\.sourceColumn)
            DataCompareMapper.mapColumns(&mappings[index], options: options)
            if keys.isEmpty {
                DataCompareMapper.chooseKey(&mappings[index])
            } else {
                DataCompareMapper.useKey(&mappings[index], columns: keys)
            }
        }
    }

    // MARK: - Comparing

    func compare(app: AppState) async {
        guard canCompare else { return }
        if mappings.isEmpty || mappedFor != endpointsSignature {
            await loadMappings(app: app)
        }
        guard !statusIsError, !mappings.isEmpty else { return }
        isBusy = true
        progress = 0
        defer { isBusy = false }
        do {
            let sourceSession = try await pool.session(for: source.endpoint, app: app)
            let targetSession = try await pool.session(for: target.endpoint, app: app)
            let comparer = DataComparer(sourceSession: sourceSession, sourceDatabase: source.endpoint.database,
                                        targetSession: targetSession, targetDatabase: target.endpoint.database,
                                        options: options)
            let result = try await comparer.compare(mappings, targetForeignKeys: targetForeignKeys) { index, total, name in
                Task { @MainActor [weak self] in
                    self?.progress = total > 0 ? Double(index) / Double(total) : 1
                    self?.progressText = name
                }
            }
            comparison = result
            if selectedTableID == nil || !result.tables.contains(where: { $0.id == selectedTableID }) {
                selectedTableID = result.tables.first(where: { $0.hasDifferences })?.id ?? result.tables.first?.id
            }
            let failed: Int = result.tables.filter { $0.error != nil }.count
            let seconds: String = String(format: "%.1f", result.duration)
            var text: String = "Compared \(result.tables.count) table(s) in \(seconds) s: "
            text += "\(result.total(.different)) different, \(result.total(.onlyInSource)) only in source, "
            text += "\(result.total(.onlyInTarget)) only in target, \(result.total(.identical)) identical rows"
            if failed > 0 { text += " · \(failed) table(s) failed" }
            statusText = text
            statusIsError = false
            showSetup = false
        } catch {
            statusText = String(describing: error)
            statusIsError = true
        }
    }

    // MARK: - Results

    var tables: [DataTableResult] { comparison?.tables ?? [] }

    var selectedTable: DataTableResult? {
        guard let selectedTableID else { return nil }
        return comparison?.tables.first { $0.id == selectedTableID }
    }

    func setTableSelected(_ id: String, _ value: Bool) {
        guard var result = comparison, let index = result.tables.firstIndex(where: { $0.id == id }) else { return }
        result.tables[index].isSelected = value
        comparison = result
    }

    func setRowSelected(tableID: String, rowID: Int, _ value: Bool) {
        guard var result = comparison, let tableIndex = result.tables.firstIndex(where: { $0.id == tableID }),
              let rowIndex = result.tables[tableIndex].rows.firstIndex(where: { $0.id == rowID }) else { return }
        result.tables[tableIndex].rows[rowIndex].isSelected = value
        comparison = result
        rowVersion += 1
    }

    func setRowsSelected(tableID: String, status: DataRowStatus, _ value: Bool) {
        guard var result = comparison, let tableIndex = result.tables.firstIndex(where: { $0.id == tableID }) else { return }
        for index in result.tables[tableIndex].rows.indices where result.tables[tableIndex].rows[index].status == status {
            result.tables[tableIndex].rows[index].isSelected = value && status != .identical
        }
        comparison = result
        rowVersion += 1
    }

    var hasDeployableDifferences: Bool {
        tables.contains { $0.isSelected && $0.hasDifferences && $0.error == nil }
    }

    // MARK: - Deployment

    func plan() -> DataSyncPlan? {
        guard let comparison else { return nil }
        return DataSyncScripter(comparison: comparison, options: options).plan()
    }

    func deploy(_ plan: DataSyncPlan, app: AppState,
                progress: @escaping @Sendable (Int, Int, String) -> Void) async throws -> ScriptRunner.Outcome {
        let session = try await pool.session(for: target.endpoint, app: app)
        return try await ScriptRunner(session: session, database: target.endpoint.database).run(plan.script,
                                                                                                progress: progress)
    }

    // MARK: - Files

    var project: CompareProject {
        let tables = mappings.map { DataTableSettings(mapping: $0) }
        return CompareProject(kind: .data, name: title, source: source.endpoint, target: target.endpoint,
                              data: DataProjectSettings(options: options, schemaMappings: schemaMappings,
                                                        tables: tables, tablePairs: tablePairs))
    }

    func save(as saveAs: Bool) {
        var url = projectURL
        if url == nil || saveAs {
            url = CompareFilePanels.save(name: "\(title).dcmp", types: [CompareFilePanels.dataProjectType])
        }
        guard let url else { return }
        do {
            try project.write(to: url)
            projectURL = url
            report("Project saved to \(url.path).")
        } catch {
            report(String(describing: error), isError: true)
        }
    }

    func open(url: URL) {
        do {
            let project = try CompareProject.read(from: url)
            guard project.kind == .data, let settings = project.data else {
                throw SQLServerError.unsupportedOperation("That is not a data comparison project.")
            }
            source.apply(project.source)
            target.apply(project.target)
            options = settings.options
            schemaMappings = settings.schemaMappings
            tablePairs = settings.tablePairs
            savedTables = settings.tables
            mappings = []
            comparison = nil
            mappedFor = ""
            projectURL = url
            report("Opened \(url.lastPathComponent). Press Compare to run it.")
        } catch {
            report(String(describing: error), isError: true)
        }
    }

    func openProject() {
        guard let url = CompareFilePanels.open(directory: false, types: [CompareFilePanels.dataProjectType]) else {
            return
        }
        open(url: url)
    }

    func exportReport(_ format: CompareReportFormat) {
        guard let comparison else { return }
        guard let url = CompareFilePanels.save(name: "Data comparison.\(format.fileExtension)",
                                               types: [CompareFilePanels.reportType(format)]) else { return }
        do {
            try DataCompareReport(comparison: comparison).render(format).write(to: url)
            report("Report saved to \(url.path).")
            if format == .html { NSWorkspace.shared.open(url) }
        } catch {
            report(String(describing: error), isError: true)
        }
    }

    func report(_ text: String, isError: Bool = false) {
        statusText = text
        statusIsError = isError
    }

    func close() {
        pool.closeAll()
    }
}
