import AppKit
import SQLServerKit

extension NSAttributedString.Key {
    /// The lexer kind a coloured run came from, recorded only for the kinds that can
    /// span lines. It is the state the next edit reads to decide how far back and
    /// forward the document has to be lexed again.
    static let sqlTokenKind = NSAttributedString.Key("dev.ssmsmac.tokenKind")
}

/// Applies T-SQL colouring to an NSTextStorage.
///
/// Re-tokenising the whole document on every keystroke is fine up to a few hundred
/// kilobytes, but scripts get big, so an edit only re-colours the lines it touched,
/// widened to the comment or string those lines sit in. The old colouring doubles as
/// the record of where such a token used to end, which is how an edit that opens or
/// closes one re-colours exactly the text whose meaning changed.
final class SQLHighlighter {
    private let lexer = TSQLLexer()
    private var palette: Theme.SyntaxPalette
    private var font: NSFont
    // Derived once per font: NSFontManager.convert per token stalled large scripts.
    private var boldFont: NSFont
    private var italicFont: NSFont

    /// Kinds whose tokens may contain line breaks.
    private static let multilineKinds: Set<String> = [
        TSQLTokenKind.blockComment.rawValue,
        TSQLTokenKind.string.rawValue,
        TSQLTokenKind.quotedIdentifier.rawValue
    ]

    init(palette: Theme.SyntaxPalette, font: NSFont) {
        self.palette = palette
        self.font = font
        (boldFont, italicFont) = SQLHighlighter.variants(of: font)
    }

    func update(palette: Theme.SyntaxPalette, font: NSFont) {
        self.palette = palette
        if font != self.font {
            self.font = font
            (boldFont, italicFont) = SQLHighlighter.variants(of: font)
        }
    }

    private static func variants(of font: NSFont) -> (bold: NSFont, italic: NSFont) {
        let manager = NSFontManager.shared
        return (manager.convert(font, toHaveTrait: .boldFontMask),
                manager.convert(font, toHaveTrait: .italicFontMask))
    }

    /// Colours `range` (the whole document when nil) from a lex of that text alone.
    func highlight(_ storage: NSTextStorage, in range: NSRange? = nil) {
        let text = storage.string as NSString
        let full = NSRange(location: 0, length: text.length)
        let target = range ?? full
        guard target.location >= 0, target.length >= 0, NSMaxRange(target) <= full.length else { return }
        let tokens = lexer.tokenize(text.substring(with: target))
        apply(tokens, in: target, to: storage)
    }

    /// Re-colours the document after the characters in `editedRange` (a range in the
    /// new text) were replaced.
    ///
    /// The edited lines are lexed in one piece. When they sit inside a comment or
    /// string that opened on an earlier line, lexing starts where that token began.
    /// When the lex ends inside a token that keeps going, or closes a token the old
    /// colouring had running on past the edited lines, the range grows to where that
    /// token ends and the lex runs again, so the text whose meaning changed is
    /// re-coloured and nothing else is.
    func rehighlight(_ storage: NSTextStorage, editedRange: NSRange) {
        let text = storage.string as NSString
        let length = text.length
        guard editedRange.location >= 0, NSMaxRange(editedRange) <= length else {
            highlight(storage)
            return
        }

        func lineEnd(_ offset: Int) -> Int {
            NSMaxRange(text.lineRange(for: NSRange(location: min(offset, length), length: 0)))
        }

        var start = text.lineRange(for: NSRange(location: editedRange.location, length: 0)).location
        var end = lineEnd(NSMaxRange(editedRange))

        // The character before the first edited line is a line break, which only a
        // multi-line token can own: the edit is inside that token.
        if start > 0, let run = multilineRun(in: storage, at: start - 1) {
            start = min(start, run.location)
        }

        var tokens: [TSQLToken] = []
        var passes = 0
        while true {
            tokens = lexer.tokenize(text.substring(with: NSRange(location: start, length: end - start)))
            guard end < length, passes < 32 else { break }
            passes += 1

            // What the text right after the lexed range was coloured as before the edit.
            let staleRun = multilineRun(in: storage, at: end)

            if let last = tokens.last, SQLHighlighter.isUnterminated(last) {
                // The token keeps going past `end`. Where the old colouring ended is
                // the best guess for where it still ends; otherwise it runs on to the
                // end of the document.
                if let staleRun, NSMaxRange(staleRun) > end {
                    end = lineEnd(NSMaxRange(staleRun))
                    continue
                }
                // An unclosed bracket stays on its line: real bracketed names never
                // span lines, and `[` is typed far too often to re-lex everything
                // below the caret each time.
                if last.kind != .quotedIdentifier {
                    end = length
                    continue
                }
            }

            if let staleRun, staleRun.location < end {
                // The lexed range closed a token the old colouring had running on past
                // `end`; its tail is stale.
                end = lineEnd(NSMaxRange(staleRun))
                continue
            }
            break
        }

        apply(tokens, in: NSRange(location: start, length: end - start), to: storage)
    }

    private func apply(_ tokens: [TSQLToken], in target: NSRange, to storage: NSTextStorage) {
        let length = storage.length
        storage.beginEditing()
        storage.setAttributes([
            .font: font,
            .foregroundColor: palette.plain
        ], range: target)

        for token in tokens {
            guard token.kind != .whitespace, token.kind != .identifier else { continue }
            let tokenRange = NSRange(location: target.location + token.start, length: token.length)
            guard NSMaxRange(tokenRange) <= length else { continue }
            var attributes: [NSAttributedString.Key: Any] = [
                .foregroundColor: Theme.color(for: token.kind, palette: palette)
            ]
            switch token.kind {
            case .lineComment, .blockComment:
                attributes[.font] = italicFont
            case .keyword:
                attributes[.font] = boldFont
            default:
                break
            }
            if SQLHighlighter.multilineKinds.contains(token.kind.rawValue) {
                attributes[.sqlTokenKind] = token.kind.rawValue
            }
            storage.addAttributes(attributes, range: tokenRange)
        }
        storage.endEditing()
    }

    /// The run of a comment, string or bracketed name that covers `index` in the
    /// current colouring, or nil when the character there is anything else.
    private func multilineRun(in storage: NSTextStorage, at index: Int) -> NSRange? {
        guard index >= 0, index < storage.length else { return nil }
        var range = NSRange(location: 0, length: 0)
        guard let kind = storage.attribute(.sqlTokenKind, at: index, longestEffectiveRange: &range,
                                           in: NSRange(location: 0, length: storage.length)) as? String,
              SQLHighlighter.multilineKinds.contains(kind) else { return nil }
        return range
    }

    /// True for a comment, string or bracketed name that ran out of input before its
    /// closing delimiter. Mirrors the lexer's own scanning so nesting and doubled
    /// quotes are judged the same way.
    static func isUnterminated(_ token: TSQLToken) -> Bool {
        let scalars = Array(token.text.utf16)
        let n = scalars.count
        switch token.kind {
        case .blockComment:
            var depth = 0
            var i = 0
            while i < n {
                if scalars[i] == 47, i + 1 < n, scalars[i + 1] == 42 { depth += 1; i += 2; continue }   // /*
                if scalars[i] == 42, i + 1 < n, scalars[i + 1] == 47 {                                   // */
                    depth -= 1
                    i += 2
                    if depth == 0 { return false }
                    continue
                }
                i += 1
            }
            return true
        case .string:
            // Optional N prefix, then the opening quote; a doubled quote is an escape.
            var i = (scalars.first == 39) ? 1 : 2
            while i < n {
                if scalars[i] == 39 {
                    if i + 1 < n, scalars[i + 1] == 39 { i += 2; continue }
                    return false
                }
                i += 1
            }
            return true
        case .quotedIdentifier:
            guard let opener = scalars.first else { return false }
            let closer: UInt16 = opener == 91 ? 93 : 34   // [ ] or " "
            var i = 1
            while i < n {
                if scalars[i] == closer {
                    if i + 1 < n, scalars[i + 1] == closer { i += 2; continue }
                    return false
                }
                i += 1
            }
            return true
        default:
            return false
        }
    }
}
