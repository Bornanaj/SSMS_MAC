import SwiftUI
import AppKit
import SQLServerKit

/// One query window: connection bar, editor, results.
struct QueryWindowView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var tab: QueryTab
    @ObservedObject var settings: AppSettings

    var body: some View {
        VStack(spacing: 0) {
            connectionBar
            Divider()
            if tab.showResultsPane {
                VSplitView {
                    editor.frame(minHeight: 120)
                    ResultsPaneView(tab: tab, settings: settings, onJumpToLine: jump(toLine:))
                        .frame(minHeight: 120, idealHeight: 260)
                }
            } else {
                editor
            }
            Divider()
            statusBar
        }
    }

    private var editor: some View {
        SQLEditorView(
            tab: tab,
            settings: settings,
            onExecute: { tab.execute() },
            onExecuteSelection: { tab.execute() },
            onCancel: { tab.cancel() }
        )
    }

    private var connectionBar: some View {
        HStack(spacing: 8) {
            Button {
                tab.execute()
            } label: {
                Label("Execute", systemImage: "play.fill")
            }
            .disabled(tab.isExecuting || !tab.isConnected)
            .help("Execute (F5)")

            Button {
                tab.cancel()
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .disabled(!tab.isExecuting)
            .help("Cancel executing query (⌘.)")

            Divider().frame(height: 16)

            Picker("", selection: Binding(
                get: { tab.database },
                set: { newValue in Task { await tab.changeDatabase(to: newValue) } }
            )) {
                if tab.availableDatabases.isEmpty {
                    Text(tab.database.isEmpty ? "<no database>" : tab.database).tag(tab.database)
                }
                ForEach(tab.availableDatabases, id: \.self) { name in
                    Text(name).tag(name)
                }
            }
            .labelsHidden()
            .frame(width: 190)
            .disabled(!tab.isConnected || tab.isExecuting)

            Divider().frame(height: 16)

            Toggle(isOn: $tab.includeActualPlan) {
                Image(systemName: "point.topleft.down.curvedto.point.bottomright.up")
            }
            .toggleStyle(.button)
            .help("Include actual execution plan")

            Toggle(isOn: $tab.includeEstimatedPlan) {
                Image(systemName: "chart.xyaxis.line")
            }
            .toggleStyle(.button)
            .help("Display estimated execution plan")

            Button {
                let formatter = SQLFormatter(style: SQLFormatter.Style())
                tab.text = formatter.format(tab.text)
            } label: {
                Image(systemName: "text.alignleft")
            }
            .help("Format the script")

            Spacer()

            if tab.isExecuting {
                ProgressView().controlSize(.small)
            }

            Text(tab.sessionName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(accentBackground)
    }

    @ViewBuilder
    private var accentBackground: some View {
        if let color = Theme.color(hex: tab.accentColorHex) {
            color.opacity(0.22)
        } else {
            Color(nsColor: .windowBackgroundColor)
        }
    }

    private var statusBar: some View {
        HStack(spacing: 14) {
            Circle()
                .fill(tab.isConnected ? Color.green : Color.secondary)
                .frame(width: 7, height: 7)
            Text(tab.statusText)
                .lineLimit(1)
            Spacer()
            if !tab.serverLabel.isEmpty {
                Text(tab.serverLabel)
            }
            if !tab.database.isEmpty {
                Text(tab.database)
            }
            Text(tab.elapsedText).monospacedDigit()
            if let summary = tab.summary {
                Text("\(summary.totalRows) rows").monospacedDigit()
            }
            Text("Ln \(caretLine), Col \(caretColumn)").monospacedDigit()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(accentBackground)
    }

    private var caretLine: Int {
        let text = tab.text as NSString
        let location = min(tab.selectedRange.location, text.length)
        var line = 1
        text.enumerateSubstrings(in: NSRange(location: 0, length: location),
                                 options: [.byLines, .substringNotRequired]) { _, _, _, _ in
            line += 1
        }
        return line
    }

    private var caretColumn: Int {
        let text = tab.text as NSString
        let location = min(tab.selectedRange.location, text.length)
        let lineRange = text.lineRange(for: NSRange(location: location, length: 0))
        return location - lineRange.location + 1
    }

    private func jump(toLine line: Int) {
        let text = tab.text as NSString
        var current = 1
        var offset = 0
        while current < line && offset < text.length {
            let lineRange = text.lineRange(for: NSRange(location: offset, length: 0))
            offset = NSMaxRange(lineRange)
            current += 1
        }
        tab.selectedRange = NSRange(location: min(offset, text.length), length: 0)
    }
}
