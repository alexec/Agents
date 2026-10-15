import Foundation

/// Whether this Mac is kept awake for agents, and for how long after they stop.
///
/// The person's, kept by the daemon, because the hold is the daemon's and the window
/// may be closed. Missing or unreadable is the default: on, for one hour. A value this
/// build does not understand is clamped into range rather than turning the hold off.
public struct WakeSettings: Codable, Hashable, Sendable {
    /// While an agent is working, and then for `graceHours` afterwards.
    public var keepsAwake: Bool
    /// Whole hours after the last agent stops, from none to eight.
    public var graceHours: Int
    /// How many finished sessions keep their runtime running, ready for a reply (#183).
    /// Beside the hold because it is the same kind of choice: what this Mac spends on
    /// agents between turns. A warm runtime never holds the Mac awake.
    public var warmRuntimes: Int
    /// While the Mac is on power, hold it awake with no agent working too (#992), so
    /// scheduled workflows fire at their time and the CI events are polled while the
    /// person is away. Off by default: it changes what the Mac spends. On battery it
    /// does nothing. Only with `keepsAwake` on.
    public var awakeOnPower: Bool

    public static let hours = 0...8
    public static let warmRange = 0...8

    public init(keepsAwake: Bool = true, graceHours: Int = 1, warmRuntimes: Int = 3,
                awakeOnPower: Bool = false) {
        self.keepsAwake = keepsAwake
        self.awakeOnPower = awakeOnPower
        self.graceHours = Self.clamp(graceHours)
        self.warmRuntimes = min(max(warmRuntimes, Self.warmRange.lowerBound), Self.warmRange.upperBound)
    }

    /// The grace as a duration. Zero is the hold ending when the work does.
    public var graceInterval: TimeInterval { TimeInterval(graceHours) * 3_600 }

    public static func clamp(_ value: Int) -> Int {
        min(max(value, hours.lowerBound), hours.upperBound)
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        keepsAwake = (try? c.decode(Bool.self, forKey: .keepsAwake)) ?? true
        graceHours = Self.clamp((try? c.decode(Int.self, forKey: .graceHours)) ?? 1)
        let warm = (try? c.decode(Int.self, forKey: .warmRuntimes)) ?? 3
        warmRuntimes = min(max(warm, Self.warmRange.lowerBound), Self.warmRange.upperBound)
        // Missing is off, so a file from before #992 keeps the current behaviour.
        awakeOnPower = (try? c.decode(Bool.self, forKey: .awakeOnPower)) ?? false
    }
}

/// The sentences the sidebar uses while a grace is running.
public enum WakeWords {
    /// "Until 3:40 pm", or "Until tomorrow, 1:10 am" when the grace crosses midnight.
    /// The clock does not count down: the time is when the hold ends.
    public static func untilLine(_ until: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let time = until.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(calendar.locale ?? .current))
        if calendar.isDate(until, inSameDayAs: now) { return "Until \(time)" }
        if let next = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)),
           calendar.isDate(until, inSameDayAs: next) {
            return "Until tomorrow, \(time)"
        }
        let day = until.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(calendar.locale ?? .current))
        return "Until \(day), \(time)"
    }

    /// The sidebar row while the hold is for the power, not for an agent (#992).
    public static let onPowerLine = "Awake while on power"

    public static let onPowerHelp = "This Mac is on power, so it stays awake for scheduled workflows and new "
        + "issues, also with no agent working. The display still sleeps."

    public static func graceHelp(_ until: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let when = untilLine(until, now: now, calendar: calendar).replacingOccurrences(of: "Until ", with: "")
        return "The last agent stopped. This Mac stays awake until \(when) so you can reply."
    }
}
