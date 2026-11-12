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

// MARK: Said on the status card and the row (#4819)

extension WorkflowHours {
    /// The zone its times are in: the file's `time-zone:`, else the viewer's own (the
    /// person's, which their Mac sets from its clock).
    public func zone(viewer: TimeZone) -> TimeZone {
        timeZone.flatMap(TimeZone.init(identifier:)) ?? viewer
    }

    /// The zone's name, only when the file names one that is not the viewer's own.
    public func zoneNote(viewer: TimeZone) -> String? {
        guard let timeZone, timeZone != viewer.identifier else { return nil }
        return timeZone
    }

    /// The window in words: `Runs 09:00–18:00, Mon–Fri`, and `(Europe/London)` after it
    /// when that is not the viewer's zone. nil for hours that limit nothing.
    public func sentence(viewer: TimeZone) -> String? {
        if let days, days.isEmpty { return "Never runs on its own: its hours name no day" }
        let time = between.map { text -> String in
            guard case .success(let range) = Self.parse(between: text) else { return text }
            return "\(Self.clock(minutes: range.from))–\(Self.clock(minutes: range.to))"
        }
        let day = days.flatMap(Self.dayWords)
        guard time != nil || day != nil else { return nil }
        var out = "Runs " + [time, day].compactMap { $0 }.joined(separator: ", ")
        if let note = zoneNote(viewer: viewer) { out += " (\(note))" }
        return out
    }

    /// Mon to Sun, as a working week reads.
    static let weekOrder: [Weekday] = [.mon, .tue, .wed, .thu, .fri, .sat, .sun]

    /// `Mon–Fri`, `Mon, Wed, Fri`, `Sat, Sun`: three days or more in a row as a range.
    /// nil for every day.
    static func dayWords(_ days: [Weekday]) -> String? {
        let set = Set(days)
        guard set != Weekday.everyDay else { return nil }
        var parts: [String] = []
        var run: [Weekday] = []
        func flush() {
            if run.count >= 3, let first = run.first, let last = run.last {
                parts.append("\(first.rawValue.capitalized)–\(last.rawValue.capitalized)")
            } else {
                parts += run.map(\.rawValue.capitalized)
            }
            run = []
        }
        for day in weekOrder {
            if set.contains(day) { run.append(day) } else { flush() }
        }
        flush()
        return parts.joined(separator: ", ")
    }

    /// `09:00`, from minutes of the day.
    static func clock(minutes: Int) -> String {
        String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }

    /// `Mon 09:00`, in `zone`, on a 24-hour clock as the file writes its hours.
    public static func dayAndClock(_ date: Date, in zone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = "EEE HH:mm"
        return formatter.string(from: date)
    }
}

extension WorkflowSummary {
    /// When its hours open, while they are shut (#4819): `Waits for its hours: opens Mon
    /// 09:00` with a trigger held, `Outside its hours: opens Mon 09:00` with none. In the
    /// hours' zone, named when it is not the viewer's own.
    public func hoursOpenSentence(viewer: TimeZone = .current) -> String? {
        guard let at = hoursOpenAt else { return nil }
        let hours = workflow.hours ?? WorkflowHours()
        var when = WorkflowHours.dayAndClock(at, in: hours.zone(viewer: viewer))
        if let note = hours.zoneNote(viewer: viewer) { when += " (\(note))" }
        return (holdsAFire ? "Waits for its hours" : "Outside its hours") + ": opens \(when)"
    }

    /// Whether a trigger is held until its hours open: the row's hourglass (#4819).
    public var waitsForItsHours: Bool { holdsAFire && hoursOpenAt != nil }
}
