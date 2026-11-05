import Foundation

/// Finds the statement around a token without relying on semicolons.
///
/// T-SQL does not require a terminator and most scripts have none, so the statement
/// a caret sits in has to be recognised from where statements begin: a keyword such
/// as SELECT, INSERT or UPDATE at parenthesis depth zero. Anything that only looks
/// like a start — the SELECT of a subquery, of a UNION branch or of an INSERT; the
/// SET of an UPDATE; a WITH that is a table hint rather than a CTE — stays inside the
/// statement it belongs to. `;` and `GO` still end one.
public enum TSQLStatements {

    /// Tokens here are the significant ones: no whitespace, no comments.
    public static func range(of tokens: [TSQLToken], containing index: Int) -> Range<Int> {
        guard !tokens.isEmpty else { return 0..<0 }
        let starts = statementStarts(tokens)
        let clamped = min(max(index, 0), tokens.count - 1)
        let start = starts.last { $0 <= clamped } ?? 0
        let end = starts.first { $0 > clamped } ?? tokens.count
        // A `;` or GO that closes the statement is not part of it.
        var trimmedEnd = end
        while trimmedEnd > start, isTerminator(tokens[trimmedEnd - 1]) { trimmedEnd -= 1 }
        return start..<max(start, trimmedEnd)
    }

    /// Indices of every token that begins a statement.
    static func statementStarts(_ tokens: [TSQLToken]) -> [Int] {
        var starts: [Int] = [0]
        var depth = 0
        /// The keyword the current statement began with, which decides whether a
        /// later SELECT or SET continues it.
        var statementKeyword = ""
        var sawValues = false

        for (index, token) in tokens.enumerated() {
            if token.kind == .punctuation {
                switch token.text {
                case "(": depth += 1
                case ")": depth = max(0, depth - 1)
                case ";":
                    if index + 1 < tokens.count { starts.append(index + 1) }
                    statementKeyword = ""
                    sawValues = false
                    depth = 0
                default: break
                }
                continue
            }
            guard depth == 0 else { continue }
            let word = token.text.uppercased()
            if word == "VALUES" { sawValues = true }

            let isGo = word == "GO" && (token.kind == .keyword || token.kind == .identifier)
            if isGo {
                if index + 1 < tokens.count { starts.append(index + 1) }
                statementKeyword = ""
                sawValues = false
                continue
            }

            guard token.kind == .keyword || token.kind == .identifier,
                  startKeywords.contains(word) else { continue }
            let previous = index > 0 ? tokens[index - 1].text.uppercased() : ""

            // The statement a WITH's CTE list belongs to follows it.
            if statementKeyword == "WITH",
               ["SELECT", "INSERT", "UPDATE", "DELETE", "MERGE"].contains(word) {
                statementKeyword = word
                continue
            }
            switch word {
            case "SELECT":
                // A UNION branch, or the SELECT that feeds an INSERT, continues.
                if ["UNION", "ALL", "EXCEPT", "INTERSECT"].contains(previous) { continue }
                if statementKeyword == "INSERT" && !sawValues { continue }
            case "SET":
                if statementKeyword == "UPDATE" || statementKeyword == "MERGE" { continue }
            case "WITH":
                // Only `WITH name AS (` or `WITH name (cols) AS (` opens a CTE; the
                // rest are hints and options: WITH (NOLOCK), WITH ROLLUP, WITH RECOMPILE.
                guard isCommonTableExpression(tokens, at: index) else { continue }
            case "UPDATE", "INSERT", "DELETE":
                // WHEN MATCHED THEN UPDATE ... inside a MERGE.
                if previous == "THEN" { continue }
            default:
                break
            }
            if index > 0 && starts.last != index { starts.append(index) }
            statementKeyword = word
            sawValues = false
        }
        return starts
    }

    private static func isCommonTableExpression(_ tokens: [TSQLToken], at index: Int) -> Bool {
        guard index + 2 < tokens.count else { return false }
        let name = tokens[index + 1]
        guard name.kind == .identifier || name.kind == .quotedIdentifier else { return false }
        let next = tokens[index + 2]
        if next.text.caseInsensitiveCompare("AS") == .orderedSame { return true }
        return next.kind == .punctuation && next.text == "("
    }

    private static func isTerminator(_ token: TSQLToken) -> Bool {
        if token.kind == .punctuation && token.text == ";" { return true }
        return token.text.caseInsensitiveCompare("GO") == .orderedSame
            && (token.kind == .keyword || token.kind == .identifier)
    }

    /// Keywords that begin a statement when they appear at depth zero.
    private static let startKeywords: Set<String> = [
        "SELECT", "INSERT", "UPDATE", "DELETE", "MERGE", "WITH", "DECLARE", "SET",
        "EXEC", "EXECUTE", "IF", "ELSE", "WHILE", "BEGIN", "END", "RETURN", "PRINT",
        "RAISERROR", "THROW", "GOTO", "WAITFOR", "USE", "TRUNCATE", "CREATE", "ALTER",
        "DROP", "GRANT", "DENY", "REVOKE", "OPEN", "CLOSE", "FETCH", "DEALLOCATE",
        "COMMIT", "ROLLBACK", "SAVE", "BULK", "BACKUP", "RESTORE", "DBCC", "KILL",
        "CHECKPOINT", "ENABLE", "DISABLE", "TRY", "CATCH"
    ]
}
