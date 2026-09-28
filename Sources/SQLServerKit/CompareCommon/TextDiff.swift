import Foundation

/// Line and word level differences for the side-by-side SQL view.
public enum TextDiff {

    public enum Operation: Sendable, Hashable {
        case equal(Int, Int)
        case delete(Int)
        case insert(Int)
    }

    /// Myers' O((N+M)·D) shortest edit script between two sequences.
    public static func operations<T>(_ a: [T], _ b: [T], equal: (T, T) -> Bool) -> [Operation] {
        // Common prefix and suffix are cheap and cover most real edits.
        var prefix = 0
        while prefix < a.count, prefix < b.count, equal(a[prefix], b[prefix]) { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix,
              equal(a[a.count - 1 - suffix], b[b.count - 1 - suffix]) { suffix += 1 }

        let aMiddle = Array(a[prefix..<(a.count - suffix)])
        let bMiddle = Array(b[prefix..<(b.count - suffix)])
        var result: [Operation] = (0..<prefix).map { .equal($0, $0) }
        for operation in myers(aMiddle, bMiddle, equal: equal) {
            switch operation {
            case .equal(let i, let j): result.append(.equal(i + prefix, j + prefix))
            case .delete(let i): result.append(.delete(i + prefix))
            case .insert(let j): result.append(.insert(j + prefix))
            }
        }
        for offset in 0..<suffix {
            result.append(.equal(a.count - suffix + offset, b.count - suffix + offset))
        }
        return result
    }

    private static func myers<T>(_ a: [T], _ b: [T], equal: (T, T) -> Bool) -> [Operation] {
        let n = a.count
        let m = b.count
        if n == 0 { return (0..<m).map { .insert($0) } }
        if m == 0 { return (0..<n).map { .delete($0) } }
        let maxD = n + m
        // Very different inputs make the trace quadratic; above this, fall back to
        // delete-all/insert-all, which is still a correct (if unhelpful) diff.
        if maxD > 40_000 { return (0..<n).map { .delete($0) } + (0..<m).map { .insert($0) } }
        let offset = maxD
        var v = [Int](repeating: 0, count: 2 * maxD + 2)
        var trace: [[Int]] = []
        var found = false
        outer: for d in 0...maxD {
            trace.append(v)
            var k = -d
            while k <= d {
                let index = k + offset
                var x: Int
                if k == -d || (k != d && v[index - 1] < v[index + 1]) {
                    x = v[index + 1]
                } else {
                    x = v[index - 1] + 1
                }
                var y = x - k
                while x < n, y < m, equal(a[x], b[y]) {
                    x += 1
                    y += 1
                }
                v[index] = x
                if x >= n && y >= m {
                    found = true
                    trace.append(v)
                    break outer
                }
                k += 2
            }
        }
        guard found else { return (0..<n).map { .delete($0) } + (0..<m).map { .insert($0) } }

        // Walk the trace backwards.
        var operations: [Operation] = []
        var x = n
        var y = m
        for d in stride(from: trace.count - 2, through: 0, by: -1) {
            let vd = trace[d]
            let k = x - y
            let previousK: Int
            if k == -d || (k != d && vd[k - 1 + offset] < vd[k + 1 + offset]) {
                previousK = k + 1
            } else {
                previousK = k - 1
            }
            let previousX = vd[previousK + offset]
            let previousY = previousX - previousK
            while x > previousX && y > previousY {
                operations.append(.equal(x - 1, y - 1))
                x -= 1
                y -= 1
            }
            if d > 0 {
                if x == previousX {
                    operations.append(.insert(y - 1))
                } else {
                    operations.append(.delete(x - 1))
                }
            }
            x = previousX
            y = previousY
        }
        while x > 0 && y > 0 {
            operations.append(.equal(x - 1, y - 1))
            x -= 1
            y -= 1
        }
        return operations.reversed()
    }

    // MARK: - Side by side

    public enum RowKind: String, Sendable, Hashable {
        case same
        case changed
        case added
        case removed
        /// Same after normalisation (whitespace or case) but not byte for byte.
        case similar
    }

    /// One aligned row: left is the source, right is the target.
    public struct Row: Sendable, Hashable, Identifiable {
        public var id: Int
        public var kind: RowKind
        public var leftNumber: Int?
        public var left: String?
        public var rightNumber: Int?
        public var right: String?
        /// UTF-16 ranges inside `left` / `right` that differ.
        public var leftHighlights: [Range<Int>]
        public var rightHighlights: [Range<Int>]
    }

    public struct Options: Sendable, Hashable {
        public var ignoreWhitespace: Bool
        public var ignoreCase: Bool
        public var inlineHighlights: Bool

        public init(ignoreWhitespace: Bool = false, ignoreCase: Bool = false, inlineHighlights: Bool = true) {
            self.ignoreWhitespace = ignoreWhitespace
            self.ignoreCase = ignoreCase
            self.inlineHighlights = inlineHighlights
        }
    }

    public static func sideBySide(left: String, right: String, options: Options = Options()) -> [Row] {
        let leftLines = splitLines(left)
        let rightLines = splitLines(right)
        let normalize: (String) -> String = { line in
            var value = line
            if options.ignoreWhitespace {
                value = value.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
            }
            if options.ignoreCase { value = value.lowercased() }
            return value
        }
        let leftKeys = leftLines.map(normalize)
        let rightKeys = rightLines.map(normalize)
        let ops = operations(leftKeys, rightKeys, equal: ==)

        var rows: [Row] = []
        var pendingDeletes: [Int] = []
        var pendingInserts: [Int] = []

        func flush() {
            let paired = min(pendingDeletes.count, pendingInserts.count)
            for index in 0..<paired {
                let l = pendingDeletes[index]
                let r = pendingInserts[index]
                var row = Row(id: rows.count, kind: .changed, leftNumber: l + 1, left: leftLines[l],
                              rightNumber: r + 1, right: rightLines[r], leftHighlights: [], rightHighlights: [])
                if options.inlineHighlights {
                    let spans = inlineChanges(leftLines[l], rightLines[r], ignoreCase: options.ignoreCase)
                    row.leftHighlights = spans.left
                    row.rightHighlights = spans.right
                }
                rows.append(row)
            }
            for l in pendingDeletes.dropFirst(paired) {
                rows.append(Row(id: rows.count, kind: .removed, leftNumber: l + 1, left: leftLines[l],
                                rightNumber: nil, right: nil, leftHighlights: [], rightHighlights: []))
            }
            for r in pendingInserts.dropFirst(paired) {
                rows.append(Row(id: rows.count, kind: .added, leftNumber: nil, left: nil,
                                rightNumber: r + 1, right: rightLines[r], leftHighlights: [], rightHighlights: []))
            }
            pendingDeletes.removeAll()
            pendingInserts.removeAll()
        }

        for operation in ops {
            switch operation {
            case .equal(let l, let r):
                flush()
                let kind: RowKind = leftLines[l] == rightLines[r] ? .same : .similar
                rows.append(Row(id: rows.count, kind: kind, leftNumber: l + 1, left: leftLines[l],
                                rightNumber: r + 1, right: rightLines[r], leftHighlights: [], rightHighlights: []))
            case .delete(let l):
                pendingDeletes.append(l)
            case .insert(let r):
                pendingInserts.append(r)
            }
        }
        flush()
        return rows
    }

    /// Indices of rows that start a block of differences, for next/previous navigation.
    public static func differenceStarts(_ rows: [Row]) -> [Int] {
        var starts: [Int] = []
        var inBlock = false
        for (index, row) in rows.enumerated() {
            let differs = row.kind == .changed || row.kind == .added || row.kind == .removed
            if differs && !inBlock { starts.append(index) }
            inBlock = differs
        }
        return starts
    }

    public static func splitLines(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    // MARK: - Inline

    /// Word-level differences between two lines as UTF-16 ranges.
    public static func inlineChanges(_ left: String, _ right: String,
                                     ignoreCase: Bool = false) -> (left: [Range<Int>], right: [Range<Int>]) {
        let leftTokens = tokens(left)
        let rightTokens = tokens(right)
        let ops = operations(leftTokens, rightTokens) { a, b in
            ignoreCase ? a.text.lowercased() == b.text.lowercased() : a.text == b.text
        }
        var leftRanges: [Range<Int>] = []
        var rightRanges: [Range<Int>] = []
        for operation in ops {
            switch operation {
            case .delete(let index): append(leftTokens[index].range, to: &leftRanges)
            case .insert(let index): append(rightTokens[index].range, to: &rightRanges)
            case .equal: continue
            }
        }
        return (leftRanges, rightRanges)
    }

    private static func append(_ range: Range<Int>, to ranges: inout [Range<Int>]) {
        if let last = ranges.last, last.upperBound == range.lowerBound {
            ranges[ranges.count - 1] = last.lowerBound..<range.upperBound
        } else {
            ranges.append(range)
        }
    }

    struct Token {
        var text: String
        var range: Range<Int>
    }

    /// Words, runs of whitespace and single punctuation characters, with UTF-16 offsets.
    static func tokens(_ line: String) -> [Token] {
        var result: [Token] = []
        var current = ""
        var start = 0
        var offset = 0
        var currentClass = -1
        func classOf(_ scalar: Unicode.Scalar) -> Int {
            if CharacterSet.whitespaces.contains(scalar) { return 0 }
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "@" || scalar == "#" { return 1 }
            return 2
        }
        for scalar in line.unicodeScalars {
            let kind = classOf(scalar)
            let width = String(scalar).utf16.count
            if kind != currentClass || kind == 2 {
                if !current.isEmpty { result.append(Token(text: current, range: start..<offset)) }
                current = ""
                start = offset
                currentClass = kind
            }
            current.unicodeScalars.append(scalar)
            offset += width
        }
        if !current.isEmpty { result.append(Token(text: current, range: start..<offset)) }
        return result
    }
}
