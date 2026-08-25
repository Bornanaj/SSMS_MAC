import Foundation

/// Scores a candidate against what the user has typed, the way SQL Prompt does:
/// a prefix beats an acronym, an acronym beats a substring, and a substring beats a
/// scattered subsequence. The matched character positions come back with the score so
/// the popup can embolden them.
public enum CompletionMatcher {

    public struct Match: Sendable, Hashable {
        /// Lower sorts first.
        public var rank: Int
        /// Indices into the candidate, for highlighting.
        public var positions: [Int]

        public init(rank: Int, positions: [Int]) {
            self.rank = rank
            self.positions = positions
        }
    }

    /// Rank bands, spaced so a per-match penalty can never cross into the next band.
    private enum Band {
        static let exact = 0
        static let prefix = 1_000
        static let acronym = 3_000
        static let wordPrefix = 5_000
        static let substring = 7_000
        static let subsequence = 10_000
    }

    public static func match(candidate: String, query: String) -> Match? {
        guard !query.isEmpty else { return Match(rank: Band.prefix, positions: []) }

        let candidateChars = Array(candidate)
        let lowerCandidate = Array(candidate.lowercased())
        let lowerQuery = Array(query.lowercased())
        guard lowerQuery.count <= lowerCandidate.count else { return nil }

        if lowerCandidate == lowerQuery {
            return Match(rank: Band.exact, positions: Array(0..<candidateChars.count))
        }

        if lowerCandidate.starts(with: lowerQuery) {
            // Shorter candidates are the better prefix match: "id" should beat "identity".
            return Match(rank: Band.prefix + candidateChars.count,
                         positions: Array(0..<lowerQuery.count))
        }

        // Acronym: "os" matches OrderSummary, "sd" matches sys_databases.
        let boundaries = wordBoundaries(candidateChars)
        if let positions = matchAcronym(lowerCandidate, lowerQuery, boundaries: boundaries) {
            return Match(rank: Band.acronym + candidateChars.count, positions: positions)
        }

        // A query that starts one of the later words, e.g. "sum" in OrderSummary.
        for boundary in boundaries.dropFirst() where boundary + lowerQuery.count <= lowerCandidate.count {
            if Array(lowerCandidate[boundary..<(boundary + lowerQuery.count)]) == lowerQuery {
                return Match(rank: Band.wordPrefix + boundary,
                             positions: Array(boundary..<(boundary + lowerQuery.count)))
            }
        }

        if let start = indexOfSubsequenceRun(lowerCandidate, lowerQuery) {
            return Match(rank: Band.substring + start,
                         positions: Array(start..<(start + lowerQuery.count)))
        }

        if let positions = matchSubsequence(lowerCandidate, lowerQuery) {
            // Tighter matches win: prefer the run that spans the fewest characters.
            let span = (positions.last ?? 0) - (positions.first ?? 0)
            return Match(rank: Band.subsequence + span, positions: positions)
        }

        return nil
    }

    /// Indices where a new word starts: the first character, any upper-case letter that
    /// follows a lower-case one, and anything after `_`, `.` or a digit boundary.
    public static func wordBoundaries(_ characters: [Character]) -> [Int] {
        var result: [Int] = []
        for (index, character) in characters.enumerated() {
            if index == 0 {
                result.append(index)
                continue
            }
            let previous = characters[index - 1]
            if previous == "_" || previous == "." || previous == " " {
                result.append(index)
            } else if character.isUppercase && !previous.isUppercase {
                result.append(index)
            } else if character.isNumber && !previous.isNumber {
                result.append(index)
            }
        }
        return result
    }

    private static func matchAcronym(_ candidate: [Character], _ query: [Character],
                                     boundaries: [Int]) -> [Int]? {
        guard query.count > 1, boundaries.count >= query.count else { return nil }
        var positions: [Int] = []
        var boundaryIndex = 0
        for queryChar in query {
            var found = false
            while boundaryIndex < boundaries.count {
                let position = boundaries[boundaryIndex]
                boundaryIndex += 1
                if candidate[position] == queryChar {
                    positions.append(position)
                    found = true
                    break
                }
            }
            guard found else { return nil }
        }
        return positions
    }

    private static func indexOfSubsequenceRun(_ candidate: [Character],
                                              _ query: [Character]) -> Int? {
        guard query.count <= candidate.count else { return nil }
        let limit = candidate.count - query.count
        var start = 0
        while start <= limit {
            if Array(candidate[start..<(start + query.count)]) == query { return start }
            start += 1
        }
        return nil
    }

    private static func matchSubsequence(_ candidate: [Character],
                                         _ query: [Character]) -> [Int]? {
        var positions: [Int] = []
        var candidateIndex = 0
        for queryChar in query {
            var found = false
            while candidateIndex < candidate.count {
                if candidate[candidateIndex] == queryChar {
                    positions.append(candidateIndex)
                    candidateIndex += 1
                    found = true
                    break
                }
                candidateIndex += 1
            }
            guard found else { return nil }
        }
        return positions
    }

    /// Filter and order a candidate list in one pass. `key` picks the text to match on.
    public static func filter<T>(_ items: [T], query: String,
                                 key: (T) -> String,
                                 basePriority: (T) -> Int) -> [(item: T, match: Match)] {
        var scored: [(item: T, match: Match)] = []
        scored.reserveCapacity(items.count)
        for item in items {
            guard let match = match(candidate: key(item), query: query) else { continue }
            // The provider's own ranking breaks ties: columns in scope before tables,
            // tables before keywords.
            let combined = Match(rank: match.rank + basePriority(item), positions: match.positions)
            scored.append((item, combined))
        }
        scored.sort { lhs, rhs in
            if lhs.match.rank != rhs.match.rank { return lhs.match.rank < rhs.match.rank }
            return key(lhs.item).count < key(rhs.item).count
        }
        return scored
    }
}
