import SwiftUI

/// Preferences window: editor, grid and execution defaults.
struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        TabView {
            editorTab.tabItem { Label("Editor", systemImage: "text.cursor") }
            gridTab.tabItem { Label("Results", systemImage: "tablecells") }
            executionTab.tabItem { Label("Execution", systemImage: "play") }
            appearanceTab.tabItem { Label("Appearance", systemImage: "paintbrush") }
        }
        .frame(width: 560, height: 420)
    }

    private var editorTab: some View {
        Form {
            TextField("Font", text: $settings.editorFontName)
            Slider(value: $settings.editorFontSize, in: 9...24, step: 1) {
                Text("Font size: \(Int(settings.editorFontSize))")
            }
            Stepper("Tab width: \(settings.editorTabWidth)", value: $settings.editorTabWidth,
                    in: 2...8)
            Toggle("Insert spaces instead of tabs", isOn: $settings.editorUsesSpaces)
            Toggle("Show line numbers", isOn: $settings.editorShowLineNumbers)
            Toggle("Highlight the current line", isOn: $settings.editorHighlightCurrentLine)
            Toggle("Word wrap", isOn: $settings.editorWordWrap)
            Toggle("Enable IntelliSense", isOn: $settings.intelliSenseEnabled)
        }
        .formStyle(.grouped)
        .padding()
    }

    private var gridTab: some View {
        Form {
            Section("Grid") {
                TextField("Grid font", text: $settings.gridFontName)
                Slider(value: $settings.gridFontSize, in: 9...20, step: 1) {
                    Text("Grid font size: \(Int(settings.gridFontSize))")
                }
                TextField("Text shown for NULL", text: $settings.gridNullText)
                TextField("Maximum rows kept in the grid",
                          value: $settings.gridMaxRows, format: .number)
                TextField("Maximum characters per cell",
                          value: $settings.gridMaxCharsPerCell, format: .number)
            }
            Section("Results to Text") {
                Picker("New windows send results to", selection: $settings.resultsDestinationRaw) {
                    Text("Grid").tag("grid")
                    Text("Text").tag("text")
                    Text("File").tag("file")
                }
                TextField("Maximum characters per column",
                          value: $settings.textResultsMaxColumnWidth, format: .number)
                TextField("Column separator", text: $settings.textResultsColumnSeparator)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var executionTab: some View {
        Form {
            TextField("Execution timeout (seconds, 0 = none)",
                      value: $settings.executionTimeoutSeconds, format: .number)
            TextField("SELECT TOP rows for scripting",
                      value: $settings.scriptSelectTopRows, format: .number)
            TextField("Rows loaded by the data editor",
                      value: $settings.editTopRows, format: .number)
            TextField("Query history entries kept",
                      value: $settings.queryHistoryLimit, format: .number)
            Toggle("Show system objects in the Object Explorer",
                   isOn: $settings.showSystemObjects)
            Toggle("Confirm before running DROP statements",
                   isOn: $settings.confirmDestructiveScripts)
        }
        .formStyle(.grouped)
        .padding()
    }

    private var appearanceTab: some View {
        Form {
            Picker("Appearance", selection: $settings.appearance) {
                Text("System").tag("system")
                Text("Light").tag("light")
                Text("Dark").tag("dark")
            }
            Toggle("Restore query tabs on launch", isOn: $settings.restoreTabsOnLaunch)
        }
        .formStyle(.grouped)
        .padding()
    }
}

/// Query history browser.
struct QueryHistoryView: View {
    @EnvironmentObject var app: AppState
    @State private var searchText = ""
    @State private var selection: UUID?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "clock.arrow.circlepath").foregroundStyle(.tint)
                Text("Query History").font(.headline)
                Spacer()
                TextField("Search", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                Button("Clear") { app.history.clear() }
            }
            .padding(12)
            Divider()

            let entries = app.history.search(searchText)
            if entries.isEmpty {
                ContentUnavailableView("No history", systemImage: "clock",
                                       description: Text("Executed queries appear here."))
            } else {
                List(entries, selection: $selection) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Image(systemName: entry.succeeded ? "checkmark.circle" : "xmark.circle")
                                .foregroundStyle(entry.succeeded ? Color.green : Color.red)
                            Text(entry.preview)
                                .font(.system(.caption, design: .monospaced))
                                .lineLimit(1)
                        }
                        HStack(spacing: 10) {
                            Text(entry.startedAt.formatted(date: .abbreviated, time: .standard))
                            Text("\(entry.server) · \(entry.database)")
                            Text(String(format: "%.3f s", entry.elapsed))
                            Text("\(entry.rowsReturned) rows")
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                    .tag(entry.id)
                    .contextMenu {
                        Button("Copy SQL") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(entry.sql, forType: .string)
                        }
                        Button("Open in New Query Window") {
                            app.openScript(entry.sql, server: app.servers.first,
                                           database: entry.database, title: "History")
                        }
                    }
                }
            }
        }
        .frame(minWidth: 700, minHeight: 460)
    }
}
