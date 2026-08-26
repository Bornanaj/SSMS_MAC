import AppKit

/// Line-number gutter drawn as a sibling of the scroll view rather than as an
/// `NSRulerView`.
///
/// A custom ruler makes `NSScrollView.tile()` lay the clip view out at full width with
/// a negative bounds origin instead of insetting its frame. Inside SwiftUI's
/// `AppKitPlatformViewHost` that geometry stops the document view from compositing
/// altogether: the text lays out, reports correct metrics and draws into an offscreen
/// bitmap, but nothing reaches the screen. Owning the gutter sidesteps the whole
/// mechanism and keeps the scroll view in its ordinary configuration.
final class LineNumberGutterView: NSView {
    weak var textView: SQLTextView?
    var palette: Theme.SyntaxPalette = Theme.light {
        didSet { needsDisplay = true }
    }
    var font: NSFont = .monospacedSystemFont(ofSize: 11, weight: .regular) {
        didSet { needsDisplay = true }
    }
    /// 1-based lines the server reported errors on.
    var errorLines: Set<Int> = [] {
        didSet { needsDisplay = true }
    }
    var bookmarkLines: Set<Int> = [] {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    private var lineCount: Int {
        guard let text = textView?.string as NSString? else { return 1 }
        var count = 1
        text.enumerateSubstrings(in: NSRange(location: 0, length: text.length),
                                 options: [.byLines, .substringNotRequired]) { _, _, _, _ in
            count += 1
        }
        return max(1, count - (text.hasSuffix("\n") ? 0 : 1) + (text.hasSuffix("\n") ? 0 : 0))
    }

    /// Wide enough for the highest line number plus padding, snapped so the width
    /// does not jitter on every keystroke.
    var preferredWidth: CGFloat {
        let digits = max(2, String(max(lineCount, 1)).count)
        let sample = String(repeating: "8", count: digits) as NSString
        let width = sample.size(withAttributes: [.font: font]).width
        return ceil(width) + 16
    }

    func refresh() {
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        palette.lineNumberBackground.setFill()
        dirtyRect.fill()

        guard let textView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return }

        // The gutter is outside the scroll view, so line positions have to be shifted
        // by however far the clip view has scrolled.
        let scrollOffset = textView.enclosingScrollView?.contentView.bounds.origin.y ?? 0
        let inset = textView.textContainerInset.height
        let text = textView.string as NSString

        let visibleRect = textView.visibleRect
        let visibleGlyphs = layoutManager.glyphRange(forBoundingRect: visibleRect, in: container)
        let visibleChars = layoutManager.characterRange(forGlyphRange: visibleGlyphs,
                                                        actualGlyphRange: nil)

        var lineNumber = 1
        if visibleChars.location > 0 {
            text.enumerateSubstrings(in: NSRange(location: 0, length: visibleChars.location),
                                     options: [.byLines, .substringNotRequired]) { _, _, _, _ in
                lineNumber += 1
            }
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
        let end = NSMaxRange(visibleGlyphs)

        while glyphIndex < end || (glyphIndex == 0 && text.length == 0) {
            var effectiveRange = NSRange(location: 0, length: 0)
            let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex,
                                                          effectiveRange: &effectiveRange,
                                                          withoutAdditionalLayout: true)
            let charRange = layoutManager.characterRange(forGlyphRange: effectiveRange,
                                                         actualGlyphRange: nil)
            let paragraph = text.length > 0
                ? text.lineRange(for: NSRange(location: min(charRange.location, text.length),
                                              length: 0))
                : NSRange(location: 0, length: 0)

            // Wrapped continuations share a line number with the fragment above them.
            if charRange.location == paragraph.location {
                let isError = errorLines.contains(lineNumber)
                let label = "\(lineNumber)" as NSString
                let chosen = isError ? errorAttributes : attributes
                let size = label.size(withAttributes: chosen)
                let y = fragment.minY + inset - scrollOffset + (fragment.height - size.height) / 2
                label.draw(at: NSPoint(x: bounds.width - size.width - 8, y: y),
                           withAttributes: chosen)
                if bookmarkLines.contains(lineNumber) {
                    let marker = NSRect(x: 3, y: y + size.height / 2 - 3, width: 6, height: 6)
                    NSColor.systemBlue.setFill()
                    NSBezierPath(ovalIn: marker).fill()
                }
                lineNumber += 1
            }

            if effectiveRange.length == 0 { break }
            glyphIndex = NSMaxRange(effectiveRange)
            if text.length == 0 { break }
        }

        // An empty document still deserves a "1".
        if text.length == 0 {
            let label = "1" as NSString
            let size = label.size(withAttributes: attributes)
            label.draw(at: NSPoint(x: bounds.width - size.width - 8, y: inset),
                       withAttributes: attributes)
        }
    }
}

/// Hosts the gutter and the scroll view side by side.
final class EditorContainerView: NSView {
    let gutter = LineNumberGutterView()
    let scrollView: NSScrollView

    var showsGutter: Bool = true {
        didSet { if showsGutter != oldValue { needsLayout = true } }
    }

    init(scrollView: NSScrollView) {
        self.scrollView = scrollView
        super.init(frame: .zero)
        addSubview(gutter)
        addSubview(scrollView)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func layout() {
        super.layout()
        let width = showsGutter ? gutter.preferredWidth : 0
        gutter.isHidden = !showsGutter
        gutter.frame = NSRect(x: 0, y: 0, width: width, height: bounds.height)
        scrollView.frame = NSRect(x: width, y: 0,
                                  width: max(0, bounds.width - width), height: bounds.height)
    }

    /// Re-runs layout when the number of digits changes, so the gutter grows at 100
    /// and 1000 lines instead of clipping.
    func refreshGutter() {
        if showsGutter, abs(gutter.frame.width - gutter.preferredWidth) > 0.5 {
            needsLayout = true
        }
        gutter.refresh()
    }
}
