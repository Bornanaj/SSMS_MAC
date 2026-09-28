import Foundation
import TDSKit

/// Data comparison results as a report: a per-table summary, and the differing rows with the
/// changed values side by side.
public struct DataCompareReport: Sendable {
    public let comparison: DataComparison
    /// Rows shown per table in the HTML report; exports always contain every kept row.
    public var htmlRowsPerTable: Int

    public init(comparison: DataComparison, htmlRowsPerTable: Int = 200) {
        self.comparison = comparison
        self.htmlRowsPerTable = htmlRowsPerTable
    }

    public func render(_ format: CompareReportFormat) throws -> Data {
        switch format {
        case .html: return Data(html().utf8)
        case .csv: return Data(csv().utf8)
        case .xml: return Data(xml().utf8)
        case .json: return try json()
        case .excel:
            // One sheet: the summary, then every kept difference in long form.
            var writer = XlsxWriter(sheetName: "Data comparison")
            var rows = summaryRows()
            rows.append([])
            rows.append(["Table", "Status", "Key", "Column", "Source value", "Target value"])
            let lines = csv().components(separatedBy: "\r\n").dropFirst().filter { !$0.isEmpty }
            for line in lines { rows.append(DataCompareReport.splitCSV(line)) }
            writer.write(columns: summaryColumns, rows: rows)
            return try writer.data()
        }
    }

    static func splitCSV(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var quoted = false
        var iterator = Array(line)
        var index = 0
        while index < iterator.count {
            let character = iterator[index]
            if quoted {
                if character == "\"" {
                    if index + 1 < iterator.count, iterator[index + 1] == "\"" {
                        current.append("\"")
                        index += 1
                    } else {
                        quoted = false
                    }
                } else {
                    current.append(character)
                }
            } else if character == "\"" {
                quoted = true
            } else if character == "," {
                fields.append(current)
                current = ""
            } else {
                current.append(character)
            }
            index += 1
        }
        fields.append(current)
        iterator.removeAll()
        return fields
    }

    private let summaryColumns = ["Table", "Comparison key", "Source rows", "Target rows", "Different",
                                  "Only in source", "Only in target", "Identical", "Status"]

    private func summaryRows() -> [[String]] {
        comparison.tables.map { table in
            [table.mapping.displayName, table.mapping.keyDescription, String(table.sourceRows), String(table.targetRows),
             String(table.different), String(table.onlyInSource), String(table.onlyInTarget), String(table.identical),
             table.error ?? (table.hasDifferences ? "Different" : "Identical")]
        }
    }

    /// Every kept difference in long form: one line per changed value.
    public func csv() -> String {
        var out = "Table,Status,Key,Column,Source value,Target value\r\n"
        for table in comparison.tables {
            let keyNames = table.mapping.keyColumns.map(\.sourceColumn)
            let columnNames = table.mapping.comparedColumns.map(\.sourceColumn)
            for row in table.rows where row.status != .identical {
                let key = zip(keyNames, row.key).map { "\($0)=\($1.displayString())" }.joined(separator: "; ")
                let fields: [[String]]
                switch row.status {
                case .different:
                    fields = row.differingColumns.map { index in
                        [columnNames[index], row.source?[index].displayString() ?? "",
                         row.target?[index].displayString() ?? ""]
                    }
                case .onlyInSource, .onlyInTarget, .identical:
                    fields = [["", row.status == .onlyInSource ? "(row)" : "", row.status == .onlyInTarget ? "(row)" : ""]]
                }
                for field in fields {
                    let line = [table.mapping.displayName, row.status.title, key] + field
                    out += line.map(ReportHTML.csvField).joined(separator: ",") + "\r\n"
                }
            }
        }
        return out
    }

    public func xml() -> String {
        var out = "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n"
        out += "<dataComparison generator=\"SSMS for Mac\" date=\"\(ReportHTML.timestamp(comparison.comparedAt))\" "
            + "source=\"\(ReportHTML.escapeXML(comparison.sourceDescription))\" "
            + "target=\"\(ReportHTML.escapeXML(comparison.targetDescription))\">\n"
        for table in comparison.tables {
            out += "  <table name=\"\(ReportHTML.escapeXML(table.mapping.displayName))\" "
                + "sourceRows=\"\(table.sourceRows)\" targetRows=\"\(table.targetRows)\" "
                + "different=\"\(table.different)\" onlyInSource=\"\(table.onlyInSource)\" "
                + "onlyInTarget=\"\(table.onlyInTarget)\" identical=\"\(table.identical)\""
            if let error = table.error { out += " error=\"\(ReportHTML.escapeXML(error))\"" }
            out += ">\n"
            let keyNames = table.mapping.keyColumns.map(\.sourceColumn)
            let columnNames = table.mapping.comparedColumns.map(\.sourceColumn)
            for row in table.rows where row.status != .identical {
                out += "    <row status=\"\(row.status.rawValue)\">\n"
                for (name, value) in zip(keyNames, row.key) {
                    out += "      <key column=\"\(ReportHTML.escapeXML(name))\">\(ReportHTML.escapeXML(value.displayString()))</key>\n"
                }
                for (index, name) in columnNames.enumerated() {
                    let differs = row.differingColumns.contains(index)
                    guard row.status != .different || differs else { continue }
                    out += "      <value column=\"\(ReportHTML.escapeXML(name))\""
                    if let source = row.source?[index] { out += " source=\"\(ReportHTML.escapeXML(source.displayString()))\"" }
                    if let target = row.target?[index] { out += " target=\"\(ReportHTML.escapeXML(target.displayString()))\"" }
                    out += " />\n"
                }
                out += "    </row>\n"
            }
            out += "  </table>\n"
        }
        return out + "</dataComparison>\n"
    }

    private struct JSONReport: Encodable {
        struct Table: Encodable {
            var name: String
            var key: String
            var sourceRows: Int
            var targetRows: Int
            var different: Int
            var onlyInSource: Int
            var onlyInTarget: Int
            var identical: Int
            var error: String?
        }
        var source: String
        var target: String
        var comparedAt: Date
        var tables: [Table]
    }

    public func json() throws -> Data {
        let report = JSONReport(source: comparison.sourceDescription, target: comparison.targetDescription,
                                comparedAt: comparison.comparedAt, tables: comparison.tables.map { table in
                                    JSONReport.Table(name: table.mapping.displayName, key: table.mapping.keyDescription,
                                                     sourceRows: table.sourceRows, targetRows: table.targetRows,
                                                     different: table.different, onlyInSource: table.onlyInSource,
                                                     onlyInTarget: table.onlyInTarget, identical: table.identical,
                                                     error: table.error)
                                })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(report)
    }

    public func html() -> String {
        var out = "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\">"
        out += "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
        out += "<title>Data comparison</title><style>\(ReportHTML.style)"
        out += " td.changed { background: var(--chg); } .grid { overflow-x: auto; }"
        out += " .grid table { font: 12px/1.4 ui-monospace, SFMono-Regular, Menlo, monospace; }</style></head><body><main>"
        out += "<h1>Data comparison</h1>"
        out += "<div class=\"muted\">Source: <b>\(ReportHTML.escape(comparison.sourceDescription))</b> &nbsp;·&nbsp; "
            + "Target: <b>\(ReportHTML.escape(comparison.targetDescription))</b> &nbsp;·&nbsp; "
            + "\(ReportHTML.timestamp(comparison.comparedAt))</div>"
        out += "<div class=\"cards\">"
        for status in DataRowStatus.allCases {
            let cssClass: String
            switch status {
            case .different: cssClass = "s-different"
            case .onlyInSource: cssClass = "s-onlyInSource"
            case .onlyInTarget: cssClass = "s-onlyInTarget"
            case .identical: cssClass = "s-identical"
            }
            out += "<div class=\"card\"><b class=\"\(cssClass)\">\(comparison.total(status))</b>\(status.title) rows</div>"
        }
        out += "</div><input id=\"filter\" type=\"search\" placeholder=\"Filter tables\">"
        out += "<table><thead><tr>" + summaryColumns.map { "<th>\($0)</th>" }.joined() + "</tr></thead><tbody>"
        for (table, row) in zip(comparison.tables, summaryRows()) {
            out += "<tr data-name=\"\(ReportHTML.escape(table.mapping.displayName.lowercased()))\">"
                + row.map { "<td>\(ReportHTML.escape($0))</td>" }.joined() + "</tr>"
        }
        out += "</tbody></table>"
        for table in comparison.tables where table.hasDifferences {
            out += "<details data-name=\"\(ReportHTML.escape(table.mapping.displayName.lowercased()))\"><summary>"
                + ReportHTML.escape(table.mapping.displayName)
                + " — \(table.different) different, \(table.onlyInSource) only in source, "
                + "\(table.onlyInTarget) only in target</summary>"
            out += rowsTable(table)
            out += "</details>"
        }
        out += "</main>\(ReportHTML.filterScript)</body></html>"
        return out
    }

    private func rowsTable(_ table: DataTableResult) -> String {
        let keyNames = table.mapping.keyColumns.map(\.sourceColumn)
        let columnNames = table.mapping.comparedColumns.map(\.sourceColumn)
        var out = "<div class=\"grid\"><table><thead><tr><th>Status</th>"
        out += keyNames.map { "<th>\(ReportHTML.escape($0))</th>" }.joined()
        for name in columnNames {
            out += "<th>\(ReportHTML.escape(name)) (source)</th><th>\(ReportHTML.escape(name)) (target)</th>"
        }
        out += "</tr></thead><tbody>"
        for row in table.rows.filter({ $0.status != .identical }).prefix(htmlRowsPerTable) {
            out += "<tr><td class=\"status\">\(row.status.title)</td>"
            out += row.key.map { "<td>\(ReportHTML.escape($0.displayString()))</td>" }.joined()
            for index in columnNames.indices {
                let changed = row.differingColumns.contains(index) ? " class=\"changed\"" : ""
                let source = row.source.map { index < $0.count ? $0[index].displayString() : "" } ?? ""
                let target = row.target.map { index < $0.count ? $0[index].displayString() : "" } ?? ""
                out += "<td\(changed)>\(ReportHTML.escape(source))</td><td\(changed)>\(ReportHTML.escape(target))</td>"
            }
            out += "</tr>"
        }
        let shown = min(htmlRowsPerTable, table.different + table.onlyInSource + table.onlyInTarget)
        out += "</tbody></table></div>"
        if shown < table.different + table.onlyInSource + table.onlyInTarget {
            out += "<div class=\"muted\" style=\"padding: 6px 12px\">Showing the first \(shown) rows; export to CSV "
                + "or Excel for all of them.</div>"
        }
        return out
    }
}
