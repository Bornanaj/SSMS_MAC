import SwiftUI
import AppKit
import SQLServerKit

extension Notification.Name {
    /// Posted by the Go To Line dialog and the Messages tab. `userInfo` carries the
    /// 1-based "line" and the "tabID" of the tab whose editor should move; without a
    /// tab id the editor in the key window acts on it.
    static let ssmsGoToLine = Notification.Name("dev.ssmsmac.goToLine")
}

/// SwiftUI wrapper around `SQLTextView` with a line-number gutter and live colouring.
///
/// The text view belongs to the tab, not to this wrapper. SwiftUI rebuilds the wrapper
/// whenever the window re-arranges itself (another tab is selected, the results pane
/// is hidden), and a rebuilt `NSTextView` would start with no undo history, no caret
/// and no scroll position. So the wrapper owns the scroll view and the gutter, and
/// adopts whichever tab's text view it is showing.
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
    ///
    /// A text view that has been shown before keeps the frame its content gave it; the
    /// initial size only applies to a fresh one.
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
        let current = textView.frame.size
        textView.frame = NSRect(origin: .zero,
                                size: NSSize(width: max(initial.width, current.width),
                                             height: max(initial.height, current.height)))
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
        let container = EditorContainerView(scrollView: scrollView)
        container.showsGutter = settings.editorShowLineNumbers

        let coordinator = context.coordinator
        coordinator.container = container
        coordinator.show(tab, focus: false)

        coordinator.observers.append(NotificationCenter.default.addObserver(
            forName: .ssmsGoToLine,
            object: nil,
            queue: .main
        ) { [weak coordinator] note in
            MainActor.assumeIsolated {
                guard let coordinator, let textView = coordinator.textView,
                      let line = note.userInfo?["line"] as? Int else { return }
                if let tabID = note.userInfo?["tabID"] as? UUID {
                    guard tabID == coordinator.tab.id else { return }
                } else {
                    guard textView.window?.isKeyWindow == true else { return }
                }
                textView.goToLine(line)
                textView.window?.makeFirstResponder(textView)
            }
        })

        coordinator.observers.append(NotificationCenter.default.addObserver(
            forName: EditorDump.requestNotification,
            object: nil,
            queue: .main
        ) { [weak coordinator] _ in
            MainActor.assumeIsolated {
                guard let coordinator, let textView = coordinator.textView,
                      textView.window?.isKeyWindow == true else { return }
                EditorDump.capture(textView: textView, tab: coordinator.tab,
                                   label: coordinator.tab.displayTitle)
            }
        })

        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.contentView.postsFrameChangedNotifications = true
        for name in [NSView.boundsDidChangeNotification, NSView.frameDidChangeNotification] {
            coordinator.observers.append(NotificationCenter.default.addObserver(
                forName: name,
                object: scrollView.contentView,
                queue: .main
            ) { [weak coordinator] _ in
                MainActor.assumeIsolated {
                    guard let coordinator, let container = coordinator.container,
                          let textView = coordinator.textView,
                          container.scrollView.documentView === textView else { return }
                    SQLEditorView.updateGeometry(textView: textView,
                                                 scrollView: container.scrollView,
                                                 wordWrap: AppSettings.shared.editorWordWrap)
                    // Remembered as it happens: when the wrapper is rebuilt, the new one
                    // may adopt the text view before the old one is torn down.
                    if !coordinator.isRestoringScroll {
                        coordinator.tab.editorScrollOrigin = container.scrollView.contentView.bounds.origin
                    }
                    container.refreshGutter()
                }
            })
        }

        return container
    }

    func updateNSView(_ container: EditorContainerView, context: Context) {
        let coordinator = context.coordinator
        coordinator.settings = settings
        // The same wrapper is handed whichever tab is selected.
        if coordinator.tab !== tab || coordinator.textView !== tab.editorTextView {
            coordinator.show(tab, focus: coordinator.tab !== tab)
        }
        guard let textView = coordinator.textView else { return }

        // An external change to the script (Format Script, template values). It goes
        // through the undo machinery: assigning `string` would leave undo entries
        // whose ranges no longer fit, and Cmd+Z would raise NSRangeException.
        if textView.string != tab.text && !coordinator.isEditing {
            coordinator.replaceAllText(with: tab.text)
        }

        if coordinator.appliedWordWrap != settings.editorWordWrap {
            coordinator.applyWordWrap(settings.editorWordWrap)
        }
        container.showsGutter = settings.editorShowLineNumbers
        SQLEditorView.updateGeometry(textView: textView, scrollView: container.scrollView,
                                     wordWrap: settings.editorWordWrap)
        coordinator.applyAppearance(to: textView, gutter: container.gutter)
        container.gutter.errorLines = Set(tab.messages
            .filter { $0.kind == .error && $0.scriptLine > 0 }
            .map(\.scriptLine))
        container.refreshGutter()
    }

    static func dismantleNSView(_ container: EditorContainerView, coordinator: Coordinator) {
        for observer in coordinator.observers {
            NotificationCenter.default.removeObserver(observer)
        }
        coordinator.observers.removeAll()
        // The text view stays with its tab; only a delegate still pointing here is
        // cleared, since a newer wrapper may already have adopted the view.
        if let textView = coordinator.textView, textView.delegate === coordinator {
            textView.delegate = nil
            textView.sqlDelegate = nil
        }
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate, SQLTextViewDelegate {
        var tab: QueryTab
        var settings: AppSettings
        weak var textView: SQLTextView?
        weak var container: EditorContainerView?
        var isEditing = false
        var observers: [NSObjectProtocol] = []
        private(set) var appliedWordWrap: Bool?
        /// Set while a tab's scroll position is being put back, so the bounds
        /// observer does not record the intermediate origin as the tab's own.
        private(set) var isRestoringScroll = false

        private let onExecute: () -> Void
        private let onExecuteSelection: () -> Void
        private let onCancel: () -> Void
        private var highlighter: SQLHighlighter
        /// The range (in the new text) of the change AppKit is about to make, collected
        /// from `shouldChangeTextIn` so `textDidChange` knows what to re-colour.
        private var pendingEdit: NSRange?
        private var pendingEditCoversAll = false

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

        // MARK: Adopting a tab's editor

        /// Puts `tab`'s text view into the scroll view, building one the first time
        /// the tab is shown and parking the previous tab's view otherwise.
        func show(_ tab: QueryTab, focus: Bool) {
            guard let container else { return }
            if let previous = textView, previous !== tab.editorTextView { park() }
            self.tab = tab
            let savedOrigin = tab.editorScrollOrigin
            isRestoringScroll = true
            defer { isRestoringScroll = false }

            let isNew = tab.editorTextView == nil
            let textView = tab.editorTextView ?? makeEditor(for: tab)
            tab.editorTextView = textView
            self.textView = textView
            textView.delegate = self
            textView.sqlDelegate = self

            let wordWrap = settings.editorWordWrap
            SQLEditorView.install(textView: textView, in: container.scrollView, wordWrap: wordWrap)
            appliedWordWrap = wordWrap
            if !isNew {
                // A view that has been shown before already has its layout; the frame
                // it needs is the one its content gave it, not the visible size.
                textView.sizeToFit()
            }

            container.gutter.textView = textView
            container.gutter.bookmarkLines = tab.bookmarks
            textView.onEffectiveAppearanceChange = { [weak self] in
                self?.refreshAppearance()
            }
            textView.onBookmarksChanged = { [weak tab, weak container] lines in
                tab?.bookmarks = lines
                container?.gutter.bookmarkLines = lines
            }
            // Completions are computed off the main actor, so the popup is opened by
            // the answer arriving rather than by the keystroke that asked for it.
            tab.onCompletionsUpdated = { [weak textView] in
                textView?.completionsDidUpdate()
            }

            applyAppearance(to: textView, gutter: container.gutter)
            if isNew { highlightAll() }

            let clip = container.scrollView.contentView
            clip.scroll(to: savedOrigin)
            container.scrollView.reflectScrolledClipView(clip)
            tab.editorScrollOrigin = savedOrigin
            container.refreshGutter()

            if focus, let window = container.window {
                // Switching tabs: the editor that just appeared should take the keys.
                DispatchQueue.main.async { [weak textView] in
                    guard let textView, textView.window === window else { return }
                    window.makeFirstResponder(textView)
                }
            }
        }

        private func makeEditor(for tab: QueryTab) -> SQLTextView {
            let textView = SQLEditorView.makeTextView(wordWrap: settings.editorWordWrap)
            // A fresh view has no undo history to protect, so a plain assignment is fine.
            textView.string = tab.text
            textView.bookmarks = tab.bookmarks
            let limit = (tab.text as NSString).length
            let selected = tab.selectedRange
            textView.setSelectedRange(NSRange(location: min(selected.location, limit),
                                              length: min(selected.length, limit - min(selected.location, limit))))
            return textView
        }

        /// Records what the next `show` needs to put back for the current tab.
        private func park() {
            guard let container, container.scrollView.documentView === textView else { return }
            tab.editorScrollOrigin = container.scrollView.contentView.bounds.origin
        }

        func applyWordWrap(_ wordWrap: Bool) {
            guard let textView, let container else { return }
            SQLEditorView.install(textView: textView, in: container.scrollView, wordWrap: wordWrap)
            appliedWordWrap = wordWrap
            textView.sizeToFit()
        }

        /// Replaces the whole document through the undo machinery, so Cmd+Z restores
        /// the previous text and the undo entries before it keep fitting the storage.
        func replaceAllText(with newText: String) {
            guard let textView else { return }
            let full = NSRange(location: 0, length: (textView.string as NSString).length)
            let caret = textView.selectedRange().location
            guard textView.shouldChangeText(in: full, replacementString: newText) else { return }
            textView.textStorage?.replaceCharacters(in: full, with: newText)
            textView.didChangeText()
            let limit = (newText as NSString).length
            textView.setSelectedRange(NSRange(location: min(caret, limit), length: 0))
            textView.scrollRangeToVisible(textView.selectedRange())
        }

        // MARK: Appearance

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
            let palette = isDark ? Theme.dark : Theme.light

            // These follow preferences rather than appearance, so they are applied on
            // every pass instead of behind the change guard.
            textView.highlightCurrentLine = settings.editorHighlightCurrentLine
            textView.indentWidth = settings.editorTabWidth
            textView.usesSpacesForTabs = settings.editorUsesSpaces
            // The highlighter is this coordinator's; the view may have been coloured by
            // an earlier one, so it is kept in step even when nothing else changes.
            highlighter.update(palette: palette, font: font)

            let theme = SQLTextView.AppliedTheme(isDark: isDark, font: font)
            guard textView.appliedTheme != theme else { return }
            textView.appliedTheme = theme

            textView.applyPalette(palette, font: font)
            gutter?.palette = palette
            gutter?.font = NSFont.monospacedSystemFont(ofSize: max(9, font.pointSize - 2),
                                                       weight: .regular)
            highlightAll()
        }

        func highlightAll() {
            guard let storage = textView?.textStorage else { return }
            highlighter.highlight(storage)
        }

        // MARK: NSTextViewDelegate

        func undoManager(for view: NSTextView) -> UndoManager? {
            tab.undoManager
        }

        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange,
                      replacementString: String?) -> Bool {
            // nil means an attribute-only change, which the colouring does not follow.
            if let replacementString {
                noteEdit(NSRange(location: affectedCharRange.location,
                                 length: (replacementString as NSString).length))
            }
            return true
        }

        func textView(_ textView: NSTextView, shouldChangeTextInRanges affectedRanges: [NSValue],
                      replacementStrings: [String]?) -> Bool {
            guard let replacementStrings, replacementStrings.count == affectedRanges.count else {
                return true
            }
            if affectedRanges.count == 1, let range = affectedRanges.first?.rangeValue {
                noteEdit(NSRange(location: range.location,
                                 length: (replacementStrings[0] as NSString).length))
            } else if !affectedRanges.isEmpty {
                // Several ranges shift each other; re-colouring everything is simplest.
                pendingEditCoversAll = true
            }
            return true
        }

        private func noteEdit(_ range: NSRange) {
            pendingEdit = pendingEdit.map { NSUnionRange($0, range) } ?? range
        }

        func textDidChange(_ notification: Notification) {
            guard let textView, let storage = textView.textStorage else { return }
            isEditing = true
            defer { isEditing = false }

            let edited = pendingEdit
            let coversAll = pendingEditCoversAll
            pendingEdit = nil
            pendingEditCoversAll = false
            if coversAll {
                highlightAll()
            } else {
                // Without a recorded edit (an input method composing text, say) the
                // caret's line is the best available guess.
                let caret = textView.selectedRange().location
                highlighter.rehighlight(storage, editedRange: edited
                    ?? NSRange(location: max(0, caret - 1), length: 0))
            }
            tab.text = textView.string
            container?.refreshGutter()
            // Completion candidates follow the text, not just the caret: an edit that
            // leaves the caret where it was (a paste, a delete, an undo) still changes
            // what should be offered.
            if settings.intelliSenseEnabled {
                tab.requestCompletions(script: textView.string,
                                       at: textView.selectedRange().location)
            }
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
            // The text view's own string is used: `tab.text` is only updated after
            // AppKit finishes the edit, so it trails the caret by one character.
            tab.requestCompletions(script: textView.string,
                                   at: textView.selectedRange().location)
        }

        /// Candidates for the caret's context. Ranking and filtering happen in the
        /// text view, which owns the query string as the user types.
        func sqlTextViewCompletionCandidates(_ textView: SQLTextView) -> [CompletionItem] {
            guard settings.intelliSenseEnabled else { return [] }
            if !tab.completionItems.isEmpty { return tab.completionItems }
            // After "alias." or "schema." a keyword list is simply the wrong answer,
            // so nothing is offered until the catalog can answer properly.
            return tab.completionIsMemberContext ? [] : Coordinator.keywordFallback
        }

        func sqlTextViewCompletionMessage(_ textView: SQLTextView) -> String? {
            guard settings.intelliSenseEnabled else { return nil }
            return tab.completionMessage
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
            }
        }

        /// Used before the server catalog has loaded, so completion is never dead.
        static let keywordFallback: [CompletionItem] = TSQLKeywords.allCompletionWords.map {
            CompletionItem(id: "keyword:\($0)", label: $0, kind: .keyword,
                           detail: "", documentation: "", insertText: $0, sortPriority: 500)
        }
    }
}
