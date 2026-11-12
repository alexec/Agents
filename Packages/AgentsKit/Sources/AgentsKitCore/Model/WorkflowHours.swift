import Foundation

/// When a workflow may start (#4818), from the file's `hours:`, for every trigger:
///
/// ```yaml
/// hours:
///   between: "18:00-09:00"     # can go past midnight
///   days: [mon, tue, wed, thu, fri]
///   time-zone: Europe/London   # optional, an IANA name
/// ```
///
/// A fire outside it is held, one as the cooldown holds one, and starts when it opens; Run
/// now always runs. A window past midnight belongs to the day it starts on. The daemon reads
/// the file and decides; this is its twin, as `WorkflowCooldown` is, for the pages that show
/// it and the control that writes it.
public struct WorkflowHours: Codable, Hashable, Sendable {
    /// As the file says it, `09:00-18:00`; nil is the whole day.
    public var between: String?
    /// The days its window starts on; nil is every day.
    public var days: [Weekday]?
    /// `time-zone:`, an IANA name; nil is the person's time zone, else the host's.
    public var timeZone: String?

    /// The key, as the file spells it.
    public static let key = "hours"

    public init(between: String? = nil, days: [Weekday]? = nil, timeZone: String? = nil) {
        self.between = between
        self.days = days
        self.timeZone = timeZone
    }

    /// A `between:` range as minutes of the day, from and to, as the daemon's parseBetween
    /// reads it: hours, or hours and `:00` or `:30`. `from` after `to` goes past midnight.
    public static func parse(between text: String) -> Result<(from: Int, to: Int), Failure> {
        let halves = text.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard halves.count == 2, let from = clock(halves[0]), let to = clock(halves[1]) else {
            return .failure(Failure(text: text))
        }
        guard from != to else { return .failure(Failure(text: text, isEmpty: true)) }
        return .success((from, to))
    }

    private static func clock(_ part: Substring) -> Int? {
        let parts = part.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), let hour = Int(parts[0]), (0...23).contains(hour) else { return nil }
        guard parts.count == 2 else { return hour * 60 }
        guard let minute = Int(parts[1]), minute == 0 || minute == 30 else { return nil }
        return hour * 60 + minute
    }

    /// Why a `between:` could not be read, as the daemon says it.
    public struct Failure: Error, Hashable, Sendable {
        public var text: String
        public var isEmpty = false

        public var message: String {
            isEmpty ? "\"\(text)\" starts and ends at the same time"
                    : "\"\(text)\" is not a range of times, like \"09:00-18:00\""
        }
    }

    /// The hours in words: `only 18:00-09:00 on Mon, Tue (Europe/London)`, as manage_workflows
    /// says them. nil for hours that limit nothing.
    public var words: String? {
        guard between != nil || days != nil else { return nil }
        var out = "only"
        if let between { out += " \(between)" }
        if let days {
            out += " on " + Weekday.allCases.filter(days.contains).map(\.rawValue.capitalized).joined(separator: ", ")
        }
        if let timeZone { out += " (\(timeZone))" }
        return out
    }
}
