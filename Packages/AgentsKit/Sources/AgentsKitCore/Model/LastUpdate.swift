import Foundation

/// How fresh a page's data is (#5139, #5141): "Last update 5 min ago", the same words on the
/// Mac window, the Remote and the web page (`Web/src/model/lastUpdate.ts`). The rule is in
/// `docs/reference/design-system.md`, "How fresh the data is".
///
/// The time is when the client read the data, not the time of the content and not the time
/// a link went down. The words are our own, not Foundation's relative format, which says
/// "5 minutes ago" and "in 0 seconds"; only an older day's date comes from Foundation.
public enum LastUpdate {
    /// "Last update 5 min ago".
    public static func line(since read: Date, now: Date = Date(),
                            calendar: Calendar = .current, locale: Locale = .current) -> String {
        "Last update \(age(since: read, now: now, calendar: calendar, locale: locale))"
    }

    /// A banner's words with the line after them: "Can't reach your Mac. Last update 5 min
    /// ago". The words alone when nothing was read yet.
    public static func banner(_ words: String, read: Date?, now: Date = Date()) -> String {
        guard let read else { return words }
        return "\(words) \(line(since: read, now: now))"
    }

    /// The age alone, for a place that has room only for it: "just now", "5 min ago",
    /// "2 h ago", "yesterday", "3 Nov".
    public static func age(since read: Date, now: Date = Date(),
                           calendar: Calendar = .current, locale: Locale = .current) -> String {
        switch Age(since: read, now: now, calendar: calendar) {
        case .justNow: "just now"
        case .minutes(let n): "\(n) min ago"
        case .hours(let n): "\(n) h ago"
        case .yesterday: "yesterday"
        case .day: date(read, now: now, calendar: calendar, locale: locale)
        }
    }

    /// What a screen reader says: "Last update 5 minutes ago".
    public static func spoken(since read: Date, now: Date = Date(),
                              calendar: Calendar = .current, locale: Locale = .current) -> String {
        let age: String = switch Age(since: read, now: now, calendar: calendar) {
        case .justNow: "just now"
        case .minutes(let n): n == 1 ? "1 minute ago" : "\(n) minutes ago"
        case .hours(let n): n == 1 ? "1 hour ago" : "\(n) hours ago"
        case .yesterday: "yesterday"
        case .day: date(read, now: now, calendar: calendar, locale: locale)
        }
        return "Last update \(age)"
    }

    /// When the words can next change: every 10 s for the first minute, then on each
    /// minute of the age.
    public static func nextChange(since read: Date, after now: Date) -> Date {
        let age = now.timeIntervalSince(read)
        if age < 60 {
            return read.addingTimeInterval((floor(max(age, 0) / 10) + 1) * 10)
        }
        return read.addingTimeInterval((floor(age / 60) + 1) * 60)
    }

    enum Age: Equatable {
        case justNow
        case minutes(Int)
        case hours(Int)
        case yesterday
        case day

        init(since read: Date, now: Date, calendar: Calendar) {
            // A read a little ahead of this clock (another machine's time) is just now.
            let seconds = max(0, now.timeIntervalSince(read))
            if seconds < 60 { self = .justNow }
            else if seconds < 3600 { self = .minutes(Int(seconds / 60)) }
            else if seconds < 24 * 3600 { self = .hours(Int(seconds / 3600)) }
            else if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
                    calendar.isDate(read, inSameDayAs: yesterday) { self = .yesterday }
            else { self = .day }
        }
    }

    /// "3 Nov" in the person's own order and time zone, with the year when it is not this one.
    private static func date(_ read: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
        var style = Date.FormatStyle(date: .omitted, time: .omitted, locale: locale, calendar: calendar,
                                     timeZone: calendar.timeZone).day().month(.abbreviated)
        if calendar.component(.year, from: read) != calendar.component(.year, from: now) {
            style = style.year()
        }
        return read.formatted(style)
    }
}
