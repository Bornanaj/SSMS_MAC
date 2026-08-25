import AppKit
import SwiftUI
import SQLServerKit

/// Editor and grid colours. The light palette matches SSMS; the dark palette keeps
/// the same hue relationships at higher lightness so scripts stay recognisable.
enum Theme {

    /// Every entry is an explicit sRGB colour. A dynamic system colour mixed in here
    /// resolves against whatever appearance happens to be current, which is how a
    /// light palette ends up painting near-black text onto a dark background.
    struct SyntaxPalette {
        var plain: NSColor
        var keyword: NSColor
        var dataType: NSColor
        var function: NSColor
        var string: NSColor
        var comment: NSColor
        var number: NSColor
        var variable: NSColor
        var quotedIdentifier: NSColor
        var op: NSColor
        var background: NSColor
        var currentLine: NSColor
        var lineNumber: NSColor
        var lineNumberBackground: NSColor
    }

    static let light = SyntaxPalette(
        plain: NSColor(srgbRed: 0.10, green: 0.10, blue: 0.10, alpha: 1),
        keyword: NSColor(srgbRed: 0.00, green: 0.00, blue: 0.80, alpha: 1),
        dataType: NSColor(srgbRed: 0.00, green: 0.44, blue: 0.44, alpha: 1),
        function: NSColor(srgbRed: 0.68, green: 0.00, blue: 0.68, alpha: 1),
        string: NSColor(srgbRed: 0.72, green: 0.10, blue: 0.10, alpha: 1),
        comment: NSColor(srgbRed: 0.00, green: 0.50, blue: 0.13, alpha: 1),
        number: NSColor(srgbRed: 0.10, green: 0.10, blue: 0.10, alpha: 1),
        variable: NSColor(srgbRed: 0.40, green: 0.25, blue: 0.00, alpha: 1),
        quotedIdentifier: NSColor(srgbRed: 0.15, green: 0.30, blue: 0.55, alpha: 1),
        op: NSColor(srgbRed: 0.35, green: 0.35, blue: 0.35, alpha: 1),
        background: NSColor(srgbRed: 1.00, green: 1.00, blue: 1.00, alpha: 1),
        currentLine: NSColor(srgbRed: 0.96, green: 0.96, blue: 0.90, alpha: 1),
        lineNumber: NSColor(srgbRed: 0.45, green: 0.45, blue: 0.45, alpha: 1),
        lineNumberBackground: NSColor(srgbRed: 0.96, green: 0.96, blue: 0.96, alpha: 1)
    )

    static let dark = SyntaxPalette(
        plain: NSColor(srgbRed: 0.87, green: 0.87, blue: 0.88, alpha: 1),
        keyword: NSColor(srgbRed: 0.35, green: 0.62, blue: 1.00, alpha: 1),
        dataType: NSColor(srgbRed: 0.30, green: 0.80, blue: 0.78, alpha: 1),
        function: NSColor(srgbRed: 0.88, green: 0.53, blue: 0.92, alpha: 1),
        string: NSColor(srgbRed: 0.94, green: 0.55, blue: 0.48, alpha: 1),
        comment: NSColor(srgbRed: 0.42, green: 0.75, blue: 0.45, alpha: 1),
        number: NSColor(srgbRed: 0.85, green: 0.79, blue: 0.55, alpha: 1),
        variable: NSColor(srgbRed: 0.92, green: 0.74, blue: 0.42, alpha: 1),
        quotedIdentifier: NSColor(srgbRed: 0.62, green: 0.78, blue: 0.98, alpha: 1),
        op: NSColor(srgbRed: 0.70, green: 0.70, blue: 0.72, alpha: 1),
        background: NSColor(srgbRed: 0.12, green: 0.12, blue: 0.13, alpha: 1),
        currentLine: NSColor(srgbRed: 0.18, green: 0.18, blue: 0.20, alpha: 1),
        lineNumber: NSColor(srgbRed: 0.55, green: 0.55, blue: 0.58, alpha: 1),
        lineNumberBackground: NSColor(srgbRed: 0.13, green: 0.13, blue: 0.14, alpha: 1)
    )

    static func palette(for appearance: NSAppearance?) -> SyntaxPalette {
        let name = appearance?.bestMatch(from: [.aqua, .darkAqua])
        return name == .darkAqua ? dark : light
    }

    static func color(for kind: TSQLTokenKind, palette: SyntaxPalette) -> NSColor {
        switch kind {
        case .keyword: return palette.keyword
        case .dataType: return palette.dataType
        case .builtInFunction: return palette.function
        case .string: return palette.string
        case .lineComment, .blockComment: return palette.comment
        case .number: return palette.number
        case .variable, .tempTable: return palette.variable
        case .quotedIdentifier: return palette.quotedIdentifier
        case .op, .punctuation: return palette.op
        default: return palette.plain
        }
    }

    /// Parse "#RRGGBB" used for the per-connection custom colour.
    static func color(hex: String?) -> Color? {
        guard var value = hex?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let number = UInt32(value, radix: 16) else { return nil }
        return Color(
            red: Double((number >> 16) & 0xFF) / 255,
            green: Double((number >> 8) & 0xFF) / 255,
            blue: Double(number & 0xFF) / 255
        )
    }

    static let connectionColors: [(name: String, hex: String)] = [
        ("None", ""),
        ("Green", "#2E7D32"),
        ("Blue", "#1565C0"),
        ("Purple", "#6A1B9A"),
        ("Orange", "#EF6C00"),
        ("Red", "#C62828"),
        ("Teal", "#00838F")
    ]
}
