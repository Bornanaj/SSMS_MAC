import AppKit
import SQLServerKit

protocol SQLTextViewDelegate: AnyObject {
    func sqlTextViewDidRequestExecute(_ textView: SQLTextView)
    func sqlTextViewDidRequestExecuteSelection(_ textView: SQLTextView)
    func sqlTextViewDidRequestCancel(_ textView: SQLTextView)
    func sqlTextView(_ textView: SQLTextView, completionsFor prefix: String, range: NSRange) -> [CompletionItem]
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

    private var lastCompletionItems: [CompletionItem] = []
    private var completionTimer: Timer?

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
            complete(nil)
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
        guard let characters = event.charactersIgnoringModifiers, let scalar = characters.unicodeScalars.first
        else { return }
        let isWordCharacter = CharacterSet.letters.contains(scalar) || scalar == "_"
        let isDot = scalar == "."
        guard isWordCharacter || isDot else { return }

        // A single character matches almost everything, so the popup would flash on
        // every keystroke without earning its place.
        if !isDot && rangeForUserCompletion.length < 2 { return }

        completionTimer?.invalidate()
        completionTimer = Timer.scheduledTimer(withTimeInterval: isDot ? 0.08 : 0.30,
                                               repeats: false) { [weak self] _ in
            guard let self, self.window?.firstResponder === self else { return }
            self.complete(nil)
        }
    }

    // MARK: - Completion

    /// AppKit binds Escape to `complete:`, so the key that should dismiss the
    /// completion list is the one that summons it — and whatever was highlighted then
    /// gets committed by the next keystroke. In a SQL editor Escape only ever cancels.
    override func cancelOperation(_ sender: Any?) {
        completionTimer?.invalidate()
        completionTimer = nil
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

    override func completions(forPartialWordRange charRange: NSRange,
                              indexOfSelectedItem index: UnsafeMutablePointer<Int>?) -> [String]? {
        let prefix = (string as NSString).substring(with: charRange)
        let items = sqlDelegate?.sqlTextView(self, completionsFor: prefix, range: charRange) ?? []
        lastCompletionItems = items
        // Deliberately leave nothing preselected. With a highlighted row, any key that
        // ends the session — including a command shortcut such as Execute — commits it,
        // so a query gains a stray keyword just as it is about to run. Arrow keys pick a
        // candidate, and only then does Return or Tab insert it.
        index?.pointee = -1
        return items.isEmpty ? nil : items.map(\.label)
    }

    override func insertCompletion(_ word: String, forPartialWordRange charRange: NSRange,
                                   movement: Int, isFinal flag: Bool) {
        // NSTextView previews the highlighted match by inserting it into the buffer as
        // selected text. That reads as the editor typing on its own, and a following
        // delimiter commits whatever happened to be highlighted, so only a deliberate
        // choice is allowed through.
        guard flag else { return }
        guard movement != NSTextMovement.cancel.rawValue else { return }
        // Insert the bracket-quoted form when the identifier needs quoting.
        let replacement = lastCompletionItems.first { $0.label == word }?.insertText ?? word
        super.insertCompletion(replacement, forPartialWordRange: charRange,
                               movement: movement, isFinal: flag)
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
