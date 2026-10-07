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
}
