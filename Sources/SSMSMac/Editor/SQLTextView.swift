import AppKit
import SQLServerKit

@MainActor
protocol SQLTextViewDelegate: AnyObject {
    func sqlTextViewDidRequestExecute(_ textView: SQLTextView)
    func sqlTextViewDidRequestExecuteSelection(_ textView: SQLTextView)
    func sqlTextViewDidRequestCancel(_ textView: SQLTextView)
    /// Candidates for the caret's context, unfiltered. The text view ranks them.
    func sqlTextViewCompletionCandidates(_ textView: SQLTextView) -> [CompletionItem]
    /// Why there are none, when there are none.
    func sqlTextViewCompletionMessage(_ textView: SQLTextView) -> String?
    func sqlTextViewDidRequestExpandWildcards(_ textView: SQLTextView)
    func sqlTextViewDidChangeCaret(_ textView: SQLTextView)
}

/// NSTextView tuned for T-SQL: block indent, comment toggling, bracket completion
/// and an IntelliSense popup backed by the native completion machinery.
final class SQLTextView: NSTextView {
    weak var sqlDelegate: SQLTextViewDelegate?
    var indentWidth = 4
    var usesSpacesForTabs = true
    var highlightCurrentLine = true
    var palette: Theme.SyntaxPalette = Theme.light

    private var completionTimer: Timer?
    /// Set while a completion request is still in flight, holding the `force` flag of
    /// the request that is waiting for it. Without it the popup would be decided
    /// against a cache that is one keystroke old and simply never appear.
    private var pendingCompletionForce: Bool?
    let completionPanel = CompletionPanelController()

    /// 1-based lines the user has bookmarked, mirrored into the gutter and the tab.
    var bookmarks: Set<Int> = [] {
        didSet { onBookmarksChanged?(bookmarks) }
    }
    var onBookmarksChanged: ((Set<Int>) -> Void)?

    /// The appearance and font last applied by a coordinator. The view outlives the
    /// SwiftUI wrapper that shows it, so a new wrapper reads this instead of
    /// re-colouring the whole document on every tab switch.
    struct AppliedTheme: Equatable {
        var isDark: Bool
        var font: NSFont
    }
    var appliedTheme: AppliedTheme?

    /// Raised when the view lands in a window or the system switches light/dark, so
    /// the coordinator can re-resolve the palette against a real appearance.
    var onEffectiveAppearanceChange: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onEffectiveAppearanceChange?()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { onEffectiveAppearanceChange?() }
    }

    /// Applies colours to everything the text view draws itself, including the
    /// attributes newly typed characters inherit.
    func applyPalette(_ palette: Theme.SyntaxPalette, font: NSFont) {
        self.palette = palette
        self.font = font
        backgroundColor = palette.background
        textColor = palette.plain
        insertionPointColor = palette.plain
        typingAttributes = [.font: font, .foregroundColor: palette.plain]
        selectedTextAttributes = [
            .backgroundColor: NSColor.selectedTextBackgroundColor
        ]
    }

    // MARK: - Key handling

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // While the list is up it owns the navigation keys, and nothing else.
        if completionPanel.isVisible,
           let key = CompletionKey.resolve(keyCode: event.keyCode, flags: event.modifierFlags) {
            switch key {
            case .up: completionPanel.moveSelection(by: -1)
            case .down: completionPanel.moveSelection(by: 1)
            case .pageUp: completionPanel.moveSelection(by: -8)
            case .pageDown: completionPanel.moveSelection(by: 8)
            case .commit: commitCompletion()
            case .dismiss: completionPanel.hide()
            }
            return
        }

        // F5 executes; Cmd+. cancels, matching the SSMS bindings people have in muscle memory.
        if event.keyCode == 96 { // F5
            if flags.contains(.shift) {
                sqlDelegate?.sqlTextViewDidRequestExecuteSelection(self)
            } else {
                sqlDelegate?.sqlTextViewDidRequestExecute(self)
            }
            return
        }
        if flags == .command, event.charactersIgnoringModifiers == "." {
            sqlDelegate?.sqlTextViewDidRequestCancel(self)
            return
        }
        if flags == .command, event.charactersIgnoringModifiers == "/" {
            toggleLineComment(nil)
            return
        }
        if event.keyCode == 48 { // Tab
            if flags.contains(.shift) {
                outdentSelection()
                return
            }
            if selectedRange().length > 0 || hasMultilineSelection {
                indentSelection()
                return
            }
            insertIndent()
            return
        }
        if flags == [.control], event.charactersIgnoringModifiers == " " {
            showCompletions(force: true)
            return
        }

        super.keyDown(with: event)
        scheduleCompletionIfNeeded(after: event)
    }

    private var hasMultilineSelection: Bool {
        let range = selectedRange()
        guard range.length > 0 else { return false }
        return (string as NSString).substring(with: range).contains("\n")
    }

    private func scheduleCompletionIfNeeded(after event: NSEvent) {
        // Backspace keeps the list open and refilters it, the way every other editor
        // behaves; it only closes once there is nothing left to filter by.
        if event.keyCode == 51 {
            guard completionPanel.isVisible else { return }
            if rangeForUserCompletion.length == 0 && !isDirectlyAfterDot() {
                completionTimer?.invalidate()
                completionPanel.hide()
            } else {
                showCompletions(force: false)
            }
            return
        }

        guard let characters = event.charactersIgnoringModifiers,
              let scalar = characters.unicodeScalars.first else { return }
        let wordCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_@#$"))
        let isWordCharacter = wordCharacters.contains(scalar)
        let isDot = scalar == "."

        guard isWordCharacter || isDot else {
            // Anything else ends the current word, so the list has nothing left to filter.
            completionTimer?.invalidate()
            pendingCompletionForce = nil
            completionPanel.hide()
            return
        }

        if completionPanel.isVisible && !isDot {
            // Already open: refilter immediately rather than waiting out the delay.
            showCompletions(force: false)
            return
        }

        // One character is enough to start filtering — waiting for two is what makes
        // the list feel like it is not there. The delay below keeps it from flashing
        // while someone types quickly.
        if !isDot && rangeForUserCompletion.length < 1 { return }

        completionTimer?.invalidate()
        completionTimer = Timer.scheduledTimer(withTimeInterval: isDot ? 0.05 : 0.25,
                                               repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.window?.firstResponder === self else { return }
                // A dot has no prefix to filter by, so the list has to be asked for
                // outright or it would close itself as soon as it opened.
                self.showCompletions(force: isDot)
            }
        }
    }

    /// True when the caret sits straight after a qualifying dot, where the member list
    /// is expected even though nothing has been typed to filter it.
    private func isDirectlyAfterDot() -> Bool {
        let start = rangeForUserCompletion.location
        guard start > 0 else { return false }
        let text = string as NSString
        guard start <= text.length else { return false }
        return text.substring(with: NSRange(location: start - 1, length: 1)) == "."
    }

    /// Called when the tab's candidate list has been recomputed; opens or re-ranks the
    /// popup against the fresh list.
    func completionsDidUpdate() {
        guard let pending = pendingCompletionForce else {
            if completionPanel.isVisible { showCompletions(force: false, isRefresh: true) }
            return
        }
        pendingCompletionForce = nil
        guard window?.firstResponder === self else { return }
        showCompletions(force: pending, isRefresh: true)
    }

    // MARK: - Completion

    /// AppKit binds Escape to `complete:`, so the key that should dismiss the
    /// completion list is the one that summons it. Escape only ever cancels here.
    override func cancelOperation(_ sender: Any?) {
        completionTimer?.invalidate()
        completionTimer = nil
        pendingCompletionForce = nil
        completionPanel.hide()
    }

    override var rangeForUserCompletion: NSRange {
        let text = string as NSString
        let caret = selectedRange().location
        guard caret <= text.length else { return NSRange(location: caret, length: 0) }
        var start = caret
        let wordCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_@#$"))
        while start > 0 {
            let range = NSRange(location: start - 1, length: 1)
            guard let scalar = text.substring(with: range).unicodeScalars.first,
                  wordCharacters.contains(scalar) else { break }
            start -= 1
        }
        return NSRange(location: start, length: caret - start)
    }

    /// The built-in completion UI is never used: it is a plain list that previews its
    /// selection straight into the buffer. Everything goes through CompletionPanelController.
    override func complete(_ sender: Any?) {
        showCompletions(force: true)
    }

    /// `isRefresh` marks the pass that runs once a request has landed, so an empty
    /// answer there is taken at face value instead of waiting for another one.
    func showCompletions(force: Bool, isRefresh: Bool = false) {
        guard let delegate = sqlDelegate else { return }
        let range = rangeForUserCompletion
        let prefix = (string as NSString).substring(with: range)
        if !force && prefix.isEmpty && !isDirectlyAfterDot() && !completionPanel.isVisible {
            completionPanel.hide()
            return
        }

        let candidates = delegate.sqlTextViewCompletionCandidates(self)
        guard !candidates.isEmpty else {
            // The list for this caret position may still be on its way; wait for it
            // once rather than concluding there is nothing to show.
            if !isRefresh { pendingCompletionForce = force }
            // On the second pass there is genuinely nothing — and after a dot, an
            // empty popup and a popup that never opened look the same. Say why.
            if isRefresh, let message = delegate.sqlTextViewCompletionMessage(self) {
                showMessage(message)
            } else {
                completionPanel.hide()
            }
            return
        }

        let ranked = CompletionMatcher.filter(candidates, query: prefix,
                                              key: { $0.label },
                                              basePriority: { $0.sortPriority })
        var seen = Set<String>()
        let entries = ranked.prefix(300).compactMap { scored -> CompletionEntry? in
            // Two providers can offer the same item; the popup keys its rows by id and
            // would drop rows if a duplicate reached it.
            guard seen.insert(scored.item.id).inserted else { return nil }
            return CompletionEntry(item: scored.item, positions: scored.match.positions)
        }
        guard !entries.isEmpty else {
            if !isRefresh { pendingCompletionForce = force }
            completionPanel.hide()
            return
        }

        pendingCompletionForce = nil
        completionPanel.onChoose = { [weak self] _ in self?.commitCompletion() }
        completionPanel.show(entries: entries, below: caretRect(), in: self)
    }

    /// One unselectable row explaining why the list is empty.
    private func showMessage(_ message: String) {
        let item = CompletionItem(id: "info:\(message)", label: message, kind: .info,
                                  detail: "", documentation: "", insertText: "",
                                  sortPriority: 0)
        completionPanel.onChoose = { [weak self] _ in self?.completionPanel.hide() }
        completionPanel.show(entries: [CompletionEntry(item: item, positions: [])],
                             below: caretRect(), in: self)
    }

    func commitCompletion() {
        // An explanation is not a completion: Return and Tab dismiss it.
        if completionPanel.selectedItem?.kind == .info {
            completionPanel.hide()
            return
        }
        guard let item = completionPanel.selectedItem else {
            completionPanel.hide()
            return
        }
        completionPanel.hide()
        let range = rangeForUserCompletion
        guard shouldChangeText(in: range, replacementString: item.insertText) else { return }
        textStorage?.replaceCharacters(in: range, with: item.insertText)
        didChangeText()
        let caret = range.location + (item.insertText as NSString).length
        setSelectedRange(NSRange(location: caret, length: 0))
    }

    /// Screen-space rectangle of the caret, used to place the list under it.
    private func caretRect() -> NSRect {
        guard let layoutManager, let container = textContainer else { return .zero }
        let range = rangeForUserCompletion
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: NSRange(location: range.location, length: 0),
            actualCharacterRange: nil)
        var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: container)
        rect.origin.x += textContainerInset.width
        rect.origin.y += textContainerInset.height
        if rect.width < 1 { rect.size.width = 1 }
        return rect
    }

    // MARK: - Navigation

    /// 1-based line containing the caret.
    var currentLine: Int {
        TextLines.line(at: selectedRange().location, in: string as NSString)
    }

    var lineCount: Int {
        TextLines.count(in: string as NSString)
    }

    /// Character range of a 1-based line.
    func range(ofLine line: Int) -> NSRange? {
        TextLines.range(ofLine: line, in: string as NSString)
    }

    @objc func goToLine(_ line: Int) {
        guard let range = range(ofLine: line) else { return }
        setSelectedRange(NSRange(location: range.location, length: 0))
        scrollRangeToVisible(range)
        showFindIndicator(for: range)
    }

    // MARK: - Bookmarks

    @objc func toggleBookmark(_ sender: Any?) {
        let line = currentLine
        if bookmarks.contains(line) { bookmarks.remove(line) } else { bookmarks.insert(line) }
    }

    @objc func nextBookmark(_ sender: Any?) {
        guard !bookmarks.isEmpty else { return }
        let line = currentLine
        // Wrap around, which is what F2 does in SSMS.
        let target = bookmarks.sorted().first { $0 > line } ?? bookmarks.min()
        if let target { goToLine(target) }
    }

    @objc func previousBookmark(_ sender: Any?) {
        guard !bookmarks.isEmpty else { return }
        let line = currentLine
        let target = bookmarks.sorted().last { $0 < line } ?? bookmarks.max()
        if let target { goToLine(target) }
    }

    @objc func clearBookmarks(_ sender: Any?) {
        bookmarks.removeAll()
    }

    @objc func expandWildcards(_ sender: Any?) {
        sqlDelegate?.sqlTextViewDidRequestExpandWildcards(self)
    }

    override func resignFirstResponder() -> Bool {
        pendingCompletionForce = nil
        completionPanel.hide()
        return super.resignFirstResponder()
    }

    // MARK: - Indentation and comments

    private var indentString: String {
        usesSpacesForTabs ? String(repeating: " ", count: indentWidth) : "\t"
    }

    private func insertIndent() {
        insertText(indentString, replacementRange: selectedRange())
    }

    @objc func indentSelection() {
        transformSelectedLines { line in self.indentString + line }
    }

    @objc func outdentSelection() {
        transformSelectedLines { line in
            if line.hasPrefix("\t") { return String(line.dropFirst()) }
            var result = line
            var removed = 0
            while removed < self.indentWidth, result.hasPrefix(" ") {
                result.removeFirst()
                removed += 1
            }
            return result
        }
    }

    @objc func toggleLineComment(_ sender: Any?) {
        let text = string as NSString
        let lineRange = text.lineRange(for: selectedRange())
        let block = text.substring(with: lineRange)
        let lines = block.components(separatedBy: "\n")
        let meaningful = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let allCommented = !meaningful.isEmpty && meaningful.allSatisfy {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("--")
        }

        let transformed = lines.map { line -> String in
            if line.trimmingCharacters(in: .whitespaces).isEmpty { return line }
            if allCommented {
                guard let range = line.range(of: "--") else { return line }
                var result = line
                result.removeSubrange(range)
                if result.hasPrefix(" ") && line[range.upperBound...].hasPrefix(" ") { result.removeFirst() }
                return result
            }
            let indent = line.prefix { $0 == " " || $0 == "\t" }
            return indent + "-- " + line.dropFirst(indent.count)
        }.joined(separator: "\n")

        replaceAndSelect(range: lineRange, with: transformed)
    }

    private func transformSelectedLines(_ transform: (String) -> String) {
        let text = string as NSString
        let lineRange = text.lineRange(for: selectedRange())
        let block = text.substring(with: lineRange)
        let hasTrailingNewline = block.hasSuffix("\n")
        var lines = block.components(separatedBy: "\n")
        if hasTrailingNewline { lines.removeLast() }
        var transformed = lines.map(transform).joined(separator: "\n")
        if hasTrailingNewline { transformed += "\n" }
        replaceAndSelect(range: lineRange, with: transformed)
    }

    private func replaceAndSelect(range: NSRange, with replacement: String) {
        guard shouldChangeText(in: range, replacementString: replacement) else { return }
        textStorage?.replaceCharacters(in: range, with: replacement)
        didChangeText()
        setSelectedRange(NSRange(location: range.location, length: (replacement as NSString).length))
    }

    @objc func uppercaseSelection(_ sender: Any?) {
        applyToSelection { $0.uppercased() }
    }

    @objc func lowercaseSelection(_ sender: Any?) {
        applyToSelection { $0.lowercased() }
    }

    private func applyToSelection(_ transform: (String) -> String) {
        let range = selectedRange()
        guard range.length > 0 else { return }
        let replacement = transform((string as NSString).substring(with: range))
        replaceAndSelect(range: range, with: replacement)
    }

    // MARK: - Current line highlight

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard highlightCurrentLine, selectedRange().length == 0,
              let layoutManager, let container = textContainer else { return }

        let text = string as NSString
        let caret = min(selectedRange().location, text.length)
        let lineRange = text.lineRange(for: NSRange(location: caret, length: 0))
        let glyphRange = layoutManager.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
        var lineRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: container)
        lineRect.origin.x = 0
        lineRect.size.width = bounds.width
        lineRect.origin.y += textContainerInset.height
        palette.currentLine.setFill()
        lineRect.fill()
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity,
                                    stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        needsDisplay = true
        sqlDelegate?.sqlTextViewDidChangeCaret(self)
    }
}

/// Line arithmetic shared by the editor, the gutter, the status bar and the tab.
///
/// Counting lines with `enumerateSubstrings(.byLines)` over `0..<caret` counts the
/// partial line the caret sits on, so the status bar said "Ln 2" on the first line and
/// bookmarks landed one line too far. Lines are counted by the breaks before an
/// offset instead, with the same terminator set `lineRange(for:)` uses.
enum TextLines {
    /// 1-based line containing the UTF-16 `offset`.
    static func line(at offset: Int, in text: NSString) -> Int {
        let end = min(max(0, offset), text.length)
        guard end > 0 else { return 1 }
        var line = 1
        var buffer = [unichar](repeating: 0, count: end)
        text.getCharacters(&buffer, range: NSRange(location: 0, length: end))
        var index = 0
        while index < end {
            switch buffer[index] {
            case 0x0A, 0x85, 0x2028, 0x2029:
                line += 1
            case 0x0D:
                // "\r\n" is one break; the "\n" half is counted when it is reached, and a
                // "\r" directly before the offset only counts when no "\n" follows it.
                if index + 1 < end, buffer[index + 1] == 0x0A { break }
                if index + 1 == end, end < text.length, text.character(at: end) == 0x0A { break }
                line += 1
            default:
                break
            }
            index += 1
        }
        return line
    }

    /// Number of lines; a trailing line break starts an empty last line, as the editor
    /// shows it. Never less than 1.
    static func count(in text: NSString) -> Int {
        line(at: text.length, in: text)
    }

    /// Character range of a 1-based line including its terminator, or nil past the end.
    static func range(ofLine line: Int, in text: NSString) -> NSRange? {
        guard line >= 1, line <= count(in: text) else { return nil }
        var current = 1
        var offset = 0
        while current < line {
            guard offset < text.length else { return nil }
            offset = NSMaxRange(text.lineRange(for: NSRange(location: offset, length: 0)))
            current += 1
        }
        return text.lineRange(for: NSRange(location: offset, length: 0))
    }
}
