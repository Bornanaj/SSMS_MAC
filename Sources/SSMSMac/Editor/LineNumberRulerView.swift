import AppKit

/// Gutter with line numbers, a marker in the margin for lines that produced an error,
/// and the bookmark dots the Edit ▸ Bookmarks commands set.
final class LineNumberRulerView: NSRulerView {
    weak var textView: NSTextView?
    var palette: Theme.SyntaxPalette = Theme.light
    var font: NSFont = .monospacedSystemFont(ofSize: 11, weight: .regular)
    /// 1-based line numbers that the server reported errors on.
    var errorLines: Set<Int> = [] {
        didSet { if errorLines != oldValue { needsDisplay = true } }
    }
    /// 1-based line numbers the user bookmarked.
    var bookmarkedLines: Set<Int> = [] {
        didSet { if bookmarkedLines != oldValue { needsDisplay = true } }
    }

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 46
    }

    required init(coder: NSCoder) { fatalError("not supported") }

    func refresh() {
        needsDisplay = true
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return }

        palette.lineNumberBackground.setFill()
        rect.fill()

        let text = textView.string as NSString
        let visibleRect = textView.enclosingScrollView?.contentView.bounds ?? .zero
        let visibleGlyphs = layoutManager.glyphRange(forBoundingRect: visibleRect, in: container)
        let visibleChars = layoutManager.characterRange(forGlyphRange: visibleGlyphs, actualGlyphRange: nil)

        // Count the newlines before the first visible character once, then walk forward.
        var lineNumber = 1
        text.enumerateSubstrings(in: NSRange(location: 0, length: visibleChars.location),
                                 options: [.byLines, .substringNotRequired]) { _, _, _, _ in
            lineNumber += 1
        }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: palette.lineNumber
        ]
        let errorAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask),
            .foregroundColor: NSColor.systemRed
        ]

        var glyphIndex = visibleGlyphs.location
        let inset = textView.textContainerInset.height

        while glyphIndex < NSMaxRange(visibleGlyphs) {
            var effectiveRange = NSRange(location: 0, length: 0)
            let lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex,
                                                          effectiveRange: &effectiveRange,
                                                          withoutAdditionalLayout: true)
            let charRange = layoutManager.characterRange(forGlyphRange: effectiveRange, actualGlyphRange: nil)
            let paragraphRange = text.lineRange(for: NSRange(location: charRange.location, length: 0))
            let isFirstFragment = charRange.location == paragraphRange.location

            if isFirstFragment {
                let isError = errorLines.contains(lineNumber)
                let label = "\(lineNumber)" as NSString
                let size = label.size(withAttributes: isError ? errorAttributes : attributes)
                let y = lineRect.minY + inset - visibleRect.minY + (lineRect.height - size.height) / 2
                let x = ruleThickness - size.width - 8
                label.draw(at: NSPoint(x: x, y: y), withAttributes: isError ? errorAttributes : attributes)

                // The bookmark dot goes in the left margin, clear of the digits.
                if bookmarkedLines.contains(lineNumber) {
                    let diameter: CGFloat = 7
                    let dot = NSRect(x: 4,
                                     y: y + (size.height - diameter) / 2,
                                     width: diameter,
                                     height: diameter)
                    NSColor.systemBlue.setFill()
                    NSBezierPath(ovalIn: dot).fill()
                }
                lineNumber += 1
            }
            glyphIndex = NSMaxRange(effectiveRange)
        }
    }
}
