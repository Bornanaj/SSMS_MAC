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
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // The diagnostics hide their window, which would otherwise quit the app immediately.
        !SelfTest.isRequested && !EditorCheck.isRequested
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false

        // Headless verification path: exercises the same models the UI binds to.
        if EditorCheck.isRequested {
            setvbuf(stdout, nil, _IOLBF, 0)
            NSApp.setActivationPolicy(.accessory)
            exit(EditorCheck.run())
        }

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

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Query") {
                Task {
                    let server = app.servers.first { $0.id == app.selectedTab?.sessionID } ?? app.servers.first
                    await app.newQueryTab(server: server, database: app.selectedTab?.database)
                }
            }
            .keyboardShortcut("n", modifiers: .command)
            .disabled(app.servers.isEmpty)

            Button("Connect to Server…") { app.activeSheet = .connect }
                .keyboardShortcut("n", modifiers: [.command, .shift])

            Divider()

            Button("Open Script…") { openScript() }
                .keyboardShortcut("o", modifiers: .command)
        }

        CommandGroup(replacing: .saveItem) {
            Button("Save Script") { saveScript(as: false) }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(app.selectedTab == nil)
            Button("Save Script As…") { saveScript(as: true) }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(app.selectedTab == nil)
        }

        CommandMenu("Query") {
            Button("Execute") { app.selectedTab?.execute() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(app.selectedTab?.isConnected != true)

            Button("Cancel Executing Query") { app.selectedTab?.cancel() }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(app.selectedTab?.isExecuting != true)

            Divider()

            Toggle("Include Actual Execution Plan", isOn: bindingActualPlan)
                .keyboardShortcut("m", modifiers: [.command, .shift])

            Toggle("Display Estimated Execution Plan", isOn: bindingEstimatedPlan)
                .keyboardShortcut("l", modifiers: [.command, .shift])

            Divider()

            Picker("Results To", selection: $settings.resultsOutputMode) {
                Text("Results to Grid").tag("grid")
                Text("Results to Text").tag("text")
            }
            .pickerStyle(.inline)

            Button("Query Options…") { app.activeSheet = .queryOptions }
                .disabled(app.selectedTab == nil)

            Divider()

            Button("Format Script") {
                guard let tab = app.selectedTab else { return }
                tab.text = SQLFormatter(style: SQLFormatter.Style()).format(tab.text)
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
            .disabled(app.selectedTab == nil)

            Button("Expand Wildcards") {
                // Routed through the responder chain so it lands on whichever editor
                // currently has focus.
                NSApp.sendAction(#selector(SQLTextView.expandWildcards(_:)), to: nil, from: nil)
            }
            .keyboardShortcut("e", modifiers: [.command, .option])

            Button("List Members") {
                NSApp.sendAction(#selector(NSTextView.complete(_:)), to: nil, from: nil)
            }
            .keyboardShortcut(.space, modifiers: [.control])

            Divider()

            Button("Dump Editor Diagnostics") { EditorDump.request() }
                .keyboardShortcut("d", modifiers: [.command, .option])

            Button("Refresh IntelliSense Cache") {
                app.selectedTab?.refreshIntelliSenseCatalog()
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
        }

        CommandMenu("Tools") {
            Button("Template Explorer…") { app.activeSheet = .templates }
                .keyboardShortcut("t", modifiers: [.command, .option])

            Button("Specify Template Values…") {
                guard let tab = app.selectedTab else { return }
                app.pendingTemplateScript = tab.text
            }
            .keyboardShortcut("m", modifiers: [.command, .shift])
            .disabled(app.selectedTab == nil)

            Divider()

            Button("Activity Monitor") {
                if let server = currentServer { app.activeSheet = .activityMonitor(server.id) }
            }
            .disabled(currentServer == nil)

            Button("Reports…") {
                if let server = currentServer {
                    app.activeSheet = .reports(server.id, app.selectedTab?.database)
                }
            }
            .keyboardShortcut("r", modifiers: [.command, .option])
            .disabled(currentServer == nil)

            Button("SQL Server Agent Jobs…") {
                if let server = currentServer { app.activeSheet = .agentJobs(server.id) }
            }
            .disabled(currentServer == nil)

            Divider()

            Button("Logins…") {
                if let server = currentServer { app.activeSheet = .logins(server.id) }
            }
            .disabled(currentServer == nil)

            Button("Database Security…") {
                if let server = currentServer, let database = app.selectedTab?.database {
                    app.activeSheet = .databaseSecurity(server.id, database)
                }
            }
            .disabled(currentServer == nil)

            Button("Index Maintenance…") {
                if let server = currentServer, let database = app.selectedTab?.database {
                    app.activeSheet = .indexMaintenance(server.id, database)
                }
            }
            .disabled(currentServer == nil)

            Divider()

            Button("Import Flat File…") {
                if let server = currentServer, let database = app.selectedTab?.database {
                    app.activeSheet = .importFlatFile(server.id, database)
                }
            }
            .disabled(currentServer == nil)

            Button("Generate Scripts…") {
                if let server = currentServer, let database = app.selectedTab?.database {
                    app.activeSheet = .generateScripts(server.id, database)
                }
            }
            .disabled(currentServer == nil)

            Divider()

            Button("Attach Database…") {
                if let server = currentServer { app.activeSheet = .attachDatabase(server.id) }
            }
            .disabled(currentServer == nil)
        }

        CommandMenu("Edit Extras") {
            Button("Go To Line…") { app.showGoToLine = true }
                .keyboardShortcut("l", modifiers: .command)
                .disabled(app.selectedTab == nil)

            Divider()

            Button("Toggle Bookmark") {
                NSApp.sendAction(#selector(SQLTextView.toggleBookmark(_:)), to: nil, from: nil)
            }
            .keyboardShortcut(KeyEquivalent("\u{F705}"), modifiers: .command)

            Button("Next Bookmark") {
                NSApp.sendAction(#selector(SQLTextView.nextBookmark(_:)), to: nil, from: nil)
            }
            .keyboardShortcut(KeyEquivalent("\u{F705}"), modifiers: [])

            Button("Previous Bookmark") {
                NSApp.sendAction(#selector(SQLTextView.previousBookmark(_:)), to: nil, from: nil)
            }
            .keyboardShortcut(KeyEquivalent("\u{F705}"), modifiers: .shift)

            Button("Clear All Bookmarks") {
                NSApp.sendAction(#selector(SQLTextView.clearBookmarks(_:)), to: nil, from: nil)
            }
            .keyboardShortcut(KeyEquivalent("\u{F705}"), modifiers: [.command, .shift])

            Divider()

            Button("Server Properties…") {
                if let server = currentServer { app.activeSheet = .serverProperties(server.id) }
            }
            .disabled(currentServer == nil)
        }

        CommandGroup(after: .sidebar) {
            Button("Toggle Results Pane") {
                app.selectedTab?.showResultsPane.toggle()
            }
            .keyboardShortcut("y", modifiers: .command)
        }

        CommandGroup(replacing: .help) {
            Link("SQL Server T-SQL reference",
                 destination: URL(string: "https://learn.microsoft.com/sql/t-sql/language-reference")!)
        }
    }

    private var currentServer: ConnectedServer? {
        app.servers.first { $0.id == app.selectedTab?.sessionID } ?? app.servers.first
    }

    private var bindingActualPlan: Binding<Bool> {
        Binding(get: { app.selectedTab?.includeActualPlan ?? false },
                set: { app.selectedTab?.includeActualPlan = $0 })
    }

    private var bindingEstimatedPlan: Binding<Bool> {
        Binding(get: { app.selectedTab?.includeEstimatedPlan ?? false },
                set: { app.selectedTab?.includeEstimatedPlan = $0 })
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
