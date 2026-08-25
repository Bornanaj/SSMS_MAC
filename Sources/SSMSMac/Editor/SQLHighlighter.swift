import AppKit
import SQLServerKit

/// Applies T-SQL colouring to an NSTextStorage.
///
/// Re-tokenising the whole document on every keystroke is fine up to a few hundred
/// kilobytes, but scripts get big, so edits only re-highlight the affected line range
/// unless the edit could have opened or closed a multi-line construct.
final class SQLHighlighter {
    private let lexer = TSQLLexer()
    private var palette: Theme.SyntaxPalette
    private var font: NSFont

    init(palette: Theme.SyntaxPalette, font: NSFont) {
        self.palette = palette
        self.font = font
    }

    func update(palette: Theme.SyntaxPalette, font: NSFont) {
        self.palette = palette
        self.font = font
    }

    func highlight(_ storage: NSTextStorage, in range: NSRange? = nil) {
        let text = storage.string
        let full = NSRange(location: 0, length: (text as NSString).length)
        let target = range ?? full
        guard target.length >= 0, NSMaxRange(target) <= full.length else { return }

        storage.beginEditing()
        storage.setAttributes([
            .font: font,
            .foregroundColor: palette.plain
        ], range: target)

        let substring = (text as NSString).substring(with: target)
        for token in lexer.tokenize(substring) {
            guard token.kind != .whitespace, token.kind != .identifier else { continue }
            let tokenRange = NSRange(location: target.location + token.start, length: token.length)
            guard NSMaxRange(tokenRange) <= full.length else { continue }
            var attributes: [NSAttributedString.Key: Any] = [
                .foregroundColor: Theme.color(for: token.kind, palette: palette)
            ]
            if token.kind == .lineComment || token.kind == .blockComment {
                attributes[.font] = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            } else if token.kind == .keyword {
                attributes[.font] = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
            }
            storage.addAttributes(attributes, range: tokenRange)
        }
        storage.endEditing()
    }

    /// Widen an edited range to whole lines, and to the whole document when the edit
    /// touched a character that can start or end a block comment or string.
    func rangeToRehighlight(for editedRange: NSRange, in text: NSString) -> NSRange {
        let lineRange = text.lineRange(for: NSRange(location: min(editedRange.location, text.length),
                                                    length: 0))
        var combined = NSUnionRange(lineRange, text.lineRange(for: NSRange(
            location: min(NSMaxRange(editedRange), text.length), length: 0)))

        let edited = text.substring(with: NSRange(location: combined.location,
                                                  length: min(combined.length, text.length - combined.location)))
        if edited.contains("/*") || edited.contains("*/") || edited.contains("'") || edited.contains("[") {
            combined = NSRange(location: 0, length: text.length)
        }
        return combined
    }
}
