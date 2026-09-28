import Foundation

public enum CompareReportFormat: String, CaseIterable, Sendable, Identifiable {
    case html
    case xml
    case excel
    case csv
    case json

    public var id: String { rawValue }

    public var fileExtension: String {
        switch self {
        case .html: return "html"
        case .xml: return "xml"
        case .excel: return "xlsx"
        case .csv: return "csv"
        case .json: return "json"
        }
    }

    public var title: String {
        switch self {
        case .html: return "Interactive HTML"
        case .xml: return "XML"
        case .excel: return "Excel workbook"
        case .csv: return "CSV"
        case .json: return "JSON"
        }
    }
}

/// Escaping and page furniture shared by the schema and data reports.
enum ReportHTML {
    static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.append(character)
            }
        }
        return out
    }

    static func escapeXML(_ text: String) -> String {
        var out = escape(text).replacingOccurrences(of: "'", with: "&apos;")
        // XML 1.0 forbids most control characters outright.
        out = String(out.unicodeScalars.filter { $0.value >= 0x20 || $0 == "\n" || $0 == "\t" || $0 == "\r" }
            .map(Character.init))
        return out
    }

    static func csvField(_ text: String) -> String {
        if text.contains(",") || text.contains("\"") || text.contains("\n") || text.contains("\r") {
            return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return text
    }

    static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }

    static let style = """
    :root { --bg:#ffffff; --fg:#1d1d1f; --muted:#6e6e73; --line:#d9d9de; --panel:#f5f5f7;
            --add:#e3f6e5; --add-strong:#a8e2b0; --del:#fde8e8; --del-strong:#f5b3b3;
            --chg:#fff4d6; --accent:#0a66d8; }
    @media (prefers-color-scheme: dark) {
      :root { --bg:#1c1c1e; --fg:#f2f2f7; --muted:#98989f; --line:#3a3a3c; --panel:#2c2c2e;
              --add:#16361d; --add-strong:#23602f; --del:#3d1a1a; --del-strong:#6f2a2a;
              --chg:#3a3216; --accent:#4c9dff; }
    }
    * { box-sizing: border-box; }
    body { margin:0; padding:24px 16px 48px; background:var(--bg); color:var(--fg);
           font: 14px/1.45 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; }
    main { max-width: 1280px; margin: 0 auto; }
    h1 { font-size: 22px; margin: 0 0 4px; }
    h2 { font-size: 17px; margin: 32px 0 8px; }
    .muted { color: var(--muted); }
    .cards { display:flex; flex-wrap:wrap; gap:10px; margin:16px 0; }
    .card { background:var(--panel); border:1px solid var(--line); border-radius:10px; padding:10px 14px; min-width:150px; }
    .card b { display:block; font-size:22px; }
    table { border-collapse: collapse; width: 100%; }
    th, td { text-align:left; padding:6px 8px; border-bottom:1px solid var(--line); vertical-align: top; }
    th { font-weight:600; background:var(--panel); position: sticky; top: 0; }
    .status { font-weight:600; white-space: nowrap; }
    .s-different { color:#b7791f; } .s-onlyInSource { color:#2f855a; } .s-onlyInTarget { color:#c53030; }
    .s-identical { color: var(--muted); }
    details { border:1px solid var(--line); border-radius:10px; margin:10px 0; background:var(--panel); }
    summary { cursor:pointer; padding:10px 12px; font-weight:600; }
    .diff { width:100%; overflow-x:auto; background:var(--bg); border-top:1px solid var(--line); }
    .diff table { font: 12px/1.4 ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; table-layout: fixed; }
    .diff td { border:none; padding:0 6px; white-space: pre-wrap; word-break: break-all; }
    .diff td.n { width:44px; color:var(--muted); text-align:right; user-select:none; }
    .diff td.code { width: calc(50% - 44px); }
    .r-changed td.code { background: var(--chg); } .r-added td.right, .r-removed td.left { background: var(--del); }
    .r-added td.right { background: var(--add); }
    mark.h { background: var(--del-strong); color: inherit; border-radius: 2px; }
    .right mark.h { background: var(--add-strong); }
    ul.details { margin: 0; padding: 4px 12px 10px 30px; }
    input#filter { width: 100%; max-width: 360px; padding: 6px 10px; border-radius: 8px; border: 1px solid var(--line);
                   background: var(--bg); color: var(--fg); margin: 8px 0; }
    """

    static let filterScript = """
    <script>
    document.getElementById('filter')?.addEventListener('input', function (event) {
      var needle = event.target.value.toLowerCase();
      document.querySelectorAll('[data-name]').forEach(function (row) {
        row.style.display = row.getAttribute('data-name').indexOf(needle) >= 0 ? '' : 'none';
      });
    });
    </script>
    """

    /// Side-by-side diff table with inline highlights.
    static func diffTable(left: String, right: String, ignoreWhitespace: Bool) -> String {
        let rows = TextDiff.sideBySide(left: left, right: right,
                                       options: TextDiff.Options(ignoreWhitespace: ignoreWhitespace))
        var out = "<div class=\"diff\"><table>"
        for row in rows {
            out += "<tr class=\"r-\(row.kind.rawValue)\">"
            out += "<td class=\"n\">\(row.leftNumber.map(String.init) ?? "")</td>"
            out += "<td class=\"code left\">\(highlighted(row.left ?? "", row.leftHighlights))</td>"
            out += "<td class=\"n\">\(row.rightNumber.map(String.init) ?? "")</td>"
            out += "<td class=\"code right\">\(highlighted(row.right ?? "", row.rightHighlights))</td>"
            out += "</tr>"
        }
        return out + "</table></div>"
    }

    private static func highlighted(_ text: String, _ ranges: [Range<Int>]) -> String {
        guard !ranges.isEmpty else { return escape(text) }
        let units = Array(text.utf16)
        var out = ""
        var cursor = 0
        for range in ranges where range.lowerBound >= cursor && range.upperBound <= units.count {
            out += escape(String(decoding: units[cursor..<range.lowerBound], as: UTF16.self))
            out += "<mark class=\"h\">" + escape(String(decoding: units[range], as: UTF16.self)) + "</mark>"
            cursor = range.upperBound
        }
        out += escape(String(decoding: units[cursor...], as: UTF16.self))
        return out
    }
}

// MARK: - Schema report

public struct SchemaCompareReport: Sendable {
    public let comparison: SchemaComparison
    public var includeIdentical: Bool

    public init(comparison: SchemaComparison, includeIdentical: Bool = false) {
        self.comparison = comparison
        self.includeIdentical = includeIdentical
    }

    public func render(_ format: CompareReportFormat) throws -> Data {
        switch format {
        case .html: return Data(html().utf8)
        case .xml: return Data(xml().utf8)
        case .csv: return Data(csv().utf8)
        case .json: return try json()
        case .excel:
            var writer = XlsxWriter(sheetName: "Schema comparison")
            writer.write(columns: ["Type", "Source name", "Status", "Target name", "Details"], rows: tableRows())
            return try writer.data()
        }
    }

    private var reported: [SchemaDifference] {
        comparison.differences.filter { includeIdentical || $0.status != .identical }
    }

    private func tableRows() -> [[String]] {
        reported.map { difference in
            [difference.type.title, difference.sourceName, difference.status.shortTitle, difference.targetName,
             difference.details.joined(separator: "; ")]
        }
    }

    public func csv() -> String {
        var out = "Type,Source name,Status,Target name,Details\r\n"
        for row in tableRows() {
            out += row.map(ReportHTML.csvField).joined(separator: ",") + "\r\n"
        }
        return out
    }

    public func xml() -> String {
        var out = "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n"
        out += "<comparison generator=\"SSMS for Mac\" date=\"\(ReportHTML.timestamp(comparison.comparedAt))\" "
            + "source=\"\(ReportHTML.escapeXML(comparison.source.origin))\" "
            + "target=\"\(ReportHTML.escapeXML(comparison.target.origin))\">\n"
        out += "  <summary"
        for status in DifferenceStatus.allCases { out += " \(status.rawValue)=\"\(comparison.count(status))\"" }
        out += " />\n"
        for difference in reported {
            out += "  <object type=\"\(difference.type.rawValue)\" status=\"\(difference.status.rawValue)\" "
                + "source=\"\(ReportHTML.escapeXML(difference.sourceName))\" "
                + "target=\"\(ReportHTML.escapeXML(difference.targetName))\">\n"
            for detail in difference.details {
                out += "    <difference>\(ReportHTML.escapeXML(detail))</difference>\n"
            }
            if !difference.sourceScript.isEmpty {
                out += "    <sourceScript><![CDATA[\(difference.sourceScript.replacingOccurrences(of: "]]>", with: "]]]]><![CDATA[>"))]]></sourceScript>\n"
            }
            if !difference.targetScript.isEmpty {
                out += "    <targetScript><![CDATA[\(difference.targetScript.replacingOccurrences(of: "]]>", with: "]]]]><![CDATA[>"))]]></targetScript>\n"
            }
            out += "  </object>\n"
        }
        return out + "</comparison>\n"
    }

    private struct JSONReport: Encodable {
        struct Item: Encodable {
            var type: String
            var status: String
            var source: String
            var target: String
            var details: [String]
            var sourceScript: String
            var targetScript: String
        }
        var source: String
        var target: String
        var comparedAt: Date
        var summary: [String: Int]
        var objects: [Item]
    }

    public func json() throws -> Data {
        var summary: [String: Int] = [:]
        for status in DifferenceStatus.allCases { summary[status.rawValue] = comparison.count(status) }
        let report = JSONReport(source: comparison.source.origin, target: comparison.target.origin,
                                comparedAt: comparison.comparedAt, summary: summary,
                                objects: reported.map {
                                    JSONReport.Item(type: $0.type.rawValue, status: $0.status.rawValue,
                                                    source: $0.sourceName, target: $0.targetName, details: $0.details,
                                                    sourceScript: $0.sourceScript, targetScript: $0.targetScript)
                                })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(report)
    }

    public func html() -> String {
        let title = "Schema comparison"
        var out = "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\">"
        out += "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
        out += "<title>\(title)</title><style>\(ReportHTML.style)</style></head><body><main>"
        out += "<h1>\(title)</h1>"
        out += "<div class=\"muted\">Source: <b>\(ReportHTML.escape(comparison.source.origin))</b> &nbsp;·&nbsp; "
            + "Target: <b>\(ReportHTML.escape(comparison.target.origin))</b> &nbsp;·&nbsp; "
            + "\(ReportHTML.timestamp(comparison.comparedAt))</div>"
        let changed = comparison.options.changedFromDefaults
        if !changed.isEmpty {
            out += "<div class=\"muted\">Options changed from the defaults: "
                + ReportHTML.escape(changed.joined(separator: ", ")) + "</div>"
        }
        out += "<div class=\"cards\">"
        for status in DifferenceStatus.allCases {
            out += "<div class=\"card\"><b class=\"s-\(status.rawValue)\">\(comparison.count(status))</b>"
                + "\(status.shortTitle)</div>"
        }
        out += "</div>"
        out += "<input id=\"filter\" type=\"search\" placeholder=\"Filter objects\">"
        out += "<table><thead><tr><th>Type</th><th>Source</th><th></th><th>Target</th></tr></thead><tbody>"
        for difference in reported {
            let name = (difference.sourceName + " " + difference.targetName).lowercased()
            out += "<tr data-name=\"\(ReportHTML.escape(name))\"><td>\(difference.type.title)</td>"
                + "<td>\(ReportHTML.escape(difference.sourceName))</td>"
                + "<td class=\"status s-\(difference.status.rawValue)\">\(difference.status.symbol) "
                + "\(difference.status.shortTitle)</td>"
                + "<td>\(ReportHTML.escape(difference.targetName))</td></tr>"
        }
        out += "</tbody></table>"
        let changedObjects = reported.filter { $0.status != .identical }
        if !changedObjects.isEmpty {
            out += "<h2>SQL differences</h2>"
            for difference in changedObjects {
                let name = (difference.sourceName + " " + difference.targetName).lowercased()
                out += "<details data-name=\"\(ReportHTML.escape(name))\"><summary>"
                    + "\(difference.type.title) \(ReportHTML.escape(difference.displayName)) — "
                    + "<span class=\"s-\(difference.status.rawValue)\">\(difference.status.shortTitle)</span></summary>"
                if !difference.details.isEmpty {
                    out += "<ul class=\"details\">" + difference.details.map { "<li>\(ReportHTML.escape($0))</li>" }
                        .joined() + "</ul>"
                }
                out += ReportHTML.diffTable(left: difference.sourceScript, right: difference.targetScript,
                                            ignoreWhitespace: comparison.options.ignoreWhitespace)
                out += "</details>"
            }
        }
        out += "</main>\(ReportHTML.filterScript)</body></html>"
        return out
    }
}
