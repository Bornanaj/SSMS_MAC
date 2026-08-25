import Foundation
import TDSKit
import SQLServerKit

/// One grid of results. Rows are stored in a plain array and the table view is told
/// to reload when `version` changes, which keeps 100k-row result sets cheap.
@MainActor
final class ResultSetModel: ObservableObject, Identifiable {
    let id: UUID
    let batchIndex: Int
    let ordinal: Int
    let columns: [TDSColumn]

    private(set) var rows: [[TDSValue]] = []
    @Published private(set) var version: Int = 0
    @Published private(set) var rowCount: Int = 0
    @Published private(set) var isTruncated = false
    @Published private(set) var isComplete = false
    @Published private(set) var elapsed: TimeInterval = 0

    /// Column widths measured once and reused when the grid is rebuilt.
    var measuredWidths: [CGFloat] = []

    init(handle: ResultSetHandle) {
        self.id = handle.id
        self.batchIndex = handle.batchIndex
        self.ordinal = handle.ordinal
        self.columns = handle.columns
    }

    func append(_ newRows: [[TDSValue]]) {
        rows.append(contentsOf: newRows)
        rowCount = rows.count
        version &+= 1
    }

    func finish(rowCount: Int, truncated: Bool, elapsed: TimeInterval) {
        self.rowCount = rowCount
        self.isTruncated = truncated
        self.elapsed = elapsed
        self.isComplete = true
        version &+= 1
    }

    /// Header shown above the grid, e.g. "(1,234 rows)".
    var summaryText: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        let count = formatter.string(from: NSNumber(value: rowCount)) ?? "\(rowCount)"
        var text = rowCount == 1 ? "(1 row)" : "(\(count) rows)"
        if isTruncated { text += " – display limited" }
        return text
    }

    func value(row: Int, column: Int) -> TDSValue {
        guard row >= 0, row < rows.count, column >= 0, column < rows[row].count else { return .null }
        return rows[row][column]
    }

    /// Rows and columns for a rectangular selection, used by Copy and Save Results As.
    func slice(rows rowIndexes: [Int], columns columnIndexes: [Int]) -> (cols: [TDSColumn], rows: [[TDSValue]]) {
        let cols = columnIndexes.compactMap { $0 < columns.count ? columns[$0] : nil }
        let data = rowIndexes.compactMap { rowIndex -> [TDSValue]? in
            guard rowIndex < rows.count else { return nil }
            let row = rows[rowIndex]
            return columnIndexes.compactMap { $0 < row.count ? row[$0] : nil }
        }
        return (cols, data)
    }
}
