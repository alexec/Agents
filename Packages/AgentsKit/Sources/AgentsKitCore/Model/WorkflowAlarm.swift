import Foundation

/// A one-time workflow trigger (#4966): `on: - once: {at: 2026-11-13T09:15}`. It fires
/// once at its time, or up to its grace late when the Mac was off or asleep, and the
/// workflow then archives itself. The daemon reads the time and fires it; this is what
/// the pages say about it.
///
/// It goes over the wire as a trigger an older reader does not know, named `once`, with
/// the file's keys kept whole, as an event trigger does (042 FR-025). A run's cause also
/// carries `due`, the instant it was set for, so the page can say how late it fired.
public struct WorkflowAlarm: Hashable, Sendable {
    public static let name = "once"

    /// `at:` as the file wrote it: a date and a time, in `time-zone:` or the person's.
    public var at: String
    /// `time-zone:`, when the file names one.
    public var timeZone: String?
    /// `grace:` as the file wrote it, such as `30m`; an hour when it says none.
    public var grace: String?
    /// The instant a run was set for, on a run's cause.
    public var due: Date?
    /// Every key, kept whole for writing back.
    public var keys: [String: JSONValue]

    public init?(keys: [String: JSONValue]) {
        guard let at = keys["at"]?.stringValue, !at.isEmpty else { return nil }
        self.at = at
        self.timeZone = keys["time-zone"]?.stringValue
        self.grace = keys["grace"]?.stringValue
        self.due = keys["due"]?.stringValue.flatMap { ISO8601DateFormatter().date(from: $0) }
        self.keys = keys
    }

    /// How late it may fire: `grace:`, or an hour.
    public var graceSeconds: TimeInterval {
        grace.flatMap(Self.seconds(of:)) ?? 3600
    }

    /// "Once, at 2026-11-13 09:15 in your time zone, or up to 1 hour late", as the daemon
    /// says it to an agent.
    public var summary: String {
        var whereSaid = timeZone.map { " (\($0))" } ?? " in your time zone"
        if at.hasSuffix("Z") || at.range(of: #"[+-]\d\d:\d\d$"#, options: .regularExpression) != nil { whereSaid = "" }
        return "Once, at \(at.replacingOccurrences(of: "T", with: " "))\(whereSaid), or up to \(Self.lengthWords(graceSeconds)) late"
    }

    /// How late a run fired, said after "Last ran …": "on time" or "12 minutes late".
    /// `nil` when the run's cause does not say when it was set for.
    public func lateness(firedAt: Date) -> String? {
        guard let due else { return nil }
        let late = firedAt.timeIntervalSince(due)
        return late < 60 ? "on time" : "\(Self.lengthWords(late)) late"
    }

    /// "30m", "2h", "1d2h" as seconds, as `cooldown:` reads them.
    static func seconds(of text: String) -> TimeInterval? {
        var total: TimeInterval = 0
        var number = ""
        for c in text.trimmingCharacters(in: .whitespaces) {
            if c.isNumber {
                number.append(c)
                continue
            }
            guard let n = Double(number) else { return nil }
            switch c {
            case "m": total += n * 60
            case "h": total += n * 3600
            case "d": total += n * 86400
            case " ": continue
            default: return nil
            }
            number = ""
        }
        return number.isEmpty && total > 0 ? total : nil
    }

    /// "less than a minute", "12 minutes", "2 hours 5 minutes", "3 days", as the daemon
    /// says how late.
    public static func lengthWords(_ seconds: TimeInterval) -> String {
        let m = Int((seconds / 60).rounded())
        func unit(_ n: Int, _ one: String) -> String { n == 1 ? "1 \(one)" : "\(n) \(one)s" }
        if m < 1 { return "less than a minute" }
        if m < 60 { return unit(m, "minute") }
        if m < 48 * 60 {
            let rest = m % 60
            return rest == 0 ? unit(m / 60, "hour") : unit(m / 60, "hour") + " " + unit(rest, "minute")
        }
        return unit(Int((Double(m) / 1440).rounded()), "day")
    }
}
