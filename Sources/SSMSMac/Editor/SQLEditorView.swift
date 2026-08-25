import SwiftUI
import AppKit
import SQLServerKit

/// SwiftUI wrapper around `SQLTextView` with a line-number gutter and live colouring.
struct SQLEditorView: NSViewRepresentable {
    @ObservedObject var tab: QueryTab
    @ObservedObject var settings: AppSettings
    var onExecute: () -> Void
    var onExecuteSelection: () -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(tab: tab, settings: settings,
                    onExecute: onExecute, onExecuteSelection: onExecuteSelection, onCancel: onCancel)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = !settings.editorWordWrap
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let textView = SQLTextView(frame: .zero)
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.delegate = context.coordinator
        textView.sqlDelegate = context.coordinator
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = !settings.editorWordWrap
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.string = tab.text

        scrollView.documentView = textView

        let ruler = LineNumberRulerView(textView: textView)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = settings.editorShowLineNumbers

        context.coordinator.textView = textView
        context.coordinator.ruler = ruler
        context.coordinator.applyAppearance(to: textView, ruler: ruler, scrollView: scrollView)
        context.coordinator.highlightAll()

        NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { _ in ruler.refresh() }
        scrollView.contentView.postsBoundsChangedNotifications = true

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        context.coordinator.tab = tab
        context.coordinator.settings = settings

        if textView.string != tab.text && !context.coordinator.isEditing {
            let selected = textView.selectedRange()
            textView.string = tab.text
            textView.setSelectedRange(NSRange(location: min(selected.location, tab.text.utf16.count), length: 0))
            context.coordinator.highlightAll()
        }

        scrollView.rulersVisible = settings.editorShowLineNumbers
        context.coordinator.applyAppearance(to: textView, ruler: context.coordinator.ruler, scrollView: scrollView)
        context.coordinator.ruler?.errorLines = Set(tab.messages
            .filter { $0.kind == .error && $0.scriptLine > 0 }
            .map(\.scriptLine))
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate, SQLTextViewDelegate {
        var tab: QueryTab
        var settings: AppSettings
        weak var textView: SQLTextView?
        weak var ruler: LineNumberRulerView?
        var isEditing = false

        private let onExecute: () -> Void
        private let onExecuteSelection: () -> Void
        private let onCancel: () -> Void
        private var highlighter: SQLHighlighter
        private var appliedFont: NSFont?
        private var appliedDark: Bool?

        init(tab: QueryTab, settings: AppSettings,
             onExecute: @escaping () -> Void,
             onExecuteSelection: @escaping () -> Void,
             onCancel: @escaping () -> Void) {
            self.tab = tab
            self.settings = settings
            self.onExecute = onExecute
            self.onExecuteSelection = onExecuteSelection
            self.onCancel = onCancel
            self.highlighter = SQLHighlighter(palette: Theme.light, font: settings.editorFont)
        }

        func applyAppearance(to textView: SQLTextView, ruler: LineNumberRulerView?, scrollView: NSScrollView) {
            let isDark = (scrollView.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
            let font = settings.editorFont
            guard appliedDark != isDark || appliedFont != font else { return }
            appliedDark = isDark
            appliedFont = font

            let palette = isDark ? Theme.dark : Theme.light
            textView.font = font
            textView.palette = palette
            textView.highlightCurrentLine = settings.editorHighlightCurrentLine
            textView.indentWidth = settings.editorTabWidth
            textView.usesSpacesForTabs = settings.editorUsesSpaces
            textView.backgroundColor = palette.background
            textView.insertionPointColor = palette.plain
            ruler?.palette = palette
            ruler?.font = NSFont.monospacedSystemFont(ofSize: max(9, font.pointSize - 2), weight: .regular)
            ruler?.needsDisplay = true
            highlighter.update(palette: palette, font: font)
            highlightAll()
        }

        func highlightAll() {
            guard let storage = textView?.textStorage else { return }
            highlighter.highlight(storage)
        }

        // MARK: NSTextViewDelegate

        func textDidChange(_ notification: Notification) {
            guard let textView = textView, let storage = textView.textStorage else { return }
            isEditing = true
            defer { isEditing = false }

            let edited = textView.string as NSString
            let range = highlighter.rangeToRehighlight(
                for: NSRange(location: max(0, textView.selectedRange().location - 1), length: 0),
                in: edited)
            highlighter.highlight(storage, in: range)
            tab.text = textView.string
            ruler?.refresh()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView else { return }
            tab.selectedRange = textView.selectedRange()
        }

        // MARK: SQLTextViewDelegate

        func sqlTextViewDidRequestExecute(_ textView: SQLTextView) { onExecute() }
        func sqlTextViewDidRequestExecuteSelection(_ textView: SQLTextView) { onExecuteSelection() }
        func sqlTextViewDidRequestCancel(_ textView: SQLTextView) { onCancel() }

        func sqlTextViewDidChangeCaret(_ textView: SQLTextView) {
            guard settings.intelliSenseEnabled else { return }
            tab.requestCompletions(at: textView.selectedRange().location)
        }

        func sqlTextView(_ textView: SQLTextView, completionsFor prefix: String,
                         range: NSRange) -> [CompletionItem] {
            guard settings.intelliSenseEnabled else { return [] }
            let items = tab.completionItems.isEmpty ? Coordinator.keywordFallback : tab.completionItems
            guard !prefix.isEmpty else { return Array(items.prefix(200)) }

            let lowered = prefix.lowercased()
            let scored = items.compactMap { item -> (CompletionItem, Int)? in
                let label = item.label.lowercased()
                if label.hasPrefix(lowered) { return (item, item.sortPriority) }
                if label.contains(lowered) { return (item, item.sortPriority + 1000) }
                return nil
            }
            return scored.sorted { lhs, rhs in
                lhs.1 == rhs.1 ? lhs.0.label < rhs.0.label : lhs.1 < rhs.1
            }.map(\.0).prefix(200).map { $0 }
        }

        /// Used before the server catalog has loaded, so completion is never dead.
        static let keywordFallback: [CompletionItem] = TSQLKeywords.allCompletionWords.map {
            CompletionItem(id: "keyword:\($0)", label: $0, kind: .keyword,
                           detail: "", documentation: "", insertText: $0, sortPriority: 500)
        }
    }
}
