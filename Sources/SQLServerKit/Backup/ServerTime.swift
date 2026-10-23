import Foundation
import TDSKit

/// Server timestamps (backup history, schedules, STOPAT) are wall-clock times in the server's
/// own time zone, which the client does not know. They are kept as `Date`s whose UTC reading is
/// that wall-clock time, and always formatted with the UTC calendar, so a time read from msdb
/// goes back into a `STOPAT` or a schedule unchanged, and the UI shows what the server shows.
public enum ServerTime {
    public static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter
    }

    /// `2026-10-23 14:05:09`, for display.
    public static func display(_ date: Date) -> String {
        formatter("yyyy-MM-dd HH:mm:ss").string(from: date)
    }

    public static func displayShort(_ date: Date) -> String {
        formatter("MMM d, HH:mm").string(from: date)
    }

    /// `'2026-10-23T14:05:09.120'`: a language-neutral literal for STOPAT and comparisons.
    public static func literal(_ date: Date) -> String {
        "'" + formatter("yyyy-MM-dd'T'HH:mm:ss.SSS").string(from: date) + "'"
    }

    /// The date part, for file name tags and job schedules (`20261023`).
    public static func format(_ date: Date, _ pattern: String) -> String {
        formatter(pattern).string(from: date)
    }

    public static func parse(_ text: String) -> Date? {
        for pattern in ["yyyy-MM-dd HH:mm:ss.SSS", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss",
                        "yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd"] {
            if let date = formatter(pattern).date(from: text) { return date }
        }
        return nil
    }

    /// Agent's packed integers: `run_date` 20261023 and `run_time` 140509.
    public static func fromAgent(date: Int, time: Int) -> Date? {
        guard date > 19000101 else { return nil }
        var components = DateComponents()
        components.year = date / 10000
        components.month = (date / 100) % 100
        components.day = date % 100
        components.hour = time / 10000
        components.minute = (time / 100) % 100
        components.second = time % 100
        return calendar.date(from: components)
    }
}

extension Dictionary where Key == String, Value == TDSValue {
    /// A datetime column as a server wall-clock `Date` (see `ServerTime`).
    func serverDate(_ key: String) -> Date? {
        guard let value = self[key], !value.isNull else { return nil }
        if case .temporal(let temporal) = value { return temporal.foundationDate }
        return ServerTime.parse(value.displayString(nullText: ""))
    }
}
