import Foundation

// MARK: - Workbook writer

/// Minimal SpreadsheetML writer: one worksheet, inline strings, a bold header row.
/// Inline strings avoid a shared string table, which keeps memory flat for wide exports
/// and still opens in Excel, Numbers and LibreOffice.
public struct XlsxWriter {

    private let sheetName: String
    private var rowsXML: String = ""
    private var rowCount: Int = 0
    private var columnWidths: [Int] = []
    private var hasHeaderRow = false

    public init(sheetName: String) {
        self.sheetName = XlsxWriter.sanitizedSheetName(sheetName)
    }

    /// Appends a bold header row (skipped when `columns` is empty) followed by the data rows.
    /// Can be called repeatedly to stream a large result set in chunks.
    public mutating func write(columns: [String], rows: [[String]]) {
        if !columns.isEmpty {
            if rowCount == 0 { hasHeaderRow = true }
            append(cells: columns, styleIndex: 1, forceText: true)
        }
        for row in rows {
            append(cells: row, styleIndex: 0, forceText: false)
        }
    }

    public func data() throws -> Data {
        var archive = XlsxZipArchive()
        try archive.add(path: "[Content_Types].xml", text: XlsxWriter.contentTypesXML)
        try archive.add(path: "_rels/.rels", text: XlsxWriter.rootRelationshipsXML)
        try archive.add(path: "xl/workbook.xml", text: workbookXML)
        try archive.add(path: "xl/_rels/workbook.xml.rels", text: XlsxWriter.workbookRelationshipsXML)
        try archive.add(path: "xl/styles.xml", text: XlsxWriter.stylesXML)
        try archive.add(path: "xl/worksheets/sheet1.xml", text: worksheetXML)
        return try archive.finish()
    }

    // MARK: - Rows

    private mutating func append(cells: [String], styleIndex: Int, forceText: Bool) {
        rowCount += 1
        var xml = "<row r=\"\(rowCount)\">"
        let style = styleIndex == 0 ? "" : " s=\"\(styleIndex)\""
        for (index, cell) in cells.enumerated() {
            noteWidth(column: index, characters: cell.count)
            let reference = XlsxWriter.columnLetter(index) + String(rowCount)
            if cell.isEmpty {
                if !style.isEmpty { xml += "<c r=\"\(reference)\"\(style)/>" }
                continue
            }
            if !forceText, XlsxWriter.isSpreadsheetNumber(cell) {
                xml += "<c r=\"\(reference)\"\(style)><v>\(cell)</v></c>"
            } else {
                xml += "<c r=\"\(reference)\"\(style) t=\"inlineStr\"><is><t xml:space=\"preserve\">"
                xml += XlsxWriter.escape(cell)
                xml += "</t></is></c>"
            }
        }
        xml += "</row>"
        rowsXML += xml
    }

    private mutating func noteWidth(column index: Int, characters: Int) {
        while columnWidths.count <= index { columnWidths.append(0) }
        if characters > columnWidths[index] { columnWidths[index] = min(characters, 80) }
    }

    /// Excel stores anything that is not a plain, round-trippable number as text. Values with
    /// more than 15 significant digits stay text so 38 digit decimals are not truncated.
    private static func isSpreadsheetNumber(_ text: String) -> Bool {
        let scalars = Array(text.unicodeScalars)
        guard !scalars.isEmpty, scalars.count <= 17 else { return false }
        var index = 0
        if scalars[index] == "-" { index += 1 }
        var integerDigits = 0
        while index < scalars.count, scalars[index].value >= 48, scalars[index].value <= 57 {
            index += 1
            integerDigits += 1
        }
        guard integerDigits > 0 else { return false }
        // Leading zeros are meaningful in identifiers such as zip codes, so keep them as text.
        let signOffset = scalars[0] == "-" ? 1 : 0
        if integerDigits > 1, scalars[signOffset] == "0" { return false }
        var fractionDigits = 0
        if index < scalars.count, scalars[index] == "." {
            index += 1
            while index < scalars.count, scalars[index].value >= 48, scalars[index].value <= 57 {
                index += 1
                fractionDigits += 1
            }
            guard fractionDigits > 0 else { return false }
        }
        guard index == scalars.count else { return false }
        return integerDigits + fractionDigits <= 15
    }

    private static func columnLetter(_ index: Int) -> String {
        var remaining = index + 1
        var letters = ""
        while remaining > 0 {
            let digit = (remaining - 1) % 26
            letters = String(UnicodeScalar(UInt8(65 + digit))) + letters
            remaining = (remaining - 1) / 26
        }
        return letters.isEmpty ? "A" : letters
    }

    /// Excel rejects these characters in a sheet name and truncates at 31 characters.
    private static func sanitizedSheetName(_ name: String) -> String {
        let forbidden = CharacterSet(charactersIn: "[]:*?/\\")
        var cleaned = String(name.unicodeScalars.map {
            forbidden.contains($0) ? Character(" ") : Character($0)
        })
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.count > 31 { cleaned = String(cleaned.prefix(31)) }
        while cleaned.hasPrefix("'") { cleaned.removeFirst() }
        while cleaned.hasSuffix("'") { cleaned.removeLast() }
        return cleaned.isEmpty ? "Sheet1" : cleaned
    }

    private static func escape(_ text: String) -> String {
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
                // Control characters other than tab/CR/LF are illegal in XML 1.0.
                if scalar.value < 0x20 && scalar != "\t" && scalar != "\n" && scalar != "\r" {
                    out += " "
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out
    }

    // MARK: - Parts

    private var worksheetXML: String {
        var xml = XlsxWriter.xmlDeclaration
        xml += "<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\">"
        if rowCount > 0 && !columnWidths.isEmpty {
            let lastColumn = XlsxWriter.columnLetter(columnWidths.count - 1)
            xml += "<dimension ref=\"A1:\(lastColumn)\(rowCount)\"/>"
        }
        xml += "<sheetViews><sheetView workbookViewId=\"0\">"
        if hasHeaderRow {
            xml += "<pane ySplit=\"1\" topLeftCell=\"A2\" activePane=\"bottomLeft\" state=\"frozen\"/>"
        }
        xml += "</sheetView></sheetViews>"
        xml += "<sheetFormatPr defaultRowHeight=\"15\"/>"
        if !columnWidths.isEmpty {
            xml += "<cols>"
            for (index, characters) in columnWidths.enumerated() {
                let width = min(80.0, max(8.0, Double(characters) + 2.0))
                let rounded = (width * 100).rounded() / 100
                xml += "<col min=\"\(index + 1)\" max=\"\(index + 1)\" width=\"\(rounded)\""
                xml += " customWidth=\"1\"/>"
            }
            xml += "</cols>"
        }
        xml += "<sheetData>" + rowsXML + "</sheetData>"
        xml += "</worksheet>"
        return xml
    }

    private var workbookXML: String {
        var xml = XlsxWriter.xmlDeclaration
        xml += "<workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\""
        xml += " xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\">"
        xml += "<sheets><sheet name=\"\(XlsxWriter.escape(sheetName))\" sheetId=\"1\" r:id=\"rId1\"/></sheets>"
        xml += "</workbook>"
        return xml
    }

    private static let xmlDeclaration = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"

    private static let contentTypesXML: String = {
        var xml = XlsxWriter.xmlDeclaration
        xml += "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">"
        xml += "<Default Extension=\"rels\""
        xml += " ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>"
        xml += "<Default Extension=\"xml\" ContentType=\"application/xml\"/>"
        xml += "<Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd."
        xml += "openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/>"
        xml += "<Override PartName=\"/xl/worksheets/sheet1.xml\" ContentType=\"application/vnd."
        xml += "openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>"
        xml += "<Override PartName=\"/xl/styles.xml\" ContentType=\"application/vnd."
        xml += "openxmlformats-officedocument.spreadsheetml.styles+xml\"/>"
        xml += "</Types>"
        return xml
    }()

    private static let rootRelationshipsXML: String = {
        var xml = XlsxWriter.xmlDeclaration
        xml += "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
        xml += "<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/"
        xml += "2006/relationships/officeDocument\" Target=\"xl/workbook.xml\"/>"
        xml += "</Relationships>"
        return xml
    }()

    private static let workbookRelationshipsXML: String = {
        var xml = XlsxWriter.xmlDeclaration
        xml += "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
        xml += "<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/"
        xml += "2006/relationships/worksheet\" Target=\"worksheets/sheet1.xml\"/>"
        xml += "<Relationship Id=\"rId2\" Type=\"http://schemas.openxmlformats.org/officeDocument/"
        xml += "2006/relationships/styles\" Target=\"styles.xml\"/>"
        xml += "</Relationships>"
        return xml
    }()

    /// Style 0 is the default cell, style 1 is the bold header.
    private static let stylesXML: String = {
        var xml = XlsxWriter.xmlDeclaration
        xml += "<styleSheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\">"
        xml += "<fonts count=\"2\">"
        xml += "<font><sz val=\"11\"/><color rgb=\"FF000000\"/><name val=\"Calibri\"/><family val=\"2\"/></font>"
        xml += "<font><b/><sz val=\"11\"/><color rgb=\"FF000000\"/><name val=\"Calibri\"/>"
        xml += "<family val=\"2\"/></font>"
        xml += "</fonts>"
        xml += "<fills count=\"2\">"
        xml += "<fill><patternFill patternType=\"none\"/></fill>"
        xml += "<fill><patternFill patternType=\"gray125\"/></fill>"
        xml += "</fills>"
        xml += "<borders count=\"1\"><border><left/><right/><top/><bottom/><diagonal/></border></borders>"
        xml += "<cellStyleXfs count=\"1\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\"/>"
        xml += "</cellStyleXfs>"
        xml += "<cellXfs count=\"2\">"
        xml += "<xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\" xfId=\"0\"/>"
        xml += "<xf numFmtId=\"0\" fontId=\"1\" fillId=\"0\" borderId=\"0\" xfId=\"0\" applyFont=\"1\"/>"
        xml += "</cellXfs>"
        xml += "<cellStyles count=\"1\"><cellStyle name=\"Normal\" xfId=\"0\" builtinId=\"0\"/></cellStyles>"
        xml += "</styleSheet>"
        return xml
    }()
}

// MARK: - Store-only ZIP container

/// Just enough of the ZIP format for an OPC package: no compression, one central directory,
/// no ZIP64. Deflate would need an external dependency, and store-only is universally readable.
private struct XlsxZipArchive {

    private struct Entry {
        var path: String
        var crc: UInt32
        var size: UInt32
        var offset: UInt32
    }

    private var payload = Data()
    private var entries: [Entry] = []
    private let timestamp = XlsxZipArchive.dosTimestamp()

    mutating func add(path: String, text: String) throws {
        let bytes = Data(text.utf8)
        guard payload.count + bytes.count < Int(UInt32.max) - 0x10000 else {
            throw SQLServerError.unsupportedOperation(
                "The workbook exceeds the 4 GB limit of the ZIP container.")
        }
        let name = Data(path.utf8)
        let crc = XlsxZipArchive.crc32(bytes)
        let entry = Entry(path: path, crc: crc, size: UInt32(bytes.count),
                          offset: UInt32(payload.count))

        payload.appendLittle(UInt32(0x0403_4B50))
        payload.appendLittle(UInt16(20))                 // version needed
        payload.appendLittle(UInt16(0x0800))             // UTF-8 file names
        payload.appendLittle(UInt16(0))                  // stored
        payload.appendLittle(timestamp.time)
        payload.appendLittle(timestamp.date)
        payload.appendLittle(crc)
        payload.appendLittle(entry.size)
        payload.appendLittle(entry.size)
        payload.appendLittle(UInt16(name.count))
        payload.appendLittle(UInt16(0))                  // extra field length
        payload.append(name)
        payload.append(bytes)

        entries.append(entry)
    }

    func finish() throws -> Data {
        var archive = payload
        let directoryOffset = archive.count
        for entry in entries {
            let name = Data(entry.path.utf8)
            archive.appendLittle(UInt32(0x0201_4B50))
            archive.appendLittle(UInt16(20))             // version made by
            archive.appendLittle(UInt16(20))             // version needed
            archive.appendLittle(UInt16(0x0800))
            archive.appendLittle(UInt16(0))
            archive.appendLittle(timestamp.time)
            archive.appendLittle(timestamp.date)
            archive.appendLittle(entry.crc)
            archive.appendLittle(entry.size)
            archive.appendLittle(entry.size)
            archive.appendLittle(UInt16(name.count))
            archive.appendLittle(UInt16(0))              // extra field length
            archive.appendLittle(UInt16(0))              // comment length
            archive.appendLittle(UInt16(0))              // disk number start
            archive.appendLittle(UInt16(0))              // internal attributes
            archive.appendLittle(UInt32(0))              // external attributes
            archive.appendLittle(entry.offset)
            archive.append(name)
        }
        let directorySize = archive.count - directoryOffset
        guard archive.count < Int(UInt32.max) else {
            throw SQLServerError.unsupportedOperation(
                "The workbook exceeds the 4 GB limit of the ZIP container.")
        }
        archive.appendLittle(UInt32(0x0605_4B50))
        archive.appendLittle(UInt16(0))                  // this disk
        archive.appendLittle(UInt16(0))                  // disk with central directory
        archive.appendLittle(UInt16(entries.count))
        archive.appendLittle(UInt16(entries.count))
        archive.appendLittle(UInt32(directorySize))
        archive.appendLittle(UInt32(directoryOffset))
        archive.appendLittle(UInt16(0))                  // comment length
        return archive
    }

    // MARK: CRC32

    private static let crcTable: [UInt32] = {
        (0..<256).map { index -> UInt32 in
            var value = UInt32(index)
            for _ in 0..<8 {
                value = (value & 1) == 1 ? (value >> 1) ^ 0xEDB8_8320 : value >> 1
            }
            return value
        }
    }()

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            let index = Int((crc ^ UInt32(byte)) & 0xFF)
            crc = (crc >> 8) ^ crcTable[index]
        }
        return crc ^ 0xFFFF_FFFF
    }

    // MARK: MS-DOS timestamp

    private static func dosTimestamp() -> (time: UInt16, date: UInt16) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second],
                                            from: Date())
        // Each field is bound to an explicitly typed local. Folding the shifts into one
        // expression is valid Swift but pushes the type checker past its budget on some
        // toolchains, which fails the build rather than merely slowing it down.
        let year: Int = max(1980, parts.year ?? 1980)
        let month: Int = parts.month ?? 1
        let day: Int = parts.day ?? 1
        let hour: Int = parts.hour ?? 0
        let minute: Int = parts.minute ?? 0
        let second: Int = parts.second ?? 0

        let packedTime: Int = (hour << 11) | (minute << 5) | (second / 2)
        let packedDate: Int = ((year - 1980) << 9) | (month << 5) | day
        return (UInt16(truncatingIfNeeded: packedTime), UInt16(truncatingIfNeeded: packedDate))
    }
}

private extension Data {
    mutating func appendLittle(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }

    mutating func appendLittle(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }
}
