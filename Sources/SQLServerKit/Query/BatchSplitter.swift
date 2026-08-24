import Foundation

/// One GO-delimited batch of a script.
public struct SQLBatch: Sendable, Hashable, Identifiable {
    public var id: Int { index }
    public var index: Int
    public var text: String
    /// 1-based line of the first character of the batch in the original document.
    public var startLine: Int
    public var endLine: Int
    /// `GO 5` repeats the batch five times, exactly like SSMS.
    public var repeatCount: Int

    public var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Splits a script on the `GO` batch separator.
///
/// `GO` is a client-side command, not T-SQL, so this has to be done here. The
/// splitter is comment- and string-aware, so a `GO` inside a literal or comment
/// never terminates a batch.
public enum BatchSplitter {

    public static func split(_ script: String) -> [SQLBatch] {
        let lexer = TSQLLexer()
        let tokens = lexer.tokenize(script)
        let utf16 = Array(script.utf16)

        struct Separator {
            let tokenIndex: Int
            let start: Int
            let end: Int
            let repeats: Int
            let line: Int
        }

        var separators: [Separator] = []

        for (index, token) in tokens.enumerated() {
            guard token.kind == .keyword || token.kind == .identifier,
                  token.text.caseInsensitiveCompare("GO") == .orderedSame else { continue }

            // GO must be the first thing on its line…
            var previous = index - 1
            var atLineStart = true
            while previous >= 0 {
                let candidate = tokens[previous]
                if candidate.kind == .whitespace {
                    if candidate.text.contains("\n") { break }
                    previous -= 1
                    continue
                }
                if candidate.kind == .lineComment || candidate.kind == .blockComment {
                    previous -= 1
                    continue
                }
                atLineStart = false
                break
            }
            if previous < 0 { atLineStart = true }
            guard atLineStart else { continue }

            // …and may only be followed by an optional repeat count and a comment.
            var end = token.start + token.length
            var repeats = 1
            var next = index + 1
            var sawCount = false
            var valid = true
            while next < tokens.count {
                let candidate = tokens[next]
                if candidate.kind == .whitespace {
                    if candidate.text.contains("\n") { break }
                    next += 1
                    continue
                }
                if candidate.kind == .lineComment { end = candidate.start + candidate.length; break }
                if candidate.kind == .number, !sawCount, let value = Int(candidate.text) {
                    repeats = max(1, value)
                    sawCount = true
                    end = candidate.start + candidate.length
                    next += 1
                    continue
                }
                if candidate.kind == .punctuation, candidate.text == ";" {
                    end = candidate.start + candidate.length
                    next += 1
                    continue
                }
                valid = false
                break
            }
            guard valid else { continue }

            separators.append(Separator(tokenIndex: index, start: token.start,
                                        end: end, repeats: repeats, line: token.line))
        }

        var batches: [SQLBatch] = []
        var cursor = 0
        var batchIndex = 0

        func appendBatch(from start: Int, to end: Int, repeats: Int) {
            guard end >= start else { return }
            let text = String(decoding: utf16[start..<end], as: UTF16.self)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            let startLine = lineNumber(of: start, in: utf16)
            let endLine = lineNumber(of: max(start, end - 1), in: utf16)
            batches.append(SQLBatch(index: batchIndex, text: text,
                                    startLine: startLine, endLine: endLine, repeatCount: repeats))
            batchIndex += 1
        }

        for separator in separators {
            appendBatch(from: cursor, to: separator.start, repeats: separator.repeats)
            cursor = separator.end
        }
        appendBatch(from: cursor, to: utf16.count, repeats: 1)

        return batches
    }

    static func lineNumber(of offset: Int, in utf16: [UInt16]) -> Int {
        var line = 1
        var i = 0
        while i < offset && i < utf16.count {
            if utf16[i] == 10 { line += 1 }
            i += 1
        }
        return line
    }

    /// The statement that surrounds `offset`, used for "execute the current statement".
    public static func statement(at offset: Int, in script: String) -> Range<Int>? {
        let lexer = TSQLLexer()
        let tokens = lexer.tokenize(script)
        var start = 0
        var end = Array(script.utf16).count
        for token in tokens where token.kind == .punctuation && token.text == ";" {
            if token.start < offset {
                start = token.start + token.length
            } else {
                end = token.start
                break
            }
        }
        return start < end ? start..<end : nil
    }
}
