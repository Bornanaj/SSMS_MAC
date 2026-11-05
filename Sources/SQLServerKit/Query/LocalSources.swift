import Foundation

/// A table the script defines for itself rather than reads from the database: a CTE,
/// a derived table, a temp table (`CREATE TABLE #t`, `SELECT … INTO #t`) or a table
/// variable. Its columns come from its own select list or column list.
struct LocalDefinition {
    enum Kind {
        case cte, derivedTable, tempTable, tableVariable, table

        var description: String {
            switch self {
            case .cte: return "CTE"
            case .derivedTable: return "derived table"
            case .tempTable: return "temp table"
            case .tableVariable: return "table variable"
            case .table: return "table created in this script"
            }
        }
    }

    enum Column {
        case named(String)
        /// `*` or `alias.*` in the defining select list, expanded from the defining
        /// query's own sources once a catalog is at hand.
        case star(qualifier: String?)
    }

    var name: String
    var kind: Kind
    var columns: [Column]
    /// The FROM sources of the defining query, for expanding a star.
    var sources: [IntelliSenseContext.Source]

    var description: String { "\(kind.description) \(name)" }
}

/// Finds the tables a script defines for itself, so a CTE or a temp table can be
/// completed like any other table.
enum LocalSources {

    // MARK: - Finding definitions

    /// Temp tables, table variables and tables created by every statement that starts
    /// before `statement`: they outlive the statement that made them.
    static func batchDefinitions(_ tokens: [TSQLToken],
                                 before statement: Range<Int>) -> [LocalDefinition] {
        var found: [LocalDefinition] = []
        let starts = TSQLStatements.statementStarts(tokens)
        for (position, start) in starts.enumerated() where start < statement.lowerBound {
            let end = position + 1 < starts.count ? starts[position + 1] : tokens.count
            found += definitions(inStatement: start..<min(end, statement.lowerBound), of: tokens)
        }
        return found
    }

    /// The CTEs a statement opens with: `WITH a AS (…), b (x, y) AS (…)`. Each one
    /// can read the ones before it.
    static func cteDefinitions(_ tokens: [TSQLToken], in range: Range<Int>) -> [LocalDefinition] {
        guard range.lowerBound < range.upperBound,
              tokens[range.lowerBound].text.uppercased() == "WITH" else { return [] }
        var result: [LocalDefinition] = []
        var index = range.lowerBound + 1
        while index < range.upperBound {
            let name = tokens[index]
            guard name.kind == .identifier || name.kind == .quotedIdentifier else { break }
            index += 1
            var namedColumns: [LocalDefinition.Column]?
            if let list = group(openingAt: index, in: tokens, limit: range.upperBound) {
                namedColumns = identifiers(leadingItemsOf: list, in: tokens).map { .named($0) }
                index = list.upperBound
            }
            guard index < range.upperBound,
                  tokens[index].text.caseInsensitiveCompare("AS") == .orderedSame,
                  let body = group(openingAt: index + 1, in: tokens, limit: range.upperBound)
            else { break }
            let inner = inside(body)
            let sources = IntelliSenseContext.parseSources(tokens, in: inner, definitions: result)
            result.append(LocalDefinition(name: IntelliSenseCatalog.unquote(name.text),
                                          kind: .cte,
                                          columns: namedColumns ?? selectListColumns(tokens, in: inner),
                                          sources: sources))
            index = body.upperBound
            if index < range.upperBound, tokens[index].kind == .punctuation,
               tokens[index].text == "," {
                index += 1
                continue
            }
            break
        }
        return result
    }

    /// A derived table: the subquery in `body`, named by its alias, with an optional
    /// column list after the alias (`(VALUES …) AS v (Id, Label)`).
    static func derivedDefinition(named alias: String, body: Range<Int>, columnList: Range<Int>?,
                                  in tokens: [TSQLToken],
                                  definitions: [LocalDefinition]) -> LocalDefinition {
        let inner = inside(body)
        let columns = columnList.map { list in
            identifiers(leadingItemsOf: list, in: tokens).map { LocalDefinition.Column.named($0) }
        } ?? selectListColumns(tokens, in: inner)
        return LocalDefinition(name: alias, kind: .derivedTable, columns: columns,
                               sources: IntelliSenseContext.parseSources(tokens, in: inner,
                                                                         definitions: definitions))
    }

    private static func definitions(inStatement range: Range<Int>,
                                    of tokens: [TSQLToken]) -> [LocalDefinition] {
        guard !range.isEmpty else { return [] }
        var result: [LocalDefinition] = []
        let ctes = cteDefinitions(tokens, in: range)
        var index = range.lowerBound
        var depth = 0
        while index < range.upperBound {
            let token = tokens[index]
            if token.kind == .punctuation {
                if token.text == "(" { depth += 1 } else if token.text == ")" { depth = max(0, depth - 1) }
                index += 1
                continue
            }
            guard depth == 0 else { index += 1; continue }
            let word = token.text.uppercased()

            // CREATE TABLE name (…)
            if word == "CREATE", index + 1 < range.upperBound,
               tokens[index + 1].text.uppercased() == "TABLE" {
                var cursor = index + 2
                if let name = readLastNamePart(tokens, &cursor, limit: range.upperBound),
                   let list = group(openingAt: cursor, in: tokens, limit: range.upperBound) {
                    result.append(LocalDefinition(name: name.text,
                                                  kind: name.kind == .tempTable ? .tempTable : .table,
                                                  columns: ddlColumns(tokens, in: list), sources: []))
                    index = list.upperBound
                    continue
                }
            }
            // DECLARE @t TABLE (…), wherever it sits in the DECLARE.
            if token.kind == .variable, index + 1 < range.upperBound,
               tokens[index + 1].text.uppercased() == "TABLE",
               let list = group(openingAt: index + 2, in: tokens, limit: range.upperBound) {
                result.append(LocalDefinition(name: token.text, kind: .tableVariable,
                                              columns: ddlColumns(tokens, in: list), sources: []))
                index = list.upperBound
                continue
            }
            // SELECT … INTO #t FROM …
            if word == "SELECT",
               let definition = selectInto(tokens, selectAt: index, limit: range.upperBound,
                                           definitions: ctes) {
                result.append(definition)
            }
            index += 1
        }
        return result
    }

    private static func selectInto(_ tokens: [TSQLToken], selectAt selectIndex: Int, limit: Int,
                                   definitions: [LocalDefinition]) -> LocalDefinition? {
        var depth = 0
        var index = selectIndex + 1
        while index < limit {
            let token = tokens[index]
            if token.kind == .punctuation {
                if token.text == "(" { depth += 1 } else if token.text == ")" { depth = max(0, depth - 1) }
            } else if depth == 0 {
                let word = token.text.uppercased()
                if word == "FROM" || word == "WHERE" { return nil }
                if word == "INTO" {
                    var cursor = index + 1
                    guard let name = readLastNamePart(tokens, &cursor, limit: limit) else { return nil }
                    return LocalDefinition(
                        name: name.text,
                        kind: name.kind == .tempTable ? .tempTable : .table,
                        columns: selectListColumns(tokens, selectAt: selectIndex, limit: limit),
                        sources: IntelliSenseContext.parseSources(tokens, in: selectIndex..<limit,
                                                                  definitions: definitions))
                }
            }
            index += 1
        }
        return nil
    }

    // MARK: - Reading columns

    /// The columns the first SELECT inside `range` produces.
    static func selectListColumns(_ tokens: [TSQLToken], in range: Range<Int>) -> [LocalDefinition.Column] {
        var depth = 0
        for index in range {
            let token = tokens[index]
            if token.kind == .punctuation {
                if token.text == "(" { depth += 1 } else if token.text == ")" { depth = max(0, depth - 1) }
                continue
            }
            if depth == 0, token.text.caseInsensitiveCompare("SELECT") == .orderedSame {
                return selectListColumns(tokens, selectAt: index, limit: range.upperBound)
            }
        }
        return []
    }

    /// The columns a select list produces, from the SELECT at `selectIndex` to its FROM:
    /// `a`, `t.a`, `expr AS a`, `expr a` and `a = expr` all name a column `a`; `*` and
    /// `t.*` stand for whatever the sources have; an expression without a name is not
    /// a column anyone can refer to.
    static func selectListColumns(_ tokens: [TSQLToken], selectAt selectIndex: Int,
                                  limit: Int) -> [LocalDefinition.Column] {
        var index = selectIndex + 1
        // DISTINCT, ALL, TOP n, TOP (n) [PERCENT] [WITH TIES]
        while index < limit {
            let word = tokens[index].text.uppercased()
            if word == "DISTINCT" || word == "ALL" { index += 1; continue }
            if word == "TOP" {
                index += 1
                if let count = group(openingAt: index, in: tokens, limit: limit) {
                    index = count.upperBound
                } else if index < limit {
                    index += 1
                }
                if index < limit, tokens[index].text.uppercased() == "PERCENT" { index += 1 }
                if index + 1 < limit, tokens[index].text.uppercased() == "WITH",
                   tokens[index + 1].text.uppercased() == "TIES" { index += 2 }
                continue
            }
            break
        }

        var items: [[Int]] = [[]]
        var depth = 0
        while index < limit {
            let token = tokens[index]
            if token.kind == .punctuation {
                if token.text == "(" {
                    depth += 1
                } else if token.text == ")" {
                    if depth == 0 { break }
                    depth -= 1
                } else if token.text == "," && depth == 0 {
                    items.append([])
                    index += 1
                    continue
                } else if token.text == ";" {
                    break
                }
            }
            if depth == 0, token.kind == .keyword || token.kind == .identifier,
               selectListEnders.contains(token.text.uppercased()) {
                break
            }
            items[items.count - 1].append(index)
            index += 1
        }
        return items.compactMap { columnName(of: $0, in: tokens) }
    }

    private static let selectListEnders: Set<String> = [
        "FROM", "INTO", "WHERE", "GROUP", "ORDER", "HAVING", "UNION", "EXCEPT", "INTERSECT",
        "FOR", "OPTION"
    ]

    private static func columnName(of item: [Int], in tokens: [TSQLToken]) -> LocalDefinition.Column? {
        guard let last = item.last else { return nil }
        let lastToken = tokens[last]
        if lastToken.kind == .op && lastToken.text == "*" {
            if item.count == 1 { return .star(qualifier: nil) }
            if item.count == 3, tokens[item[1]].text == "." {
                return .star(qualifier: IntelliSenseCatalog.unquote(tokens[item[0]].text))
            }
            return nil
        }
        // name = expression
        if item.count >= 3, tokens[item[1]].kind == .op, tokens[item[1]].text == "=",
           isName(tokens[item[0]]) {
            return .named(IntelliSenseCatalog.unquote(tokens[item[0]].text))
        }
        if item.count == 1 {
            return isName(lastToken) ? .named(IntelliSenseCatalog.unquote(lastToken.text)) : nil
        }
        let previous = tokens[item[item.count - 2]]
        // expression AS name: after AS any word is the name, even a keyword.
        if previous.text.caseInsensitiveCompare("AS") == .orderedSame {
            return isWord(lastToken) ? .named(IntelliSenseCatalog.unquote(lastToken.text)) : nil
        }
        guard isName(lastToken) else { return nil }
        // t.name
        if previous.kind == .punctuation && previous.text == "." {
            return .named(IntelliSenseCatalog.unquote(lastToken.text))
        }
        // expression name: an alias without AS follows an operand, never an operator.
        if previous.kind == .op { return nil }
        if previous.kind == .punctuation && previous.text != ")" { return nil }
        if previous.kind == .keyword {
            let word = previous.text.uppercased()
            guard word == "END" || word == "NULL" else { return nil }
        }
        return .named(IntelliSenseCatalog.unquote(lastToken.text))
    }

    /// Column names from a CREATE TABLE or DECLARE … TABLE list: the first word of each
    /// item that is not a constraint.
    static func ddlColumns(_ tokens: [TSQLToken], in list: Range<Int>) -> [LocalDefinition.Column] {
        let skipped: Set<String> = ["CONSTRAINT", "PRIMARY", "UNIQUE", "FOREIGN", "CHECK",
                                    "INDEX", "PERIOD", "WITH"]
        return leadingTokens(ofItemsIn: list, in: tokens)
            .filter { !skipped.contains($0.text.uppercased()) && isWord($0) }
            .map { .named(IntelliSenseCatalog.unquote($0.text)) }
    }

    private static func identifiers(leadingItemsOf list: Range<Int>, in tokens: [TSQLToken]) -> [String] {
        leadingTokens(ofItemsIn: list, in: tokens)
            .filter(isWord)
            .map { IntelliSenseCatalog.unquote($0.text) }
    }

    /// The first token of each comma-separated item inside a parenthesised list.
    private static func leadingTokens(ofItemsIn list: Range<Int>, in tokens: [TSQLToken]) -> [TSQLToken] {
        var result: [TSQLToken] = []
        var depth = 0
        var atItemStart = true
        for index in inside(list) {
            let token = tokens[index]
            if token.kind == .punctuation {
                if token.text == "(" {
                    depth += 1
                } else if token.text == ")" {
                    depth -= 1
                } else if token.text == "," && depth == 0 {
                    atItemStart = true
                }
                continue
            }
            if atItemStart && depth == 0 {
                result.append(token)
                atItemStart = false
            }
        }
        return result
    }

    // MARK: - Token helpers

    /// The parenthesised group opening at `index`, parentheses included. A group the
    /// user has not closed yet runs to `limit`.
    static func group(openingAt index: Int, in tokens: [TSQLToken], limit: Int) -> Range<Int>? {
        guard index >= 0, index < limit, tokens[index].kind == .punctuation,
              tokens[index].text == "(" else { return nil }
        var depth = 0
        var cursor = index
        while cursor < limit {
            let token = tokens[cursor]
            if token.kind == .punctuation {
                if token.text == "(" {
                    depth += 1
                } else if token.text == ")" {
                    depth -= 1
                    if depth == 0 { return index..<(cursor + 1) }
                }
            }
            cursor += 1
        }
        return index..<limit
    }

    /// The tokens between a group's parentheses.
    static func inside(_ group: Range<Int>) -> Range<Int> {
        guard group.count >= 2 else { return group.upperBound..<group.upperBound }
        return (group.lowerBound + 1)..<(group.upperBound - 1)
    }

    /// Reads `a.b.c`, `#t` or `@t` and returns its last part, moving `cursor` past it.
    static func readLastNamePart(_ tokens: [TSQLToken], _ cursor: inout Int,
                                 limit: Int) -> TSQLToken? {
        var last: TSQLToken?
        while cursor < limit {
            let token = tokens[cursor]
            guard token.kind == .identifier || token.kind == .quotedIdentifier
                    || token.kind == .tempTable || token.kind == .variable else { break }
            last = token
            cursor += 1
            if cursor < limit, tokens[cursor].kind == .punctuation, tokens[cursor].text == "." {
                cursor += 1
                continue
            }
            break
        }
        return last
    }

    static func isName(_ token: TSQLToken) -> Bool {
        token.kind == .identifier || token.kind == .quotedIdentifier
    }

    private static func isWord(_ token: TSQLToken) -> Bool {
        switch token.kind {
        case .identifier, .quotedIdentifier, .keyword, .dataType, .builtInFunction: return true
        default: return false
        }
    }
}
