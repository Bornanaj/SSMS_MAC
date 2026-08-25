import Foundation
import TDSKit

/// One source column and where it lands in the target table.
public struct ImportColumnMapping: Sendable, Hashable, Identifiable {
    public var id: Int { sourceIndex }
    public var sourceIndex: Int
    public var sourceName: String
    public var targetName: String
    public var sqlType: String
    public var isNullable: Bool
    public var include: Bool

    public init(sourceIndex: Int, sourceName: String, targetName: String,
                sqlType: String, isNullable: Bool, include: Bool = true) {
        self.sourceIndex = sourceIndex
        self.sourceName = sourceName
        self.targetName = targetName
        self.sqlType = sqlType
        self.isNullable = isNullable
        self.include = include
    }
}

/// What the import wizard shows before anything is written to the server.
public struct ImportPreview: Sendable {
    public var detectedDelimiter: String
    public var hasHeaderRow: Bool
    public var columns: [ImportColumnMapping]
    public var sampleRows: [[String]]
    public var estimatedRowCount: Int
    public var encodingName: String

    public init(detectedDelimiter: String, hasHeaderRow: Bool, columns: [ImportColumnMapping],
                sampleRows: [[String]], estimatedRowCount: Int, encodingName: String) {
        self.detectedDelimiter = detectedDelimiter
        self.hasHeaderRow = hasHeaderRow
        self.columns = columns
        self.sampleRows = sampleRows
        self.estimatedRowCount = estimatedRowCount
        self.encodingName = encodingName
    }
}

/// The "Import Flat File" wizard: sniff the file, propose a table, then load it.
public struct FlatFileImporter: Sendable {

    private let session: SQLServerSession

    public init(session: SQLServerSession) {
        self.session = session
    }

    // MARK: - Preview

    public func preview(url: URL, sampleRows: Int = 100) throws -> ImportPreview {
        let (text, encodingName) = try FlatFileImporter.readText(at: url)
        let delimiter = FlatFileImporter.sniffDelimiter(in: text)
        var rows = CSVParser.parse(text, delimiter: Character(delimiter), limit: sampleRows + 1)
        guard !rows.isEmpty else {
            throw SQLServerError.unsupportedOperation("The file is empty or could not be parsed.")
        }

        let hasHeader = FlatFileImporter.looksLikeHeader(rows[0], following: Array(rows.dropFirst()))
        let header = hasHeader ? rows.removeFirst() : []
        let columnCount = rows.map(\.count).max() ?? header.count

        var mappings: [ImportColumnMapping] = []
        for index in 0..<columnCount {
            let sourceName = index < header.count && !header[index].isEmpty
                ? header[index]
                : "Column \(index + 1)"
            let samples = rows.compactMap { index < $0.count ? $0[index] : nil }
            let inferred = FlatFileImporter.inferType(samples)
            mappings.append(ImportColumnMapping(
                sourceIndex: index,
                sourceName: sourceName,
                targetName: FlatFileImporter.sanitiseColumnName(sourceName),
                sqlType: inferred.type,
                isNullable: inferred.nullable
            ))
        }

        // A byte-per-line estimate is good enough for a progress bar.
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let byteCount = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        let sampleBytes = text.utf8.count
        let sampledLines = max(rows.count, 1)
        let estimated = sampleBytes > 0 && byteCount > 0
            ? Int(Double(byteCount) / Double(sampleBytes) * Double(sampledLines))
            : sampledLines

        return ImportPreview(detectedDelimiter: delimiter,
                             hasHeaderRow: hasHeader,
                             columns: mappings,
                             sampleRows: Array(rows.prefix(sampleRows)),
                             estimatedRowCount: max(estimated, sampledLines),
                             encodingName: encodingName)
    }

    // MARK: - Scripting and loading

    public func createTableScript(database: String, schema: String, table: String,
                                  mappings: [ImportColumnMapping]) -> String {
        let included = mappings.filter(\.include)
        let columns = included.map { mapping in
            "\t\(SQLIdentifier.quote(mapping.targetName)) \(mapping.sqlType) "
                + (mapping.isNullable ? "NULL" : "NOT NULL")
        }.joined(separator: ",\n")
        return "CREATE TABLE \(SQLIdentifier.quote(schema: schema, name: table)) (\n\(columns)\n);\n"
    }

    @discardableResult
    public func importFile(url: URL, database: String, schema: String, table: String,
                           preview: ImportPreview, createTable: Bool, truncateFirst: Bool,
                           batchSize: Int = 500,
                           progress: @escaping @Sendable (Double, Int) -> Void) async throws -> Int {
        let (text, _) = try FlatFileImporter.readText(at: url)
        var rows = CSVParser.parse(text, delimiter: Character(preview.detectedDelimiter), limit: 0)
        if preview.hasHeaderRow, !rows.isEmpty { rows.removeFirst() }

        let included = preview.columns.filter(\.include)
        guard !included.isEmpty else {
            throw SQLServerError.unsupportedOperation("No columns were selected for import.")
        }

        let connection = try await session.openConnection(database: database)
        defer { Task { try? await connection.close() } }

        let target = SQLIdentifier.quote(schema: schema, name: table)
        if createTable {
            _ = try await connection.query(
                createTableScript(database: database, schema: schema, table: table,
                                  mappings: preview.columns))
        }
        if truncateFirst {
            _ = try await connection.query("TRUNCATE TABLE \(target);")
        }

        let columnList = included.map { SQLIdentifier.quote($0.targetName) }.joined(separator: ", ")
        let effectiveBatch = max(1, min(batchSize, 1000))
        var imported = 0
        var index = 0

        while index < rows.count {
            let end = min(index + effectiveBatch, rows.count)
            var tuples: [String] = []
            tuples.reserveCapacity(end - index)

            for row in rows[index..<end] {
                let values = included.map { mapping -> String in
                    let raw = mapping.sourceIndex < row.count ? row[mapping.sourceIndex] : ""
                    return FlatFileImporter.literal(raw, sqlType: mapping.sqlType,
                                                    nullable: mapping.isNullable)
                }
                tuples.append("(" + values.joined(separator: ", ") + ")")
            }

            let statement = "INSERT INTO \(target) (\(columnList)) VALUES\n"
                + tuples.joined(separator: ",\n") + ";"
            _ = try await connection.query(statement)

            imported += end - index
            index = end
            progress(Double(imported) / Double(max(rows.count, 1)), imported)
        }

        return imported
    }

    // MARK: - File reading

    static func readText(at url: URL) throws -> (text: String, encodingName: String) {
        let data = try Data(contentsOf: url)

        // Honour a BOM when there is one; otherwise try UTF-8 then fall back to Windows-1252,
        // which is what most exported CSVs actually are.
        if data.count >= 2, data[0] == 0xFF, data[1] == 0xFE {
            let body = data.dropFirst(2)
            if let text = String(data: body, encoding: .utf16LittleEndian) {
                return (text, "UTF-16 LE")
            }
        }
        if data.count >= 2, data[0] == 0xFE, data[1] == 0xFF {
            let body = data.dropFirst(2)
            if let text = String(data: body, encoding: .utf16BigEndian) {
                return (text, "UTF-16 BE")
            }
        }
        if data.count >= 3, data[0] == 0xEF, data[1] == 0xBB, data[2] == 0xBF {
            let body = data.dropFirst(3)
            if let text = String(data: body, encoding: .utf8) { return (text, "UTF-8") }
        }
        if let text = String(data: data, encoding: .utf8) { return (text, "UTF-8") }
        if let text = String(data: data, encoding: .windowsCP1252) { return (text, "Windows-1252") }
        if let text = String(data: data, encoding: .isoLatin1) { return (text, "ISO-8859-1") }
        throw SQLServerError.unsupportedOperation("The file's text encoding could not be determined.")
    }

    /// Pick the delimiter that yields the most consistent field count across sample lines.
    static func sniffDelimiter(in text: String) -> String {
        let candidates = [",", ";", "\t", "|"]
        let lines = text.split(separator: "\n", maxSplits: 20, omittingEmptySubsequences: true)
            .prefix(20)
            .map(String.init)
        guard !lines.isEmpty else { return "," }

        var best = ","
        var bestScore = -1.0
        for candidate in candidates {
            let counts = lines.map { line -> Int in
                CSVParser.parse(line, delimiter: Character(candidate), limit: 1).first?.count ?? 0
            }
            guard let first = counts.first, first > 1 else { continue }
            let consistent = counts.filter { $0 == first }.count
            // Prefer consistency, then a higher field count as the tie-break.
            let score = Double(consistent) / Double(counts.count) * 100 + Double(first)
            if score > bestScore {
                bestScore = score
                best = candidate
            }
        }
        return best
    }

    /// A first row is a header when it is all non-numeric and the rows below are not.
    static func looksLikeHeader(_ first: [String], following rows: [[String]]) -> Bool {
        guard !first.isEmpty else { return false }
        let firstLooksTextual = first.allSatisfy { field in
            let trimmed = field.trimmingCharacters(in: .whitespaces)
            return !trimmed.isEmpty && Double(trimmed) == nil
        }
        guard firstLooksTextual else { return false }
        guard let sample = rows.first else { return true }
        // If the following row is also entirely textual we still assume a header,
        // because that is by far the more common shape for exported files.
        return sample.count == first.count
    }

    static func sanitiseColumnName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Column" }
        let cleaned = trimmed.map { character -> Character in
            character.isLetter || character.isNumber || character == "_" ? character : "_"
        }
        var result = String(cleaned)
        if let first = result.first, first.isNumber { result = "_" + result }
        return String(result.prefix(128))
    }

    // MARK: - Type inference

    static func inferType(_ samples: [String]) -> (type: String, nullable: Bool) {
        let values = samples.map { $0.trimmingCharacters(in: .whitespaces) }
        let nonEmpty = values.filter { !$0.isEmpty && $0.uppercased() != "NULL" }
        let nullable = nonEmpty.count != values.count

        guard !nonEmpty.isEmpty else { return ("nvarchar(255)", true) }

        if nonEmpty.allSatisfy({ ["0", "1", "true", "false"].contains($0.lowercased()) }) {
            return ("bit", nullable)
        }
        if nonEmpty.allSatisfy({ Int32($0) != nil }) { return ("int", nullable) }
        if nonEmpty.allSatisfy({ Int64($0) != nil }) { return ("bigint", nullable) }
        if nonEmpty.allSatisfy({ isDecimal($0) }) {
            let (precision, scale) = decimalShape(nonEmpty)
            return ("decimal(\(precision),\(scale))", nullable)
        }
        if nonEmpty.allSatisfy({ UUID(uuidString: $0) != nil }) {
            return ("uniqueidentifier", nullable)
        }
        if nonEmpty.allSatisfy({ looksLikeDate($0) }) { return ("date", nullable) }
        if nonEmpty.allSatisfy({ looksLikeDateTime($0) }) { return ("datetime2(3)", nullable) }

        let longest = nonEmpty.map(\.count).max() ?? 0
        switch longest {
        case 0...50: return ("nvarchar(50)", nullable)
        case 51...100: return ("nvarchar(100)", nullable)
        case 101...255: return ("nvarchar(255)", nullable)
        case 256...4000: return ("nvarchar(4000)", nullable)
        default: return ("nvarchar(max)", nullable)
        }
    }

    private static func isDecimal(_ value: String) -> Bool {
        guard Double(value) != nil else { return false }
        let body = value.hasPrefix("-") || value.hasPrefix("+") ? String(value.dropFirst()) : value
        return body.allSatisfy { $0.isNumber || $0 == "." } && body.filter { $0 == "." }.count <= 1
    }

    private static func decimalShape(_ values: [String]) -> (precision: Int, scale: Int) {
        var maxIntegerDigits = 1
        var maxScale = 0
        for value in values {
            let body = value.hasPrefix("-") || value.hasPrefix("+") ? String(value.dropFirst()) : value
            let parts = body.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
            maxIntegerDigits = max(maxIntegerDigits, parts.first?.count ?? 1)
            if parts.count > 1 { maxScale = max(maxScale, parts[1].count) }
        }
        let precision = min(38, maxIntegerDigits + maxScale)
        return (max(precision, 1), min(maxScale, precision))
    }

    private static func looksLikeDate(_ value: String) -> Bool {
        let patterns = ["yyyy-MM-dd", "yyyy/MM/dd", "MM/dd/yyyy", "dd/MM/yyyy", "dd.MM.yyyy"]
        return matches(value, patterns: patterns)
    }

    private static func looksLikeDateTime(_ value: String) -> Bool {
        let patterns = ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm",
                        "MM/dd/yyyy HH:mm:ss", "yyyy-MM-dd HH:mm:ss.SSS"]
        return matches(value, patterns: patterns)
    }

    private static func matches(_ value: String, patterns: [String]) -> Bool {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        for pattern in patterns {
            formatter.dateFormat = pattern
            if formatter.date(from: value) != nil { return true }
        }
        return false
    }

    /// Build the T-SQL literal for one field, letting the server do the final conversion.
    static func literal(_ raw: String, sqlType: String, nullable: Bool) -> String {
        let value = raw.trimmingCharacters(in: .whitespaces)
        if value.isEmpty || value.uppercased() == "NULL" {
            return nullable ? "NULL" : "''"
        }
        let lowered = sqlType.lowercased()
        if lowered == "bit" {
            let truthy = ["1", "true", "yes", "y", "t"].contains(value.lowercased())
            return truthy ? "1" : "0"
        }
        if lowered.hasPrefix("int") || lowered.hasPrefix("bigint") || lowered.hasPrefix("smallint")
            || lowered.hasPrefix("tinyint") || lowered.hasPrefix("decimal")
            || lowered.hasPrefix("numeric") || lowered.hasPrefix("float") || lowered.hasPrefix("real") {
            // Guard against a stray non-numeric value slipping past inference.
            return Double(value) != nil ? value : "NULL"
        }
        return SQLIdentifier.literal(value)
    }
}

/// RFC 4180 CSV reader that keeps quoted fields containing delimiters and newlines intact.
enum CSVParser {

    /// `limit` of 0 means "read every row".
    static func parse(_ text: String, delimiter: Character, limit: Int) -> [[String]] {
        var rows: [[String]] = []
        var field = ""
        var row: [String] = []
        var inQuotes = false

        let characters = Array(text)
        var index = 0
        let count = characters.count

        while index < count {
            let character = characters[index]

            if inQuotes {
                if character == "\"" {
                    if index + 1 < count, characters[index + 1] == "\"" {
                        field.append("\"")
                        index += 2
                        continue
                    }
                    inQuotes = false
                    index += 1
                    continue
                }
                field.append(character)
                index += 1
                continue
            }

            switch character {
            case "\"":
                inQuotes = true
                index += 1
            case delimiter:
                row.append(field)
                field = ""
                index += 1
            case "\r":
                index += 1
            case "\n":
                row.append(field)
                rows.append(row)
                field = ""
                row = []
                index += 1
                if limit > 0 && rows.count >= limit { return rows }
            default:
                field.append(character)
                index += 1
            }
        }

        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows
    }
}
