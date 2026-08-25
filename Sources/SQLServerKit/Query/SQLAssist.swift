import Foundation

/// Editing assists modelled on SQL Prompt: expanding a wildcard into the real column
/// list, naming aliases, and completing a JOIN from the foreign key that already
/// describes the relationship.
public enum SQLAssist {

    // MARK: - Wildcard expansion

    public struct Expansion: Sendable {
        public var text: String
        /// Where the caret should land afterwards.
        public var caret: Int
        public var expandedCount: Int
    }

    /// Replace `*` and `alias.*` in the statement containing `offset` with the columns
    /// those wildcards stand for. Returns nil when there is nothing to expand or the
    /// tables in scope are not in the catalog.
    public static func expandWildcards(script: String, offset: Int,
                                       catalog: IntelliSenseCatalog) -> Expansion? {
        let lexer = TSQLLexer()
        let tokens = lexer.tokenize(script)
        let significant = tokens.filter {
            $0.kind != .whitespace && $0.kind != .lineComment && $0.kind != .blockComment
        }
        guard !significant.isEmpty else { return nil }

        let statement = statementRange(significant, containing: offset)
        let context = IntelliSenseContext.analyse(tokens: tokens, offset: offset)
        guard !context.sources.isEmpty else { return nil }

        // Only wildcards in a select list, never COUNT(*) and never a multiplication.
        var replacements: [(range: NSRange, text: String)] = []
        for index in statement {
            let token = significant[index]
            guard token.kind == .op, token.text == "*" else { continue }
            guard isSelectListWildcard(significant, at: index, in: statement) else { continue }

            var qualifier: String?
            var start = token.start
            if index >= 2, significant[index - 1].kind == .punctuation,
               significant[index - 1].text == "." {
                let candidate = significant[index - 2]
                if candidate.kind == .identifier || candidate.kind == .quotedIdentifier {
                    qualifier = IntelliSenseCatalog.unquote(candidate.text)
                    start = candidate.start
                }
            }

            let sources = qualifier.map { name in
                context.sources.filter {
                    $0.alias?.caseInsensitiveCompare(name) == .orderedSame
                        || $0.table.caseInsensitiveCompare(name) == .orderedSame
                }
            } ?? context.sources
            guard !sources.isEmpty else { continue }

            let needsQualifier = context.sources.count > 1
            var columns: [String] = []
            for source in sources {
                guard let object = catalog.object(named: source.table, schema: source.schema)
                else { continue }
                let prefix = needsQualifier
                    ? (source.alias ?? source.table).map { String($0) }.joined() + "."
                    : ""
                for column in object.columns {
                    let name = SQLIdentifier.isRegular(column.name)
                        ? column.name
                        : SQLIdentifier.quote(column.name)
                    columns.append(prefix + name)
                }
            }
            guard !columns.isEmpty else { continue }

            let end = token.start + token.length
            replacements.append((NSRange(location: start, length: end - start),
                                 columns.joined(separator: ", ")))
        }

        guard !replacements.isEmpty else { return nil }

        // Apply back to front so earlier offsets stay valid.
        let text = script as NSString
        let result = NSMutableString(string: text)
        var caret = offset
        for replacement in replacements.sorted(by: { $0.range.location > $1.range.location }) {
            result.replaceCharacters(in: replacement.range, with: replacement.text)
            if replacement.range.location < caret {
                caret += (replacement.text as NSString).length - replacement.range.length
            }
        }
        return Expansion(text: result as String, caret: caret, expandedCount: replacements.count)
    }

    private static func isSelectListWildcard(_ tokens: [TSQLToken], at index: Int,
                                             in statement: Range<Int>) -> Bool {
        // A wildcard belongs to a select list when the nearest clause keyword before it
        // is SELECT, and it is not the argument of a function call.
        if index > 0, tokens[index - 1].kind == .punctuation, tokens[index - 1].text == "(" {
            return false
        }
        var cursor = index - 1
        while cursor >= statement.lowerBound {
            let token = tokens[cursor]
            let upper = token.text.uppercased()
            if token.kind == .keyword || token.kind == .identifier {
                if upper == "SELECT" { return true }
                if ["FROM", "WHERE", "GROUP", "ORDER", "HAVING", "SET", "VALUES",
                    "INSERT", "UPDATE", "DELETE", "JOIN", "ON"].contains(upper) {
                    return false
                }
            }
            // A preceding operand means this is multiplication, not a wildcard.
            if token.kind == .number { return false }
            if token.kind == .punctuation, token.text == ")" { return false }
            cursor -= 1
        }
        return false
    }

    private static func statementRange(_ tokens: [TSQLToken], containing offset: Int) -> Range<Int> {
        var start = 0
        var end = tokens.count
        var index = 0
        for (position, token) in tokens.enumerated() {
            if token.start + token.length <= offset { index = position }
        }
        var cursor = index
        while cursor > 0 {
            let token = tokens[cursor]
            if token.kind == .punctuation && token.text == ";" { start = cursor + 1; break }
            if token.text.caseInsensitiveCompare("GO") == .orderedSame
                && (token.kind == .keyword || token.kind == .identifier) {
                start = cursor + 1
                break
            }
            cursor -= 1
        }
        cursor = index + 1
        while cursor < tokens.count {
            if tokens[cursor].kind == .punctuation && tokens[cursor].text == ";" {
                end = cursor
                break
            }
            cursor += 1
        }
        return start..<max(start, end)
    }

    // MARK: - Aliases

    /// Initials for a CamelCase or under_scored name, falling back to the leading
    /// letters, and made unique against the aliases already in the statement.
    public static func suggestedAlias(for table: String, existing: Set<String>) -> String {
        let bare = IntelliSenseCatalog.unquote(table)
        let characters = Array(bare)
        let boundaries = CompletionMatcher.wordBoundaries(characters)
        var candidate = String(boundaries.compactMap { index -> Character? in
            let character = characters[index]
            return character.isLetter ? Character(character.lowercased()) : nil
        })
        if candidate.isEmpty {
            candidate = String(bare.prefix(1)).lowercased()
        }
        if candidate.count > 4 { candidate = String(candidate.prefix(4)) }

        let taken = Set(existing.map { $0.lowercased() })
        guard taken.contains(candidate) else { return candidate }
        var suffix = 2
        while taken.contains("\(candidate)\(suffix)") { suffix += 1 }
        return "\(candidate)\(suffix)"
    }

    /// The aliases already used in the statement around `offset`.
    public static func aliasesInScope(script: String, offset: Int) -> Set<String> {
        let lexer = TSQLLexer()
        let context = IntelliSenseContext.analyse(tokens: lexer.tokenize(script), offset: offset)
        var result = Set<String>()
        for source in context.sources {
            if let alias = source.alias { result.insert(alias) }
            result.insert(source.table)
        }
        return result
    }

    // MARK: - JOIN conditions

    public struct JoinSuggestion: Sendable, Hashable, Identifiable {
        public var id: String { condition }
        public var condition: String
        public var constraintName: String
        public var detail: String
    }

    /// ON conditions implied by the foreign keys between the table being joined and the
    /// tables already in scope.
    public static func joinConditions(script: String, offset: Int,
                                      joining table: String, alias: String?,
                                      catalog: IntelliSenseCatalog) -> [JoinSuggestion] {
        let lexer = TSQLLexer()
        let context = IntelliSenseContext.analyse(tokens: lexer.tokenize(script), offset: offset)
        let target = IntelliSenseCatalog.unquote(table)
        let targetPrefix = alias ?? target

        var suggestions: [JoinSuggestion] = []
        for source in context.sources {
            let other = source.table
            guard other.caseInsensitiveCompare(target) != .orderedSame else { continue }
            let otherPrefix = source.alias ?? other

            for relationship in catalog.relationships(between: target, and: other) {
                let targetIsParent = relationship.parentTable
                    .caseInsensitiveCompare(target) == .orderedSame
                let targetColumns = targetIsParent
                    ? relationship.parentColumns : relationship.referencedColumns
                let otherColumns = targetIsParent
                    ? relationship.referencedColumns : relationship.parentColumns
                guard targetColumns.count == otherColumns.count, !targetColumns.isEmpty else {
                    continue
                }

                let clauses = zip(targetColumns, otherColumns).map { target, other in
                    "\(targetPrefix).\(target) = \(otherPrefix).\(other)"
                }
                suggestions.append(JoinSuggestion(
                    condition: clauses.joined(separator: " AND "),
                    constraintName: relationship.name,
                    detail: "\(relationship.parentTable) -> \(relationship.referencedTable)"))
            }
        }
        return suggestions
    }
}
