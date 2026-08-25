import AppKit
import SwiftUI
import SQLServerKit

/// One row of the completion list: the item plus the character positions that matched
/// what was typed, so they can be emboldened.
struct CompletionEntry: Identifiable, Hashable {
    var item: CompletionItem
    var positions: [Int]

    var id: String { item.id }
}

extension CompletionItem.Kind {
    /// SF Symbol and tint per kind, so the list is scannable without reading it.
    var symbol: String {
        switch self {
        case .keyword: return "text.word.spacing"
        case .table: return "tablecells"
        case .view: return "eye"
        case .column: return "list.bullet"
        case .procedure: return "gearshape.2"
        case .function: return "function"
        case .schema: return "folder"
        case .database: return "cylinder"
        case .variable: return "at"
        case .snippet: return "curlybraces"
        case .dataType: return "textformat.abc"
        case .alias: return "tag"
        case .parameter: return "slider.horizontal.3"
        }
    }

    var tint: Color {
        switch self {
        case .keyword: return .blue
        case .table: return .teal
        case .view: return .purple
        case .column: return .secondary
        case .procedure, .function: return .orange
        case .schema, .database: return .cyan
        case .variable, .parameter: return .yellow
        case .snippet: return .green
        case .dataType: return .mint
        case .alias: return .pink
        }
    }

    var caption: String {
        switch self {
        case .keyword: return "keyword"
        case .table: return "table"
        case .view: return "view"
        case .column: return "column"
        case .procedure: return "procedure"
        case .function: return "function"
        case .schema: return "schema"
        case .database: return "database"
        case .variable: return "variable"
        case .snippet: return "snippet"
        case .dataType: return "type"
        case .alias: return "alias"
        case .parameter: return "parameter"
        }
    }
}

/// The list itself. Selection is driven from the text view rather than from SwiftUI,
/// because the panel never takes key focus away from the editor.
struct CompletionListView: View {
    var entries: [CompletionEntry]
    var selectedIndex: Int
    var onChoose: (Int) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                            row(entry, isSelected: index == selectedIndex)
                                .id(index)
                                .contentShape(Rectangle())
                                .onTapGesture { onChoose(index) }
                        }
                    }
                    .padding(.vertical, 3)
                }
                .onChange(of: selectedIndex) { _, newValue in
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }

            if let selected = entries.indices.contains(selectedIndex) ? entries[selectedIndex] : nil,
               !selected.item.documentation.isEmpty || !selected.item.detail.isEmpty {
                Divider()
                documentation(selected)
            }
        }
        .frame(width: 460, height: 260)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func row(_ entry: CompletionEntry, isSelected: Bool) -> some View {
        HStack(spacing: 7) {
            Image(systemName: entry.item.kind.symbol)
                .font(.system(size: 11))
                .foregroundStyle(isSelected ? Color.white : entry.item.kind.tint)
                .frame(width: 15)

            highlighted(entry)
                .lineLimit(1)

            Spacer(minLength: 8)

            Text(entry.item.detail.isEmpty ? entry.item.kind.caption : entry.item.detail)
                .font(.system(size: 10))
                .foregroundStyle(isSelected ? Color.white.opacity(0.8) : Color.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(isSelected ? Color.accentColor : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .padding(.horizontal, 4)
    }

    /// Emboldens the characters the matcher actually matched.
    private func highlighted(_ entry: CompletionEntry) -> Text {
        let characters = Array(entry.item.label)
        let matched = Set(entry.positions)
        var result = Text("")
        for (index, character) in characters.enumerated() {
            let piece = Text(String(character))
                .font(.system(size: 12, weight: matched.contains(index) ? .bold : .regular,
                              design: .monospaced))
            result = result + piece
        }
        return result
    }

    @ViewBuilder
    private func documentation(_ entry: CompletionEntry) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: entry.item.kind.symbol)
                    .foregroundStyle(entry.item.kind.tint)
                Text(entry.item.detail.isEmpty ? entry.item.label : entry.item.detail)
                    .font(.system(size: 11, weight: .medium))
                Spacer()
                Text(entry.item.kind.caption)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            if !entry.item.documentation.isEmpty {
                Text(entry.item.documentation)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Owns the floating panel. Deliberately non-activating: the editor keeps key focus and
/// forwards the navigation keys, which is what stops the list from ever typing on its own.
@MainActor
final class CompletionPanelController {
    private(set) var entries: [CompletionEntry] = []
    private(set) var selectedIndex = 0
    private var panel: NSPanel?
    private var hosting: NSHostingView<CompletionListView>?
    var onChoose: ((CompletionItem) -> Void)?

    var isVisible: Bool { panel?.isVisible ?? false }

    var selectedItem: CompletionItem? {
        entries.indices.contains(selectedIndex) ? entries[selectedIndex].item : nil
    }

    func show(entries: [CompletionEntry], below caretRect: NSRect, in view: NSView) {
        guard !entries.isEmpty, let window = view.window else {
            hide()
            return
        }
        self.entries = entries
        selectedIndex = 0

        let panel = existingPanel()
        render()

        // Prefer below the caret; flip above when the screen runs out.
        let inWindow = view.convert(caretRect, to: nil)
        let onScreen = window.convertToScreen(inWindow)
        let size = NSSize(width: 460, height: 260)
        var origin = NSPoint(x: onScreen.minX, y: onScreen.minY - size.height - 4)
        if let screen = window.screen {
            if origin.y < screen.visibleFrame.minY {
                origin.y = onScreen.maxY + 4
            }
            let maxX = screen.visibleFrame.maxX - size.width - 8
            origin.x = min(max(origin.x, screen.visibleFrame.minX + 8), maxX)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)

        if panel.parent == nil { window.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
    }

    func hide() {
        guard let panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        entries = []
        selectedIndex = 0
    }

    func moveSelection(by delta: Int) {
        guard !entries.isEmpty else { return }
        var index = selectedIndex + delta
        if index < 0 { index = entries.count - 1 }
        if index >= entries.count { index = 0 }
        selectedIndex = index
        render()
    }

    func moveSelection(to index: Int) {
        guard entries.indices.contains(index) else { return }
        selectedIndex = index
        render()
    }

    private func render() {
        let view = CompletionListView(entries: entries, selectedIndex: selectedIndex) { [weak self] index in
            guard let self else { return }
            self.moveSelection(to: index)
            if let item = self.selectedItem { self.onChoose?(item) }
        }
        if let hosting {
            hosting.rootView = view
        } else {
            let hosting = NSHostingView(rootView: view)
            self.hosting = hosting
            existingPanel().contentView = hosting
        }
    }

    private func existingPanel() -> NSPanel {
        if let panel { return panel }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 260),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: true)
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = true
        panel.isMovable = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.worksWhenModal = true
        self.panel = panel
        return panel
    }
}
