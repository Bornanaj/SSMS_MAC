import Foundation

/// Text handling for module definitions and constraint expressions: finding and rewriting
/// the `CREATE <kind> <name>` header, and reducing text to a form two definitions can be
/// compared in under the comparison options.
public enum ModuleText {

    // MARK: - Header

    public struct Header: Sendable, Hashable {
        /// UTF-16 range from the CREATE/ALTER keyword to the end of the object name.
        public var range: Range<Int>
        /// `PROCEDURE`, `FUNCTION`, `VIEW`, `TRIGGER`, `RULE`, `DEFAULT`.
        public var kind: String
        /// Unquoted name parts as written, e.g. `["dbo", "MyProc"]`.
        public var nameParts: [String]
        /// For triggers: the range and parts of the `ON <target>` object name.
        public var targetRange: Range<Int>?
        public var targetParts: [String]
        /// DDL triggers name `DATABASE` or `ALL SERVER` instead of an object.
        public var isDatabaseTrigger: Bool
    }

    private static let kindWords: [String: String] = [
        "PROCEDURE": "PROCEDURE", "PROC": "PROCEDURE", "FUNCTION": "FUNCTION", "VIEW": "VIEW",
        "TRIGGER": "TRIGGER", "RULE": "RULE", "DEFAULT": "DEFAULT"
    ]

    public static func header(of text: String) -> Header? {
        let tokens = TSQLLexer().tokenize(text)
        var index = 0
        func skipTrivia() {
            while index < tokens.count,
                  [.whitespace, .lineComment, .blockComment].contains(tokens[index].kind) {
                index += 1
            }
        }
        func word(_ token: TSQLToken) -> String { token.text.uppercased() }

        skipTrivia()
        guard index < tokens.count else { return nil }
        let first = word(tokens[index])
        guard first == "CREATE" || first == "ALTER" else { return nil }
        let start = tokens[index].start
        index += 1
        skipTrivia()
        if first == "CREATE", index < tokens.count, word(tokens[index]) == "OR" {
            index += 1
            skipTrivia()
            guard index < tokens.count, word(tokens[index]) == "ALTER" else { return nil }
            index += 1
            skipTrivia()
        }
        guard index < tokens.count, let kind = kindWords[word(tokens[index])] else { return nil }
        index += 1
        skipTrivia()

        let (parts, end, next) = readName(tokens, from: index)
        guard !parts.isEmpty else { return nil }
        var header = Header(range: start..<end, kind: kind, nameParts: parts,
                            targetRange: nil, targetParts: [], isDatabaseTrigger: false)
        index = next

        if kind == "TRIGGER" {
            skipTrivia()
            if index < tokens.count, word(tokens[index]) == "ON" {
                index += 1
                skipTrivia()
                if index < tokens.count {
                    let upper = word(tokens[index])
                    if upper == "DATABASE" || upper == "ALL" {
                        header.isDatabaseTrigger = true
                    } else {
                        let (targetParts, targetEnd, _) = readName(tokens, from: index)
                        if !targetParts.isEmpty {
                            header.targetParts = targetParts
                            header.targetRange = tokens[index].start..<targetEnd
                        }
                    }
                }
            }
        }
        return header
    }

    /// Reads `a`, `a.b` or `a.b.c` starting at `index`; returns unquoted parts, the UTF-16
    /// end offset and the next token index.
    static func readName(_ tokens: [TSQLToken], from start: Int) -> ([String], Int, Int) {
        var parts: [String] = []
        var index = start
        var end = start < tokens.count ? tokens[start].start : 0
        while index < tokens.count {
            let token = tokens[index]
            guard isNameToken(token) else { break }
            parts.append(unquote(token.text))
            end = token.start + token.length
            index += 1
            // Whitespace around the dot is legal but rare; tolerate it.
            var lookahead = index
            while lookahead < tokens.count, tokens[lookahead].kind == .whitespace { lookahead += 1 }
            guard lookahead < tokens.count, tokens[lookahead].text == "." else { break }
            index = lookahead + 1
            while index < tokens.count, tokens[index].kind == .whitespace { index += 1 }
        }
        return (parts, end, index)
    }

    static func isNameToken(_ token: TSQLToken) -> Bool {
        switch token.kind {
        case .identifier, .quotedIdentifier, .keyword, .dataType, .builtInFunction: return true
        default: return false
        }
    }

    /// `[a]]b]` -> `a]b`, `"x"` -> `x`, anything else unchanged.
    public static func unquote(_ text: String) -> String {
        if text.hasPrefix("["), text.hasSuffix("]"), text.count >= 2 {
            return String(text.dropFirst().dropLast()).replacingOccurrences(of: "]]", with: "]")
        }
        if text.hasPrefix("\""), text.hasSuffix("\""), text.count >= 2 {
            return String(text.dropFirst().dropLast()).replacingOccurrences(of: "\"\"", with: "\"")
        }
        return text
    }

    /// Replace the header with `<verb> <kind> <name>` and, for a DML trigger, the target
    /// after ON. `verb` is `CREATE`, `ALTER` or `CREATE OR ALTER`.
    public static func rewrite(_ text: String, verb: String, quotedName: String,
                               triggerTarget: String? = nil) -> String {
        guard let header = header(of: text) else { return text }
        var result = text
        // Replace the target first so the header range stays valid.
        if let target = triggerTarget, let range = header.targetRange {
            result = (result as NSString).replacingCharacters(
                in: NSRange(location: range.lowerBound, length: range.count), with: target)
        }
        let replacement = "\(verb) \(header.kind) \(quotedName)"
        return (result as NSString).replacingCharacters(
            in: NSRange(location: header.range.lowerBound, length: header.range.count),
            with: replacement)
    }

    // MARK: - Comparison forms

    public struct Normalization: Sendable, Hashable {
        public var ignoreWhitespace: Bool
        public var ignoreComments: Bool
        public var caseSensitive: Bool
        public var ignoreBrackets: Bool

        public init(ignoreWhitespace: Bool = true, ignoreComments: Bool = false,
                    caseSensitive: Bool = false, ignoreBrackets: Bool = true) {
            self.ignoreWhitespace = ignoreWhitespace
            self.ignoreComments = ignoreComments
            self.caseSensitive = caseSensitive
            self.ignoreBrackets = ignoreBrackets
        }
    }

    /// Text reduced to what the options say matters. The header is replaced with a
    /// canonical one first, so `CREATE PROC dbo.x` and `CREATE PROCEDURE [dbo].[x]` agree.
    public static func comparable(_ text: String, normalization: Normalization,
                                  canonicalName: String? = nil) -> String {
        var source = text.replacingOccurrences(of: "\r\n", with: "\n")
        if let canonicalName {
            source = rewrite(source, verb: "CREATE", quotedName: canonicalName)
        }
        let tokens = TSQLLexer().tokenize(source)
        var pieces: [String] = []
        pieces.reserveCapacity(tokens.count)
        for token in tokens {
            switch token.kind {
            case .whitespace:
                if !normalization.ignoreWhitespace { pieces.append(token.text) }
                continue
            case .lineComment, .blockComment:
                if normalization.ignoreComments { continue }
                pieces.append(normalization.ignoreWhitespace
                              ? collapseWhitespace(token.text) : token.text)
            case .string:
                pieces.append(token.text)
            case .quotedIdentifier:
                var value = token.text
                if normalization.ignoreBrackets {
                    let bare = unquote(token.text)
                    if SQLIdentifier.isRegular(bare) { value = bare }
                }
                pieces.append(normalization.caseSensitive ? value : value.lowercased())
            default:
                pieces.append(normalization.caseSensitive ? token.text : token.text.lowercased())
            }
        }
        if normalization.ignoreWhitespace {
            return pieces.joined(separator: " ")
        }
        return pieces.joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func collapseWhitespace(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Canonical form of a default, check, computed-column or filter expression.
    ///
    /// SQL Server stores these re-parenthesised — `DEFAULT 0` comes back as `((0))` and
    /// `Price >= 0` as `([Price]>=(0))` — so parentheses around a single token and around
    /// the whole expression are dropped, identifiers lose their brackets and everything
    /// outside string literals is lowercased.
    public static func expression(_ text: String) -> String {
        var tokens: [String] = []
        for token in TSQLLexer().significantTokens(text) {
            switch token.kind {
            case .string:
                tokens.append(token.text)
            case .quotedIdentifier:
                let bare = unquote(token.text)
                tokens.append(SQLIdentifier.isRegular(bare) ? bare.lowercased() : token.text.lowercased())
            default:
                tokens.append(token.text.lowercased())
            }
        }

        // Parentheses around exactly one token, unless they are a call's argument list.
        var changed = true
        while changed {
            changed = false
            var index = 0
            while index + 2 < tokens.count {
                if tokens[index] == "(", tokens[index + 2] == ")", tokens[index + 1] != "(",
                   tokens[index + 1] != ")" {
                    let previous = index > 0 ? tokens[index - 1] : ""
                    let isCall = !previous.isEmpty && isWordLike(previous)
                        && !expressionKeywords.contains(previous)
                    if !isCall {
                        tokens.remove(at: index + 2)
                        tokens.remove(at: index)
                        changed = true
                        continue
                    }
                }
                index += 1
            }
        }

        // Outer parentheses that wrap the whole expression.
        while tokens.count >= 2, tokens.first == "(", tokens.last == ")",
              matchingClose(tokens, openAt: 0) == tokens.count - 1 {
            tokens.removeFirst()
            tokens.removeLast()
        }
        return tokens.joined(separator: " ")
    }

    private static let expressionKeywords: Set<String> =
        ["and", "or", "not", "in", "is", "like", "between", "case", "when", "then", "else",
         "exists", "as", "select", "where", "on"]

    private static func isWordLike(_ text: String) -> Bool {
        guard let first = text.unicodeScalars.first else { return false }
        return CharacterSet.letters.contains(first) || first == "_" || first == "@"
            || first == "[" || first == "#"
    }

    private static func matchingClose(_ tokens: [String], openAt start: Int) -> Int? {
        var depth = 0
        for index in start..<tokens.count {
            if tokens[index] == "(" { depth += 1 }
            if tokens[index] == ")" {
                depth -= 1
                if depth == 0 { return index }
            }
        }
        return nil
    }

    // MARK: - Reference scanning

    /// Two-part names mentioned in a module body, for ordering deployment when the catalog's
    /// dependency list is unavailable (snapshots from scripts, encrypted neighbours).
    public static func referencedNames(in text: String, defaultSchema: String = "dbo") -> Set<String> {
        let tokens = TSQLLexer().significantTokens(text)
        var names: Set<String> = []
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            if isNameToken(token), token.kind != .keyword {
                let (parts, _, next) = readName(tokens, from: index)
                if parts.count >= 2 {
                    let schema = parts[parts.count - 2]
                    let name = parts[parts.count - 1]
                    names.insert("\(schema.lowercased()).\(name.lowercased())")
                } else if parts.count == 1 {
                    names.insert("\(defaultSchema.lowercased()).\(parts[0].lowercased())")
                }
                index = max(next, index + 1)
                continue
            }
            index += 1
        }
        return names
    }
}
