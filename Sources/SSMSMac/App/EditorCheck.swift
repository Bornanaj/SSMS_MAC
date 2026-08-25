import AppKit
import Foundation

/// Headless diagnostic for the query editor's text view.
///
/// Text that never lays out and text that lays out in an invisible colour look
/// identical from the outside, so this reports both: container geometry and glyph
/// counts on one side, resolved foreground/background colours on the other.
///
///     ssms-mac --editor-check
@MainActor
enum EditorCheck {

    static var isRequested: Bool {
        CommandLine.arguments.contains("--editor-check")
    }

    private static let sample = """
    SELECT TOP (10) c.CustomerId, c.FullName, c.Balance
    FROM dbo.Customers AS c
    WHERE c.IsActive = 1 -- only live rows
    ORDER BY c.Balance DESC;
    """

    static func run() -> Int32 {
        var failures: [String] = []

        func check(_ label: String, _ ok: Bool, _ detail: String = "") {
            print("[\(ok ? "PASS" : "FAIL")] \(label)\(detail.isEmpty ? "" : " — \(detail)")")
            if !ok { failures.append(label) }
        }

        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            let isDark = appearanceName == .darkAqua
            print("\n▸ \(isDark ? "dark" : "light") appearance")

            let host = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 500))
            host.appearance = NSAppearance(named: appearanceName)

            // SwiftUI hands NSViewRepresentable a zero-sized scroll view and lays it
            // out afterwards. Building the container at its final size hid a text
            // container that never recovered from a zero starting width, so the
            // diagnostic has to reproduce that ordering exactly.
            let scrollView = NSScrollView()
            let textView = SQLEditorView.makeTextView(wordWrap: false)
            SQLEditorView.install(textView: textView, in: scrollView, wordWrap: false)
            textView.string = sample

            host.addSubview(scrollView)
            scrollView.frame = host.bounds

            host.appearance = NSAppearance(named: appearanceName)
            scrollView.appearance = NSAppearance(named: appearanceName)
            textView.appearance = NSAppearance(named: appearanceName)
            let palette = isDark ? Theme.dark : Theme.light
            let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
            textView.font = font
            textView.palette = palette
            textView.applyPalette(palette, font: font)

            let highlighter = SQLHighlighter(palette: palette, font: font)
            if let storage = textView.textStorage { highlighter.highlight(storage) }

            // Force a layout pass the way a real window would.
            host.layoutSubtreeIfNeeded()
            scrollView.layoutSubtreeIfNeeded()
            guard let layoutManager = textView.layoutManager,
                  let container = textView.textContainer else {
                check("layout manager present", false)
                continue
            }
            layoutManager.ensureLayout(for: container)

            let containerSize = container.containerSize
            let usedRect = layoutManager.usedRect(for: container)
            let glyphCount = layoutManager.numberOfGlyphs

            // A TextKit 2 view whose legacy layoutManager has been touched lays out
            // correctly and composites nothing, so pin the engine explicitly.
            check("uses TextKit 1", textView.textLayoutManager == nil,
                  textView.textLayoutManager == nil ? "NSLayoutManager" : "NSTextLayoutManager")

            // A custom NSRulerView leaves the clip view at full width with a negative
            // bounds origin, and the document view then never composites.
            if let clip = textView.enclosingScrollView?.contentView {
                check("clip view origin is sane",
                      clip.bounds.origin.x == 0 && clip.frame.origin.x == 0,
                      "frame \(NSStringFromRect(clip.frame)) bounds \(NSStringFromRect(clip.bounds))")
            }
            check("no ruler installed",
                  textView.enclosingScrollView?.rulersVisible == false,
                  "rulersVisible = \(textView.enclosingScrollView?.rulersVisible ?? false)")

            check("container has usable width", containerSize.width > 50,
                  String(format: "%.1f", containerSize.width))
            check("glyphs generated", glyphCount >= sample.utf16.count - 5,
                  "\(glyphCount) glyphs for \(sample.utf16.count) characters")
            check("text occupies area", usedRect.width > 100 && usedRect.height > 20,
                  String(format: "%.1f x %.1f", usedRect.width, usedRect.height))

            // Colour contrast: text has to differ from what is painted behind it.
            let background = textView.backgroundColor
            var checkedRuns = 0
            var invisibleRuns: [String] = []
            textView.textStorage?.enumerateAttribute(
                .foregroundColor,
                in: NSRange(location: 0, length: (sample as NSString).length)
            ) { value, range, _ in
                guard let color = value as? NSColor else {
                    invisibleRuns.append("no colour at \(range.location)")
                    return
                }
                checkedRuns += 1
                if contrast(color, background) < 1.6 {
                    let text = (sample as NSString).substring(with: range)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    invisibleRuns.append("\"\(text.prefix(16))\" \(describe(color))")
                }
            }
            check("every run has a foreground colour", checkedRuns > 0, "\(checkedRuns) runs")
            check("no run blends into the background", invisibleRuns.isEmpty,
                  invisibleRuns.prefix(3).joined(separator: "; "))

            // Typing has to inherit a visible colour even before highlighting runs.
            let typingColor = textView.typingAttributes[.foregroundColor] as? NSColor
            check("typing attributes carry a colour", typingColor != nil,
                  typingColor.map(describe) ?? "none")
            if let typingColor {
                check("typed text would be visible",
                      contrast(typingColor, background) >= 1.6,
                      "\(describe(typingColor)) on \(describe(background))")
            }
        }

        print("")
        if failures.isEmpty {
            print("EDITOR CHECK PASSED")
            return 0
        }
        print("EDITOR CHECK FAILED: \(failures.joined(separator: ", "))")
        return 1
    }

    /// WCAG relative luminance ratio, resolved through the view's appearance so
    /// dynamic system colours report what will actually be drawn.
    private static func contrast(_ a: NSColor, _ b: NSColor) -> CGFloat {
        let lhs = luminance(a)
        let rhs = luminance(b)
        return (max(lhs, rhs) + 0.05) / (min(lhs, rhs) + 0.05)
    }

    private static func luminance(_ color: NSColor) -> CGFloat {
        guard let rgb = color.usingColorSpace(.sRGB) else { return 0.5 }
        func channel(_ value: CGFloat) -> CGFloat {
            value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(rgb.redComponent)
            + 0.7152 * channel(rgb.greenComponent)
            + 0.0722 * channel(rgb.blueComponent)
    }

    private static func describe(_ color: NSColor) -> String {
        guard let rgb = color.usingColorSpace(.sRGB) else { return "\(color)" }
        return String(format: "#%02X%02X%02X",
                      Int(rgb.redComponent * 255), Int(rgb.greenComponent * 255),
                      Int(rgb.blueComponent * 255))
    }
}
