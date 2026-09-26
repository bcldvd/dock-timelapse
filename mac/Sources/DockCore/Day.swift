import Foundation

/// A calendar day with no time zone, stored as "YYYY-MM-DD" (what `snapshots.json` uses).
/// Arithmetic runs on a day ordinal, so DST and time zones can never shift a date.
public struct Day: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(_ year: Int, _ month: Int, _ day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    public init?(iso: String) {
        let parts = iso.prefix(10).split(separator: "-")
        guard parts.count == 3, let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (1...12).contains(m), (1...31).contains(d) else { return nil }
        self.init(y, m, d)
        guard Day(ordinal: ordinal) == self else { return nil }  // rejects 2026-02-30
    }

    /// Days since 1970-01-01 (Howard Hinnant's days_from_civil).
    public var ordinal: Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146097 + doe - 719468
    }

    public init(ordinal z0: Int) {
        let z = z0 + 719468
        let era = (z >= 0 ? z : z - 146096) / 146097
        let doe = z - era * 146097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        self.init(yoe + era * 400 + (m <= 2 ? 1 : 0), m, d)
    }

    public var iso: String { String(format: "%04d-%02d-%02d", year, month, day) }
    public var description: String { iso }

    public func adding(days: Int) -> Day { Day(ordinal: ordinal + days) }
    public func days(since other: Day) -> Int { ordinal - other.ordinal }

    public static func < (a: Day, b: Day) -> Bool { a.ordinal < b.ordinal }

    static let monthNames = ["January", "February", "March", "April", "May", "June", "July", "August",
                             "September", "October", "November", "December"]

    /// "20 May 2026"
    public var long: String { "\(day) \(Day.monthNames[month - 1]) \(year)" }
    /// "20 May 2026" → "20 May 2026", "3 September 2026" → "3 Sep 2026"
    public var short: String { "\(day) \(Day.monthNames[month - 1].prefix(3)) \(year)" }
    /// "May 2026"
    public var monthYear: String { "\(Day.monthNames[month - 1]) \(year)" }
}

/// A local wall-clock time, like Python's naive `datetime` (what `captured_at` stores).
public struct LocalTime: Hashable, Comparable, Sendable {
    public let day: Day
    public let hour: Int
    public let minute: Int
    public let second: Int

    public init(_ day: Day, _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0) {
        self.day = day
        self.hour = hour
        self.minute = minute
        self.second = second
    }

    public init(_ date: Date, calendar: Calendar = .current) {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        self.init(Day(c.year!, c.month!, c.day!), c.hour!, c.minute!, c.second!)
    }

    public static func now() -> LocalTime { LocalTime(Date()) }

    /// Parses "2026-01-10T09:00:00" (what `iso` writes).
    public init?(iso: String) {
        let parts = iso.split(separator: "T", maxSplits: 1)
        guard parts.count == 2, parts[0].count == 10, let day = Day(iso: String(parts[0])) else { return nil }
        let hms = parts[1].prefix(8).split(separator: ":").compactMap { Int($0) }
        guard hms.count == 3, (0..<24).contains(hms[0]), (0..<60).contains(hms[1]), (0..<60).contains(hms[2])
        else { return nil }
        self.init(day, hms[0], hms[1], hms[2])
    }

    /// "2026-01-10T09:00:00"
    public var iso: String { day.iso + String(format: "T%02d:%02d:%02d", hour, minute, second) }

    var seconds: Int { ((day.ordinal * 24 + hour) * 60 + minute) * 60 + second }
    public static func < (a: LocalTime, b: LocalTime) -> Bool { a.seconds < b.seconds }
}
