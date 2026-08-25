import Foundation

/// Classification of a T-SQL token. Drives syntax colouring, the GO splitter,
/// statement detection and IntelliSense context.
public enum TSQLTokenKind: String, Sendable, Hashable {
    case keyword
    case dataType
    case builtInFunction
    case identifier
    case quotedIdentifier   // [x] or "x"
    case string
    case number
    case lineComment
    case blockComment
    case op
    case punctuation
    case variable           // @local or @@GLOBAL
    case tempTable          // #tmp or ##global
    case whitespace
    case unknown
}

public struct TSQLToken: Sendable, Hashable {
    public var kind: TSQLTokenKind
    /// UTF-16 offsets, so they map straight onto NSTextView ranges.
    public var start: Int
    public var length: Int
    public var text: String
    /// 1-based line on which the token starts.
    public var line: Int

    public var range: Range<Int> { start..<(start + length) }
}

/// A hand written T-SQL lexer. It is deliberately tolerant: unknown input is
/// emitted as `.unknown` rather than throwing, because it runs on every keystroke.
public struct TSQLLexer: Sendable {

    public init() {}

    public func tokenize(_ source: String) -> [TSQLToken] {
        let scalars = Array(source.utf16)
        var tokens: [TSQLToken] = []
        var i = 0
        var line = 1
        let n = scalars.count

        func peek(_ offset: Int = 0) -> UInt16? {
            let index = i + offset
            return index < n ? scalars[index] : nil
        }

        func substring(_ start: Int, _ end: Int) -> String {
            String(decoding: scalars[start..<end], as: UTF16.self)
        }

        func isLetter(_ c: UInt16) -> Bool {
            (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c > 127
        }
        func isDigit(_ c: UInt16) -> Bool { c >= 48 && c <= 57 }
        func isIdentStart(_ c: UInt16) -> Bool { isLetter(c) || c == 95 }
        func isIdentPart(_ c: UInt16) -> Bool { isLetter(c) || isDigit(c) || c == 95 || c == 36 || c == 35 }

        while i < n {
            let start = i
            let startLine = line
            let c = scalars[i]

            // whitespace
            if c == 32 || c == 9 || c == 10 || c == 13 {
                while i < n {
                    let ch = scalars[i]
                    if ch == 10 { line += 1 }
                    if ch == 32 || ch == 9 || ch == 10 || ch == 13 { i += 1 } else { break }
                }
                tokens.append(TSQLToken(kind: .whitespace, start: start, length: i - start,
                                        text: substring(start, i), line: startLine))
                continue
            }

            // line comment
            if c == 45, peek(1) == 45 { // --
                while i < n && scalars[i] != 10 { i += 1 }
                tokens.append(TSQLToken(kind: .lineComment, start: start, length: i - start,
                                        text: substring(start, i), line: startLine))
                continue
            }

            // block comment (T-SQL allows nesting)
            if c == 47, peek(1) == 42 { // /*
                var depth = 0
                while i < n {
                    if scalars[i] == 47, i + 1 < n, scalars[i + 1] == 42 {
                        depth += 1; i += 2; continue
                    }
                    if scalars[i] == 42, i + 1 < n, scalars[i + 1] == 47 {
                        depth -= 1; i += 2
                        if depth == 0 { break }
                        continue
                    }
                    if scalars[i] == 10 { line += 1 }
                    i += 1
                }
                tokens.append(TSQLToken(kind: .blockComment, start: start, length: i - start,
                                        text: substring(start, i), line: startLine))
                continue
            }

            // string literal, optionally N prefixed
            if c == 39 || ((c == 78 || c == 110) && peek(1) == 39) {
                if c != 39 { i += 1 }
                i += 1 // opening quote
                while i < n {
                    if scalars[i] == 39 {
                        if i + 1 < n && scalars[i + 1] == 39 { i += 2; continue }
                        i += 1
                        break
                    }
                    if scalars[i] == 10 { line += 1 }
                    i += 1
                }
                tokens.append(TSQLToken(kind: .string, start: start, length: i - start,
                                        text: substring(start, i), line: startLine))
                continue
            }

            // bracketed identifier
            if c == 91 { // [
                i += 1
                while i < n {
                    if scalars[i] == 93 {
                        if i + 1 < n && scalars[i + 1] == 93 { i += 2; continue }
                        i += 1
                        break
                    }
                    if scalars[i] == 10 { line += 1 }
                    i += 1
                }
                tokens.append(TSQLToken(kind: .quotedIdentifier, start: start, length: i - start,
                                        text: substring(start, i), line: startLine))
                continue
            }

            // double quoted identifier
            if c == 34 {
                i += 1
                while i < n {
                    if scalars[i] == 34 {
                        if i + 1 < n && scalars[i + 1] == 34 { i += 2; continue }
                        i += 1
                        break
                    }
                    if scalars[i] == 10 { line += 1 }
                    i += 1
                }
                tokens.append(TSQLToken(kind: .quotedIdentifier, start: start, length: i - start,
                                        text: substring(start, i), line: startLine))
                continue
            }

            // variables
            if c == 64 { // @
                i += 1
                if i < n && scalars[i] == 64 { i += 1 }
                while i < n && isIdentPart(scalars[i]) { i += 1 }
                tokens.append(TSQLToken(kind: .variable, start: start, length: i - start,
                                        text: substring(start, i), line: startLine))
                continue
            }

            // temp tables
            if c == 35 { // #
                i += 1
                if i < n && scalars[i] == 35 { i += 1 }
                while i < n && isIdentPart(scalars[i]) { i += 1 }
                tokens.append(TSQLToken(kind: .tempTable, start: start, length: i - start,
                                        text: substring(start, i), line: startLine))
                continue
            }

            // numbers, including 0x hex and exponent forms
            if isDigit(c) || (c == 46 && (peek(1).map(isDigit) ?? false)) {
                if c == 48, let next = peek(1), next == 120 || next == 88 { // 0x
                    i += 2
                    while i < n, isDigit(scalars[i]) ||
                        (scalars[i] | 0x20) >= 97 && (scalars[i] | 0x20) <= 102 { i += 1 }
                } else {
                    while i < n && isDigit(scalars[i]) { i += 1 }
                    if i < n && scalars[i] == 46 {
                        i += 1
                        while i < n && isDigit(scalars[i]) { i += 1 }
                    }
                    if i < n, scalars[i] == 101 || scalars[i] == 69 { // e/E
                        var j = i + 1
                        if j < n, scalars[j] == 43 || scalars[j] == 45 { j += 1 }
                        if j < n, isDigit(scalars[j]) {
                            i = j
                            while i < n && isDigit(scalars[i]) { i += 1 }
                        }
                    }
                }
                tokens.append(TSQLToken(kind: .number, start: start, length: i - start,
                                        text: substring(start, i), line: startLine))
                continue
            }

            // identifiers and keywords
            if isIdentStart(c) {
                while i < n && isIdentPart(scalars[i]) { i += 1 }
                let text = substring(start, i)
                let upper = text.uppercased()
                let kind: TSQLTokenKind
                if TSQLKeywords.reserved.contains(upper) {
                    kind = .keyword
                } else if TSQLKeywords.dataTypes.contains(upper) {
                    kind = .dataType
                } else if TSQLKeywords.functions.contains(upper) {
                    kind = .builtInFunction
                } else {
                    kind = .identifier
                }
                tokens.append(TSQLToken(kind: kind, start: start, length: i - start,
                                        text: text, line: startLine))
                continue
            }

            // operators and punctuation
            let twoCharOperators: Set<String> = ["<=", ">=", "<>", "!=", "!<", "!>", "+=", "-=",
                                                 "*=", "/=", "%=", "&=", "|=", "^=", "::"]
            if i + 1 < n {
                let pair = substring(i, i + 2)
                if twoCharOperators.contains(pair) {
                    i += 2
                    tokens.append(TSQLToken(kind: .op, start: start, length: 2, text: pair, line: startLine))
                    continue
                }
            }
            let single = substring(i, i + 1)
            i += 1
            let punctuation: Set<String> = ["(", ")", ",", ";", "."]
            tokens.append(TSQLToken(kind: punctuation.contains(single) ? .punctuation : .op,
                                    start: start, length: 1, text: single, line: startLine))
        }

        return tokens
    }

    /// Tokens with whitespace and comments removed – handy for parsing.
    public func significantTokens(_ source: String) -> [TSQLToken] {
        tokenize(source).filter {
            $0.kind != .whitespace && $0.kind != .lineComment && $0.kind != .blockComment
        }
    }
}
