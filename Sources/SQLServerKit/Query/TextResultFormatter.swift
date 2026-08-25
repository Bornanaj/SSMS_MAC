import Foundation
import TDSKit

/// Renders a result set the way SSMS does in "Results To Text" mode: one fixed width
/// column per field, a rule of hyphens under the headers, and a trailing row count.
public struct TextResultFormatter: Sendable {

    public struct Style: Sendable {
        /// SSMS pads with spaces between columns; the delimiter is configurable there too.
        public var columnSeparator: String = "  "
        public var maxColumnWidth: Int = 256
        public var nullText: String = "NULL"
        public var printColumnHeaders: Bool = true
        public var rightAlignNumerics: Bool = true

        public init() {}
    }

    public var style: Style

    public init(style: Style = Style()) {
        self.style = style
    }

    // MARK: - Formatting

    /// Lines are terminated rather than joined, so appending `rowsAffected(_:)` produces
    /// the blank separator line SSMS prints between the rows and the count.
    public func format(columns: [TDSColumn], rows: [[TDSValue]]) -> String {
        guard !columns.isEmpty else { return "" }

        let limit: Int = max(1, style.maxColumnWidth)
        let headers: [String] = columns.map(\.name)
        let cells: [[String]] = renderCells(columns: columns, rows: rows)
        let widths: [Int] = measure(headers: headers, cells: cells, columns: columns, limit: limit)
        let rightAligned: [Bool] = columns.map { column in
            style.rightAlignNumerics && column.typeInfo.dataType.isNumeric
        }

        var output = ""
        if style.printColumnHeaders {
            // Headers stay left aligned even over numeric columns, as sqlcmd and SSMS do.
            let flushLeft = [Bool](repeating: false, count: columns.count)
            output += compose(headers, widths: widths, rightAligned: flushLeft) + "\n"
            output += rule(widths: widths) + "\n"
        }
        for cell in cells {
            output += compose(cell, widths: widths, rightAligned: rightAligned) + "\n"
        }
        return output
    }

    public func format(_ resultSet: TDSResultSet) -> String {
        format(columns: resultSet.columns, rows: resultSet.rows)
    }

    public func rowsAffected(_ count: Int64) -> String {
        let noun: String = count == 1 ? "row" : "rows"
        return "\n(\(count) \(noun) affected)\n"
    }

    // MARK: - Layout

    private func renderCells(columns: [TDSColumn], rows: [[TDSValue]]) -> [[String]] {
        var cells: [[String]] = []
        cells.reserveCapacity(rows.count)
        for row in rows {
            var line: [String] = []
            line.reserveCapacity(columns.count)
            for index in columns.indices {
                // A short row can only come from a malformed stream; treat the gap as NULL
                // rather than trapping on the index.
                let value: TDSValue = index < row.count ? row[index] : .null
                line.append(value.displayString(nullText: style.nullText))
            }
            cells.append(line)
        }
        return cells
    }

    private func measure(headers: [String], cells: [[String]],
                         columns: [TDSColumn], limit: Int) -> [Int] {
        var widths: [Int] = []
        widths.reserveCapacity(columns.count)
        for index in columns.indices {
            var width: Int = style.printColumnHeaders ? Self.displayWidth(headers[index]) : 0
            for cell in cells {
                width = max(width, Self.displayWidth(cell[index]))
            }
            widths.append(min(max(width, 1), limit))
        }
        return widths
    }

    private func compose(_ values: [String], widths: [Int], rightAligned: [Bool]) -> String {
        var parts: [String] = []
        parts.reserveCapacity(values.count)
        for index in values.indices {
            parts.append(Self.fit(values[index], width: widths[index],
                                  rightAligned: rightAligned[index]))
        }
        let line: String = parts.joined(separator: style.columnSeparator)
        return Self.trimmingTrailingBlanks(line)
    }

    private func rule(widths: [Int]) -> String {
        let runs: [String] = widths.map { String(repeating: "-", count: $0) }
        return runs.joined(separator: style.columnSeparator)
    }

    /// Pads or truncates to exactly `width` display cells. Long values are cut, never wrapped.
    private static func fit(_ text: String, width: Int, rightAligned: Bool) -> String {
        let measured: Int = displayWidth(text)
        if measured == width { return text }
        if measured > width {
            let cut: String = truncate(text, to: width)
            let shortfall: Int = width - displayWidth(cut)
            guard shortfall > 0 else { return cut }
            let padding = String(repeating: " ", count: shortfall)
            return rightAligned ? padding + cut : cut + padding
        }
        let padding = String(repeating: " ", count: width - measured)
        return rightAligned ? padding + text : text + padding
    }

    private static func truncate(_ text: String, to width: Int) -> String {
        var result = ""
        var used = 0
        for character in text {
            let cells: Int = displayWidth(of: character)
            if used + cells > width { break }
            result.append(character)
            used += cells
        }
        return result
    }

    private static func trimmingTrailingBlanks(_ line: String) -> String {
        var slice: Substring = line[...]
        while let last = slice.last, last == " " || last == "\t" {
            slice = slice.dropLast()
        }
        return String(slice)
    }

    // MARK: - Width

    /// Counted in grapheme clusters, not UTF-8 bytes: Persian letters plus their combining
    /// marks occupy one cell, while CJK and fullwidth forms occupy two in a monospaced font.
    static func displayWidth(_ text: String) -> Int {
        var total = 0
        for character in text {
            total += displayWidth(of: character)
        }
        return total
    }

    private static func displayWidth(of character: Character) -> Int {
        guard let scalar = character.unicodeScalars.first else { return 0 }
        return isWide(scalar) ? 2 : 1
    }

    private static func isWide(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x1100...0x115F,            // Hangul Jamo initial consonants
             0x2E80...0x303E,            // CJK radicals, Kangxi, CJK symbols
             0x3041...0x33FF,            // kana, Hangul compatibility jamo, CJK compatibility
             0x3400...0x4DBF,            // CJK extension A
             0x4E00...0x9FFF,            // CJK unified ideographs
             0xA000...0xA4CF,            // Yi
             0xAC00...0xD7A3,            // Hangul syllables
             0xF900...0xFAFF,            // CJK compatibility ideographs
             0xFE10...0xFE19,            // vertical forms
             0xFE30...0xFE6F,            // CJK compatibility forms, small form variants
             0xFF00...0xFF60,            // fullwidth forms
             0xFFE0...0xFFE6,            // fullwidth signs
             0x1F300...0x1F64F,          // pictographs and emoticons
             0x1F900...0x1F9FF,          // supplemental symbols
             0x20000...0x2FFFD,          // CJK extensions B and beyond
             0x30000...0x3FFFD:
            return true
        default:
            return false
        }
    }
}
