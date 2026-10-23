import Foundation

/// File name tags: `<AUTO>`, `<DATABASE>`, `<INSTANCE>`, `<SERVER>`, `<AVAILABILITYGROUP>`,
/// `<TYPE>` and `<DATETIME format>`, with the date format written the way SQL Backup users write
/// it (`yyyymmdd_hhnnss`: `nn` is minutes, and `mm` straight after `hh` is minutes too).
///
/// One-off backups expand the tags here. Scheduled jobs cannot, because the date and the
/// database are only known when the job runs, so `sqlExpression` compiles the same format into
/// T-SQL that builds the name inside the job step.
public enum BackupFileNaming {

    public static let defaultDateFormat = "yyyymmdd_hhnnss"

    public struct Context: Sendable {
        public var database: String
        public var type: BackupType
        public var instance: String
        public var server: String
        public var availabilityGroup: String
        public var date: Date
        public var defaultFormat: String

        public init(database: String, type: BackupType, instance: String, server: String,
                    availabilityGroup: String = "", date: Date,
                    defaultFormat: String = BackupOptions.defaultFileNameFormat) {
            self.database = database
            self.type = type
            self.instance = instance
            self.server = server
            self.availabilityGroup = availabilityGroup
            self.date = date
            self.defaultFormat = defaultFormat
        }
    }

    // MARK: - Tokens

    enum Piece: Equatable {
        case literal(String)
        case database
        case instance
        case server
        case availabilityGroup
        case type
        case auto
        case date([DatePart])
    }

    enum DatePart: Equatable {
        case literal(String)
        case year4
        case year2
        case month
        case day
        case hour
        case minute
        case second
    }

    /// Splits a format into literal text and tags. Unknown `<…>` text stays literal.
    static func pieces(_ format: String) -> [Piece] {
        var result: [Piece] = []
        var literal = ""
        var index = format.startIndex
        while index < format.endIndex {
            if format[index] == "<", let close = format[index...].firstIndex(of: ">") {
                let body = String(format[format.index(after: index)..<close])
                if let piece = tag(body) {
                    if !literal.isEmpty { result.append(.literal(literal)); literal = "" }
                    result.append(piece)
                    index = format.index(after: close)
                    continue
                }
            }
            literal.append(format[index])
            index = format.index(after: index)
        }
        if !literal.isEmpty { result.append(.literal(literal)) }
        return result
    }

    private static func tag(_ body: String) -> Piece? {
        let trimmed = body.trimmingCharacters(in: .whitespaces)
        let upper = trimmed.uppercased()
        switch upper {
        case "DATABASE": return .database
        case "INSTANCE": return .instance
        case "SERVER": return .server
        case "AVAILABILITYGROUP": return .availabilityGroup
        case "TYPE": return .type
        case "AUTO": return .auto
        case "DATETIME": return .date(dateParts(defaultDateFormat))
        default:
            guard upper.hasPrefix("DATETIME ") else { return nil }
            let format = String(trimmed.dropFirst("DATETIME ".count)).trimmingCharacters(in: .whitespaces)
            return .date(dateParts(format.isEmpty ? defaultDateFormat : format))
        }
    }

    static func dateParts(_ format: String) -> [DatePart] {
        var parts: [DatePart] = []
        var literal = ""
        let characters: [Character] = Array(format)
        var index = 0
        var lastWasHour = false
        func flush() {
            if !literal.isEmpty { parts.append(.literal(literal)); literal = "" }
        }
        func run(_ character: Character) -> Int {
            var count = 0
            while index + count < characters.count,
                  characters[index + count].lowercased() == character.lowercased() { count += 1 }
            return count
        }
        while index < characters.count {
            let character = characters[index]
            let count = run(character)
            switch character.lowercased() {
            case "y" where count >= 4:
                flush(); parts.append(.year4); index += 4; lastWasHour = false
            case "y" where count >= 2:
                flush(); parts.append(.year2); index += 2; lastWasHour = false
            case "m" where count >= 2:
                flush(); parts.append(lastWasHour ? .minute : .month); index += 2; lastWasHour = false
            case "d" where count >= 2:
                flush(); parts.append(.day); index += 2; lastWasHour = false
            case "h" where count >= 2:
                flush(); parts.append(.hour); index += 2; lastWasHour = true
            case "n" where count >= 2:
                flush(); parts.append(.minute); index += 2; lastWasHour = false
            case "s" where count >= 2:
                flush(); parts.append(.second); index += 2; lastWasHour = false
            default:
                literal.append(character); index += 1
                // A separator between the hour and "mm" (hh:mm) still means minutes.
                if character.isLetter { lastWasHour = false }
            }
        }
        flush()
        return parts
    }

    // MARK: - Expansion

    /// The file name (without folder or extension) for one database.
    public static func expand(_ format: String, context: Context) -> String {
        var text = ""
        for piece in pieces(format) {
            switch piece {
            case .literal(let value): text += value
            case .database: text += sanitize(context.database)
            case .instance: text += sanitize(context.instance)
            case .server: text += sanitize(context.server)
            case .availabilityGroup:
                text += sanitize(context.availabilityGroup.isEmpty ? context.instance : context.availabilityGroup)
            case .type: text += context.type.tag
            case .auto:
                // <AUTO> inside a format means the default format; avoid recursing into itself.
                let inner = context.defaultFormat.uppercased().contains("<AUTO>")
                    ? BackupOptions.defaultFileNameFormat : context.defaultFormat
                text += expand(inner, context: context)
            case .date(let parts): text += render(parts, date: context.date)
            }
        }
        return text
    }

    /// Folder tags expand the same way (`D:\Backups\<DATABASE>`).
    public static func expandFolder(_ folder: String, context: Context) -> String {
        expand(folder, context: context)
    }

    static func render(_ parts: [DatePart], date: Date) -> String {
        let components = ServerTime.calendar.dateComponents([.year, .month, .day, .hour, .minute, .second],
                                                            from: date)
        func pad(_ value: Int?, _ width: Int) -> String {
            let text = String(value ?? 0)
            return String(repeating: "0", count: max(0, width - text.count)) + text
        }
        var text = ""
        for part in parts {
            switch part {
            case .literal(let value): text += value
            case .year4: text += pad(components.year, 4)
            case .year2: text += pad((components.year ?? 0) % 100, 2)
            case .month: text += pad(components.month, 2)
            case .day: text += pad(components.day, 2)
            case .hour: text += pad(components.hour, 2)
            case .minute: text += pad(components.minute, 2)
            case .second: text += pad(components.second, 2)
            }
        }
        return text
    }

    /// Characters a database name may contain that a file name may not.
    static func sanitize(_ value: String) -> String {
        let forbidden: Set<Character> = ["/", "\\", ":", "*", "?", "\"", "<", ">", "|"]
        return String(value.map { forbidden.contains($0) ? "_" : $0 })
    }

    /// File names for every stripe of a backup: `name.bak`, or `name_1of4.bak` … when split.
    public static func stripeNames(base: String, count: Int, fileExtension: String) -> [String] {
        guard count > 1 else { return ["\(base).\(fileExtension)"] }
        return (1...count).map { "\(base)_\($0)of\(count).\(fileExtension)" }
    }

    // MARK: - T-SQL

    /// Variables the generated job step declares before it uses `sqlExpression`.
    public struct SQLVariables: Sendable {
        public var database = "@db"
        public var type = "@type_tag"
        public var instance = "@instance"
        public var server = "@server"
        public var availabilityGroup = "@ag"
        public var date = "@started"

        public init() {}
    }

    /// A T-SQL expression that builds the same name at run time.
    public static func sqlExpression(_ format: String, defaultFormat: String = BackupOptions.defaultFileNameFormat,
                                     variables: SQLVariables = SQLVariables()) -> String {
        var terms: [String] = []
        for piece in pieces(format) {
            switch piece {
            case .literal(let value): terms.append(SQLIdentifier.literal(value))
            case .database: terms.append(sanitizeSQL(variables.database))
            case .instance: terms.append(sanitizeSQL(variables.instance))
            case .server: terms.append(sanitizeSQL(variables.server))
            case .availabilityGroup: terms.append(sanitizeSQL(variables.availabilityGroup))
            case .type: terms.append(variables.type)
            case .auto:
                let inner = defaultFormat.uppercased().contains("<AUTO>")
                    ? BackupOptions.defaultFileNameFormat : defaultFormat
                terms.append("(" + sqlExpression(inner, defaultFormat: defaultFormat, variables: variables) + ")")
            case .date(let parts): terms.append(contentsOf: sqlDateTerms(parts, variable: variables.date))
            }
        }
        return terms.isEmpty ? "N''" : terms.joined(separator: " + ")
    }

    private static func sqlDateTerms(_ parts: [DatePart], variable: String) -> [String] {
        var terms: [String] = []
        var pattern = ""
        func flush() {
            if !pattern.isEmpty {
                terms.append("FORMAT(\(variable), \(SQLIdentifier.literal(pattern)), 'en-US')")
                pattern = ""
            }
        }
        for part in parts {
            switch part {
            case .literal(let value):
                flush()
                terms.append(SQLIdentifier.literal(value))
            case .year4: pattern += "yyyy"
            case .year2: pattern += "yy"
            case .month: pattern += "MM"
            case .day: pattern += "dd"
            case .hour: pattern += "HH"
            case .minute: pattern += "mm"
            case .second: pattern += "ss"
            }
        }
        flush()
        return terms
    }

    /// The T-SQL counterpart of `sanitize`.
    private static func sanitizeSQL(_ variable: String) -> String {
        var expression = variable
        for character in ["/", "\\", ":", "*", "?", "\"", "<", ">", "|"] {
            expression = "REPLACE(\(expression), \(SQLIdentifier.literal(character)), N'_')"
        }
        return expression
    }
}
