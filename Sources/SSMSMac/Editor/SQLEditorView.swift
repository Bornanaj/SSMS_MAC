import SwiftUI
import AppKit
import SQLServerKit

extension Notification.Name {
    /// Posted by the Go To Line dialog; the focused editor acts on it.
    static let ssmsGoToLine = Notification.Name("dev.ssmsmac.goToLine")
}

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

    // MARK: - View construction

    /// Builds the editor's text view. Shared with the `--editor-check` diagnostic so
    /// the thing under test is the thing that ships.
    ///
    /// The TextKit 1 stack is assembled by hand on purpose. `NSTextView(frame:)` opts
    /// into TextKit 2 on macOS 14+, and the first touch of the legacy `layoutManager`
    /// property migrates it back mid-flight. The highlighter, the gutter and the
    /// current-line band all use that property, so pinning the engine up front keeps
    /// the view from switching engines after it is already on screen.
    static func makeTextView(wordWrap: Bool) -> SQLTextView {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                     height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = wordWrap
        layoutManager.addTextContainer(container)

        let textView = SQLTextView(frame: .zero, textContainer: container)
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
        textView.textContainerInset = NSSize(width: 6, height: 8)
        return textView
    }

    /// Places the text view inside the scroll view and sizes its text container.
    ///
    /// `isHorizontallyResizable` (the text view sizes itself to its content),
    /// `widthTracksTextView` (the container follows the text view) and an autoresizing
    /// mask of `.width` (the superview sizes the text view) are mutually exclusive.
    /// Only one of the three may be active for a given wrap mode.
    static func install(textView: SQLTextView, in scrollView: NSScrollView, wordWrap: Bool) {
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = !wordWrap
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        // The gutter is a sibling view; a custom NSRulerView breaks the scroll view's
        // tiling badly enough that the document view stops compositing entirely.
        scrollView.hasVerticalRuler = false
        scrollView.rulersVisible = false

        let visible = scrollView.contentSize
        let initial = NSSize(width: max(visible.width, 400), height: max(visible.height, 200))
        textView.frame = NSRect(origin: .zero, size: initial)
        textView.isVerticallyResizable = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)

        guard let container = textView.textContainer else {
            scrollView.documentView = textView
            return
        }

        if wordWrap {
            textView.isHorizontallyResizable = false
            textView.autoresizingMask = [.width]
            container.widthTracksTextView = true
            container.size = NSSize(width: initial.width, height: CGFloat.greatestFiniteMagnitude)
        } else {
            textView.isHorizontallyResizable = true
            textView.autoresizingMask = []
            container.widthTracksTextView = false
            container.size = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                    height: CGFloat.greatestFiniteMagnitude)
        }
        container.heightTracksTextView = false

        // Keeps the editor filling the pane when the document is shorter or narrower
        // than the visible area, so clicks in the empty region still land in the text.
        textView.minSize = initial
        scrollView.documentView = textView
    }

    /// Re-applies the sizes that depend on the visible area, which SwiftUI only
    /// establishes after the representable has been created.
    static func updateGeometry(textView: SQLTextView, scrollView: NSScrollView, wordWrap: Bool) {
        let visible = scrollView.contentSize
        guard visible.width > 1, visible.height > 1 else { return }
        textView.minSize = visible
        if wordWrap {
            textView.textContainer?.size = NSSize(width: visible.width,
                                                  height: CGFloat.greatestFiniteMagnitude)
        }
        if textView.frame.width < visible.width {
            textView.setFrameSize(NSSize(width: visible.width,
                                         height: max(textView.frame.height, visible.height)))
        }
    }

    func makeNSView(context: Context) -> EditorContainerView {
        let scrollView = NSScrollView()
        let textView = SQLEditorView.makeTextView(wordWrap: settings.editorWordWrap)
        textView.delegate = context.coordinator
        textView.sqlDelegate = context.coordinator
        SQLEditorView.install(textView: textView, in: scrollView,
                              wordWrap: settings.editorWordWrap)
        textView.string = tab.text

        let container = EditorContainerView(scrollView: scrollView)
        container.gutter.textView = textView
        container.showsGutter = settings.editorShowLineNumbers

        let coordinator = context.coordinator
        coordinator.textView = textView
        coordinator.container = container
        textView.onEffectiveAppearanceChange = { [weak coordinator] in
            coordinator?.refreshAppearance()
        }
        textView.onBookmarksChanged = { [weak container] lines in
            container?.gutter.bookmarkLines = lines
        }
        coordinator.applyAppearance(to: textView, gutter: container.gutter)
        coordinator.highlightAll()

        NotificationCenter.default.addObserver(
            forName: .ssmsGoToLine,
            object: nil,
            queue: .main
        ) { [weak textView] note in
            MainActor.assumeIsolated {
                guard let textView, textView.window?.isKeyWindow == true,
                      let line = note.userInfo?["line"] as? Int else { return }
                textView.goToLine(line)
            }
        }

        NotificationCenter.default.addObserver(
            forName: EditorDump.requestNotification,
            object: nil,
            queue: .main
        ) { [weak coordinator] _ in
            MainActor.assumeIsolated {
                guard let coordinator, let textView = coordinator.textView,
                      textView.window?.isKeyWindow == true else { return }
                EditorDump.capture(textView: textView, tabText: coordinator.tab.text,
                                   label: coordinator.tab.displayTitle)
            }
        }

        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.contentView.postsFrameChangedNotifications = true
        for name in [NSView.boundsDidChangeNotification, NSView.frameDidChangeNotification] {
            NotificationCenter.default.addObserver(
                forName: name,
                object: scrollView.contentView,
                queue: .main
            ) { [weak container, weak textView] _ in
                MainActor.assumeIsolated {
                    guard let container, let textView else { return }
                    SQLEditorView.updateGeometry(textView: textView,
                                                 scrollView: container.scrollView,
                                                 wordWrap: AppSettings.shared.editorWordWrap)
                    container.refreshGutter()
                }
            }
        }

        return container
    }

    func updateNSView(_ container: EditorContainerView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        context.coordinator.tab = tab
        context.coordinator.settings = settings

        if textView.string != tab.text && !context.coordinator.isEditing {
            let selected = textView.selectedRange()
            textView.string = tab.text
            let limit = (tab.text as NSString).length
            textView.setSelectedRange(NSRange(location: min(selected.location, limit), length: 0))
            context.coordinator.highlightAll()
        }

        container.showsGutter = settings.editorShowLineNumbers
        SQLEditorView.updateGeometry(textView: textView, scrollView: container.scrollView,
                                     wordWrap: settings.editorWordWrap)
        context.coordinator.applyAppearance(to: textView, gutter: container.gutter)
        container.gutter.errorLines = Set(tab.messages
            .filter { $0.kind == .error && $0.scriptLine > 0 }
            .map(\.scriptLine))
        container.refreshGutter()
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate, SQLTextViewDelegate {
        var tab: QueryTab
        var settings: AppSettings
        weak var textView: SQLTextView?
        weak var container: EditorContainerView?
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

        /// Re-resolve after the view joins a window or the system theme flips.
        func refreshAppearance() {
            guard let textView else { return }
            applyAppearance(to: textView, gutter: container?.gutter)
        }

        func applyAppearance(to textView: SQLTextView, gutter: LineNumberGutterView?) {
            // Ask the text view itself: before it joins a window its enclosing scroll
            // view still reports the process default appearance.
            let isDark = textView.effectiveAppearance
                .bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let font = settings.editorFont

            // These follow preferences rather than appearance, so they are applied on
            // every pass instead of behind the change guard.
            textView.highlightCurrentLine = settings.editorHighlightCurrentLine
            textView.indentWidth = settings.editorTabWidth
            textView.usesSpacesForTabs = settings.editorUsesSpaces

            guard appliedDark != isDark || appliedFont != font else { return }
            appliedDark = isDark
            appliedFont = font

            let palette = isDark ? Theme.dark : Theme.light
            textView.applyPalette(palette, font: font)
            gutter?.palette = palette
            gutter?.font = NSFont.monospacedSystemFont(ofSize: max(9, font.pointSize - 2),
                                                       weight: .regular)
            highlighter.update(palette: palette, font: font)
            highlightAll()
        }

        func highlightAll() {
            guard let storage = textView?.textStorage else { return }
            highlighter.highlight(storage)
        }

        // MARK: NSTextViewDelegate

        func textDidChange(_ notification: Notification) {
            guard let textView, let storage = textView.textStorage else { return }
            isEditing = true
            defer { isEditing = false }

            let edited = textView.string as NSString
            let range = highlighter.rangeToRehighlight(
                for: NSRange(location: max(0, textView.selectedRange().location - 1), length: 0),
                in: edited)
            highlighter.highlight(storage, in: range)
            tab.text = textView.string
            container?.refreshGutter()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView else { return }
            tab.selectedRange = textView.selectedRange()
            container?.gutter.refresh()
        }

        // MARK: SQLTextViewDelegate

        func sqlTextViewDidRequestExecute(_ textView: SQLTextView) { onExecute() }
        func sqlTextViewDidRequestExecuteSelection(_ textView: SQLTextView) { onExecuteSelection() }
        func sqlTextViewDidRequestCancel(_ textView: SQLTextView) { onCancel() }

        func sqlTextViewDidChangeCaret(_ textView: SQLTextView) {
            guard settings.intelliSenseEnabled else { return }
            tab.requestCompletions(at: textView.selectedRange().location)
        }

        /// Candidates for the caret's context. Ranking and filtering happen in the
        /// text view, which owns the query string as the user types.
        func sqlTextViewCompletionCandidates(_ textView: SQLTextView) -> [CompletionItem] {
            guard settings.intelliSenseEnabled else { return [] }
            return tab.completionItems.isEmpty ? Coordinator.keywordFallback : tab.completionItems
        }

        func sqlTextViewDidRequestExpandWildcards(_ textView: SQLTextView) {
            Task { @MainActor in
                guard let expansion = await tab.expandWildcards(at: textView.selectedRange().location)
                else { return }
                let range = NSRange(location: 0, length: (textView.string as NSString).length)
                guard textView.shouldChangeText(in: range, replacementString: expansion.text) else {
                    return
                }
                textView.textStorage?.replaceCharacters(in: range, with: expansion.text)
                textView.didChangeText()
                let limit = (expansion.text as NSString).length
                textView.setSelectedRange(NSRange(location: min(expansion.caret, limit), length: 0))
                self.highlightAll()
            }
        }

        /// Used before the server catalog has loaded, so completion is never dead.
        static let keywordFallback: [CompletionItem] = TSQLKeywords.allCompletionWords.map {
            CompletionItem(id: "keyword:\($0)", label: $0, kind: .keyword,
                           detail: "", documentation: "", insertText: $0, sortPriority: 500)
        }
    }
}
