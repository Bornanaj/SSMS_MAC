import SwiftUI
import AppKit
import Combine
import TDSKit
import SQLServerKit

/// Everything behind one Schema Compare window: the project, the last comparison, what is
/// ticked for deployment and how the results list is filtered.
@MainActor
final class SchemaCompareModel: ObservableObject {
    enum Grouping: String, CaseIterable, Identifiable {
        case status = "Result"
        case type = "Object type"
        var id: String { rawValue }
    }

    let source = EndpointSelection()
    let target = EndpointSelection()
    let pool = CompareSessionPool()

    @Published var options = SchemaCompareOptions()
    @Published var filter = SchemaFilter()
    @Published var mappings = SchemaMappings()

    @Published private(set) var comparison: SchemaComparison?
    @Published var differences: [SchemaDifference] = []
    @Published var selectedID: String?
    @Published var search = ""
    @Published var visibleStatuses: Set<DifferenceStatus> = [.different, .onlyInSource, .onlyInTarget]
    @Published var grouping: Grouping = .status

    @Published private(set) var isBusy = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var progressText = ""
    @Published var statusText = ""
    @Published var statusIsError = false
    @Published var projectURL: URL?
    @Published var showSetup = true
    @Published var showDeployment = false

    private var forwarding: [AnyCancellable] = []

    init() {
        // The endpoint pickers publish on their own; the window's toolbar depends on them too.
        forwarding.append(source.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() })
        forwarding.append(target.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() })
    }

    // MARK: - Setup

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
        return "Schema Compare"
    }

    func swap() {
        let left = source.endpoint
        let right = target.endpoint
        let leftDatabases = source.databases
        source.apply(right)
        target.apply(left)
        source.databases = target.databases
        target.databases = leftDatabases
        mappings.schemaMappings = mappings.schemaMappings.map {
            SchemaNameMapping(id: $0.id, source: $0.target, target: $0.source)
        }
        mappings.objectMappings = mappings.objectMappings.map {
            ObjectMapping(id: $0.id, source: $0.target, target: $0.source)
        }
        comparison = nil
        differences = []
    }

    // MARK: - Comparing

    func compare(app: AppState) async {
        guard canCompare else { return }
        isBusy = true
        statusIsError = false
        progress = 0
        defer { isBusy = false }
        do {
            let sourceSnapshot = try await load(source.endpoint, side: "source", app: app, share: 0.45, offset: 0)
            let targetSnapshot = try await load(target.endpoint, side: "target", app: app, share: 0.45, offset: 0.45)
            progressText = "Comparing"
            progress = 0.92
            let comparer = SchemaComparer(options: options, filter: filter, mappings: mappings)
            let result = await Task.detached(priority: .userInitiated) {
                comparer.compare(source: sourceSnapshot, target: targetSnapshot)
            }.value
            let previouslyDeselected = Set(differences.filter { !$0.isSelected }.map(\.id))
            comparison = result
            differences = result.differences.map { difference in
                var copy = difference
                if previouslyDeselected.contains(difference.id) { copy.isSelected = false }
                return copy
            }
            if selectedID == nil || !differences.contains(where: { $0.id == selectedID }) {
                selectedID = visibleDifferences.first?.id
            }
            progress = 1
            let warnings: Int = sourceSnapshot.warnings.count + targetSnapshot.warnings.count
            var text: String = "Compared at \(Self.time()): \(result.count(.different)) different, "
            text += "\(result.count(.onlyInSource)) only in source, \(result.count(.onlyInTarget)) only in target, "
            text += "\(result.count(.identical)) identical"
            if warnings > 0 { text += " · \(warnings) warning(s) while reading" }
            statusText = text
            showSetup = false
        } catch {
            statusText = String(describing: error)
            statusIsError = true
        }
    }

    private func load(_ endpoint: CompareEndpoint, side: String, app: AppState, share: Double,
                      offset: Double) async throws -> SchemaSnapshot {
        switch endpoint.kind {
        case .snapshot:
            progressText = "Loading \(side) snapshot"
            let url = URL(fileURLWithPath: endpoint.path)
            return try await Task.detached { try SchemaSnapshotFile.read(from: url) }.value
        case .scriptsFolder:
            progressText = "Reading \(side) scripts"
            let url = URL(fileURLWithPath: endpoint.path)
            return try await Task.detached { try ScriptsFolder.read(from: url) }.value
        case .database:
            progressText = "Connecting to \(side)"
            let session = try await pool.session(for: endpoint, app: app)
            let reader = LiveSchemaReader(session: session)
            let database = endpoint.database
            return try await reader.read(database: database) { fraction, text in
                Task { @MainActor [weak self] in
                    self?.progress = offset + share * fraction
                    self?.progressText = "\(side.capitalized): \(text)"
                }
            }
        }
    }

    static func time() -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: Date())
    }

    // MARK: - Results

    var visibleDifferences: [SchemaDifference] {
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        return differences.filter { difference in
            guard visibleStatuses.contains(difference.status) else { return false }
            guard !needle.isEmpty else { return true }
            return difference.sourceName.lowercased().contains(needle)
                || difference.targetName.lowercased().contains(needle)
                || difference.type.title.lowercased().contains(needle)
        }
    }

    struct Group: Identifiable {
        var id: String
        var title: String
        var items: [SchemaDifference]
    }

    var groups: [Group] {
        let visible = visibleDifferences
        switch grouping {
        case .status:
            return DifferenceStatus.allCases.compactMap { status in
                let items = visible.filter { $0.status == status }
                return items.isEmpty ? nil : Group(id: status.rawValue, title: status.title, items: items)
            }
        case .type:
            return SchemaObjectType.allCases.compactMap { type in
                let items = visible.filter { $0.type == type }
                return items.isEmpty ? nil : Group(id: type.rawValue, title: type.pluralTitle, items: items)
            }
        }
    }

    var selectedDifference: SchemaDifference? {
        guard let selectedID else { return nil }
        return differences.first { $0.id == selectedID }
    }

    func count(_ status: DifferenceStatus) -> Int {
        differences.reduce(0) { $0 + ($1.status == status ? 1 : 0) }
    }

    var deploymentCount: Int {
        differences.reduce(0) { $0 + ($1.isSelected && $1.status != .identical ? 1 : 0) }
    }

    func isSelected(_ id: String) -> Bool {
        differences.first { $0.id == id }?.isSelected ?? false
    }

    func setSelected(_ id: String, _ value: Bool) {
        guard let index = differences.firstIndex(where: { $0.id == id }) else { return }
        differences[index].isSelected = value
    }

    func setSelected(_ items: [SchemaDifference], _ value: Bool) {
        let ids = Set(items.map(\.id))
        for index in differences.indices where ids.contains(differences[index].id) {
            differences[index].isSelected = value && differences[index].status != .identical
        }
    }

    /// Filters out the selected object from future comparisons, like Redgate's
    /// "Exclude objects like this".
    func excludeFromComparison(_ difference: SchemaDifference) {
        let key = difference.sourceKey ?? difference.targetKey
        guard let key else { return }
        filter.rules.append(SchemaFilterRule(action: .exclude, types: [key.type], field: .qualifiedName,
                                             op: .equals, value: key.qualifiedName))
        differences.removeAll { $0.id == difference.id }
    }

    // MARK: - Deployment

    /// The comparison as it currently stands, including ticks.
    var currentComparison: SchemaComparison? {
        guard var result = comparison else { return nil }
        result.differences = differences
        return result
    }

    func plan() -> DeploymentPlan? {
        guard let result = currentComparison else { return nil }
        let database = target.endpoint.kind == .database ? target.endpoint.database : nil
        return SchemaDeploymentPlanner(comparison: result, targetDatabaseName: database).plan()
    }

    func deploy(_ plan: DeploymentPlan, app: AppState,
                progress: @escaping @Sendable (Int, Int, String) -> Void) async throws -> ScriptRunner.Outcome {
        let endpoint = target.endpoint
        guard endpoint.kind == .database else {
            throw SQLServerError.unsupportedOperation("Only a live database can be deployed to with a script.")
        }
        let session = try await pool.session(for: endpoint, app: app)
        return try await ScriptRunner(session: session, database: endpoint.database).run(plan.script, progress: progress)
    }

    func deployToScriptsFolder() throws -> [String] {
        guard let result = currentComparison, target.endpoint.kind == .scriptsFolder else { return [] }
        return try ScriptsFolder.apply(result, to: URL(fileURLWithPath: target.endpoint.path))
    }

    // MARK: - Files

    var project: CompareProject {
        let deselected = Set(differences.filter { !$0.isSelected && $0.status != .identical }.map(\.id))
        return CompareProject(kind: .schema, name: title, source: source.endpoint, target: target.endpoint,
                              schema: SchemaProjectSettings(options: options, filter: filter, mappings: mappings,
                                                            deselected: deselected))
    }

    func save(as saveAs: Bool) {
        var url = projectURL
        if url == nil || saveAs {
            url = CompareFilePanels.save(name: "\(title).scmp", types: [CompareFilePanels.schemaProjectType])
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
            guard project.kind == .schema, let settings = project.schema else {
                throw SQLServerError.unsupportedOperation("That is not a schema comparison project.")
            }
            source.apply(project.source)
            target.apply(project.target)
            options = settings.options
            filter = settings.filter
            mappings = settings.mappings
            comparison = nil
            differences = []
            projectURL = url
            report("Opened \(url.lastPathComponent). Press Compare to run it.")
        } catch {
            report(String(describing: error), isError: true)
        }
    }

    func openProject() {
        guard let url = CompareFilePanels.open(directory: false, types: [CompareFilePanels.schemaProjectType]) else {
            return
        }
        open(url: url)
    }

    func exportReport(_ format: CompareReportFormat) {
        guard let result = currentComparison else { return }
        guard let url = CompareFilePanels.save(name: "Schema comparison.\(format.fileExtension)",
                                               types: [CompareFilePanels.reportType(format)]) else { return }
        do {
            try SchemaCompareReport(comparison: result).render(format).write(to: url)
            report("Report saved to \(url.path).")
            if format == .html { NSWorkspace.shared.open(url) }
        } catch {
            report(String(describing: error), isError: true)
        }
    }

    func saveSnapshot(ofSource: Bool) {
        guard let result = comparison else { return }
        let snapshot = ofSource ? result.source : result.target
        let name = (snapshot.databaseName.isEmpty ? "Schema" : snapshot.databaseName) + ".\(SchemaSnapshotFile.fileExtension)"
        guard let url = CompareFilePanels.save(name: name, types: [CompareFilePanels.snapshotType]) else { return }
        do {
            try SchemaSnapshotFile.write(snapshot, to: url)
            report("Snapshot saved to \(url.path) (\(snapshot.objects.count) objects).")
        } catch {
            report(String(describing: error), isError: true)
        }
    }

    func saveScriptsFolder(ofSource: Bool) {
        guard let result = comparison else { return }
        let snapshot = ofSource ? result.source : result.target
        guard let url = CompareFilePanels.chooseFolder(prompt: "Write Scripts") else { return }
        do {
            let count = try ScriptsFolder.write(snapshot, to: url)
            report("\(count) object scripts written to \(url.path).")
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
