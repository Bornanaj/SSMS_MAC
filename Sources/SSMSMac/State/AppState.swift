import Foundation
import SwiftUI
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
    @Published var activeSheet: AppSheet?
    @Published var statusMessage: String = "Ready"
    /// Set to the current script when the user asks to fill in template placeholders.
    @Published var pendingTemplateScript: String?
    @Published var showGoToLine = false

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
        case indexMaintenance(UUID, String)
        case generateScripts(UUID, String)
        case dependencies(UUID, String, String, String)
        case designTable(UUID, String, String, String)
        case detachDatabase(UUID, String)
        case attachDatabase(UUID)
        case shrinkDatabase(UUID, String)
        case diskUsage(UUID, String)
        case queryOptions
        case templates
        case logins(UUID)
        case databaseSecurity(UUID, String)
        case permissions(UUID, String, String?, String?)
        case agentJobs(UUID)
        case reports(UUID, String?)
        case serverProperties(UUID)
        case registeredServers
        case exportData(UUID, String, String?, String?)

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
            case .indexMaintenance(let s, let d): return "indexes-\(s)-\(d)"
            case .generateScripts(let s, let d): return "genscripts-\(s)-\(d)"
            case .dependencies(let s, let d, let sc, let n): return "deps-\(s)-\(d)-\(sc)-\(n)"
            case .designTable(let s, let d, let sc, let t): return "design-\(s)-\(d)-\(sc)-\(t)"
            case .detachDatabase(let s, let d): return "detach-\(s)-\(d)"
            case .attachDatabase(let s): return "attach-\(s)"
            case .shrinkDatabase(let s, let d): return "shrink-\(s)-\(d)"
            case .diskUsage(let s, let d): return "diskusage-\(s)-\(d)"
            case .queryOptions: return "queryoptions"
            case .templates: return "templates"
            case .logins(let s): return "logins-\(s)"
            case .databaseSecurity(let s, let d): return "dbsecurity-\(s)-\(d)"
            case .permissions(let s, let d, let sc, let o):
                return "perms-\(s)-\(d)-\(sc ?? "")-\(o ?? "")"
            case .agentJobs(let s): return "agent-\(s)"
            case .reports(let s, let d): return "reports-\(s)-\(d ?? "")"
            case .serverProperties(let s): return "serverprops-\(s)"
            case .registeredServers: return "registeredservers"
            case .exportData(let s, let d, let sc, let t):
                return "exportdata-\(s)-\(d)-\(sc ?? "")-\(t ?? "")"
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

    // MARK: - Connecting

    /// `persist` is false for the headless self test, which must not leave entries in
    /// the user's saved connection list.
    func connect(profile: ConnectionProfile, password: String?, accessToken: String? = nil,
                 persist: Bool = true) async {
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
            if persist { connections.save(profile, password: password) }
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
        tabs.append(tab)
        selectedTabID = tab.id
        if let server {
            await tab.attach(session: server.session, database: database)
        }
        tab.isDirty = false
        return tab
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
}
