import Foundation

/// A day of the week, in the order `Calendar` numbers them.
///
/// Its own type rather than a raw `Int` because the file says `mon` and the calendar
/// says 2, and exactly one place should know that.
public enum Weekday: String, Codable, Hashable, Sendable, CaseIterable {
    case sun, mon, tue, wed, thu, fri, sat

    /// What `Calendar.component(.weekday:)` returns for this day: Sunday is 1.
    public var calendarValue: Int { (Self.allCases.firstIndex(of: self) ?? 0) + 1 }

    public init?(calendarValue: Int) {
        guard (1...7).contains(calendarValue) else { return nil }
        self = Self.allCases[calendarValue - 1]
    }

    public static let everyDay = Set(Weekday.allCases)
    public static let weekdays: Set<Weekday> = [.mon, .tue, .wed, .thu, .fri]
}

/// When a workflow runs, for the workflows that run on a clock.
///
/// The granularity is the hour and the half hour and nothing finer. That is a floor
/// rather than an oversight: a schedule that can fire every minute invites workflows
/// that produce results faster than anyone can read them, and nothing this feature is
/// for needs it.
///
/// Nothing here is precomputed. `nextDue` is asked afresh against the current calendar
/// every time, so a machine that changes time zone, or clocks that go back, need no
/// rewrite and cause no double fire.
public struct WorkflowSchedule: Codable, Hashable, Sendable {
    /// Which minutes of the hour. A subset of `{0, 30}`, enforced where it is parsed.
    public var minutes: Set<Int>
    /// The first and the last hour of the day it may run in, inclusive at both ends. The
    /// first is after the last when `between:` goes past midnight (#4818), `22:00-02:00`:
    /// the hours after midnight then belong to the day before, so `days: [fri]` runs on
    /// Friday night into Saturday. Two numbers rather than a `ClosedRange`, which cannot
    /// hold a range that wraps and refuses to decode one.
    public var firstHour: Int
    public var lastHour: Int
    /// Where in its first hour the range begins, and where in its last it ends: `0` or
    /// `30`. What makes `between: 09:00-18:00` stop at six rather than at half past,
    /// and `09:30-17:00` start at half past nine rather than at nine. The defaults are
    /// the whole of both hours, which is what a range read as hours alone always meant.
    public var startMinute: Int
    public var endMinute: Int
    /// The days it may run on. Every day unless the file says otherwise.
    public var days: Set<Weekday>

    /// The only minutes a schedule may name.
    public static let allowedMinutes: Set<Int> = [0, 30]

    public init(minutes: Set<Int> = [0], hours: ClosedRange<Int> = 0...23,
                startMinute: Int = 0, endMinute: Int = 30,
                days: Set<Weekday> = Weekday.everyDay) {
        self.init(minutes: minutes, firstHour: hours.lowerBound, lastHour: hours.upperBound,
                  startMinute: startMinute, endMinute: endMinute, days: days)
    }

    /// One whose range can go past midnight: `firstHour` after `lastHour`.
    public init(minutes: Set<Int> = [0], firstHour: Int, lastHour: Int,
                startMinute: Int = 0, endMinute: Int = 30,
                days: Set<Weekday> = Weekday.everyDay) {
        self.minutes = minutes
        self.firstHour = firstHour
        self.lastHour = lastHour
        self.startMinute = startMinute
        self.endMinute = endMinute
        self.days = days
    }

    private enum CodingKeys: String, CodingKey { case minutes, hours, startMinute, endMinute, days }

    /// `hours` is `[first, last]` on the wire, as it always was.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let hours = try c.decode([Int].self, forKey: .hours)
        guard hours.count == 2 else {
            throw DecodingError.dataCorruptedError(forKey: .hours, in: c, debugDescription: "hours is not [first, last]")
        }
        self.init(minutes: try c.decode(Set<Int>.self, forKey: .minutes), firstHour: hours[0], lastHour: hours[1],
                  startMinute: try c.decode(Int.self, forKey: .startMinute), endMinute: try c.decode(Int.self, forKey: .endMinute),
                  days: try c.decode(Set<Weekday>.self, forKey: .days))
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(minutes, forKey: .minutes)
        try c.encode([firstHour, lastHour], forKey: .hours)
        try c.encode(startMinute, forKey: .startMinute)
        try c.encode(endMinute, forKey: .endMinute)
        try c.encode(days, forKey: .days)
    }

    /// Whether a given moment is one this schedule names.
    ///
    /// Seconds are not looked at: the caller decides which window of time it is asking
    /// about, and this answers for the minute that moment falls in.
    public func matches(_ date: Date, calendar: Calendar = .current) -> Bool {
        let parts = calendar.dateComponents([.hour, .minute, .weekday], from: date)
        guard let hour = parts.hour, let minute = parts.minute,
              let weekday = parts.weekday.flatMap(Weekday.init(calendarValue:)) else { return false }
        guard minutes.contains(minute) else { return false }
        let x = hour * 60 + minute, lo = firstHour * 60 + startMinute, hi = lastHour * 60 + endMinute
        if lo <= hi { return x >= lo && x <= hi && days.contains(weekday) }
        // Past midnight (#4818): the part after midnight is the day before's.
        if x >= lo { return days.contains(weekday) }
        let dayBefore = Weekday(calendarValue: (weekday.calendarValue + 5) % 7 + 1) ?? weekday
        return x <= hi && days.contains(dayBefore)
    }

    /// The next moment at or after `date` that this schedule names, or nil when it names
    /// none — an empty minute set, or an empty day set, is a schedule that never fires.
    ///
    /// Walks forward a half hour at a time from the next boundary. A week of half hours
    /// is 336 steps, which is nothing, and walking beats arithmetic here because the
    /// arithmetic is where daylight saving hides: on the morning the clocks go forward
    /// there is no 1:30am, and `Calendar` is the only thing that knows it.
    public func nextDue(after date: Date, calendar: Calendar = .current) -> Date? {
        guard !minutes.isEmpty, !days.isEmpty else { return nil }

        // Start at the boundary after `date`, so a schedule due exactly now is the
        // caller's to have already fired rather than one this hands back again.
        var parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        parts.second = 0
        parts.nanosecond = 0
        parts.minute = (parts.minute ?? 0) < 30 ? 30 : 60
        guard var candidate = calendar.date(from: parts) else { return nil }

        // Eight days of half hours: a week, plus one for the day a clock change adds or
        // removes. Past that there is nothing to find that is not found sooner.
        for _ in 0..<(8 * 48) {
            if matches(candidate, calendar: calendar) { return candidate }
            guard let next = calendar.date(byAdding: .minute, value: 30, to: candidate) else { return nil }
            // A clock change can move a half-hour step somewhere unexpected. Landing on
            // the same instant twice would spin, so this only ever moves forward.
            candidate = next > candidate ? next : candidate.addingTimeInterval(1800)
        }
        return nil
    }

    /// The schedule in the words the folder page and the confirmation both use.
    public var summary: String {
        let when: String
        if minutes == Self.allowedMinutes {
            when = "on the hour and half hour"
        } else if minutes == [30] {
            when = "on the half hour"
        } else {
            when = "on the hour"
        }
        let dayPart: String
        if days == Weekday.everyDay { dayPart = "Every day" }
        else if days == Weekday.weekdays { dayPart = "Every weekday" }
        else {
            let ordered = Weekday.allCases.filter(days.contains).map(\.rawValue.capitalized)
            dayPart = ordered.joined(separator: ", ")
        }
        if firstHour == 0, lastHour == 23 { return "\(dayPart) \(when)" }
        if firstHour == lastHour, minutes.count == 1, let minute = minutes.first {
            return "\(dayPart) at \(Self.clock(firstHour, minute))"
        }
        // The end as a time it can actually run at: a range ending on the half hour
        // says so only when the schedule runs on the half hour.
        let end = endMinute == 30 && minutes.contains(30) ? 30 : 0
        return "\(dayPart) \(when) between \(Self.clock(firstHour, startMinute)) and \(Self.clock(lastHour, end))"
    }

    /// A time of day the way somebody would say it, not the way a file writes it.
    static func clock(_ hour: Int, _ minute: Int) -> String {
        let suffix = hour < 12 ? "am" : "pm"
        let twelve = hour % 12 == 0 ? 12 : hour % 12
        return minute == 0 ? "\(twelve)\(suffix)" : String(format: "%d:%02d%@", twelve, minute, suffix)
    }
}
