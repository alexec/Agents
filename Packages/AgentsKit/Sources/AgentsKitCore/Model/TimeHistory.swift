import Foundation

/// Where the time of running chats went, by runtime (#852): the agent working, its tools,
/// waiting for the person, and waiting on others. Drawn on the Time page as the usage
/// charts on Cost are (#823).
///
/// Bounded as `UsageHistory` is: the last 168 hours by the hour and the last 90 days by
/// the day, per runtime. Both tiers are written on every turn. Idle time between turns
/// is not kept: it says how long a chat stays open, not where its work went.
public struct TimeHistory: Codable, Sendable, Hashable {
    /// `yyyy-MM-ddTHH` in the host's own calendar, then runtime id.
    public var hours: [String: [String: TimeBucket]]
    /// `yyyy-MM-dd` in the host's own calendar, then runtime id.
    public var days: [String: [String: TimeBucket]]
    /// The host's hour when this was read, as `UsageHistory.now`.
    public var now: String
    /// The zone those stamps are in, as `UsageHistory.timeZone`.
    public var timeZone: String?
    /// `yyyy-MM-dd`, then the day's recap figures (#985): kept for as many days as `days`.
    public var recap: [String: DayRecap]
    /// The person's records (#985): a handful of values, kept for ever.
    public var records: TimeRecords

    public init(hours: [String: [String: TimeBucket]] = [:],
                days: [String: [String: TimeBucket]] = [:], now: String = "", timeZone: String? = nil,
                recap: [String: DayRecap] = [:], records: TimeRecords = TimeRecords()) {
        self.hours = hours
        self.days = days
        self.now = now
        self.timeZone = timeZone
        self.recap = recap
        self.records = records
    }

    private enum CodingKeys: String, CodingKey { case hours, days, now, timeZone, recap, records }

    /// A file written before #985 has no recap or records.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hours = try container.decode([String: [String: TimeBucket]].self, forKey: .hours)
        days = try container.decode([String: [String: TimeBucket]].self, forKey: .days)
        now = try container.decode(String.self, forKey: .now)
        timeZone = try container.decodeIfPresent(String.self, forKey: .timeZone)
        recap = try container.decodeIfPresent([String: DayRecap].self, forKey: .recap) ?? [:]
        records = try container.decodeIfPresent(TimeRecords.self, forKey: .records) ?? TimeRecords()
    }

    public var isEmpty: Bool { hours.isEmpty && days.isEmpty && recap.isEmpty }

    /// Change a day's recap, and take what it now says as records where they beat the
    /// ones held.
    public mutating func changeRecap(_ day: String, _ change: (inout DayRecap) -> Void) {
        var recap = self.recap[day] ?? DayRecap()
        change(&recap)
        self.recap[day] = recap
        records.note(recap, day: day)
    }

    /// What `gh` said about the pull requests merged on each of these days. A day it
    /// named none of is a day with none.
    public mutating func setPRsMerged(_ counts: [String: Int], on days: [String]) {
        for day in days {
            changeRecap(day) { $0.prsMerged = counts[day] ?? 0 }
        }
    }

    /// Add a stretch of one kind of time, split across the hours it covers, so no hour
    /// holds more than happened in it.
    public mutating func add(_ kind: TimeKind, from start: Date, to end: Date, runtime: String,
                             calendar: Calendar = .current) {
        var from = start
        while from < end {
            let hourStart = calendar.dateInterval(of: .hour, for: from)?.start ?? from
            let next = min(end, calendar.date(byAdding: .hour, value: 1, to: hourStart) ?? end)
            guard next > from else { break }
            var bucket = TimeBucket()
            bucket[kind] = next.timeIntervalSince(from)
            add(bucket, runtime: runtime, hour: UsageHistory.hourStamp(for: from, calendar: calendar))
            from = next
        }
    }

    /// Add a bucket into both tiers.
    public mutating func add(_ bucket: TimeBucket, runtime: String, hour: String) {
        hours[hour, default: [:]][runtime, default: TimeBucket()].add(bucket)
        days[String(hour.prefix(10)), default: [:]][runtime, default: TimeBucket()].add(bucket)
    }

    /// One turn's split, banked as `add` does, and counted as a turn in the hour it ended.
    public mutating func add(_ segments: [TimeSegment], runtime: String, calendar: Calendar = .current) {
        guard let last = segments.last else { return }
        for segment in segments {
            add(segment.kind, from: segment.start, to: segment.end, runtime: runtime, calendar: calendar)
        }
        add(TimeBucket(turns: 1), runtime: runtime, hour: UsageHistory.hourStamp(for: last.end, calendar: calendar))
    }

    /// Drop what is past the bound, by count as `UsageHistory.prune` does.
    public mutating func prune() {
        let hoursKept = Set(hours.keys.sorted().suffix(UsageHistory.hoursKept))
        hours = hours.filter { hoursKept.contains($0.key) }
        let daysKept = Set(days.keys.sorted().suffix(UsageHistory.daysKept))
        days = days.filter { daysKept.contains($0.key) }
        let recapKept = Set(recap.keys.sorted().suffix(UsageHistory.daysKept))
        recap = recap.filter { recapKept.contains($0.key) }
    }
}

/// The four kinds of time in a running chat, drawn in this order from the bottom.
public enum TimeKind: String, Codable, CaseIterable, Sendable, Hashable, Identifiable {
    /// The model thinking and writing: running, and no tool call open.
    case agent
    /// A tool call open, other than an ask or a wait.
    case tools
    /// Waiting on other agents or shared things: `wait_for_event`, `wait_for_agents`, `check_again`, `lease_resource`.
    case others
    /// Waiting for the person: a question, a form, a permission.
    case person

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .agent: "Agent"
        case .tools: "Tools"
        case .others: "Waiting on others"
        case .person: "Waiting for you"
        }
    }
}

/// Seconds of each kind of time, for one runtime in one hour or one day.
public struct TimeBucket: Codable, Sendable, Hashable {
    public var agent: Double
    public var tools: Double
    public var others: Double
    public var person: Double
    /// Turns that ended in the bucket.
    public var turns: Int

    public init(agent: Double = 0, tools: Double = 0, others: Double = 0, person: Double = 0, turns: Int = 0) {
        self.agent = agent
        self.tools = tools
        self.others = others
        self.person = person
        self.turns = turns
    }

    public subscript(kind: TimeKind) -> Double {
        get {
            switch kind {
            case .agent: agent
            case .tools: tools
            case .others: others
            case .person: person
            }
        }
        set {
            switch kind {
            case .agent: agent = newValue
            case .tools: tools = newValue
            case .others: others = newValue
            case .person: person = newValue
            }
        }
    }

    public var total: Double { agent + tools + others + person }

    public mutating func add(_ other: TimeBucket) {
        agent += other.agent
        tools += other.tools
        others += other.others
        person += other.person
        turns += other.turns
    }
}

/// A stretch of one kind of time.
public struct TimeSegment: Sendable, Hashable {
    public var kind: TimeKind
    public var start: Date
    public var end: Date

    public init(_ kind: TimeKind, from start: Date, to end: Date) {
        self.kind = kind
        self.start = start
        self.end = end
    }

    public var seconds: Double { end.timeIntervalSince(start) }
}

/// What a turn's timing is worked out from: the few entries that open or close a
/// stretch. Read from `TranscriptEntry` by the daemon as entries are recorded, and from
/// the bytes of a transcript when the history is seeded.
public enum TimeMark: Sendable, Hashable {
    case state(AgentState, at: Date)
    /// A tool call began. `name` is the runtime's name for it, or its title.
    case toolStarted(id: String, name: String, at: Date)
    case toolEnded(id: String, at: Date)
    /// The person was asked something outside a tool call: a form or a permission.
    case askOpened(id: String, at: Date)
    case askClosed(id: String?, at: Date)

    public var at: Date {
        switch self {
        case .state(_, let at), .toolStarted(_, _, let at), .toolEnded(_, let at),
             .askOpened(_, let at), .askClosed(_, let at): at
        }
    }

    /// The mark an entry makes, if any.
    public static func of(_ entry: TranscriptEntry) -> TimeMark? {
        switch entry.kind {
        case .stateChanged(let state, _):
            return .state(state, at: entry.at)
        case .toolCall(let call):
            guard let id = call.toolCallID else { return nil }
            return .toolStarted(id: id, name: call.name ?? call.title, at: entry.at)
        case .toolCallUpdate(let call):
            guard let id = call.toolCallID, call.status == "completed" || call.status == "failed" else { return nil }
            return .toolEnded(id: id, at: entry.at)
        case .elicitationAsked(let request):
            return .askOpened(id: request.id.uuidString, at: entry.at)
        case .elicitationAnswered(let id, _, _):
            return .askClosed(id: id.uuidString, at: entry.at)
        case .permissionAsked:
            return .askOpened(id: "permission", at: entry.at)
        case .permissionAnswered:
            return .askClosed(id: "permission", at: entry.at)
        default:
            return nil
        }
    }

    /// What kind of time a tool call is, by its name. Matched by the end of the name, as
    /// the app tells its own tools apart: runtimes prefix them differently
    /// (`mcp__agents__`, `mcp.agents.`, `agents_`).
    public static func kind(ofTool name: String) -> TimeKind {
        let name = name.lowercased()
        // Antigravity's own `ask_question` has the app's name, and is the person's time all the
        // same; `ask_form` is the app's name before #2298, in older records. `ask_secret` waits
        // on the person too (#2885).
        if name.hasSuffix("askuserquestion") || name.hasSuffix(AppTool.askQuestion) || name.hasSuffix("ask_form")
            || name.hasSuffix(AppTool.askSecret) {
            return .person
        }
        // `release_resource` ends with `lease_resource`: a release is quick, and a tool.
        if name.hasSuffix(AppTool.releaseResource) { return .tools }
        if name.hasSuffix(AppTool.waitForEvent) || name.hasSuffix(AppTool.waitForAgents)
            || name.hasSuffix(AppTool.checkAgain) || name.hasSuffix(AppTool.leaseResource) { return .others }
        return .tools
    }

    /// A turn's marks cut into stretches of each kind, in order.
    ///
    /// Only time spent running or waiting on the person counts. Where kinds overlap, the
    /// person comes first, then others, then tools; what is left of running is the
    /// agent's. Tool calls that run at the same time count once. A call or an ask still
    /// open at the end closes there.
    public static func segments(_ marks: [TimeMark]) -> [TimeSegment] {
        split(marks).segments
    }

    /// `segments`, and the marks that carry what is still open at the last mark into
    /// whatever follows: the state, and every call or ask not yet closed. A turn too long
    /// to hold whole is banked in parts this way.
    public static func split(_ marks: [TimeMark]) -> (segments: [TimeSegment], carry: [TimeMark]) {
        let marks = marks.sorted { $0.at < $1.at }
        guard let first = marks.first?.at else { return ([], []) }
        // Open things of each kind, by id.
        var state: AgentState?
        var open: [TimeKind: Set<String>] = [:]
        var segments: [TimeSegment] = []
        var since = first

        func current() -> TimeKind? {
            guard state == .running || state == .waitingOnUser else { return nil }
            if state == .waitingOnUser || !(open[.person] ?? []).isEmpty { return .person }
            if !(open[.others] ?? []).isEmpty { return .others }
            if !(open[.tools] ?? []).isEmpty { return .tools }
            return .agent
        }
        var toolKinds: [String: TimeKind] = [:]
        for mark in marks {
            if let kind = current(), mark.at > since {
                if let last = segments.last, last.kind == kind, last.end == since {
                    segments[segments.count - 1].end = mark.at
                } else {
                    segments.append(TimeSegment(kind, from: since, to: mark.at))
                }
            }
            since = mark.at
            switch mark {
            case .state(let next, _):
                state = next
                // A turn's end closes whatever it left open.
                if next != .running && next != .waitingOnUser {
                    open = [:]
                    toolKinds = [:]
                }
            case .toolStarted(let id, let name, _):
                let kind = kind(ofTool: name)
                toolKinds[id] = kind
                open[kind, default: []].insert(id)
            case .toolEnded(let id, _):
                if let kind = toolKinds.removeValue(forKey: id) { open[kind]?.remove(id) }
            case .askOpened(let id, _):
                open[.person, default: []].insert("ask:" + id)
            case .askClosed(let id, _):
                if let id { open[.person]?.remove("ask:" + id) } else { open[.person] = [] }
            }
        }
        var carry: [TimeMark] = []
        if let state, state == .running || state == .waitingOnUser {
            carry.append(.state(state, at: since))
            for (id, kind) in toolKinds.sorted(by: { $0.key < $1.key }) where open[kind]?.contains(id) == true {
                carry.append(.toolStarted(id: id, name: Self.name(of: kind), at: since))
            }
            for ask in (open[.person] ?? []).sorted() where ask.hasPrefix("ask:") {
                carry.append(.askOpened(id: String(ask.dropFirst(4)), at: since))
            }
        }
        return (segments, carry)
    }

    /// A tool name `kind(ofTool:)` reads back as this kind, for a carried call.
    private static func name(of kind: TimeKind) -> String {
        switch kind {
        case .person: AppTool.askQuestion
        case .others: AppTool.waitForEvent
        case .agent, .tools: "tool"
        }
    }
}
