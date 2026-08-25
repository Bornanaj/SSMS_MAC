import Foundation
import SwiftUI
import SQLServerKit

/// User preferences, mirrored into UserDefaults so they survive relaunch.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @AppStorage("appearance") var appearance: String = "system"
    @AppStorage("editorFontName") var editorFontName: String = "SF Mono"
    @AppStorage("editorFontSize") var editorFontSize: Double = 13
    @AppStorage("editorTabWidth") var editorTabWidth: Int = 4
    @AppStorage("editorUsesSpaces") var editorUsesSpaces: Bool = true
    @AppStorage("editorWordWrap") var editorWordWrap: Bool = false
    @AppStorage("editorShowLineNumbers") var editorShowLineNumbers: Bool = true
    @AppStorage("editorHighlightCurrentLine") var editorHighlightCurrentLine: Bool = true
    @AppStorage("intelliSenseEnabled") var intelliSenseEnabled: Bool = true

    @AppStorage("gridFontName") var gridFontName: String = "SF Mono"
    @AppStorage("gridFontSize") var gridFontSize: Double = 12
    @AppStorage("gridNullText") var gridNullText: String = "NULL"
    @AppStorage("gridMaxRows") var gridMaxRows: Int = 100_000
    @AppStorage("gridMaxCharsPerCell") var gridMaxCharsPerCell: Int = 65535
    /// "grid" or "text", matching QueryOutputMode.
    @AppStorage("resultsOutputMode") var resultsOutputMode: String = "grid"

    @AppStorage("executionTimeoutSeconds") var executionTimeoutSeconds: Int = 0
    @AppStorage("showSystemObjects") var showSystemObjects: Bool = false
    @AppStorage("confirmDestructiveScripts") var confirmDestructiveScripts: Bool = true
    @AppStorage("queryHistoryLimit") var queryHistoryLimit: Int = 500
    @AppStorage("scriptSelectTopRows") var scriptSelectTopRows: Int = 1000
    @AppStorage("editTopRows") var editTopRows: Int = 200
    @AppStorage("restoreTabsOnLaunch") var restoreTabsOnLaunch: Bool = true

    var editorFont: NSFont {
        NSFont(name: editorFontName, size: editorFontSize)
            ?? .monospacedSystemFont(ofSize: editorFontSize, weight: .regular)
    }

    var gridFont: NSFont {
        NSFont(name: gridFontName, size: gridFontSize)
            ?? .monospacedSystemFont(ofSize: gridFontSize, weight: .regular)
    }

    var colorScheme: ColorScheme? {
        switch appearance {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    /// SET options applied to every new query connection.
    var defaultSetOptions: QuerySetOptions { QuerySetOptions() }
}
