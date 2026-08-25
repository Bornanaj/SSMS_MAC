import Foundation

/// Token-driven T-SQL pretty printer.
///
/// It reflows clauses and indentation but never rewrites the inside of a string
/// literal, comment or bracketed identifier, so formatting is always safe to run.
public struct SQLFormatter: Sendable {

    public struct Style: Sendable {
        public enum Case: String, Sendable, CaseIterable { case upper, lower, preserve }

        public var keywordCase: Case
        public var indentWidth: Int
        public var alignColumns: Bool
        public var maxLineLength: Int

        public init() {
            keywordCase = .upper
            indentWidth = 4
            alignColumns = true
            maxLineLength = 110
        }
    }

    private let style: Style
    private let lexer = TSQLLexer()

    public init(style: Style = Style()) {
        self.style = style
    }

    /// Clauses that start a new line at the current statement's indentation.
    private static let majorClauses: Set<String> = [
        "SELECT", "FROM", "WHERE", "GROUP", "HAVING", "ORDER", "UNION", "EXCEPT", "INTERSECT",
        "INSERT", "UPDATE", "DELETE", "MERGE", "VALUES", "SET", "INTO", "OUTPUT", "OPTION",
        "DECLARE", "BEGIN", "END", "IF", "ELSE", "WHILE", "RETURN", "EXEC", "EXECUTE",
        "CREATE", "ALTER", "DROP", "TRUNCATE", "WITH", "GO", "PRINT", "RAISERROR", "THROW",
        "COMMIT", "ROLLBACK", "SAVE", "USE", "GRANT", "REVOKE", "DENY"
    ]

    /// Join keywords that also begin a line, handled before `majorClauses` so that
    /// `LEFT OUTER JOIN` stays on one line.
    private static let joinStarters: Set<String> = [
        "JOIN", "INNER", "LEFT", "RIGHT", "FULL", "CROSS", "OUTER", "APPLY"
    ]

    /// Continuation keywords that get one extra level of indent.
    private static let continuations: Set<String> = ["ON", "AND", "OR", "WHEN", "THEN", "ELSE"]

    public func format(_ sql: String) -> String {
        let tokens = lexer.tokenize(sql)
        var output = ""
        var indent = 0
        var parenDepth = 0
        var atLineStart = true
        var previous: TSQLToken?
        var pendingBlankLines = 0
        var inSelectList = false

        // Emits the line break only; callers write the indentation themselves so it
        // never ends up applied twice.
        func newline() {
            guard !atLineStart else { return }
            output += "\n"
            atLineStart = true
        }

        func indentLine(extra: Int = 0) {
            output += String(repeating: " ", count: max(0, (indent + extra) * style.indentWidth))
        }

        func emit(_ text: String, spaceBefore: Bool = true) {
            if atLineStart {
                output += text
                atLineStart = false
                return
            }
            if spaceBefore, let last = output.last, last != " ", last != "(", last != "\n" {
                output += " "
            }
            output += text
        }

        var index = 0
        while index < tokens.count {
            let token = tokens[index]

            switch token.kind {
            case .whitespace:
                // Preserve at most one blank line between statements.
                let newlines = token.text.filter { $0 == "\n" }.count
                if newlines >= 2 { pendingBlankLines = 1 }
                index += 1
                continue

            case .lineComment, .blockComment:
                if pendingBlankLines > 0 { output += "\n"; pendingBlankLines = 0 }
                newline()
                indentLine()
                output += token.text
                output += "\n"
                atLineStart = true
                index += 1
                previous = token
                continue

            default:
                break
            }

            let upper = token.text.uppercased()
            let isWord = token.kind == .keyword || token.kind == .identifier
                || token.kind == .dataType || token.kind == .builtInFunction

            if pendingBlankLines > 0 {
                newline()
                output += "\n"
                indentLine()
                atLineStart = true
                pendingBlankLines = 0
            }

            if isWord, upper == "GO" {
                newline()
                output += "GO\n"
                atLineStart = true
                indent = 0
                parenDepth = 0
                inSelectList = false
                index += 1
                previous = token
                continue
            }

            if isWord, parenDepth == 0, SQLFormatter.joinStarters.contains(upper),
               !(previous.map { SQLFormatter.joinStarters.contains($0.text.uppercased()) } ?? false) {
                inSelectList = false
                newline()
                indentLine()
                emit(cased(token), spaceBefore: false)
                index += 1
                previous = token
                continue
            }

            if isWord, parenDepth == 0, SQLFormatter.majorClauses.contains(upper) {
                if upper == "END" { indent = max(0, indent - 1) }
                newline()
                indentLine()
                emit(cased(token), spaceBefore: false)
                if upper == "BEGIN" { indent += 1 }
                inSelectList = (upper == "SELECT")
                index += 1
                previous = token
                continue
            }

            if isWord, SQLFormatter.continuations.contains(upper), parenDepth == 0 {
                newline()
                indentLine(extra: 1)
                emit(cased(token), spaceBefore: false)
                index += 1
                previous = token
                continue
            }

            if token.kind == .punctuation {
                switch token.text {
                case "(":
                    parenDepth += 1
                    emit("(", spaceBefore: shouldSpaceBeforeParen(previous))
                case ")":
                    parenDepth = max(0, parenDepth - 1)
                    emit(")", spaceBefore: false)
                case ",":
                    output += ","
                    atLineStart = false
                    if parenDepth == 0 && inSelectList && style.alignColumns {
                        newline()
                        indentLine(extra: 1)
                    }
                case ";":
                    emit(";", spaceBefore: false)
                    newline()
                    inSelectList = false
                default:
                    emit(token.text, spaceBefore: false)
                }
                index += 1
                previous = token
                continue
            }

            if token.kind == .op {
                emit(token.text, spaceBefore: token.text != ".")
                index += 1
                previous = token
                continue
            }

            // A dot binds tightly on both sides: schema.table.column
            let tightLeft = previous?.kind == .punctuation && previous?.text == "."
                || previous?.kind == .op && previous?.text == "."
            emit(cased(token), spaceBefore: !tightLeft)
            index += 1
            previous = token
        }

        return output
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                String(line).hasSuffix(" ")
                    ? String(String(line).reversed().drop { $0 == " " }.reversed())
                    : String(line)
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    private func shouldSpaceBeforeParen(_ previous: TSQLToken?) -> Bool {
        guard let previous else { return false }
        switch previous.kind {
        case .builtInFunction, .identifier, .quotedIdentifier: return false
        case .punctuation: return previous.text == ","
        default: return true
        }
    }

    private func cased(_ token: TSQLToken) -> String {
        guard token.kind == .keyword || token.kind == .dataType || token.kind == .builtInFunction
        else { return token.text }
        switch style.keywordCase {
        case .upper: return token.text.uppercased()
        case .lower: return token.text.lowercased()
        case .preserve: return token.text
        }
    }
}
