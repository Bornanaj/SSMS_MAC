import Foundation

/// Calendar arithmetic on the proleptic Gregorian calendar, matching SQL Server exactly.
public enum TDSCalendar {
    /// Days from 1970-01-01 to a civil date (Howard Hinnant's algorithm).
    public static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146097 + doe - 719468
    }

    public static func civilFromDays(_ days: Int) -> (year: Int, month: Int, day: Int) {
        var z = days
        z += 719468
        let era = (z >= 0 ? z : z - 146096) / 146097
        let doe = z - era * 146097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
        let y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        return (m <= 2 ? y + 1 : y, m, d)
    }

    /// Days from 0001-01-01 to 1970-01-01.
    public static let daysFromYearOneToEpoch = 719162
    /// Days from 1900-01-01 to 1970-01-01.
    public static let daysFrom1900ToEpoch = 25567
}

/// A SQL Server date/time value kept in its exact server representation so that
/// rendering never loses precision or drifts with the local time zone.
public struct TDSTemporal: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case date
        case time
        case smallDateTime
        case dateTime
        case dateTime2
        case dateTimeOffset
    }

    public var kind: Kind
    public var year: Int = 1900
    public var month: Int = 1
    public var day: Int = 1
    public var hour: Int = 0
    public var minute: Int = 0
    public var second: Int = 0
    /// Fractional seconds expressed in nanoseconds (SQL Server tops out at 100 ns).
    public var nanosecond: Int = 0
    /// Minutes east of UTC, only for `datetimeoffset`.
    public var offsetMinutes: Int = 0
    public var scale: Int = 7

    public init(kind: Kind) { self.kind = kind }

    public var hasDate: Bool { kind != .time }
    public var hasTime: Bool { kind != .date }

    private func pad(_ v: Int, _ width: Int) -> String {
        let s = String(abs(v))
        return String(repeating: "0", count: max(0, width - s.count)) + s
    }

    private var fractionString: String {
        switch kind {
        case .date: return ""
        case .smallDateTime: return ""
        case .dateTime:
            // datetime keeps 1/300 s ticks, rendered with 3 digits
            let ms = nanosecond / 1_000_000
            return "." + pad(ms, 3)
        case .time, .dateTime2, .dateTimeOffset:
            guard scale > 0 else { return "" }
            let digits = min(scale, 9)
            var frac = nanosecond
            // nanoseconds -> `digits` significant fractional digits
            let divisor = Int(pow(10.0, Double(9 - digits)))
            frac = frac / max(divisor, 1)
            return "." + pad(frac, digits)
        }
    }

    /// SSMS-compatible rendering.
    public var displayString: String {
        var parts: [String] = []
        if hasDate {
            parts.append("\(pad(year, 4))-\(pad(month, 2))-\(pad(day, 2))")
        }
        if hasTime {
            parts.append("\(pad(hour, 2)):\(pad(minute, 2)):\(pad(second, 2))" + fractionString)
        }
        var s = parts.joined(separator: " ")
        if kind == .dateTimeOffset {
            let sign = offsetMinutes < 0 ? "-" : "+"
            let abs = Swift.abs(offsetMinutes)
            s += " \(sign)\(pad(abs / 60, 2)):\(pad(abs % 60, 2))"
        }
        return s
    }

    /// Literal that can be pasted back into a T-SQL script.
    public var sqlLiteral: String { "'" + displayString + "'" }

    /// Best-effort bridge to Foundation for sorting and charting.
    public var foundationDate: Date? {
        guard hasDate else { return nil }
        let days = TDSCalendar.daysFromCivil(year: year, month: month, day: day)
        var seconds = Double(days) * 86_400
        seconds += Double(hour * 3600 + minute * 60 + second)
        seconds += Double(nanosecond) / 1_000_000_000
        if kind == .dateTimeOffset { seconds -= Double(offsetMinutes * 60) }
        return Date(timeIntervalSince1970: seconds)
    }
}

/// A decoded SQL Server value.
public enum TDSValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    /// 4 byte `real`; kept apart from `double` so it renders with 7 digits like SSMS.
    case float(Float)
    case decimal(TDSDecimal)
    case string(String)
    case binary([UInt8])
    case uuid(UUID)
    case temporal(TDSTemporal)
    case xml(String)

    public var isNull: Bool { if case .null = self { return true }; return false }

    /// Plain text rendering used by the results grid, matching SSMS conventions.
    public func displayString(nullText: String = "NULL") -> String {
        switch self {
        case .null: return nullText
        case .bool(let b): return b ? "1" : "0"
        case .int(let i): return String(i)
        case .double(let d):
            if d == d.rounded() && abs(d) < 1e15 {
                return String(format: "%.0f", d)
            }
            return shortestRoundTrip(d)
        case .float(let f):
            if f == f.rounded() && abs(f) < 1e7 {
                return String(format: "%.0f", f)
            }
            return shortestRoundTrip(Double(f), maxPrecision: 9)
        case .decimal(let d): return d.description
        case .string(let s): return s
        case .binary(let b): return "0x" + b.hexString
        case .uuid(let u): return u.uuidString
        case .temporal(let t): return t.displayString
        case .xml(let x): return x
        }
    }

    private func shortestRoundTrip(_ d: Double, maxPrecision: Int = 17) -> String {
        for precision in 1...maxPrecision {
            let s = String(format: "%.\(precision)g", d)
            if maxPrecision <= 9 {
                if Float(s) == Float(d) { return s }
            } else if Double(s) == d {
                return s
            }
        }
        return String(d)
    }

    /// A T-SQL literal for this value, used by the data editor and script generator.
    public var sqlLiteral: String {
        switch self {
        case .null: return "NULL"
        case .bool(let b): return b ? "1" : "0"
        case .int(let i): return String(i)
        case .double(let d): return shortestRoundTrip(d)
        case .float(let f): return shortestRoundTrip(Double(f), maxPrecision: 9)
        case .decimal(let d): return d.description
        case .string(let s): return "N'" + s.replacingOccurrences(of: "'", with: "''") + "'"
        case .binary(let b): return "0x" + b.hexString
        case .uuid(let u): return "'" + u.uuidString + "'"
        case .temporal(let t): return t.sqlLiteral
        case .xml(let x): return "N'" + x.replacingOccurrences(of: "'", with: "''") + "'"
        }
    }
}

/// Exact decimal value: `mantissa / 10^scale` with an explicit sign, so 38 digit
/// numerics survive without going through `Double`.
public struct TDSDecimal: Sendable, Hashable, CustomStringConvertible {
    /// Decimal digits of the magnitude, most significant first. Empty means zero.
    public var digits: String
    public var scale: Int
    public var isNegative: Bool

    public init(digits: String, scale: Int, isNegative: Bool) {
        self.digits = digits.isEmpty ? "0" : digits
        self.scale = scale
        self.isNegative = isNegative
    }

    public init(int64 value: Int64, scale: Int) {
        self.isNegative = value < 0
        self.digits = String(value.magnitude)
        self.scale = scale
    }

    public var description: String {
        var mag = digits
        while mag.count > 1 && mag.hasPrefix("0") { mag.removeFirst() }
        var text: String
        if scale == 0 {
            text = mag
        } else {
            if mag.count <= scale {
                mag = String(repeating: "0", count: scale - mag.count + 1) + mag
            }
            let idx = mag.index(mag.endIndex, offsetBy: -scale)
            text = String(mag[mag.startIndex..<idx]) + "." + String(mag[idx...])
        }
        if isNegative && !(text.allSatisfy { $0 == "0" || $0 == "." }) { text = "-" + text }
        return text
    }

    public var doubleValue: Double { Double(description) ?? 0 }
}
