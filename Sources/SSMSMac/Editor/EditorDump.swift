import AppKit
import Foundation

/// Writes the live state of the focused editor to a log file.
///
/// Invisible text has several possible causes that all look identical on screen —
/// an empty text storage, a zero-width text container, a font that failed to load,
/// a colour that matches the background. This records all of them at once so the
/// cause can be read off rather than guessed at.
enum EditorDump {
    static let requestNotification = Notification.Name("dev.ssmsmac.dumpEditorState")

    static var logURL: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/ssms-mac-editor-dump.txt")
    }

    static func request() {
        NotificationCenter.default.post(name: requestNotification, object: nil)
    }

    @MainActor
    static func capture(textView: SQLTextView, tabText: String, label: String) {
        var out = "=== editor dump \(label) ===\n"

        func line(_ key: String, _ value: Any) {
            out += String(format: "%-28s %@\n", (key as NSString).utf8String!, "\(value)")
        }

        let storage = textView.textStorage
        line("tab.text length", tabText.utf16.count)
        line("tab.text preview", String(tabText.prefix(60)).replacingOccurrences(of: "\n", with: "\\n"))
        line("textView.string length", (textView.string as NSString).length)
        line("textView.string preview",
             String(textView.string.prefix(60)).replacingOccurrences(of: "\n", with: "\\n"))
        line("textStorage length", storage?.length ?? -1)

        line("textView.frame", NSStringFromRect(textView.frame))
        line("textView.bounds", NSStringFromRect(textView.bounds))
        line("textView.isHidden", textView.isHidden)
        line("textView.alphaValue", textView.alphaValue)
        line("textContainerInset", NSStringFromSize(textView.textContainerInset))
        line("isHorizontallyResizable", textView.isHorizontallyResizable)
        line("isVerticallyResizable", textView.isVerticallyResizable)
        line("autoresizingMask", textView.autoresizingMask.rawValue)
        line("minSize", NSStringFromSize(textView.minSize))
        line("maxSize", NSStringFromSize(textView.maxSize))

        if let container = textView.textContainer {
            line("container.size", NSStringFromSize(container.size))
            line("widthTracksTextView", container.widthTracksTextView)
            line("heightTracksTextView", container.heightTracksTextView)
            line("lineFragmentPadding", container.lineFragmentPadding)
        } else {
            line("textContainer", "nil")
        }

        if let layoutManager = textView.layoutManager, let container = textView.textContainer {
            layoutManager.ensureLayout(for: container)
            line("numberOfGlyphs", layoutManager.numberOfGlyphs)
            line("usedRect", NSStringFromRect(layoutManager.usedRect(for: container)))
            line("textContainers", layoutManager.textContainers.count)
        } else {
            line("layoutManager", "nil")
        }

        // Render the text view on its own. If glyphs show up here but not on screen,
        // something is covering it; if they are missing here too, drawing is at fault.
        if let rep = textView.bitmapImageRepForCachingDisplay(in: textView.bounds) {
            textView.cacheDisplay(in: textView.bounds, to: rep)
            var distinctColours = Set<UInt32>()
            var nonBackground = 0
            let background = textView.backgroundColor.usingColorSpace(.sRGB)
            let bgKey = background.map { key($0.redComponent, $0.greenComponent, $0.blueComponent) }
            let width = min(rep.pixelsWide, 400)
            let height = min(rep.pixelsHigh, 60)
            for x in 0..<width {
                for y in 0..<height {
                    guard let colour = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                    let value = key(colour.redComponent, colour.greenComponent, colour.blueComponent)
                    distinctColours.insert(value)
                    if let bgKey, value != bgKey { nonBackground += 1 }
                }
            }
            line("offscreen size", "\(rep.pixelsWide)x\(rep.pixelsHigh)")
            line("offscreen distinct colours", distinctColours.count)
            line("offscreen non-bg pixels", "\(nonBackground) of \(width * height) sampled")
        } else {
            line("offscreen render", "unavailable")
        }

        if let ruler = textView.enclosingScrollView?.verticalRulerView {
            line("ruler.frame", NSStringFromRect(ruler.frame))
            line("ruler.ruleThickness", ruler.ruleThickness)
            line("ruler.isHidden", ruler.isHidden)
        } else {
            line("verticalRulerView", "nil")
        }

        if let clip = textView.enclosingScrollView?.contentView {
            line("clipView.frame", NSStringFromRect(clip.frame))
            line("clipView.bounds", NSStringFromRect(clip.bounds))
        }

        if let scrollView = textView.enclosingScrollView {
            out += "--- scrollView subviews ---\n"
            for sub in scrollView.subviews {
                out += "  \(type(of: sub)) \(NSStringFromRect(sub.frame)) hidden=\(sub.isHidden)\n"
            }
            line("textView in window", NSStringFromRect(
                textView.convert(textView.bounds, to: nil)))
        }

        if let scrollView = textView.enclosingScrollView {
            line("scrollView.frame", NSStringFromRect(scrollView.frame))
            line("scrollView.contentSize", NSStringFromSize(scrollView.contentSize))
            line("documentVisibleRect", NSStringFromRect(scrollView.documentVisibleRect))
            line("documentView is textView", scrollView.documentView === textView)
        } else {
            line("enclosingScrollView", "nil")
        }

        line("visibleRect", NSStringFromRect(textView.visibleRect))
        line("wantsLayer", textView.wantsLayer)
        if let layer = textView.layer {
            line("layer.bounds", NSStringFromRect(layer.bounds))
            line("layer.opacity", layer.opacity)
            line("layer.isHidden", layer.isHidden)
            line("layer.hasContents", layer.contents != nil)
            line("layer.sublayers", layer.sublayers?.count ?? 0)
            line("layer.contentsScale", layer.contentsScale)
            line("layer.masksToBounds", layer.masksToBounds)
            line("layerRedrawPolicy", textView.layerContentsRedrawPolicy.rawValue)
        } else {
            line("layer", "nil")
        }
        if let clip = textView.enclosingScrollView?.contentView {
            line("clip.wantsLayer", clip.wantsLayer)
            line("clip.layer.sublayers", clip.layer?.sublayers?.count ?? -1)
            line("clip.visibleRect", NSStringFromRect(clip.visibleRect))
        }
        if let scrollView = textView.enclosingScrollView {
            line("scroll.wantsLayer", scrollView.wantsLayer)
            line("scroll.visibleRect", NSStringFromRect(scrollView.visibleRect))
            line("scroll.superview", scrollView.superview.map { "\(type(of: $0))" } ?? "nil")
            line("scroll.superview.frame",
                 scrollView.superview.map { NSStringFromRect($0.frame) } ?? "nil")
            line("scroll.superview.clips",
                 scrollView.superview?.layer?.masksToBounds ?? false)
        }
        line("window", textView.window.map { NSStringFromRect($0.frame) } ?? "nil")
        line("window.isVisible", textView.window?.isVisible ?? false)
        line("effectiveAppearance", textView.effectiveAppearance.name.rawValue)
        line("font", textView.font.map { "\($0.fontName) \($0.pointSize)" } ?? "nil")
        line("textColor", describe(textView.textColor))
        line("backgroundColor", describe(textView.backgroundColor))
        line("drawsBackground", textView.drawsBackground)
        line("typingAttributes.color",
             describe(textView.typingAttributes[.foregroundColor] as? NSColor))
        line("typingAttributes.font",
             (textView.typingAttributes[.font] as? NSFont).map { "\($0.fontName) \($0.pointSize)" }
                ?? "nil")

        out += "--- attribute runs ---\n"
        if let storage, storage.length > 0 {
            var index = 0
            var runs = 0
            while index < storage.length && runs < 12 {
                var range = NSRange(location: 0, length: 0)
                let attributes = storage.attributes(at: index, effectiveRange: &range)
                let text = (storage.string as NSString).substring(with: range)
                    .replacingOccurrences(of: "\n", with: "\\n")
                let color = describe(attributes[.foregroundColor] as? NSColor)
                let font = (attributes[.font] as? NSFont).map { "\($0.fontName) \($0.pointSize)" }
                    ?? "no font"
                out += "  [\(range.location)..<\(NSMaxRange(range))] \(color) \(font) "
                    + "\"\(text.prefix(24))\"\n"
                index = NSMaxRange(range)
                runs += 1
            }
        } else {
            out += "  (text storage is empty)\n"
        }
        out += "\n"

        let url = logURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(out.utf8))
            try? handle.close()
        } else {
            try? out.write(to: url, atomically: true, encoding: .utf8)
        }
        FileHandle.standardError.write(Data(out.utf8))
    }

    private static func key(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> UInt32 {
        (UInt32(r * 255) << 16) | (UInt32(g * 255) << 8) | UInt32(b * 255)
    }

    private static func describe(_ color: NSColor?) -> String {
        guard let color else { return "nil" }
        guard let rgb = color.usingColorSpace(.sRGB) else { return "\(color)" }
        return String(format: "#%02X%02X%02X@%.2f",
                      Int(rgb.redComponent * 255), Int(rgb.greenComponent * 255),
                      Int(rgb.blueComponent * 255), rgb.alphaComponent)
    }
}
