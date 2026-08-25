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
