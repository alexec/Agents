import Foundation

/// The Hours setting on a workflow's Configuration (#4820): what each of its controls writes.
/// The web page's `model/workflowHours.ts` is its twin. Every change is a whole `hours:`, and
/// one that limits nothing (no `between:`, no `days:`) is Any time, which takes the key out.
extension WorkflowHours {
    /// What Some hours writes first: working hours.
    public static let working = WorkflowHours(between: "09:00-17:00", days: [.mon, .tue, .wed, .thu, .fri])

    /// The times the From and To menus offer: every half hour, as minutes of the day.
    public static let halfHours = Array(stride(from: 0, to: 24 * 60, by: 30))

    /// The days the control shows, as `words` orders them.
    public static let shownDays = Weekday.allCases

    /// Minutes of the day as the file writes them: `09:00`, `18:30`.
    public static func clockText(_ minutes: Int) -> String {
        String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }

    /// A day as the control names it: `Mon`.
    public static func dayName(_ day: Weekday) -> String { day.rawValue.capitalized }

    /// Whether it limits when the workflow starts; false is Any time.
    public var limits: Bool { named != nil || between != nil || days != nil }

    /// The Hours menu's choices (#4821): Any time, the project's working hours, outside
    /// them, or hours of its own.
    public enum Choice: String, CaseIterable, Hashable, Sendable {
        case anyTime, working, notWorking, some

        public var title: String {
            switch self {
            case .anyTime: "Any time"
            case .working: "Working hours"
            case .notWorking: "Outside working hours"
            case .some: "Some hours"
            }
        }
    }

    /// What the Hours menu shows.
    public var choice: Choice {
        switch named {
        case .working: .working
        case .notWorking: .notWorking
        case nil: limits ? .some : .anyTime
        }
    }

    /// What a choice writes: Some hours first writes working hours' times, or the project's.
    public static func chosen(_ choice: Choice, project: WorkflowHours? = nil) -> WorkflowHours {
        switch choice {
        case .anyTime: WorkflowHours()
        case .working: WorkflowHours(named: .working)
        case .notWorking: WorkflowHours(named: .notWorking)
        case .some: project.map { WorkflowHours(between: $0.between, days: $0.days, timeZone: $0.timeZone) } ?? .working
        }
    }

    /// Project Settings ▸ General's Working hours line (#4821).
    public static func workingSentence(_ hours: WorkflowHours?) -> String {
        let shown = hours ?? .working
        let words = shown.sentence(viewer: .current).map { $0.replacingOccurrences(of: "Runs ", with: "") } ?? "all day"
        return "Working hours are \(words)\(hours == nil ? " (the default)" : ""). A workflow with `hours: working` "
            + "starts only in them, and one with `hours: not-working` only outside them. Saved in .agents/folder.json."
    }

    /// `between:` as minutes of the day; nil is the whole day (or text the daemon refuses).
    public var window: (from: Int, to: Int)? {
        guard let between, case .success(let w) = Self.parse(between: between) else { return nil }
        return w
    }

    /// Whether the day's box is ticked: every day is, with no `days:`.
    public func admits(_ day: Weekday) -> Bool { days?.contains(day) ?? true }

    /// From set to a time, or to All day with nil. Coming from All day, or onto the To time,
    /// the window is eight hours long.
    public func starting(at minute: Int?) -> WorkflowHours {
        var out = self
        guard let minute else {
            out.between = nil
            return out
        }
        var to = window?.to ?? (minute + 8 * 60) % (24 * 60)
        if to == minute { to = (minute + 8 * 60) % (24 * 60) }
        out.between = "\(Self.clockText(minute))-\(Self.clockText(to))"
        return out
    }

    /// To set to a time; nil when there is no From, or it is the From time.
    public func ending(at minute: Int) -> WorkflowHours? {
        guard let from = window?.from, from != minute else { return nil }
        var out = self
        out.between = "\(Self.clockText(from))-\(Self.clockText(minute))"
        return out
    }

    /// A day's box ticked or not; nil when it would leave no day. Every day is no `days:`.
    public func toggling(_ day: Weekday) -> WorkflowHours? {
        var set = Set(days ?? Weekday.allCases)
        if set.contains(day) { set.remove(day) } else { set.insert(day) }
        guard !set.isEmpty else { return nil }
        var out = self
        out.days = set.count == Weekday.allCases.count ? nil : Weekday.allCases.filter(set.contains)
        return out
    }

    /// The time zone menu's choice: nil is Your time zone.
    public func inZone(_ zone: String?) -> WorkflowHours {
        var out = self
        out.timeZone = zone
        return out
    }

    /// The sentence beside the control.
    public static func sentence(_ hours: WorkflowHours?) -> String {
        guard let hours, let words = hours.words else {
            return "Any time: a trigger starts it at any hour."
        }
        if hours.named != nil {
            return "Starts \(words), as Project Settings sets them. A trigger outside them waits, and starts it once they open."
        }
        return "Starts \(words). A trigger outside them waits, and starts it once they open."
    }

    /// The time zones the menu offers, after Your time zone: the file's own too, when it is
    /// not one this Mac knows.
    public static func zones(with current: String?) -> [String] {
        let known = TimeZone.knownTimeZoneIdentifiers
        guard let current, !known.contains(current) else { return known }
        return (known + [current]).sorted()
    }
}
