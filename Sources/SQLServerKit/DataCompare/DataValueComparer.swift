import Foundation
import TDSKit

/// Value equality with the semantics SQL Server itself applies — collation-aware text,
/// trailing spaces ignored, numbers compared by value whatever their type — plus the
/// comparison options on top.
public struct DataValueComparer: Sendable {
    public let options: DataCompareOptions

    public init(options: DataCompareOptions) {
        self.options = options
    }

    /// How text in a column compares, from its collation name.
    public struct TextRule: Sendable, Hashable {
        public var caseInsensitive: Bool
        public var accentInsensitive: Bool

        public static let exact = TextRule(caseInsensitive: false, accentInsensitive: false)

        public init(caseInsensitive: Bool, accentInsensitive: Bool) {
            self.caseInsensitive = caseInsensitive
            self.accentInsensitive = accentInsensitive
        }

        public init(collation: String?) {
            let name = (collation ?? "").uppercased()
            if name.isEmpty || name.contains("_BIN") {
                self = .exact
                return
            }
            caseInsensitive = name.contains("_CI")
            accentInsensitive = name.contains("_AI")
        }
    }

    public func rule(for column: DataColumnMapping) -> TextRule {
        if options.forceBinaryCollation { return .exact }
        return TextRule(collation: column.source.collation ?? column.target.collation)
    }

    // MARK: - Equality

    public func equal(_ lhs: TDSValue, _ rhs: TDSValue, rule: TextRule) -> Bool {
        let a = normalizedNull(lhs)
        let b = normalizedNull(rhs)
        switch (a, b) {
        case (.null, .null): return true
        case (.null, _), (_, .null): return false
        case let (.string(x), .string(y)):
            return normalizedText(x, rule: rule) == normalizedText(y, rule: rule)
        case let (.xml(x), .xml(y)), let (.xml(x), .string(y)), let (.string(x), .xml(y)):
            return x == y
        case let (.binary(x), .binary(y)):
            return x == y
        case let (.uuid(x), .uuid(y)):
            return x == y
        case let (.temporal(x), .temporal(y)):
            return temporalKey(x) == temporalKey(y)
        case (.double, _), (.float, _), (_, .double), (_, .float):
            guard let x = doubleValue(a), let y = doubleValue(b) else { return false }
            if options.floatDecimalPlaces >= 0 {
                let factor = pow(10.0, Double(options.floatDecimalPlaces))
                return (x * factor).rounded() == (y * factor).rounded()
            }
            return x == y
        default:
            if let x = numericKey(a), let y = numericKey(b) { return x == y }
            return a == b
        }
    }

    private func normalizedNull(_ value: TDSValue) -> TDSValue {
        if options.treatEmptyStringsAsNull, case .string(let text) = value, text.isEmpty { return .null }
        return value
    }

    func normalizedText(_ text: String, rule: TextRule) -> String {
        var value = text
        if options.ignoreWhiteSpace {
            value = value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        } else if options.ignoreTrailingSpaces {
            while value.hasSuffix(" ") { value.removeLast() }
        }
        var folding: String.CompareOptions = []
        if rule.caseInsensitive { folding.insert(.caseInsensitive) }
        if rule.accentInsensitive { folding.insert(.diacriticInsensitive) }
        if !folding.isEmpty { value = value.folding(options: folding, locale: nil) }
        return value
    }

    // MARK: - Keys

    /// Canonical text for one key value, so rows can be matched through a dictionary. Two
    /// values that SQL Server considers equal produce the same text.
    public func keyComponent(_ value: TDSValue, rule: TextRule) -> String {
        switch value {
        case .null: return "\u{0}N"
        case .string(let text):
            var trimmed = text
            // The server's = ignores trailing spaces regardless of options.
            while trimmed.hasSuffix(" ") { trimmed.removeLast() }
            var folding: String.CompareOptions = []
            if rule.caseInsensitive { folding.insert(.caseInsensitive) }
            if rule.accentInsensitive { folding.insert(.diacriticInsensitive) }
            if !folding.isEmpty { trimmed = trimmed.folding(options: folding, locale: nil) }
            return "s" + trimmed
        case .binary(let bytes): return "b" + SQLLiteral.hex(bytes)
        case .uuid(let uuid): return "u" + uuid.uuidString
        case .temporal(let temporal): return "t" + temporalKey(temporal)
        case .xml(let text): return "x" + text
        case .double(let number): return "n" + canonicalDouble(number)
        case .float(let number): return "n" + canonicalDouble(Double(number))
        default: return "n" + (numericKey(value) ?? value.displayString())
        }
    }

    public func key(_ values: ArraySlice<TDSValue>, rules: [TextRule]) -> String {
        var parts: [String] = []
        parts.reserveCapacity(values.count)
        for (offset, value) in values.enumerated() {
            let rule = offset < rules.count ? rules[offset] : .exact
            parts.append(keyComponent(value, rule: rule))
        }
        return parts.joined(separator: "\u{1F}")
    }

    // MARK: - Numbers and dates

    /// Decimal digits with trailing zeros removed, so 1, 1.0 and 1.00 agree.
    func numericKey(_ value: TDSValue) -> String? {
        switch value {
        case .bool(let flag): return flag ? "1" : "0"
        case .int(let number): return String(number)
        case .decimal(let decimal): return Self.canonicalDecimal(decimal.description)
        case .double(let number): return canonicalDouble(number)
        case .float(let number): return canonicalDouble(Double(number))
        default: return nil
        }
    }

    static func canonicalDecimal(_ text: String) -> String {
        var value = text
        var negative = false
        if value.hasPrefix("-") { negative = true; value.removeFirst() }
        if value.contains(".") {
            while value.hasSuffix("0") { value.removeLast() }
            if value.hasSuffix(".") { value.removeLast() }
        }
        while value.count > 1 && value.hasPrefix("0") && !value.hasPrefix("0.") { value.removeFirst() }
        if value.isEmpty || value == "0" { return "0" }
        return (negative ? "-" : "") + value
    }

    private func canonicalDouble(_ number: Double) -> String {
        if number == number.rounded(), abs(number) < 1e15 { return String(Int64(number)) }
        return Self.canonicalDecimal(String(number))
    }

    private func doubleValue(_ value: TDSValue) -> Double? {
        switch value {
        case .double(let number): return number
        case .float(let number): return Double(number)
        case .int(let number): return Double(number)
        case .decimal(let decimal): return decimal.doubleValue
        case .bool(let flag): return flag ? 1 : 0
        default: return nil
        }
    }

    /// Instant-based text for dates: datetimeoffset values in different offsets are equal
    /// when they name the same moment, as they are in SQL Server.
    func temporalKey(_ value: TDSTemporal) -> String {
        var year = value.year, month = value.month, day = value.day
        var hour = value.hour, minute = value.minute
        let second = value.second
        var nanosecond = options.ignoreFractionalSeconds ? 0 : value.nanosecond
        if value.kind == .dateTimeOffset, value.offsetMinutes != 0 {
            var days = TDSCalendar.daysFromCivil(year: year, month: month, day: day)
            var minutes = hour * 60 + minute - value.offsetMinutes
            while minutes < 0 { minutes += 1440; days -= 1 }
            while minutes >= 1440 { minutes -= 1440; days += 1 }
            let civil = TDSCalendar.civilFromDays(days)
            year = civil.year; month = civil.month; day = civil.day
            hour = minutes / 60; minute = minutes % 60
        }
        if value.kind == .date { hour = 0; minute = 0; nanosecond = 0 }
        let date = value.hasDate ? String(format: "%04d%02d%02d", year, month, day) : "--------"
        return date + String(format: "%02d%02d%02d%09d", hour, minute, second, nanosecond)
    }
}
