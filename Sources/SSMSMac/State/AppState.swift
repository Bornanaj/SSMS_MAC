import Foundation
import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers
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
    @Published var tabs: [QueryTab] = [] {
        didSet { observeSelectedTab() }
    }
    @Published var selectedTabID: UUID? {
        didSet { observeSelectedTab() }
    }

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
    private var selectedTabObservers: [AnyCancellable] = []

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
        case alwaysOn(UUID, String?)
        case reports(UUID, String?)
        case serverProperties(UUID)
        case registeredServers
        case exportData(UUID, String, String?, String?)
        case queryStore(UUID, String?)
        case errorLog(UUID)
        case executionPlan(String, String)
        case comparePlans(String, String)

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
            case .alwaysOn(let s, let group): return "alwayson-\(s)-\(group ?? "")"
            case .reports(let s, let d): return "reports-\(s)-\(d ?? "")"
            case .serverProperties(let s): return "serverprops-\(s)"
            case .registeredServers: return "registeredservers"
            case .exportData(let s, let d, let sc, let t):
                return "exportdata-\(s)-\(d)-\(sc ?? "")-\(t ?? "")"
            case .queryStore(let s, let d): return "querystore-\(s)-\(d ?? "")"
            case .errorLog(let s): return "errorlog-\(s)"
            case .executionPlan(let title, _): return "plan-\(title)"
            case .comparePlans(let title, _): return "planCompare-\(title)"
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
        connectionError = nil

        // A saved connection that is already open. A second session would carry the
        // same id (the session id is the profile id), which gives the Object Explorer
        // two roots with one identity and breaks the sheets and disconnect keyed by it.
        // Editing the server or login in the connect dialog gives the profile a new id,
        // so only a genuine reconnect lands here.
        if let existing = servers.first(where: { $0.id == profile.id }) {
            if persist {
                var saved = profile
                saved.discoveredServerName = existing.profile.discoveredServerName
                connections.save(saved, password: password)
            }
            if let root = explorer.roots.first(where: { $0.id.hasPrefix(existing.id.uuidString) }) {
                explorer.selectedID = root.id
            }
            statusMessage = "Already connected to \(existing.displayName)."
            await newQueryTab(server: existing,
                              database: profile.database.isEmpty ? nil : profile.database)
            return
        }

        isConnecting = true
        defer { isConnecting = false }

        do {
            let session = try await SQLServerSession.connect(profile: profile,
                                                             password: password,
                                                             accessToken: accessToken)
            let info = await session.serverInfo
            // The engine's own name is what the saved connection is listed under from
            // now on; the address stays in the profile as the second line.
            var saved = profile
            if !info.serverName.isEmpty { saved.discoveredServerName = info.serverName }
            let server = ConnectedServer(session: session, profile: saved, serverInfo: info)
            servers.append(server)
            if persist { connections.save(saved, password: password) }
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
        // Every finished run lands in the history browser, with what it returned and
        // how long it took.
        history.limit = max(1, settings.queryHistoryLimit)
        tab.onExecutionRecorded = { [weak self] entry in
            self?.history.record(entry)
        }
        tabs.append(tab)
        selectedTabID = tab.id
        if let server {
            await tab.attach(session: server.session, database: database)
        }
        // Text handed in (a template, a scripted object) is unsaved work; a tab opened
        // from a file is marked clean by its caller.
        tab.isDirty = !text.isEmpty
        return tab
    }

    /// Closes `tab` without asking. The interactive paths go through
    /// `closeTabAskingToSave`; this is what they end in, and what the headless self
    /// test calls directly.
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

    /// Query Options ▸ Results describes how every window renders text output.
    func applyResultsPreferences(_ preferences: QueryResultsPreferences) {
        for tab in tabs { tab.textResultPreferences = preferences }
    }

    /// The Query menu's enabled states come from the selected tab, but a `Commands`
    /// body only re-evaluates when this object publishes. The tab state the menu reads
    /// is forwarded; `text` and `selectedRange` deliberately are not, since re-rendering
    /// the window on every keystroke is exactly what that would cost.
    private func observeSelectedTab() {
        selectedTabObservers.removeAll()
        guard let tab = selectedTab else { return }
        func forward<Value>(_ publisher: Published<Value>.Publisher) {
            publisher.dropFirst()
                .sink { [weak self] _ in self?.objectWillChange.send() }
                .store(in: &selectedTabObservers)
        }
        forward(tab.$isExecuting)
        forward(tab.$isConnecting)
        forward(tab.$sessionID)
        forward(tab.$executionPlanXML)
        forward(tab.$resultSets)
    }

    // MARK: - Closing tabs with unsaved changes

    private enum SaveChoice { case save, discard, cancel }

    /// Closes `tab`, first asking what to do with unsaved changes. Returns false when
    /// the user cancelled or the save failed.
    @discardableResult
    func closeTabAskingToSave(_ tab: QueryTab) -> Bool {
        guard settleUnsavedChanges(in: tab) else { return false }
        closeTab(tab)
        return true
    }

    /// Closes every tab but `kept`, stopping at the first Cancel.
    func closeOtherTabs(keeping kept: QueryTab) {
        for tab in tabs where tab.id != kept.id {
            guard closeTabAskingToSave(tab) else { return }
        }
    }

    /// Asks about every tab with unsaved changes before the app quits. Returns false
    /// when the user cancelled.
    func prepareToTerminate() -> Bool {
        for tab in tabs where tab.isDirty {
            guard settleUnsavedChanges(in: tab) else { return false }
        }
        return true
    }

    /// Save / Don't Save / Cancel for a dirty tab; true means closing may go ahead.
    private func settleUnsavedChanges(in tab: QueryTab) -> Bool {
        guard tab.isDirty else { return true }
        // Show the tab being asked about, so the question has something to refer to.
        selectedTabID = tab.id
        switch askToSaveChanges(in: tab) {
        case .save: return saveScript(tab, as: false)
        case .discard: return true
        case .cancel: return false
        }
    }

    private func askToSaveChanges(in tab: QueryTab) -> SaveChoice {
        let name = tab.fileURL?.lastPathComponent ?? tab.title
        let alert = NSAlert()
        alert.messageText = "Do you want to save the changes made to “\(name)”?"
        alert.informativeText = "Your changes will be lost if you don’t save them."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don’t Save")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .save
        case .alertThirdButtonReturn: return .discard
        default: return .cancel
        }
    }

    // MARK: - Script files

    /// The types the open and save panels accept. `.sql` has no system-wide type: until
    /// the bundle's exported declaration is registered it resolves to a dynamic type
    /// that does not conform to plain text, which greyed .sql files out. Listing the
    /// extension itself keeps them selectable from a plain `swift run` as well.
    static let scriptContentTypes: [UTType] = {
        var types: [UTType] = [UTType(exportedAs: "dev.ssmsmac.sql", conformingTo: .plainText)]
        if let byExtension = UTType(filenameExtension: "sql") { types.append(byExtension) }
        types.append(contentsOf: [.plainText, .text])
        var seen = Set<String>()
        return types.filter { seen.insert($0.identifier).inserted }
    }()

    /// File ▸ Open Script: a new tab on the current tab's server and database.
    func openScriptPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = AppState.scriptContentTypes
        panel.allowsOtherFileTypes = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let text: String
        do {
            text = try AppState.readScript(at: url)
        } catch {
            presentError("The script could not be opened.",
                         detail: "\(url.lastPathComponent): \(error.localizedDescription)")
            return
        }
        let server = servers.first { $0.id == selectedTab?.sessionID } ?? servers.first
        let database = selectedTab?.database
        Task {
            let tab = await newQueryTab(server: server, database: database, text: text)
            tab.fileURL = url
            tab.title = url.lastPathComponent
            tab.isDirty = false
        }
    }

    /// SSMS wrote UTF-16 for years and plenty of scripts are Windows-1252; a UTF-8
    /// read alone fails on both. The byte order mark and the file's own encoding
    /// attribute are tried first, then UTF-8, then Windows-1252.
    static func readScript(at url: URL) throws -> String {
        var encoding = String.Encoding.utf8
        if let detected = try? String(contentsOf: url, usedEncoding: &encoding) { return detected }
        let data = try Data(contentsOf: url)
        if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
        if let windows = String(data: data, encoding: .windowsCP1252) { return windows }
        throw CocoaError(.fileReadInapplicableStringEncoding)
    }

    /// File ▸ Save Script. Returns true once the file is on disk; the tab is only
    /// marked clean then.
    @discardableResult
    func saveScript(_ tab: QueryTab, as saveAs: Bool) -> Bool {
        var target = tab.fileURL
        if target == nil || saveAs {
            let panel = NSSavePanel()
            panel.allowedContentTypes = AppState.scriptContentTypes
            panel.allowsOtherFileTypes = true
            panel.canCreateDirectories = true
            if let existing = tab.fileURL {
                panel.directoryURL = existing.deletingLastPathComponent()
                panel.nameFieldStringValue = existing.lastPathComponent
            } else {
                panel.nameFieldStringValue = tab.title.lowercased().hasSuffix(".sql")
                    ? tab.title : tab.title + ".sql"
            }
            guard panel.runModal() == .OK, let chosen = panel.url else { return false }
            target = chosen
        }
        guard let url = target else { return false }

        do {
            try tab.text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            presentError("The script could not be saved.",
                         detail: "\(url.lastPathComponent): \(error.localizedDescription)")
            return false
        }
        tab.fileURL = url
        tab.title = url.lastPathComponent
        tab.isDirty = false
        statusMessage = "Saved \(url.lastPathComponent)."
        return true
    }

    private func presentError(_ message: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.runModal()
    }
}
