import Foundation
import TDSKit

// MARK: - Format

/// Everything the "Save results as…" menu offers.
public enum ExportFormat: String, CaseIterable, Sendable, Identifiable {
    case csv
    case tsv
    case json
    case xml
    case markdown
    case html
    case sqlInsert
    case xlsx

    public var id: String { rawValue }

    public var fileExtension: String {
        switch self {
        case .csv: return "csv"
        case .tsv: return "tsv"
        case .json: return "json"
        case .xml: return "xml"
        case .markdown: return "md"
        case .html: return "html"
        case .sqlInsert: return "sql"
        case .xlsx: return "xlsx"
        }
    }

    public var displayName: String {
        switch self {
        case .csv: return "CSV (Comma delimited)"
        case .tsv: return "Tab delimited"
        case .json: return "JSON"
        case .xml: return "XML"
        case .markdown: return "Markdown table"
        case .html: return "HTML"
        case .sqlInsert: return "INSERT statements"
        case .xlsx: return "Excel workbook"
        }
    }

    /// XLSX is a zip container, so it can only be produced as bytes, never as text.
    public var isBinary: Bool { self == .xlsx }
}

// MARK: - Options

public struct ExportOptions: Sendable {
    public var includeHeaders: Bool = true
    /// Only consulted for `.csv`; `.tsv` always uses a tab.
    public var delimiter: String = ","
    public var quoteAllFields: Bool = false
    /// Text written for NULL in the flat formats. JSON/XML/SQL use their own null form.
    public var nullText: String = "NULL"
    public var lineEnding: String = "\r\n"
    public var encoding: String.Encoding = .utf8
    public var writeByteOrderMark: Bool = true
    /// Used as the XLSX sheet name, the HTML title and the INSERT target.
    public var tableName: String = "Results"
    /// Rows per INSERT batch for `.sqlInsert`.
    public var batchSize: Int = 1000

    public init() {}
}

// MARK: - Exporter

public struct ResultExporter: Sendable {

    public init() {}

    public func export(columns: [TDSColumn], rows: [[TDSValue]], format: ExportFormat,
                       to url: URL, options: ExportOptions) throws {
        if format == .xlsx {
            let headers = Self.headerNames(columns)
            var writer = XlsxWriter(sheetName: options.tableName)
            let cells = rows.map { row in
                (0..<headers.count).map { index in
                    Self.text(Self.value(row, index), options: options)
                }
            }
            writer.write(columns: options.includeHeaders ? headers : [], rows: cells)
            try writer.data().write(to: url, options: .atomic)
            return
        }
        let text = try string(columns: columns, rows: rows, format: format, options: options)
        try Self.encode(text, options: options).write(to: url, options: .atomic)
    }

    public func string(columns: [TDSColumn], rows: [[TDSValue]], format: ExportFormat,
                       options: ExportOptions) throws -> String {
        let headers = Self.headerNames(columns)
        switch format {
        case .csv:
            return delimited(headers: headers, rows: rows, delimiter: options.delimiter,
                             options: options)
        case .tsv:
            return delimited(headers: headers, rows: rows, delimiter: "\t", options: options)
        case .json:
            return json(headers: headers, rows: rows, options: options)
        case .xml:
            return xml(headers: headers, rows: rows, options: options)
        case .markdown:
            return markdown(headers: headers, rows: rows, options: options)
        case .html:
            return html(headers: headers, rows: rows, options: options)
        case .sqlInsert:
            return sqlInsert(headers: headers, rows: rows, options: options)
        case .xlsx:
            throw SQLServerError.unsupportedOperation(
                "Excel workbooks are binary; use export(columns:rows:format:to:options:).")
        }
    }

    // MARK: - Delimited

    private func delimited(headers: [String], rows: [[TDSValue]], delimiter: String,
                           options: ExportOptions) -> String {
        let separator = delimiter.isEmpty ? "," : delimiter
        var out = ""
        if options.includeHeaders {
            out += headers.map { Self.csvField($0, separator: separator, quoteAll: options.quoteAllFields) }
                .joined(separator: separator)
            out += options.lineEnding
        }
        for row in rows {
            var fields: [String] = []
            fields.reserveCapacity(headers.count)
            for index in 0..<headers.count {
                let text = Self.text(Self.value(row, index), options: options)
                fields.append(Self.csvField(text, separator: separator, quoteAll: options.quoteAllFields))
            }
            out += fields.joined(separator: separator)
            out += options.lineEnding
        }
        return out
    }

    /// RFC 4180: quote when the field carries the delimiter, a quote, CR or LF.
    private static func csvField(_ text: String, separator: String, quoteAll: Bool) -> String {
        var needsQuotes = quoteAll
        if !needsQuotes {
            needsQuotes = text.contains("\"") || text.contains("\n") || text.contains("\r")
                || (!separator.isEmpty && text.contains(separator))
        }
        guard needsQuotes else { return text }
        return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    // MARK: - JSON

    /// Hand rolled so that 38 digit decimals never touch `Double`.
    private func json(headers: [String], rows: [[TDSValue]], options: ExportOptions) -> String {
        var out = "["
        out += options.lineEnding
        for (rowIndex, row) in rows.enumerated() {
            out += "  {"
            out += options.lineEnding
            for index in 0..<headers.count {
                out += "    \"" + Self.jsonEscape(headers[index]) + "\": "
                out += Self.jsonValue(Self.value(row, index))
                if index < headers.count - 1 { out += "," }
                out += options.lineEnding
            }
            out += "  }"
            if rowIndex < rows.count - 1 { out += "," }
            out += options.lineEnding
        }
        out += "]"
        out += options.lineEnding
        return out
    }

    private static func jsonValue(_ value: TDSValue) -> String {
        switch value {
        case .null:
            return "null"
        case .bool(let flag):
            return flag ? "true" : "false"
        case .int(let number):
            return String(number)
        case .double(let number):
            guard number.isFinite else { return "null" }
            return numberOrString(value.displayString())
        case .float(let number):
            guard number.isFinite else { return "null" }
            return numberOrString(value.displayString())
        case .decimal(let number):
            return numberOrString(number.description)
        case .string, .binary, .uuid, .temporal, .xml:
            return "\"" + jsonEscape(value.displayString()) + "\""
        }
    }

    /// Emit a bare JSON number when the text really is one, otherwise fall back to a string
    /// so the document stays parseable.
    private static func numberOrString(_ text: String) -> String {
        isJSONNumber(text) ? text : "\"" + jsonEscape(text) + "\""
    }

    private static func isJSONNumber(_ text: String) -> Bool {
        let scalars = Array(text.unicodeScalars)
        guard !scalars.isEmpty else { return false }
        var index = 0
        if scalars[index] == "-" { index += 1 }
        var digits = 0
        while index < scalars.count, scalars[index].isASCIIDigit { index += 1; digits += 1 }
        guard digits > 0 else { return false }
        if index < scalars.count, scalars[index] == "." {
            index += 1
            var fraction = 0
            while index < scalars.count, scalars[index].isASCIIDigit { index += 1; fraction += 1 }
            guard fraction > 0 else { return false }
        }
        if index < scalars.count, scalars[index] == "e" || scalars[index] == "E" {
            index += 1
            if index < scalars.count, scalars[index] == "+" || scalars[index] == "-" { index += 1 }
            var exponent = 0
            while index < scalars.count, scalars[index].isASCIIDigit { index += 1; exponent += 1 }
            guard exponent > 0 else { return false }
        }
        return index == scalars.count
    }

    private static func jsonEscape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count + 8)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    out += String(format: "\\u%04X", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out
    }

    // MARK: - XML

    private func xml(headers: [String], rows: [[TDSValue]], options: ExportOptions) -> String {
        let elements = headers.map { Self.xmlElementName($0) }
        var out = "<?xml version=\"1.0\" encoding=\"\(Self.charsetName(options.encoding))\"?>"
        out += options.lineEnding
        out += "<Results>"
        out += options.lineEnding
        for row in rows {
            out += "  <Row>"
            out += options.lineEnding
            for index in 0..<headers.count {
                let value = Self.value(row, index)
                let name = elements[index]
                if value.isNull {
                    out += "    <\(name) />"
                } else {
                    out += "    <\(name)>" + Self.xmlEscape(value.displayString()) + "</\(name)>"
                }
                out += options.lineEnding
            }
            out += "  </Row>"
            out += options.lineEnding
        }
        out += "</Results>"
        out += options.lineEnding
        return out
    }

    /// Column names such as "Order Total" or "2024" are not valid XML names, so fold them
    /// into something a parser accepts while staying recognisable.
    private static func xmlElementName(_ name: String) -> String {
        var out = ""
        for (offset, scalar) in name.unicodeScalars.enumerated() {
            let isFirst = offset == 0
            if scalar.isXMLNameStart || (!isFirst && scalar.isXMLNameFollow) {
                out.unicodeScalars.append(scalar)
            } else {
                out += "_"
            }
        }
        if out.isEmpty { return "Column" }
        if let first = out.unicodeScalars.first, !first.isXMLNameStart { out = "_" + out }
        if out.count >= 3, out.prefix(3).lowercased() == "xml" { out = "_" + out }
        return out
    }

    private static func xmlEscape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count + 8)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            default:
                // XML 1.0 forbids most control characters outright.
                if scalar.value < 0x20 && scalar != "\t" && scalar != "\n" && scalar != "\r" {
                    out += " "
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out
    }

    // MARK: - Markdown

    private func markdown(headers: [String], rows: [[TDSValue]], options: ExportOptions) -> String {
        var out = ""
        if options.includeHeaders {
            out += "| " + headers.map { Self.markdownCell($0) }.joined(separator: " | ") + " |"
            out += options.lineEnding
            out += "| " + headers.map { _ in "---" }.joined(separator: " | ") + " |"
            out += options.lineEnding
        }
        for row in rows {
            let cells = (0..<headers.count).map { index in
                Self.markdownCell(Self.text(Self.value(row, index), options: options))
            }
            out += "| " + cells.joined(separator: " | ") + " |"
            out += options.lineEnding
        }
        return out
    }

    private static func markdownCell(_ text: String) -> String {
        var out = text.replacingOccurrences(of: "\\", with: "\\\\")
        out = out.replacingOccurrences(of: "|", with: "\\|")
        out = out.replacingOccurrences(of: "\r\n", with: "<br>")
        out = out.replacingOccurrences(of: "\n", with: "<br>")
        out = out.replacingOccurrences(of: "\r", with: "<br>")
        return out
    }

    // MARK: - HTML

    private func html(headers: [String], rows: [[TDSValue]], options: ExportOptions) -> String {
        let end = options.lineEnding
        let title = Self.xmlEscape(options.tableName.isEmpty ? "Results" : options.tableName)
        var out = "<!DOCTYPE html>" + end
        out += "<html lang=\"en\">" + end
        out += "<head>" + end
        out += "<meta charset=\"\(Self.charsetName(options.encoding))\">" + end
        out += "<title>\(title)</title>" + end
        out += """
        <style>
        :root { color-scheme: light dark; }
        body { font: 13px -apple-system, "Helvetica Neue", Arial, sans-serif; margin: 24px; }
        h1 { font-size: 17px; font-weight: 600; margin: 0 0 12px; }
        table { border-collapse: collapse; width: 100%; }
        th, td { border: 1px solid #c8c8c8; padding: 4px 8px; text-align: left;
                 white-space: pre-wrap; vertical-align: top; }
        th { background: #ececec; font-weight: 600; position: sticky; top: 0; }
        tbody tr:nth-child(even) { background: rgba(127,127,127,0.08); }
        td.num { text-align: right; font-variant-numeric: tabular-nums; }
        td.null { color: #888; font-style: italic; }
        p.meta { color: #888; margin-top: 12px; }
        </style>
        """
        out += end + "</head>" + end + "<body>" + end
        out += "<h1>\(title)</h1>" + end
        out += "<table>" + end
        if options.includeHeaders {
            out += "<thead><tr>"
            for header in headers { out += "<th>" + Self.xmlEscape(header) + "</th>" }
            out += "</tr></thead>" + end
        }
        out += "<tbody>" + end
        for row in rows {
            out += "<tr>"
            for index in 0..<headers.count {
                let value = Self.value(row, index)
                if value.isNull {
                    out += "<td class=\"null\">" + Self.xmlEscape(options.nullText) + "</td>"
                } else {
                    let cssClass = Self.isNumeric(value) ? " class=\"num\"" : ""
                    out += "<td\(cssClass)>" + Self.xmlEscape(value.displayString()) + "</td>"
                }
            }
            out += "</tr>" + end
        }
        out += "</tbody>" + end + "</table>" + end
        out += "<p class=\"meta\">\(rows.count) row\(rows.count == 1 ? "" : "s")</p>" + end
        out += "</body>" + end + "</html>" + end
        return out
    }

    private static func isNumeric(_ value: TDSValue) -> Bool {
        switch value {
        case .int, .double, .float, .decimal: return true
        default: return false
        }
    }

    // MARK: - INSERT statements

    private func sqlInsert(headers: [String], rows: [[TDSValue]], options: ExportOptions) -> String {
        let end = options.lineEnding
        let target = Self.quotedTarget(options.tableName)
        let columnList = headers.map { SQLIdentifier.quote($0) }.joined(separator: ", ")
        guard !rows.isEmpty else {
            return "-- No rows to script for \(target)." + end
        }
        // The VALUES table constructor tops out at 1000 rows per statement.
        let perStatement = max(1, min(options.batchSize <= 0 ? 1000 : options.batchSize, 1000))
        var out = ""
        var index = 0
        while index < rows.count {
            let upper = min(index + perStatement, rows.count)
            out += "INSERT INTO \(target) (\(columnList)) VALUES" + end
            for rowIndex in index..<upper {
                let row = rows[rowIndex]
                let literals = (0..<headers.count)
                    .map { Self.value(row, $0).sqlLiteral }
                    .joined(separator: ", ")
                out += "    (" + literals + ")"
                out += rowIndex == upper - 1 ? ";" : ","
                out += end
            }
            out += "GO" + end
            index = upper
            if index < rows.count { out += end }
        }
        return out
    }

    /// Accepts "Table", "dbo.Table" and "db.dbo.Table" and quotes every part.
    private static func quotedTarget(_ name: String) -> String {
        let raw = name.isEmpty ? "Results" : name
        guard !raw.contains("[") && !raw.contains("]") else { return raw }
        let parts = raw.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count > 1, parts.allSatisfy({ !$0.isEmpty }), parts.count <= 3 else {
            return SQLIdentifier.quote(raw)
        }
        return parts.map { SQLIdentifier.quote($0) }.joined(separator: ".")
    }

    // MARK: - Shared helpers

    private static func value(_ row: [TDSValue], _ index: Int) -> TDSValue {
        index >= 0 && index < row.count ? row[index] : .null
    }

    /// Flat-format cell text. `displayString` already renders binary as 0x hex, dates in
    /// full server precision and decimals without a Double round trip.
    private static func text(_ value: TDSValue, options: ExportOptions) -> String {
        value.displayString(nullText: options.nullText)
    }

    private static func headerNames(_ columns: [TDSColumn]) -> [String] {
        var used = Set<String>()
        var names: [String] = []
        names.reserveCapacity(columns.count)
        for (offset, column) in columns.enumerated() {
            let base = column.name.isEmpty ? "Column\(offset + 1)" : column.name
            var candidate = base
            var suffix = 1
            while !used.insert(candidate.lowercased()).inserted {
                suffix += 1
                candidate = "\(base)_\(suffix)"
            }
            names.append(candidate)
        }
        return names
    }

    private static func charsetName(_ encoding: String.Encoding) -> String {
        switch encoding {
        case .utf8: return "utf-8"
        case .utf16, .utf16LittleEndian, .utf16BigEndian: return "utf-16"
        case .utf32, .utf32LittleEndian, .utf32BigEndian: return "utf-32"
        case .isoLatin1: return "iso-8859-1"
        case .windowsCP1252: return "windows-1252"
        case .ascii: return "us-ascii"
        default: return "utf-8"
        }
    }

    private static func encode(_ text: String, options: ExportOptions) throws -> Data {
        guard var data = text.data(using: options.encoding, allowLossyConversion: true) else {
            throw SQLServerError.unsupportedOperation(
                "The result set cannot be written in the selected text encoding.")
        }
        // Foundation already prefixes a BOM for the endianness-free .utf16/.utf32 encodings.
        if options.writeByteOrderMark, let bom = byteOrderMark(options.encoding) {
            data = bom + data
        }
        return data
    }

    private static func byteOrderMark(_ encoding: String.Encoding) -> Data? {
        switch encoding {
        case .utf8: return Data([0xEF, 0xBB, 0xBF])
        case .utf16LittleEndian: return Data([0xFF, 0xFE])
        case .utf16BigEndian: return Data([0xFE, 0xFF])
        case .utf32LittleEndian: return Data([0xFF, 0xFE, 0x00, 0x00])
        case .utf32BigEndian: return Data([0x00, 0x00, 0xFE, 0xFF])
        default: return nil
        }
    }
}

// MARK: - Scalar helpers

private extension Unicode.Scalar {
    var isASCIIDigit: Bool { value >= 48 && value <= 57 }

    /// XML 1.0 NameStartChar, restricted to the ranges that matter for column names.
    var isXMLNameStart: Bool {
        if self == "_" || self == ":" { return true }
        if (value >= 65 && value <= 90) || (value >= 97 && value <= 122) { return true }
        switch value {
        case 0xC0...0xD6, 0xD8...0xF6, 0xF8...0x2FF, 0x370...0x37D, 0x37F...0x1FFF,
             0x200C...0x200D, 0x2070...0x218F, 0x2C00...0x2FEF, 0x3001...0xD7FF,
             0xF900...0xFDCF, 0xFDF0...0xFFFD, 0x10000...0xEFFFF:
            return true
        default:
            return false
        }
    }

    var isXMLNameFollow: Bool {
        if isXMLNameStart { return true }
        if isASCIIDigit { return true }
        if self == "-" || self == "." { return true }
        return value == 0xB7 || (value >= 0x300 && value <= 0x36F)
            || (value >= 0x203F && value <= 0x2040)
    }
}
