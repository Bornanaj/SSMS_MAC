import Foundation
import SwiftUI
import AppKit
import TDSKit
import SQLServerKit

/// A server the user is connected to, plus the UI-visible bits of its identity.
@MainActor
final class ConnectedServer: ObservableObject, Identifiable {
    let id: UUID
    let session: SQLServerSession
    let profile: ConnectionProfile
    @Published var serverInfo: ServerInfo

    init(session: SQLServerSession, profile: ConnectionProfile, serverInfo: ServerInfo) {
        self.id = session.id
        self.session = session
        self.profile = profile
        self.serverInfo = serverInfo
    }

    var displayName: String {
        serverInfo.serverName.isEmpty ? profile.displayName : serverInfo.serverName
    }
}

/// Top level application state: connected servers, query tabs, and the sheets
/// the main window can present.
@MainActor
final class AppState: ObservableObject {
    @Published private(set) var servers: [ConnectedServer] = []
    @Published var tabs: [QueryTab] = []
    @Published var selectedTabID: UUID?

    @Published var isConnecting = false
    @Published var connectionError: String?

    @Published var showConnectSheet = false
    @Published var showObjectExplorer = true
    /// The Object Explorer Details list under the tree, toggled with F7 like SSMS.
    @Published var showExplorerDetails = false
    @Published var activeSheet: AppSheet?
    @Published var statusMessage: String = "Ready"

    let explorer = ObjectExplorerModel()
    let connections = ConnectionStore()
    let settings = AppSettings.shared
    let history = QueryHistoryStore()

    private var untitledCounter = 1

    enum AppSheet: Identifiable {
        case connect
        case activityMonitor(UUID)
        case databaseProperties(UUID, String)
        case tableProperties(UUID, String, String, String)
        case backup(UUID, String)
        case restore(UUID)
        case importFlatFile(UUID, String)
        case exportResults(UUID)
        case editData(UUID, String, String, String)
        case scriptPreview(String, String)
        case executionPlan(String, String)
        case indexMaintenance(UUID, String)

        // Object and server management
        case serverProperties(UUID)
        case newDatabase(UUID)
        case attachDatabase(UUID)
        case detachDatabase(UUID, String)
        case shrinkDatabase(UUID, String)
        case renameObject(UUID, ObjectExplorerNode)
        case deleteObject(UUID, ObjectExplorerNode)
        case dependencies(UUID, ObjectExplorerNode)
        case permissions(UUID, ObjectExplorerNode)
        case generateScripts(UUID, String)

        // Monitoring
        case serverLog(UUID)
        case agentJob(UUID, String)
        case queryStore(UUID, String)
        case serverDashboard(UUID)

        // Query window
        case queryOptions(UUID)
        case templateParameters(UUID)
        case goToLine(UUID)
        case multiServerQuery(UUID)

        var id: String {
            switch self {
            case .connect: return "connect"
            case .activityMonitor(let s): return "activity-\(s)"
            case .databaseProperties(let s, let d): return "dbprops-\(s)-\(d)"
            case .tableProperties(let s, let d, let sc, let t): return "tblprops-\(s)-\(d)-\(sc)-\(t)"
            case .backup(let s, let d): return "backup-\(s)-\(d)"
            case .restore(let s): return "restore-\(s)"
            case .importFlatFile(let s, let d): return "import-\(s)-\(d)"
            case .exportResults(let t): return "export-\(t)"
            case .editData(let s, let d, let sc, let t): return "edit-\(s)-\(d)-\(sc)-\(t)"
            case .scriptPreview(let title, _): return "script-\(title)"
            case .executionPlan(let title, _): return "plan-\(title)"
            case .indexMaintenance(let s, let d): return "indexes-\(s)-\(d)"
            case .serverProperties(let s): return "serverprops-\(s)"
            case .newDatabase(let s): return "newdb-\(s)"
            case .attachDatabase(let s): return "attach-\(s)"
            case .detachDatabase(let s, let d): return "detach-\(s)-\(d)"
            case .shrinkDatabase(let s, let d): return "shrink-\(s)-\(d)"
            case .renameObject(let s, let n): return "rename-\(s)-\(n.id)"
            case .deleteObject(let s, let n): return "delete-\(s)-\(n.id)"
            case .dependencies(let s, let n): return "deps-\(s)-\(n.id)"
            case .permissions(let s, let n): return "perms-\(s)-\(n.id)"
            case .generateScripts(let s, let d): return "genscripts-\(s)-\(d)"
            case .serverLog(let s): return "log-\(s)"
            case .agentJob(let s, let j): return "job-\(s)-\(j)"
            case .queryStore(let s, let d): return "querystore-\(s)-\(d)"
            case .serverDashboard(let s): return "dashboard-\(s)"
            case .queryOptions(let t): return "queryoptions-\(t)"
            case .templateParameters(let t): return "templateparams-\(t)"
            case .goToLine(let t): return "gotoline-\(t)"
            case .multiServerQuery(let t): return "multiserver-\(t)"
            }
        }
    }

    var selectedTab: QueryTab? {
        guard let selectedTabID else { return tabs.first }
        return tabs.first { $0.id == selectedTabID }
    }

    func server(id: UUID) -> ConnectedServer? { servers.first { $0.id == id } }

    /// The server a node in the Object Explorer belongs to.
    func server(for node: ObjectExplorerNode) -> ConnectedServer? {
        guard let head = node.id.split(separator: "/").first,
              let uuid = UUID(uuidString: String(head)) else { return nil }
        return server(id: uuid)
    }

    /// The server the menus act on: the one behind the front query tab, else the first.
    var currentServer: ConnectedServer? {
        servers.first { $0.id == selectedTab?.sessionID } ?? servers.first
    }

    /// The node the Object Explorer has selected, if any.
    var selectedExplorerNode: ObjectExplorerNode? {
        explorer.selectedID.flatMap { explorer.node(id: $0) }
    }

    // MARK: - Connecting

    func connect(profile: ConnectionProfile, password: String?, accessToken: String? = nil) async {
        isConnecting = true
        connectionError = nil
        defer { isConnecting = false }

        do {
            let session = try await SQLServerSession.connect(profile: profile,
                                                             password: password,
                                                             accessToken: accessToken)
            let info = await session.serverInfo
            let server = ConnectedServer(session: session, profile: profile, serverInfo: info)
            servers.append(server)
            connections.save(profile, password: password)
            await explorer.addServer(session: session)
            statusMessage = "Connected to \(info.serverName)."

            // SSMS opens a query window against the server you just connected to when
            // there is nothing else to look at.
            if tabs.isEmpty {
                await newQueryTab(server: server, database: info.currentDatabase)
            }
        } catch {
            connectionError = String(describing: error)
            statusMessage = "Connection failed."
        }
    }

    func disconnect(server: ConnectedServer) async {
        explorer.removeServer(sessionID: server.id)
        for tab in tabs where tab.sessionID == server.id {
            await tab.disconnect()
        }
        await server.session.close()
        servers.removeAll { $0.id == server.id }
        statusMessage = "Disconnected from \(server.displayName)."
    }

    // MARK: - Query tabs

    @discardableResult
    func newQueryTab(server: ConnectedServer?, database: String?, text: String = "") async -> QueryTab {
        let tab = QueryTab(title: "SQLQuery\(untitledCounter).sql", text: text)
        untitledCounter += 1
        tab.maxRows = settings.gridMaxRows
        tab.timeoutSeconds = settings.executionTimeoutSeconds
        tab.resultsDestination = settings.defaultResultsDestination
        tab.textResultOptions = settings.textResultOptions
        tab.onExecutionFinished = { [weak self] finished in
            self?.recordHistory(for: finished)
        }
        tab.requestResultsFile = { [weak self] finished, contents in
            self?.saveResultsToFile(tab: finished, contents: contents)
        }
        tabs.append(tab)
        selectedTabID = tab.id
        if let server {
            await tab.attach(session: server.session, database: database)
        }
        tab.isDirty = false
        return tab
    }

    /// Query History is filled from here rather than from `QueryTab`, which has no idea
    /// the store exists.
    private func recordHistory(for tab: QueryTab) {
        let script = tab.executedScript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !script.isEmpty else { return }
        history.limit = settings.queryHistoryLimit
        let firstError = tab.messages.first { $0.kind == .error }
        history.record(QueryHistoryEntry(
            sql: script,
            server: tab.serverLabel.isEmpty ? tab.sessionName : tab.serverLabel,
            database: tab.database,
            startedAt: tab.summary?.startedAt ?? Date(),
            elapsed: tab.summary?.elapsed ?? tab.elapsed,
            rowsReturned: tab.summary?.totalRows ?? 0,
            succeeded: tab.summary?.succeeded ?? (firstError == nil),
            errorText: firstError?.text
        ))
    }

    /// Results to File: SSMS asks for the destination once the query has finished.
    private func saveResultsToFile(tab: QueryTab, contents: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.allowsOtherFileTypes = true
        let base = tab.fileURL?.deletingPathExtension().lastPathComponent ?? tab.title
        panel.nameFieldStringValue = base.replacingOccurrences(of: ".sql", with: "") + ".rpt"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                do {
                    try contents.write(to: url, atomically: true, encoding: .utf8)
                    self?.statusMessage = "Results written to \(url.lastPathComponent)."
                } catch {
                    self?.statusMessage = "Could not write results: \(error)"
                }
            }
        }
    }

    func closeTab(_ tab: QueryTab) {
        Task { await tab.disconnect() }
        tabs.removeAll { $0.id == tab.id }
        if selectedTabID == tab.id { selectedTabID = tabs.last?.id }
    }

    func openScript(_ sql: String, server: ConnectedServer?, database: String?, title: String) {
        Task {
            let tab = await newQueryTab(server: server, database: database, text: sql)
            tab.title = title
            tab.isDirty = false
        }
    }

    /// Where the Permissions dialog should point for a tree node.
    ///
    /// A principal is not a securable — there is nothing to grant *on* a login. Picking
    /// one opens the scope it lives in, which is where its grants are listed.
    func permissionTarget(for node: ObjectExplorerNode) -> PermissionTarget {
        switch node.kind {
        case .server, .login, .serverRole, .credential, .linkedServer:
            return .server
        case .database, .databaseUser, .databaseRole, .applicationRole:
            return .database
        case .schema:
            return .schema(node.name ?? node.label)
        case .folder:
            return node.database == nil ? .server : .database
        default:
            return .object(schema: node.schema ?? "dbo", name: node.name ?? node.label)
        }
    }
}
