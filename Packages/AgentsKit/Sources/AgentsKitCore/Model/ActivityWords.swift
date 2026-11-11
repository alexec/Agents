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

    /// How long a chat has been quiet, and how old the session is, at the foot of its
    /// transcript (#1564): "Last activity 12 minutes ago · started 3 hours ago". Nil under
    /// five minutes of quiet, and for a date ahead of `now`. Both are a time ago, never a
    /// clock time or a day (`ago`). The page has its own copy (`quietLine` in
    /// `Web/src/model/activity.ts`), held to `Fixtures/web/activity/quiet.json`.
    public static func quiet(since date: Date, startedAt: Date, now: Date = Date()) -> String? {
        let minutes = Int((now.timeIntervalSince(date) / 60).rounded(.down))
        guard minutes >= quietMinutes else { return nil }
        // Never younger than its quiet: a host's clock can put the start a little late.
        let age = max(minutes, Int((now.timeIntervalSince(startedAt) / 60).rounded(.down)))
        return "Last activity \(ago(minutes)) · started \(ago(age))"
    }

    /// Whole minutes as a time ago, rounded down to the largest unit: "5 minutes ago",
    /// "1 hour ago", "3 days ago".
    static func ago(_ minutes: Int) -> String {
        let hours = minutes / 60
        let (count, unit) = hours < 1 ? (minutes, "minute") : hours < 24 ? (hours, "hour") : (hours / 24, "day")
        return count == 1 ? "1 \(unit) ago" : "\(count) \(unit)s ago"
    }

    /// When a prompt was sent, on its row of the Prompts list (#1658): "14:05" today,
    /// "3 Oct 14:05" this year, "3 Oct 2025 14:05" before. The page has its own copy
    /// (`sentWords` in `Web/src/model/sessionPrompts.ts`).
    public static func sent(_ date: Date, now: Date = Date(), timeZone: TimeZone = .current) -> String {
        // One calendar for every row, read in the zone asked (#1850).
        let at = gregorian.dateComponents(in: timeZone, from: date)
        let today = gregorian.dateComponents(in: timeZone, from: now)
        let time = String(format: "%02d:%02d", at.hour ?? 0, at.minute ?? 0)
        if at.year == today.year, at.month == today.month, at.day == today.day { return time }
        let day = "\(at.day ?? 1) \(months[((at.month ?? 1) - 1) % 12])"
        return at.year == today.year ? "\(day) \(time)" : "\(day) \(at.year ?? 0) \(time)"
    }

    /// How long a chat is quiet before its foot says so.
    public static let quietMinutes = 5

    private static let gregorian = Calendar(identifier: .gregorian)
    private static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                                 "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
}
