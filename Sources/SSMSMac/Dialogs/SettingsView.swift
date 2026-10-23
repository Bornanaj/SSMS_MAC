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
        .frame(width: 520, height: 360)
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
