import Foundation

/// A cursor over the significant tokens of one T-SQL statement, with the helpers the DDL
/// parser needs: keyword matching, multi-part names, balanced parentheses and raw text
/// extraction (so expressions keep their original spelling).
struct DDLTokenCursor {
    let source: String
    let tokens: [TSQLToken]
    var position: Int = 0
    /// Shared between a cursor and its sub-cursors so slicing a statement never copies it.
    private let buffer: TextBuffer

    final class TextBuffer {
        let utf16: [UInt16]
        init(_ text: String) { utf16 = Array(text.utf16) }
    }

    private var utf16: [UInt16] { buffer.utf16 }

    init(_ source: String) {
        self.source = source
        self.tokens = TSQLLexer().significantTokens(source)
        self.buffer = TextBuffer(source)
    }

    private init(source: String, tokens: [TSQLToken], buffer: TextBuffer) {
        self.source = source
        self.tokens = tokens
        self.buffer = buffer
    }

    var isAtEnd: Bool { position >= tokens.count }
    var current: TSQLToken? { position < tokens.count ? tokens[position] : nil }

    func peek(_ offset: Int = 0) -> TSQLToken? {
        let index = position + offset
        return index >= 0 && index < tokens.count ? tokens[index] : nil
    }

    /// Upper-cased text of the token at `offset`, empty past the end.
    func word(_ offset: Int = 0) -> String {
        peek(offset)?.text.uppercased() ?? ""
    }

    func isWord(_ text: String, at offset: Int = 0) -> Bool {
        word(offset) == text
    }

    /// True when the next tokens spell `words` (case-insensitive).
    func matches(_ words: [String]) -> Bool {
        for (offset, word) in words.enumerated() where self.word(offset) != word { return false }
        return true
    }

    @discardableResult
    mutating func accept(_ text: String) -> Bool {
        guard word() == text else { return false }
        position += 1
        return true
    }

    @discardableResult
    mutating func accept(_ words: [String]) -> Bool {
        guard matches(words) else { return false }
        position += words.count
        return true
    }

    mutating func advance(_ count: Int = 1) {
        position = min(tokens.count, position + count)
    }

    /// One identifier, unquoted.
    mutating func identifier() -> String? {
        guard let token = current, ModuleText.isNameToken(token) || token.kind == .tempTable else { return nil }
        position += 1
        return ModuleText.unquote(token.text)
    }

    /// `a`, `a.b`, `a.b.c` — unquoted parts.
    mutating func multipartName() -> [String] {
        var parts: [String] = []
        guard let first = identifier() else { return parts }
        parts.append(first)
        while word() == ".", let next = peek(1), ModuleText.isNameToken(next) {
            position += 1
            parts.append(ModuleText.unquote(next.text))
            position += 1
        }
        return parts
    }

    /// Schema and name, defaulting the schema to `dbo`.
    mutating func objectName(defaultSchema: String = "dbo") -> (schema: String, name: String)? {
        let parts = multipartName()
        guard let name = parts.last else { return nil }
        let schema = parts.count >= 2 ? parts[parts.count - 2] : defaultSchema
        return (schema, name)
    }

    /// Index of the token that closes the parenthesis at `position` (which must be "(").
    func matchingParenthesis(from start: Int? = nil) -> Int? {
        var depth = 0
        var index = start ?? position
        while index < tokens.count {
            let text = tokens[index].text
            if text == "(" { depth += 1 }
            if text == ")" {
                depth -= 1
                if depth == 0 { return index }
            }
            index += 1
        }
        return nil
    }

    /// Source text from the start of token `from` to the end of token `to` (inclusive).
    func text(from: Int, to: Int) -> String {
        guard from <= to, from < tokens.count, to < tokens.count else { return "" }
        let start = tokens[from].start
        let end = tokens[to].start + tokens[to].length
        return String(decoding: utf16[start..<end], as: UTF16.self)
    }

    /// Source text from token `from` to the end of the statement.
    func text(from: Int) -> String {
        guard from < tokens.count else { return "" }
        return String(decoding: utf16[tokens[from].start...], as: UTF16.self)
    }

    /// Contents of a parenthesised list, split on top-level commas, as token index ranges.
    /// The cursor must be on "("; it is left after the closing ")".
    mutating func parenthesizedList() -> [Range<Int>] {
        guard word() == "(", let close = matchingParenthesis() else { return [] }
        var items: [Range<Int>] = []
        var depth = 0
        var itemStart = position + 1
        var index = position + 1
        while index < close {
            let text = tokens[index].text
            if text == "(" { depth += 1 }
            if text == ")" { depth -= 1 }
            if text == ",", depth == 0 {
                if itemStart < index { items.append(itemStart..<index) }
                itemStart = index + 1
            }
            index += 1
        }
        if itemStart < close { items.append(itemStart..<close) }
        position = close + 1
        return items
    }

    /// A sub-cursor over a token range of this statement.
    func sub(_ range: Range<Int>) -> DDLTokenCursor {
        DDLTokenCursor(source: source, tokens: Array(tokens[range]), buffer: buffer)
    }

    /// `(a ASC, b DESC)` column lists.
    mutating func indexColumns() -> [IndexColumn] {
        parenthesizedList().compactMap { range -> IndexColumn? in
            var cursor = sub(range)
            guard let name = cursor.identifier() else { return nil }
            let descending = cursor.accept("DESC")
            return IndexColumn(name: name, isDescending: descending)
        }
    }

    /// `(a, b)` plain name lists.
    mutating func nameList() -> [String] {
        parenthesizedList().compactMap { range -> String? in
            var cursor = sub(range)
            return cursor.identifier()
        }
    }

    /// `WITH ( NAME = value, … )` into upper-cased keys and raw values.
    mutating func optionList() -> [String: String] {
        var options: [String: String] = [:]
        for range in parenthesizedList() {
            var cursor = sub(range)
            guard let key = cursor.current?.text.uppercased() else { continue }
            cursor.advance()
            if cursor.accept("=") {
                let value = cursor.isAtEnd ? "" : cursor.text(from: cursor.position, to: cursor.tokens.count - 1)
                options[key] = value
            } else {
                options[key] = "ON"
            }
        }
        return options
    }

    /// Skips to the end of a clause: stops before any of `stops` at depth 0.
    mutating func skipUntil(_ stops: Set<String>) -> Range<Int> {
        let start = position
        var depth = 0
        while let token = current {
            if depth == 0, stops.contains(token.text.uppercased()) { break }
            if token.text == "(" { depth += 1 }
            if token.text == ")" {
                if depth == 0 { break }
                depth -= 1
            }
            position += 1
        }
        return start..<position
    }
}

extension String {
    /// Text of a quoted literal: `N'it''s'` -> `it's`.
    var sqlStringValue: String {
        var text = self
        if text.hasPrefix("N'") || text.hasPrefix("n'") { text.removeFirst() }
        guard text.hasPrefix("'"), text.hasSuffix("'"), text.count >= 2 else { return self }
        return String(text.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
    }
}
