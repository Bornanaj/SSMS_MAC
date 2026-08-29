import Foundation
import TDSKit

/// Options for Results to Text, matching the Query Results → Text page in SSMS options.
public struct TextResultOptions: Sendable, Hashable {
    /// SSMS calls this "Maximum number of characters displayed in each column".
    public var maxColumnWidth: Int
    public var columnSeparator: String
    public var nullText: String
    public var includeHeaders: Bool
    public var lineEnding: String
    /// Numbers are right aligned, which is what makes a text result readable.
    public var rightAlignNumbers: Bool
    /// Print `(n rows affected)` after each result set, the way the Messages pane does.
    public var includeRowCount: Bool

    public init(maxColumnWidth: Int = 256,
                columnSeparator: String = " ",
                nullText: String = "NULL",
                includeHeaders: Bool = true,
                lineEnding: String = "\n",
                rightAlignNumbers: Bool = true,
                includeRowCount: Bool = true) {
        self.maxColumnWidth = maxColumnWidth
        self.columnSeparator = columnSeparator
        self.nullText = nullText
        self.includeHeaders = includeHeaders
        self.lineEnding = lineEnding
        self.rightAlignNumbers = rightAlignNumbers
        self.includeRowCount = includeRowCount
    }
}

/// Renders a result set the way SSMS's Results to Text does: fixed width columns, a rule
/// of dashes under the headers, and a row count underneath.
///
/// Column widths come from the widest value actually present, clamped to
/// `maxColumnWidth`, so a `nvarchar(max)` column does not push everything off screen.
public struct TextResultFormatter: Sendable {

    public var options: TextResultOptions

    public init(options: TextResultOptions = TextResultOptions()) {
        self.options = options
    }

    // MARK: Column aligned

    public func format(columns: [TDSColumn], rows: [[TDSValue]]) -> String {
        guard !columns.isEmpty else {
            return options.includeRowCount ? rowCountLine(0) : ""
        }
        let cells = rows.map { row in
            columns.indices.map { index in
                truncate(TextResultFormatter.text(value(row, index), nullText: options.nullText))
            }
        }
        let headers = columns.map { truncate($0.name) }
        let widths = columns.indices.map { index -> Int in
            var width = options.includeHeaders ? headers[index].count : 1
            for row in cells { width = max(width, row[index].count) }
            return max(1, min(width, max(1, options.maxColumnWidth)))
        }
        let alignment = columns.map { options.rightAlignNumbers && TextResultFormatter.isNumeric($0) }

        var out = ""
        if options.includeHeaders {
            out += line(headers, widths: widths, rightAligned: alignment.map { _ in false })
            out += options.lineEnding
            out += line(widths.map { String(repeating: "-", count: $0) },
                        widths: widths,
                        rightAligned: alignment.map { _ in false })
            out += options.lineEnding
        }
        for row in cells {
            out += line(row, widths: widths, rightAligned: alignment)
            out += options.lineEnding
        }
        if options.includeRowCount {
            out += options.lineEnding
            out += rowCountLine(rows.count)
        }
        return out
    }

    private func line(_ cells: [String], widths: [Int], rightAligned: [Bool]) -> String {
        var parts: [String] = []
        parts.reserveCapacity(cells.count)
        for (index, cell) in cells.enumerated() {
            let width = index < widths.count ? widths[index] : cell.count
            let isRight = index < rightAligned.count && rightAligned[index]
            parts.append(pad(cell, to: width, rightAligned: isRight))
        }
        // Trailing padding on the last column is noise in a text file, so it is dropped.
        var text = parts.joined(separator: options.columnSeparator)
        while text.hasSuffix(" ") { text.removeLast() }
        return text
    }

    private func pad(_ text: String, to width: Int, rightAligned: Bool) -> String {
        guard text.count < width else { return text }
        let padding = String(repeating: " ", count: width - text.count)
        return rightAligned ? padding + text : text + padding
    }

    private func truncate(_ text: String) -> String {
        let limit = max(1, options.maxColumnWidth)
        guard text.count > limit else { return text }
        return String(text.prefix(limit))
    }

    private func rowCountLine(_ count: Int) -> String {
        "(\(count) row\(count == 1 ? "" : "s") affected)" + options.lineEnding
    }

    // MARK: Delimited

    /// SSMS's "Results to text" also has a delimited mode, used for pasting into a shell.
    public func formatDelimited(columns: [TDSColumn],
                                rows: [[TDSValue]],
                                delimiter: String = "\t") -> String {
        var out = ""
        if options.includeHeaders, !columns.isEmpty {
            out += columns.map(\.name).joined(separator: delimiter) + options.lineEnding
        }
        for row in rows {
            out += columns.indices
                .map { TextResultFormatter.text(value(row, $0), nullText: options.nullText) }
                .joined(separator: delimiter)
            out += options.lineEnding
        }
        if options.includeRowCount {
            out += options.lineEnding + rowCountLine(rows.count)
        }
        return out
    }

    // MARK: Helpers

    private func value(_ row: [TDSValue], _ index: Int) -> TDSValue {
        index >= 0 && index < row.count ? row[index] : .null
    }

    static func text(_ value: TDSValue, nullText: String) -> String {
        value.isNull ? nullText : value.displayString(nullText: nullText)
    }

    /// Which columns get right aligned. This is the wire type, not the rendered text, so a
    /// numeric column of nulls still lines up with its neighbours.
    static func isNumeric(_ column: TDSColumn) -> Bool {
        switch column.typeInfo.dataType {
        case .tinyInt, .smallInt, .int, .bigInt, .intN,
             .real, .float, .floatN,
             .money, .smallMoney, .moneyN,
             .decimalLegacy, .numericLegacy, .decimalN, .numericN:
            return true
        default:
            return false
        }
    }
}
