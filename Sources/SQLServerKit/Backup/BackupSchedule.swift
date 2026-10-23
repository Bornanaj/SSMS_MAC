import Foundation

/// One SQL Server Agent schedule, in the shape of SQL Backup's Schedule Editor. It converts to
/// `sp_add_schedule` arguments, back from `msdb.dbo.sysschedules`, and expands into occurrences
/// for the time line.
public struct BackupSchedule: Codable, Hashable, Sendable, Identifiable {
    public enum Frequency: String, Codable, CaseIterable, Sendable {
        case once
        case daily
        case weekly
        case monthly
        case monthlyRelative
        case agentStart
        case cpuIdle

        public var title: String {
            switch self {
            case .once: return "One time"
            case .daily: return "Daily"
            case .weekly: return "Weekly"
            case .monthly: return "Monthly (day of month)"
            case .monthlyRelative: return "Monthly (relative)"
            case .agentStart: return "When SQL Server Agent starts"
            case .cpuIdle: return "When the CPU becomes idle"
            }
        }

        var agentCode: Int {
            switch self {
            case .once: return 1
            case .daily: return 4
            case .weekly: return 8
            case .monthly: return 16
            case .monthlyRelative: return 32
            case .agentStart: return 64
            case .cpuIdle: return 128
            }
        }
    }

    public enum RepeatUnit: String, Codable, CaseIterable, Sendable {
        case seconds
        case minutes
        case hours

        var agentCode: Int {
            switch self {
            case .seconds: return 2
            case .minutes: return 4
            case .hours: return 8
            }
        }

        var seconds: Int {
            switch self {
            case .seconds: return 1
            case .minutes: return 60
            case .hours: return 3600
            }
        }
    }

    public static let weekdayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
    public static let ordinalNames: [(Int, String)] = [(1, "First"), (2, "Second"), (4, "Third"), (8, "Fourth"),
                                                       (16, "Last")]
    public static let relativeDayNames: [(Int, String)] = [(1, "Sunday"), (2, "Monday"), (3, "Tuesday"),
                                                           (4, "Wednesday"), (5, "Thursday"), (6, "Friday"),
                                                           (7, "Saturday"), (8, "Day"), (9, "Weekday"),
                                                           (10, "Weekend day")]

    public var id: UUID
    public var name: String
    public var isEnabled: Bool
    public var frequency: Frequency
    /// Every n days (daily), weeks (weekly) or months (monthly and relative).
    public var interval: Int
    /// Weekly: Sunday = 1, Monday = 2, Tuesday = 4 … Saturday = 64.
    public var weekdays: Int
    public var dayOfMonth: Int
    /// Monthly relative: first = 1, second = 2, third = 4, fourth = 8, last = 16.
    public var relativeOrdinal: Int
    /// Monthly relative: Sunday = 1 … Saturday = 7, day = 8, weekday = 9, weekend day = 10.
    public var relativeDay: Int
    public var repeats: Bool
    public var repeatInterval: Int
    public var repeatUnit: RepeatUnit
    /// Seconds after midnight.
    public var startTime: Int
    public var endTime: Int
    /// Server wall-clock dates (see `ServerTime`).
    public var startDate: Date
    public var endDate: Date?

    public init(id: UUID = UUID(), name: String = "", isEnabled: Bool = true, frequency: Frequency = .daily,
                interval: Int = 1, weekdays: Int = 62, dayOfMonth: Int = 1, relativeOrdinal: Int = 1,
                relativeDay: Int = 1, repeats: Bool = false, repeatInterval: Int = 1, repeatUnit: RepeatUnit = .hours,
                startTime: Int = 0, endTime: Int = 86_399, startDate: Date = Date(), endDate: Date? = nil) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.frequency = frequency
        self.interval = interval
        self.weekdays = weekdays
        self.dayOfMonth = dayOfMonth
        self.relativeOrdinal = relativeOrdinal
        self.relativeDay = relativeDay
        self.repeats = repeats
        self.repeatInterval = repeatInterval
        self.repeatUnit = repeatUnit
        self.startTime = startTime
        self.endTime = endTime
        self.startDate = ServerTime.calendar.startOfDay(for: startDate)
        self.endDate = endDate
    }

    /// The schedules SQL Backup's worked example uses: full daily at midnight, differential daily
    /// at noon, log every hour.
    public static func suggested(for type: BackupType, today: Date = Date()) -> BackupSchedule {
        switch type {
        case .full:
            return BackupSchedule(name: "Daily at 00:00", frequency: .daily, startTime: 0, startDate: today)
        case .differential:
            return BackupSchedule(name: "Daily at 12:00", frequency: .daily, startTime: 12 * 3600, startDate: today)
        case .log:
            return BackupSchedule(name: "Every hour", frequency: .daily, repeats: true, repeatInterval: 1,
                                  repeatUnit: .hours, startTime: 0, endTime: 86_399, startDate: today)
        }
    }

    // MARK: Text

    /// Parses the command line's schedule text: `daily 00:00`, `daily every 15 minutes`,
    /// `every 2 hours`, `weekly mon,wed,fri 01:30`, `monthly 1 02:00`, `once 2026-11-01 03:00`,
    /// `agent-start` and `cpu-idle`. Times are the server's.
    public static func parse(_ text: String, today: Date = Date()) -> BackupSchedule? {
        let words: [String] = text.lowercased().split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard let first = words.first else { return nil }
        func time(_ word: String?) -> Int? {
            guard let word else { return nil }
            let parts = word.split(separator: ":").compactMap { Int($0) }
            guard parts.count >= 2, (0...23).contains(parts[0]), (0...59).contains(parts[1]) else { return nil }
            return parts[0] * 3600 + parts[1] * 60 + (parts.count > 2 ? parts[2] : 0)
        }
        func repeating(_ rest: ArraySlice<String>, base: BackupSchedule) -> BackupSchedule? {
            // every N minutes|hours|seconds [from HH:MM to HH:MM]
            let list = Array(rest)
            guard list.count >= 3, list[0] == "every", let count = Int(list[1]), count > 0 else { return nil }
            var schedule = base
            schedule.repeats = true
            schedule.repeatInterval = count
            switch list[2] {
            case "minute", "minutes", "min", "mins": schedule.repeatUnit = .minutes
            case "hour", "hours", "h": schedule.repeatUnit = .hours
            case "second", "seconds", "s": schedule.repeatUnit = .seconds
            default: return nil
            }
            if list.count >= 7, list[3] == "from", list[5] == "to", let from = time(list[4]), let to = time(list[6]) {
                schedule.startTime = from
                schedule.endTime = to
            }
            return schedule
        }
        let base = BackupSchedule(name: text, startDate: today)
        switch first {
        case "agent-start":
            var schedule = base
            schedule.frequency = .agentStart
            return schedule
        case "cpu-idle", "idle":
            var schedule = base
            schedule.frequency = .cpuIdle
            return schedule
        case "every":
            return repeating(words[...], base: base)
        case "daily":
            if words.count > 1, words[1] == "every" { return repeating(words.dropFirst(), base: base) }
            guard let at = time(words.count > 1 ? words[1] : "00:00") else { return nil }
            var schedule = base
            schedule.startTime = at
            return schedule
        case "weekly":
            guard words.count >= 2 else { return nil }
            let names = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]
            var mask = 0
            for day in words[1].split(separator: ",") {
                guard let index = names.firstIndex(where: { day.hasPrefix($0) }) else { return nil }
                mask |= 1 << index
            }
            var schedule = base
            schedule.frequency = .weekly
            schedule.weekdays = mask
            if words.count > 2, words[2] == "every", let repeated = repeating(words.dropFirst(2), base: schedule) {
                return repeated
            }
            guard let at = time(words.count > 2 ? words[2] : "00:00") else { return nil }
            schedule.startTime = at
            return schedule
        case "monthly":
            guard words.count >= 2, let day = Int(words[1]), (1...31).contains(day),
                  let at = time(words.count > 2 ? words[2] : "00:00") else { return nil }
            var schedule = base
            schedule.frequency = .monthly
            schedule.dayOfMonth = day
            schedule.startTime = at
            return schedule
        case "once":
            guard words.count >= 3, let day = ServerTime.parse(words[1]), let at = time(words[2]) else { return nil }
            var schedule = base
            schedule.frequency = .once
            schedule.startDate = day
            schedule.startTime = at
            return schedule
        default:
            return nil
        }
    }

    static func timeText(_ seconds: Int) -> String {
        String(format: "%02d:%02d", seconds / 3600, (seconds / 60) % 60)
    }

    public var summary: String {
        var recurrence: String
        switch frequency {
        case .once:
            return "Once on \(ServerTime.format(startDate, "yyyy-MM-dd")) at \(Self.timeText(startTime))"
        case .agentStart:
            return Frequency.agentStart.title
        case .cpuIdle:
            return Frequency.cpuIdle.title
        case .daily:
            recurrence = interval <= 1 ? "Every day" : "Every \(interval) days"
        case .weekly:
            let days: [String] = (0..<7).compactMap { weekdays & (1 << $0) != 0 ? Self.weekdayNames[$0] : nil }
            let every = interval <= 1 ? "Every week" : "Every \(interval) weeks"
            recurrence = days.isEmpty ? every : "\(every) on \(days.joined(separator: ", "))"
        case .monthly:
            let every = interval <= 1 ? "every month" : "every \(interval) months"
            recurrence = "Day \(dayOfMonth) of \(every)"
        case .monthlyRelative:
            let ordinal = Self.ordinalNames.first { $0.0 == relativeOrdinal }?.1 ?? "First"
            let day = Self.relativeDayNames.first { $0.0 == relativeDay }?.1 ?? "Sunday"
            let every = interval <= 1 ? "every month" : "every \(interval) months"
            recurrence = "\(ordinal) \(day.lowercased()) of \(every)"
        }
        if repeats {
            let singular = String(repeatUnit.rawValue.dropLast())
            let unit: String = repeatInterval == 1 ? singular : singular + "s"
            let window = startTime == 0 && endTime >= 86_340 ? ""
                : " between \(Self.timeText(startTime)) and \(Self.timeText(endTime))"
            return "\(recurrence), every \(repeatInterval) \(unit)\(window)"
        }
        return "\(recurrence) at \(Self.timeText(startTime))"
    }

    // MARK: Agent

    static func packedTime(_ seconds: Int) -> Int {
        (seconds / 3600) * 10000 + ((seconds / 60) % 60) * 100 + seconds % 60
    }

    static func unpackedTime(_ packed: Int) -> Int {
        (packed / 10000) * 3600 + ((packed / 100) % 100) * 60 + packed % 100
    }

    /// Arguments for `msdb.dbo.sp_add_schedule`, without `@schedule_name`.
    public var agentArguments: [String] {
        var arguments: [String] = ["@enabled = \(isEnabled ? 1 : 0)", "@freq_type = \(frequency.agentCode)"]
        switch frequency {
        case .daily:
            arguments.append("@freq_interval = \(max(1, interval))")
        case .weekly:
            arguments.append("@freq_interval = \(max(1, weekdays))")
            arguments.append("@freq_recurrence_factor = \(max(1, interval))")
        case .monthly:
            arguments.append("@freq_interval = \(min(31, max(1, dayOfMonth)))")
            arguments.append("@freq_recurrence_factor = \(max(1, interval))")
        case .monthlyRelative:
            arguments.append("@freq_interval = \(min(10, max(1, relativeDay)))")
            arguments.append("@freq_relative_interval = \(relativeOrdinal)")
            arguments.append("@freq_recurrence_factor = \(max(1, interval))")
        case .once, .agentStart, .cpuIdle:
            arguments.append("@freq_interval = 0")
        }
        let hasTime = frequency != .agentStart && frequency != .cpuIdle
        if hasTime && repeats && frequency != .once {
            arguments.append("@freq_subday_type = \(repeatUnit.agentCode)")
            arguments.append("@freq_subday_interval = \(max(1, repeatInterval))")
        } else {
            arguments.append("@freq_subday_type = 1")
            arguments.append("@freq_subday_interval = 0")
        }
        arguments.append("@active_start_date = \(ServerTime.format(startDate, "yyyyMMdd"))")
        arguments.append("@active_end_date = \(endDate.map { ServerTime.format($0, "yyyyMMdd") } ?? "99991231")")
        arguments.append("@active_start_time = \(Self.packedTime(startTime))")
        arguments.append("@active_end_time = \(Self.packedTime(repeats ? endTime : 86_399))")
        return arguments
    }

    /// A schedule as msdb stores it.
    public init(name: String, isEnabled: Bool, freqType: Int, freqInterval: Int, subdayType: Int, subdayInterval: Int,
                relativeInterval: Int, recurrenceFactor: Int, activeStartDate: Int, activeEndDate: Int,
                activeStartTime: Int, activeEndTime: Int) {
        let frequency: Frequency
        switch freqType {
        case 1: frequency = .once
        case 8: frequency = .weekly
        case 16: frequency = .monthly
        case 32: frequency = .monthlyRelative
        case 64: frequency = .agentStart
        case 128: frequency = .cpuIdle
        default: frequency = .daily
        }
        let unit: RepeatUnit = subdayType == 2 ? .seconds : (subdayType == 4 ? .minutes : .hours)
        let start = ServerTime.fromAgent(date: activeStartDate, time: 0) ?? Date()
        let end = activeEndDate >= 99991231 ? nil : ServerTime.fromAgent(date: activeEndDate, time: 0)
        self.init(name: name, isEnabled: isEnabled, frequency: frequency,
                  interval: frequency == .daily ? max(1, freqInterval) : max(1, recurrenceFactor),
                  weekdays: frequency == .weekly ? freqInterval : 62,
                  dayOfMonth: frequency == .monthly ? max(1, freqInterval) : 1,
                  relativeOrdinal: max(1, relativeInterval), relativeDay: frequency == .monthlyRelative ? freqInterval : 1,
                  repeats: subdayType > 1, repeatInterval: max(1, subdayInterval), repeatUnit: unit,
                  startTime: Self.unpackedTime(activeStartTime), endTime: Self.unpackedTime(activeEndTime),
                  startDate: start, endDate: end)
    }

    // MARK: Occurrences

    /// When the schedule fires between two server times, at most `limit` times.
    public func occurrences(from: Date, to: Date, limit: Int = 500) -> [Date] {
        guard isEnabled, from < to else { return [] }
        let calendar = ServerTime.calendar
        var result: [Date] = []
        if frequency == .agentStart || frequency == .cpuIdle { return [] }
        if frequency == .once {
            let when = startDate.addingTimeInterval(TimeInterval(startTime))
            return when >= from && when <= to ? [when] : []
        }
        var day = max(calendar.startOfDay(for: from), startDate)
        let lastDay = min(to, endDate.map { $0.addingTimeInterval(86_399) } ?? to)
        while day <= lastDay && result.count < limit {
            if fires(on: day) {
                for seconds in times() {
                    let when = day.addingTimeInterval(TimeInterval(seconds))
                    if when >= from && when <= to { result.append(when) }
                    if result.count >= limit { break }
                }
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return result
    }

    func times() -> [Int] {
        guard repeats else { return [startTime] }
        let step = max(1, repeatInterval) * repeatUnit.seconds
        return Array(stride(from: startTime, through: max(startTime, endTime), by: max(step, 1)))
    }

    func fires(on day: Date) -> Bool {
        let calendar = ServerTime.calendar
        let every = max(1, interval)
        switch frequency {
        case .daily:
            let days = calendar.dateComponents([.day], from: startDate, to: day).day ?? 0
            return days >= 0 && days % every == 0
        case .weekly:
            let weekday = calendar.component(.weekday, from: day)
            guard weekdays & (1 << (weekday - 1)) != 0 else { return false }
            let startWeek = calendar.date(byAdding: .day, value: 1 - calendar.component(.weekday, from: startDate),
                                          to: startDate) ?? startDate
            let weeks = (calendar.dateComponents([.day], from: startWeek, to: day).day ?? 0) / 7
            return weeks % every == 0
        case .monthly:
            guard monthMatches(day, every: every) else { return false }
            return calendar.component(.day, from: day) == dayOfMonth
        case .monthlyRelative:
            guard monthMatches(day, every: every) else { return false }
            return relativeDate(in: day).map { calendar.isDate($0, inSameDayAs: day) } ?? false
        case .once, .agentStart, .cpuIdle:
            return false
        }
    }

    private func monthMatches(_ day: Date, every: Int) -> Bool {
        let calendar = ServerTime.calendar
        let start = calendar.dateComponents([.year, .month], from: startDate)
        let now = calendar.dateComponents([.year, .month], from: day)
        let months = ((now.year ?? 0) - (start.year ?? 0)) * 12 + (now.month ?? 0) - (start.month ?? 0)
        return months >= 0 && months % every == 0
    }

    /// The day a relative schedule fires in the month of `day`.
    func relativeDate(in day: Date) -> Date? {
        let calendar = ServerTime.calendar
        guard let range = calendar.range(of: .day, in: .month, for: day),
              let first = calendar.date(from: calendar.dateComponents([.year, .month], from: day)) else { return nil }
        let days: [Date] = range.compactMap { calendar.date(byAdding: .day, value: $0 - 1, to: first) }
        let matching: [Date] = days.filter { date in
            let weekday = calendar.component(.weekday, from: date)
            switch relativeDay {
            case 1...7: return weekday == relativeDay
            case 9: return weekday >= 2 && weekday <= 6
            case 10: return weekday == 1 || weekday == 7
            default: return true
            }
        }
        if relativeOrdinal == 16 { return matching.last }
        let index: Int = relativeOrdinal == 1 ? 0 : (relativeOrdinal == 2 ? 1 : (relativeOrdinal == 4 ? 2 : 3))
        return index < matching.count ? matching[index] : nil
    }
}
