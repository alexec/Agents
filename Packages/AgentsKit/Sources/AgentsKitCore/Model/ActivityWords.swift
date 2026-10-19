import Foundation

/// When a session last did anything, in the corner of its row (#341): "now", "5m", "3h",
/// "2d". The same on the window's row, the Remote's and the page's, which has its own copy
/// (`shortAgo` in `Web/src/model/activity.ts`), held to `Fixtures/web/activity/short.json`.
public enum ActivityWords {
    /// Whole minutes, hours or days since `date`, rounded down; "now" under a minute, and
    /// for a date ahead of `now`, which a host's clock a little fast would give.
    public static func short(since date: Date, now: Date = Date()) -> String {
        let minutes = max(0, Int((now.timeIntervalSince(date) / 60).rounded(.down)))
        if minutes < 1 { return "now" }
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }
        return "\(hours / 24)d"
    }

    /// How long a chat has been quiet, at the foot of its transcript (#1564): "Last
    /// activity 12 minutes ago · 14:32". Nil under five minutes, and for a date ahead of
    /// `now`. Past a day it gives the day instead: "yesterday · 14:32", "3 Oct · 09:10",
    /// and the year when it is not this one. The page has its own copy (`quietLine` in
    /// `Web/src/model/activity.ts`), held to `Fixtures/web/activity/quiet.json`.
    public static func quiet(since date: Date, now: Date = Date(), timeZone: TimeZone = .current) -> String? {
        let minutes = Int((now.timeIntervalSince(date) / 60).rounded(.down))
        guard minutes >= quietMinutes else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let at = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let time = String(format: "%02d:%02d", at.hour ?? 0, at.minute ?? 0)
        let hours = minutes / 60
        let when: String
        if hours < 1 {
            when = "\(minutes) minutes ago"
        } else if hours < 24 {
            when = hours == 1 ? "1 hour ago" : "\(hours) hours ago"
        } else {
            let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                               to: calendar.startOfDay(for: now)).day ?? 0
            let today = calendar.dateComponents([.year], from: now)
            let day = "\(at.day ?? 1) \(months[((at.month ?? 1) - 1) % 12])"
            when = days == 1 ? "yesterday"
                : at.year == today.year ? day : "\(day) \(at.year ?? 0)"
        }
        return "Last activity \(when) · \(time)"
    }

    /// How long a chat is quiet before its foot says so.
    public static let quietMinutes = 5

    private static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                                 "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
}
