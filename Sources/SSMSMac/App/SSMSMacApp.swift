import SwiftUI
import AppKit
import SQLServerKit

@main
struct SSMSMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var app = AppState()
    @StateObject private var settings = AppSettings.shared

    var body: some Scene {
        WindowGroup("SSMS for Mac") {
            MainWindowView()
                .environmentObject(app)
                .environmentObject(settings)
                .preferredColorScheme(settings.colorScheme)
                .frame(minWidth: 1000, minHeight: 640)
        }
        .commands { AppCommands(app: app, settings: settings) }

        Settings {
            SettingsView()
                .environmentObject(app)
                .environmentObject(settings)
        }

        Window("Query History", id: "history") {
            QueryHistoryView()
                .environmentObject(app)
        }

        Window("Template Explorer", id: "templates") {
            TemplateExplorerView()
                .environmentObject(app)
                .environmentObject(settings)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // The self test hides its window, which would otherwise quit the app immediately.
        !SelfTest.isRequested
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false

        // Headless verification path: exercises the same models the UI binds to.
        if SelfTest.isRequested {
            setvbuf(stdout, nil, _IOLBF, 0)
            NSApp.setActivationPolicy(.accessory)
            for window in NSApp.windows { window.setFrame(.zero, display: false) }
            Task { @MainActor in
                let status = await SelfTest.run()
                exit(status)
            }
        }
    }
}

/// Menu bar, laid out the way SSMS arranges its menus.
struct AppCommands: Commands {
    @ObservedObject var app: AppState
    @ObservedObject var settings: AppSettings
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        fileCommands
        saveCommands
        editCommands
        queryCommands
        resultsCommands
        toolsCommands
        viewCommands

        CommandGroup(replacing: .help) {
            Link("SQL Server T-SQL reference",
                 destination: URL(string: "https://learn.microsoft.com/sql/t-sql/language-reference")!)
        }
    }

    // MARK: - File

    private var fileCommands: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Query") {
                Task {
                    await app.newQueryTab(server: currentServer,
                                          database: app.selectedTab?.database)
                }
            }
            .keyboardShortcut("n", modifiers: .command)
            .disabled(app.servers.isEmpty)

            Button("Connect to Server…") { app.activeSheet = .connect }
                .keyboardShortcut("n", modifiers: [.command, .shift])

            Button("New Database…") {
                if let server = currentServer { app.activeSheet = .newDatabase(server.id) }
            }
            .disabled(currentServer == nil)

            Divider()

            Button("Open Script…") { openScript() }
                .keyboardShortcut("o", modifiers: .command)
        }
    }

    private var saveCommands: some Commands {
        CommandGroup(replacing: .saveItem) {
            Button("Save Script") { saveScript(as: false) }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(app.selectedTab == nil)
            Button("Save Script As…") { saveScript(as: true) }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(app.selectedTab == nil)
        }
    }

    // MARK: - Edit

    private var editCommands: some Commands {
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Go To Line…") {
                if let tab = app.selectedTab { app.activeSheet = .goToLine(tab.id) }
            }
            .keyboardShortcut("g", modifiers: .command)
            .disabled(app.selectedTab == nil)

            Menu("Bookmarks") {
                Button("Toggle Bookmark") { app.selectedTab?.toggleBookmark() }
                    .keyboardShortcut("k", modifiers: [.command, .option])
                Button("Next Bookmark") { app.selectedTab?.goToNextBookmark() }
                    .keyboardShortcut("n", modifiers: [.command, .option])
                Button("Previous Bookmark") { app.selectedTab?.goToPreviousBookmark() }
                    .keyboardShortcut("p", modifiers: [.command, .option])
                Divider()
                Button("Clear All Bookmarks") { app.selectedTab?.clearBookmarks() }
            }
            .disabled(app.selectedTab == nil)

            Button("Specify Values for Template Parameters…") {
                if let tab = app.selectedTab { app.activeSheet = .templateParameters(tab.id) }
            }
            .keyboardShortcut("m", modifiers: [.command, .shift])
            .disabled(app.selectedTab == nil)
        }
    }

    // MARK: - Query

    private var queryCommands: some Commands {
        CommandMenu("Query") {
            Button("Execute") { app.selectedTab?.execute() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(app.selectedTab?.isConnected != true)

            Button("Cancel Executing Query") { app.selectedTab?.cancel() }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(app.selectedTab?.isExecuting != true)

            Button("Run on Multiple Servers…") {
                if let tab = app.selectedTab { app.activeSheet = .multiServerQuery(tab.id) }
            }
            .disabled(app.selectedTab == nil || app.servers.count < 2)

            Divider()

            Toggle("Include Actual Execution Plan", isOn: bindingActualPlan)
                .keyboardShortcut("m", modifiers: [.command, .control])

            Toggle("Display Estimated Execution Plan", isOn: bindingEstimatedPlan)
                .keyboardShortcut("l", modifiers: [.command, .shift])

            Toggle("Include Client Statistics", isOn: bindingClientStatistics)

            Divider()

            Button("Format Script") {
                guard let tab = app.selectedTab else { return }
                tab.text = SQLFormatter(style: SQLFormatter.Style()).format(tab.text)
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
            .disabled(app.selectedTab == nil)

            Button("Refresh IntelliSense Cache") {
                app.selectedTab?.refreshIntelliSenseCatalog()
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])

            Button("Query Options…") {
                if let tab = app.selectedTab { app.activeSheet = .queryOptions(tab.id) }
            }
            .keyboardShortcut("o", modifiers: [.command, .option])
            .disabled(app.selectedTab == nil)
        }
    }

    private var resultsCommands: some Commands {
        CommandMenu("Results") {
            Button("Results to Grid") { app.selectedTab?.resultsDestination = .grid }
                .keyboardShortcut("d", modifiers: .command)
            Button("Results to Text") { app.selectedTab?.resultsDestination = .text }
                .keyboardShortcut("t", modifiers: .command)
            Button("Results to File") { app.selectedTab?.resultsDestination = .file }
                .keyboardShortcut("f", modifiers: [.command, .control])

            Divider()

            Button("Re-render Text Results") { app.selectedTab?.renderTextResults() }
                .disabled(app.selectedTab == nil)

            Button("Copy Text Results") {
                guard let text = app.selectedTab?.textResults, !text.isEmpty else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            .disabled(app.selectedTab?.textResults.isEmpty != false)
        }
    }

    // MARK: - Tools

    private var toolsCommands: some Commands {
        CommandMenu("Tools") {
            Button("Activity Monitor") {
                if let server = currentServer { app.activeSheet = .activityMonitor(server.id) }
            }
            .disabled(currentServer == nil)

            Button("Server Dashboard") {
                if let server = currentServer { app.activeSheet = .serverDashboard(server.id) }
            }
            .disabled(currentServer == nil)

            Button("SQL Server Logs") {
                if let server = currentServer { app.activeSheet = .serverLog(server.id) }
            }
            .disabled(currentServer == nil)

            Button("SQL Server Agent Jobs") {
                if let server = currentServer { app.activeSheet = .agentJob(server.id, "") }
            }
            .disabled(currentServer == nil)

            Divider()

            Button("Query Store…") {
                if let server = currentServer, let database = currentDatabase {
                    app.activeSheet = .queryStore(server.id, database)
                }
            }
            .disabled(currentServer == nil || currentDatabase == nil)

            Button("Index Maintenance…") {
                if let server = currentServer, let database = currentDatabase {
                    app.activeSheet = .indexMaintenance(server.id, database)
                }
            }
            .disabled(currentServer == nil || currentDatabase == nil)

            Button("Generate Scripts…") {
                if let server = currentServer, let database = currentDatabase {
                    app.activeSheet = .generateScripts(server.id, database)
                }
            }
            .disabled(currentServer == nil || currentDatabase == nil)

            Button("Import Flat File…") {
                if let server = currentServer, let database = currentDatabase {
                    app.activeSheet = .importFlatFile(server.id, database)
                }
            }
            .disabled(currentServer == nil || currentDatabase == nil)

            Divider()

            Button("Server Properties…") {
                if let server = currentServer { app.activeSheet = .serverProperties(server.id) }
            }
            .disabled(currentServer == nil)
        }
    }

    // MARK: - View

    private var viewCommands: some Commands {
        CommandGroup(after: .sidebar) {
            Button("Toggle Results Pane") {
                app.selectedTab?.showResultsPane.toggle()
            }
            .keyboardShortcut("y", modifiers: .command)

            Button(app.showExplorerDetails
                   ? "Hide Object Explorer Details" : "Show Object Explorer Details") {
                app.showExplorerDetails.toggle()
            }
            .keyboardShortcut("7", modifiers: .command)

            Divider()

            Button("Template Explorer") { openWindow(id: "templates") }
                .keyboardShortcut("t", modifiers: [.command, .option])

            Button("Query History") { openWindow(id: "history") }
                .keyboardShortcut("h", modifiers: [.command, .option])
        }
    }

    // MARK: - Helpers

    private var currentServer: ConnectedServer? { app.currentServer }

    private var currentDatabase: String? {
        if let database = app.selectedTab?.database, !database.isEmpty { return database }
        let info = currentServer?.serverInfo.currentDatabase
        return (info?.isEmpty == false) ? info : nil
    }

    private var bindingActualPlan: Binding<Bool> {
        Binding(get: { app.selectedTab?.includeActualPlan ?? false },
                set: { app.selectedTab?.includeActualPlan = $0 })
    }

    private var bindingEstimatedPlan: Binding<Bool> {
        Binding(get: { app.selectedTab?.includeEstimatedPlan ?? false },
                set: { app.selectedTab?.includeEstimatedPlan = $0 })
    }

    private var bindingClientStatistics: Binding<Bool> {
        Binding(get: { app.selectedTab?.includeClientStatistics ?? false },
                set: { app.selectedTab?.includeClientStatistics = $0 })
    }

    private func openScript() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText]
        panel.allowsOtherFileTypes = true
        panel.begin { response in
            guard response == .OK, let url = panel.url,
                  let text = try? String(contentsOf: url, encoding: .utf8) else { return }
            Task { @MainActor in
                let server = app.servers.first
                let tab = await app.newQueryTab(server: server, database: nil, text: text)
                tab.fileURL = url
                tab.title = url.lastPathComponent
                tab.isDirty = false
            }
        }
    }

    private func saveScript(as saveAs: Bool) {
        guard let tab = app.selectedTab else { return }
        if let url = tab.fileURL, !saveAs {
            try? tab.text.write(to: url, atomically: true, encoding: .utf8)
            tab.isDirty = false
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = tab.title.hasSuffix(".sql") ? tab.title : tab.title + ".sql"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                try? tab.text.write(to: url, atomically: true, encoding: .utf8)
                tab.fileURL = url
                tab.title = url.lastPathComponent
                tab.isDirty = false
            }
        }
    }
}
