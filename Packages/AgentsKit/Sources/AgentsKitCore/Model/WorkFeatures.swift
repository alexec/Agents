import Foundation

/// Work ▸ Features (#3269, spec 3265), as the web page's `model/workFeatures.ts`: each `feature:`
/// label (`forge/features`) with its epic counts, in the groups of `Group` (#4115); opened, its
/// open epics, each with its progress and its lead, and its loose issues (the open issues with the
/// label and no parent epic).
public enum WorkFeatures {
    /// A feature's name as a title: work is Work.
    public static func title(_ name: String) -> String {
        guard let first = name.first else { return name }
        return first.uppercased() + name.dropFirst()
    }

    /// A feature's counts: "3 epics · 2 open", and "· 4 open issues" when it has open issues
    /// that are not epics (#3741).
    public static func countWords(_ feature: DaemonAPI.ForgeFeature) -> String {
        let epics = "\(feature.epics) \(feature.epics == 1 ? "epic" : "epics") · \(feature.open) open"
        guard let issues = feature.issues, issues > 0 else { return epics }
        return epics + " · \(issues) open \(issues == 1 ? "issue" : "issues")"
    }

    /// A feature with no open epic and no open issue (#3741). A daemon that does not count the
    /// issues says nothing, so none of its features is finished.
    public static func isFinished(_ feature: DaemonAPI.ForgeFeature) -> Bool {
        feature.open == 0 && feature.issues == 0
    }

    /// The groups of the list, from the top (#4115): each feature is in the first one it matches.
    public enum Group: CaseIterable, Sendable {
        /// A session on its work waits for Alex, a pull request waits for Alex's approval, or an
        /// issue is labelled alex-todo.
        case needsYou
        /// A session that is not archived is labelled with one of its open issues or epics.
        case inFlight
        /// Open work and no session on it.
        case idle
        /// No open epic and no open issue (#3741).
        case finished

        /// The group's head: "Needs you", "Finished"; its count follows it in the tertiary colour (#4416).
        public var words: String {
            switch self {
            case .needsYou: return "Needs you"
            case .inFlight: return "In flight"
            case .idle: return "Idle"
            case .finished: return "Finished"
            }
        }
    }

    /// The features in their groups, as the list shows them (#4115): Needs you, In flight and Idle
    /// in their order, Idle the least recently updated first, and Finished at the bottom.
    public static func groups(_ features: [DaemonAPI.ForgeFeature], agents: [Agent] = [], approvals: [String] = [])
        -> [(group: Group, features: [DaemonAPI.ForgeFeature])] {
        let waiting = Set(approvals.map { "P" + WorkList.shortRef($0) })
        var by: [Group: [DaemonAPI.ForgeFeature]] = [:]
        for f in features {
            by[group(f, sessions: sessions(of: f, in: agents), approvals: waiting), default: []].append(f)
        }
        by[.idle]?.sort { ($0.updatedAt ?? .distantPast) < ($1.updatedAt ?? .distantPast) }
        return Group.allCases.compactMap { g in by[g].map { (g, $0) } }
    }

    private static func group(_ f: DaemonAPI.ForgeFeature, sessions: [Agent], approvals: Set<String>) -> Group {
        if isFinished(f) { return .finished }
        if !(f.waiting ?? []).isEmpty || sessions.contains(where: { a in
            a.state == .waitingOnUser || a.labels.contains { approvals.contains($0.value) }
        }) { return .needsYou }
        return sessions.isEmpty ? .idle : .inFlight
    }

    /// The sessions on a feature's work (#4115), of those this app knows: not archived, and
    /// labelled with the short ref of one of its open issues or epics (#3265, or ENG-5), as a lane
    /// and a lead label theirs.
    public static func sessions(of feature: DaemonAPI.ForgeFeature, in agents: [Agent]) -> [Agent] {
        let refs = Set((feature.refs ?? []).map(WorkList.shortRef))
        guard !refs.isEmpty else { return [] }
        return agents.filter { a in a.state != .archived && a.labels.contains { refs.contains($0.value) } }
    }

    /// An In flight feature's sessions: "1 session", "3 sessions".
    public static func sessionWords(_ count: Int) -> String { "\(count) \(count == 1 ? "session" : "sessions")" }

    /// A feature's bar (epic.md, Features note 2): its epics closed, of all; nil with no epic.
    public static func epicsDone(_ feature: DaemonAPI.ForgeFeature) -> Double? {
        feature.epics > 0 ? Double(max(feature.epics - feature.open, 0)) / Double(feature.epics) : nil
    }

    /// The words at a feature's bar: "1 of 2 epics done", "0 of 1 epic done".
    public static func epicsDoneWords(_ feature: DaemonAPI.ForgeFeature) -> String {
        "\(max(feature.epics - feature.open, 0)) of \(feature.epics) \(feature.epics == 1 ? "epic" : "epics") done"
    }

    /// What waits for the person on a Needs you feature (Features note 2): "P#4405 waits for your
    /// approval", "#4290 waits for you", "“Work look: epic page” needs you"; nil with nothing.
    public static func needsWords(_ feature: DaemonAPI.ForgeFeature, sessions: [Agent], approvals: [String]) -> String? {
        let waiting = approvals.map { "P" + WorkList.shortRef($0) }
        if let pr = waiting.first(where: { p in sessions.contains { $0.labels.contains { $0.value == p } } }) {
            return "\(pr) waits for your approval"
        }
        if let ref = feature.waiting?.first { return "\(WorkList.shortRef(ref)) waits for you" }
        if let session = sessions.first(where: { $0.state == .waitingOnUser }) {
            return session.title.map { "“\($0)” needs you" } ?? "A session needs you"
        }
        return nil
    }

    /// The features of several machines as one list, by name: the counts of one feature added up.
    /// Its issues are unknown when one machine does not count them.
    public static func merge(_ lists: [[DaemonAPI.ForgeFeature]]) -> [DaemonAPI.ForgeFeature] {
        var by: [String: DaemonAPI.ForgeFeature] = [:]
        var order: [String] = []
        for f in lists.joined() {
            let key = f.name.lowercased()
            if var had = by[key] {
                had.epics += f.epics
                had.open += f.open
                had.issues = had.issues.flatMap { mine in f.issues.map { mine + $0 } }
                had.color = had.color ?? f.color
                had.refs = union(had.refs, f.refs)
                had.waiting = union(had.waiting, f.waiting)
                had.updatedAt = [had.updatedAt, f.updatedAt].compactMap(\.self).max()
                by[key] = had
            } else {
                by[key] = f
                order.append(key)
            }
        }
        return order.compactMap { by[$0] }.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    private static func union(_ a: [String]?, _ b: [String]?) -> [String]? {
        guard let a else { return b }
        guard let b else { return a }
        return a + b.filter { !a.contains($0) }
    }

    /// An opened feature: its open epics and its loose issues, each once, the last updated first.
    public struct Opened: Equatable, Sendable {
        public var epics: [DaemonAPI.ForgeItem]
        public var loose: [DaemonAPI.ForgeItem]
    }

    /// The open issues with a feature's label, read from `forge/issues`, as the feature shows them:
    /// the epics, and the issues with no parent that are not epics. A child of an epic is in its plan.
    public static func opened(_ items: [DaemonAPI.ForgeItem]) -> Opened {
        var seen = Set<String>()
        let mine = items.filter { $0.node.kind == "issue" && $0.state == "open" && seen.insert($0.node.ref).inserted }
            .sorted { $0.updatedAt > $1.updatedAt }
        return Opened(epics: mine.filter(isEpic), loose: mine.filter { !isEpic($0) && $0.parent == nil })
    }

    /// An epic: labelled epic, or the parent of sub-issues.
    public static func isEpic(_ item: DaemonAPI.ForgeItem) -> Bool {
        item.level == "epic" || (item.progress?.total ?? 0) > 0
    }

    /// An epic's progress: "1 of 6", its closed sub-issues of all; "0 of 0" with none yet.
    public static func progressWords(_ item: DaemonAPI.ForgeItem) -> String {
        "\(item.progress?.done ?? 0) of \(item.progress?.total ?? 0)"
    }

    /// The session that leads an epic, of those this app knows: labelled lead and the epic's short
    /// ref (#3265, or ENG-5 on Linear), as Start lead labels it; not archived; a live one first,
    /// then the newest.
    public static func lead(of epic: DaemonAPI.LineageNode, in agents: [Agent]) -> Agent? {
        let ref = WorkList.shortRef(epic.ref)
        return agents.filter { a in
            a.state != .archived && a.labels.contains { $0.value == "lead" } && a.labels.contains { $0.value == ref }
        }.max { a, b in
            a.state.holdsRuntime != b.state.holdsRuntime ? b.state.holdsRuntime : a.createdAt < b.createdAt
        }
    }

    /// An epic's lead on its row: "● lead working", "● lead needs you", "lead stopped"; "No lead"
    /// with none (features-delivery.md note 7).
    public static func leadWords(_ state: AgentState?) -> String {
        switch state {
        case nil, .archived: return "No lead"
        case .waitingOnUser: return "● lead needs you"
        case .starting, .running: return "● lead working"
        case .finished: return "lead waiting"
        case .stopped: return "lead stopped"
        case .queued: return "lead queued"
        }
    }

    // MARK: The delivery view (#4587, specs/4328-work-look/features-delivery.md)

    /// A feature in Needs you or In flight starts open; Idle and Finished start folded, except Idle
    /// when no feature is in Needs you or In flight (note 3, state 14).
    public static func startsOpen(_ group: Group, in groups: [Group]) -> Bool {
        switch group {
        case .needsYou, .inFlight: return true
        case .idle: return !groups.contains(.needsYou) && !groups.contains(.inFlight)
        case .finished: return false
        }
    }

    /// Where a child is on the page (note 4): closed; open with something for the person; open
    /// with a lane or an open pull request; open with nothing on it.
    public enum Flight: Int, Sendable, Comparable, CaseIterable {
        case needsYou, working, notStarted, done

        public static func < (a: Flight, b: Flight) -> Bool { a.rawValue < b.rawValue }
    }

    /// What works on a child, as the page reads it until `work/features` (#4586) says it: the
    /// sessions labelled with its short ref (a lane labels its issue `#<n>`, and its pull request
    /// `P#<n>`), and that pull request among the open ones read.
    public struct Work: Sendable, Equatable {
        public var sessions: [Agent]
        public var pr: DaemonAPI.ForgeItem?
        /// `work/features` says it waits for the person (`WorkTimelineChild.waitsForPerson`).
        public var waitsForPerson: Bool

        public init(sessions: [Agent] = [], pr: DaemonAPI.ForgeItem? = nil, waitsForPerson: Bool = false) {
            self.sessions = sessions
            self.pr = pr
            self.waitsForPerson = waitsForPerson
        }
    }

    /// A child's work: the sessions this app knows that are labelled with it and not archived,
    /// a live one first; and the open pull request one of them is labelled with, by `P#<n>`.
    public static func work(of item: DaemonAPI.ForgeItem, agents: [Agent], pulls: [String: DaemonAPI.ForgeItem],
                            waiting: Set<String> = []) -> Work {
        let ref = WorkList.shortRef(item.node.ref)
        let mine = agents.filter { a in a.state != .archived && a.labels.contains { $0.value == ref } }
            .sorted { a, b in a.state.holdsRuntime != b.state.holdsRuntime ? a.state.holdsRuntime : a.createdAt > b.createdAt }
        let pr = mine.lazy.flatMap(\.labels).first { $0.value.hasPrefix("P#") && pulls[$0.value] != nil }.flatMap { pulls[$0.value] }
        return Work(sessions: mine, pr: pr, waitsForPerson: waiting.contains(item.node.ref))
    }

    /// The open pull requests read, by the label a lane gives each: *P#45*.
    public static func pullsByLabel(_ pulls: [DaemonAPI.ForgeItem]) -> [String: DaemonAPI.ForgeItem] {
        var by: [String: DaemonAPI.ForgeItem] = [:]
        for p in pulls where p.state == "open" { by["P" + WorkList.shortRef(p.node.ref), default: p] = p }
        return by
    }

    /// A child's flight (note 4, note 8): needs you when it is labelled alex-todo, a session on it
    /// asks a question, or its pull request waits for approval (`approvals`, as *P#45*); working
    /// with a lane or an open pull request.
    public static func flight(_ item: DaemonAPI.ForgeItem, work: Work, approvals: Set<String>) -> Flight {
        if item.state != "open" { return .done }
        if waitsForPerson(item) || work.waitsForPerson || work.sessions.contains(where: { $0.state == .waitingOnUser }) { return .needsYou }
        if let pr = work.pr, approvals.contains("P" + WorkList.shortRef(pr.node.ref)) { return .needsYou }
        return work.sessions.isEmpty && work.pr == nil ? .notStarted : .working
    }

    static func waitsForPerson(_ item: DaemonAPI.ForgeItem) -> Bool {
        item.labels.contains { $0.name.lowercased() == "alex-todo" }
    }

    /// A child in flight, as its line shows it (note 8).
    public struct Line: Sendable, Equatable {
        public var item: DaemonAPI.ForgeItem
        public var flight: Flight
        /// *P#45 waits for your approval*, *Working · “Gift card errors” · checks running*.
        public var words: String
        /// The lane named in the words, for its link to the chat.
        public var lane: Agent?
        public var pr: DaemonAPI.ForgeItem?
    }

    /// A child's line, or nil when it is not in flight (note 8).
    public static func line(_ item: DaemonAPI.ForgeItem, work: Work, approvals: Set<String>) -> Line? {
        let flight = flight(item, work: work, approvals: approvals)
        let prRef = work.pr.map { "P" + WorkList.shortRef($0.node.ref) }
        let lane = work.sessions.first
        switch flight {
        case .done, .notStarted:
            return nil
        case .needsYou:
            let words: String
            if let prRef, approvals.contains(prRef) {
                words = "\(prRef) waits for your approval"
            } else if work.sessions.contains(where: { $0.state == .waitingOnUser }) {
                words = "Needs you · the lane asks a question"
            } else {
                words = "waits for you (alex-todo)"
            }
            return Line(item: item, flight: flight, words: words, lane: work.sessions.first { $0.state == .waitingOnUser } ?? lane,
                        pr: work.pr)
        case .working:
            var parts: [String]
            if let lane { parts = ["Working", "“\(lane.title ?? "A session")”"] } else { parts = ["\(prRef ?? "") open"] }
            if let checks = work.pr.flatMap(checkWords) { parts.append(checks) }
            return Line(item: item, flight: flight, words: parts.joined(separator: " · "), lane: lane, pr: work.pr)
        }
    }

    /// A pull request's checks in words (note 8): *checks running*, *checks failed*, *approved*; nil otherwise.
    public static func checkWords(_ pr: DaemonAPI.ForgeItem) -> String? {
        switch pr.checks {
        case "failing": return "checks failed"
        case "running", "pending": return "checks running"
        default: return pr.review == "approved" ? "approved" : nil
        }
    }

    /// The most lines in flight an epic shows before *2 more in flight* (note 8); a phone's (note 14).
    public static let shownInFlight = 5
    public static let shownInFlightOnPhone = 2

    /// The children in flight, as the page lists them: Needs you first, then Working, each the
    /// most recently updated first.
    public static func inFlight(_ items: [DaemonAPI.ForgeItem], work: (DaemonAPI.ForgeItem) -> Work,
                                approvals: Set<String>) -> [Line] {
        items.compactMap { line($0, work: work($0), approvals: approvals) }
            .sorted { a, b in a.flight != b.flight ? a.flight < b.flight : a.item.updatedAt > b.item.updatedAt }
    }

    /// A bar's three parts (note 4): done, in flight and not started, of the children counted.
    public struct Tally: Sendable, Equatable {
        public var done = 0
        public var inFlight = 0
        public var notStarted = 0

        public init(done: Int = 0, inFlight: Int = 0, notStarted: Int = 0) {
            self.done = done
            self.inFlight = inFlight
            self.notStarted = notStarted
        }

        public var total: Int { done + inFlight + notStarted }

        /// The bar's parts as shares: done (purple), in flight (green); the rest is grey.
        public var shares: (done: Double, inFlight: Double) {
            total > 0 ? (Double(done) / Double(total), Double(inFlight) / Double(total)) : (0, 0)
        }

        /// *9 of 21 done*; *4 of 9* on an epic's line.
        public var words: String { "\(done) of \(total) done" }
        public var epicWords: String { "\(done) of \(total)" }

        public static func + (a: Tally, b: Tally) -> Tally {
            Tally(done: a.done + b.done, inFlight: a.inFlight + b.inFlight, notStarted: a.notStarted + b.notStarted)
        }
    }

    public static func tally(_ items: [DaemonAPI.ForgeItem], work: (DaemonAPI.ForgeItem) -> Work, approvals: Set<String>) -> Tally {
        var t = Tally()
        for item in items {
            switch flight(item, work: work(item), approvals: approvals) {
            case .done: t.done += 1
            case .needsYou, .working: t.inFlight += 1
            case .notStarted: t.notStarted += 1
            }
        }
        return t
    }

    /// An epic's tally before its plan is read (note 16): its closed sub-issues of all.
    public static func tally(progress epic: DaemonAPI.ForgeItem) -> Tally {
        let done = epic.progress?.done ?? 0
        return Tally(done: done, notStarted: max((epic.progress?.total ?? 0) - done, 0))
    }

    /// An open epic as its line needs it, from `work/features` or, from an older daemon, from
    /// `forge/plan` and `lineage/forecast` (note 16): its children, the first step with an open
    /// child of all its steps, that step's open blockers outside the plan, and its forecast.
    public struct Place: Sendable, Equatable {
        public var children: [DaemonAPI.ForgeItem]
        public var step: Int?
        public var steps: Int
        public var blockedOutside: [DaemonAPI.LineageNode]
        public var closes: Date?
        /// The forecast waits for the person (the Timeline's `forecast.waits`, note 12).
        public var waits: Bool

        public init(children: [DaemonAPI.ForgeItem], step: Int? = nil, steps: Int = 0,
                    blockedOutside: [DaemonAPI.LineageNode] = [], closes: Date? = nil, waits: Bool = false) {
            self.children = children
            self.step = step
            self.steps = steps
            self.blockedOutside = blockedOutside
            self.closes = closes
            self.waits = waits
        }
    }

    /// An epic's place from `work/features`; nil when its plan could not be read.
    public static func place(_ epic: DaemonAPI.WorkFeatureEpic) -> Place? {
        guard let children = epic.children else { return nil }
        return Place(children: children.map(\.item), step: epic.step, steps: epic.steps,
                     blockedOutside: epic.blockedOutside ?? [], closes: epic.forecast?.mid, waits: epic.forecast?.waits == true)
    }

    /// An epic's place from `forge/plan` and its forecast's P50, for an older daemon (note 16).
    public static func place(_ plan: DaemonAPI.ForgePlan, closes: Date?) -> Place {
        let open = plan.children.filter { $0.item.state == "open" }
        let step = open.map(\.step).min()
        var outside: [DaemonAPI.LineageNode] = []
        for child in open where child.step == step {
            for b in child.blockedOutside ?? [] where !outside.contains(b) { outside.append(b) }
        }
        return Place(children: plan.children.map(\.item), step: step, steps: plan.steps.count, blockedOutside: outside,
                     closes: closes)
    }

    /// Where an epic is in its plan (note 5, note 12): *step 2 of 3*, *· waits for #10* when its
    /// first open step waits on an open issue outside the plan, *· closes about Thu* from its
    /// forecast, or *· waits for you* when the forecast waits. Nil for a plan with no open child.
    public static func whereWords(_ place: Place, now: Date = Date(), calendar: Calendar = .current) -> String? {
        guard let step = place.step, place.steps > 0 else { return nil }
        var parts = ["step \(step) of \(place.steps)"]
        var outside: [String] = []
        for b in place.blockedOutside where !outside.contains(WorkList.shortRef(b.ref)) { outside.append(WorkList.shortRef(b.ref)) }
        if !outside.isEmpty { parts.append("waits for \(outside.joined(separator: ", "))") }
        if place.waits {
            parts.append("waits for you")
        } else if let closes = place.closes {
            parts.append("closes about \(dayWords(closes, now: now, calendar: calendar))")
        }
        return parts.joined(separator: " · ")
    }

    /// `work/features`' features as one list, as `merge` does `forge/features`'; with each
    /// feature's open epics and loose issues as items, by name in lower case; each epic's place by
    /// ref; the refs `work/features` says wait for the person.
    public struct Read: Sendable, Equatable {
        public var features: [DaemonAPI.ForgeFeature] = []
        public var items: [String: [DaemonAPI.ForgeItem]] = [:]
        public var places: [String: Place] = [:]
        /// The epics whose plan could not be read.
        public var unread: Set<String> = []
        public var waiting: Set<String> = []

        public init() {}
    }

    public static func read(_ lists: [DaemonAPI.WorkFeatures]) -> Read {
        var out = Read()
        out.features = merge(lists.map { $0.features.map(\.feature) })
        for f in lists.flatMap(\.features) {
            let key = f.feature.name.lowercased()
            out.items[key, default: []] += f.epics.map(\.item) + f.loose.map(\.item)
            for epic in f.epics {
                if let place = place(epic) { out.places[epic.item.node.ref] = place } else { out.unread.insert(epic.item.node.ref) }
                for child in epic.children ?? [] where child.waitsForPerson == true { out.waiting.insert(child.item.node.ref) }
            }
            for child in f.loose where child.waitsForPerson == true { out.waiting.insert(child.item.node.ref) }
        }
        return out
    }

    /// A forecast's day: *today*, *tomorrow*, *Thu* within a week, else *Nov 20*.
    static func dayWords(_ date: Date, now: Date, calendar: Calendar) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
        if days <= 0 { return "today" }
        if days == 1 { return "tomorrow" }
        let style = Date.FormatStyle(timeZone: calendar.timeZone)
        return days < 7 ? date.formatted(style.weekday(.abbreviated)) : date.formatted(style.month(.abbreviated).day())
    }

    /// The rest under an epic's lines (note 9): *2 more not started · 4 done*, or *2 not started*
    /// under *Nothing in flight*; nil with neither. The page adds *open the epic for the plan* as a link.
    public static func restWords(_ tally: Tally, afterLines: Bool = true) -> String? {
        var parts: [String] = []
        if tally.notStarted > 0 { parts.append("\(tally.notStarted) \(afterLines ? "more " : "")not started") }
        if tally.done > 0 { parts.append("\(tally.done) done") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// *2 more in flight*: the lines past those shown (note 8).
    public static func moreInFlightWords(_ more: Int) -> String { "\(more) more in flight" }

    /// The rest on a phone, one line (note 15): *1 more in flight · 2 not started · 4 done*.
    public static func phoneRestWords(_ tally: Tally, moreInFlight: Int) -> String? {
        var parts: [String] = []
        if moreInFlight > 0 { parts.append("\(moreInFlight) more in flight") }
        if tally.notStarted > 0 { parts.append("\(tally.notStarted) not started") }
        if tally.done > 0 { parts.append("\(tally.done) done") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// A feature's line 2 (note 3): *2 epics · 4 in flight*, *1 epic · 2 in flight · 2 sessions*,
    /// *1 epic · nothing in flight · updated 3 d ago*. The epics are its open ones, or all of them
    /// when none is open; `inFlight` is nil while its children are read (an Idle feature folded
    /// has none: no session is on its work).
    public static func deliveryWords(_ feature: DaemonAPI.ForgeFeature, inFlight: Int?, sessions: Int?,
                                     now: Date = Date()) -> String {
        let epics = feature.open > 0 ? feature.open : feature.epics
        var parts = epics > 0 || feature.issues == nil ? ["\(epics) \(epics == 1 ? "epic" : "epics")"] : []
        if let issues = feature.issues, issues > 0, epics == 0 { parts.append("\(issues) open \(issues == 1 ? "issue" : "issues")") }
        if let inFlight, inFlight > 0 { parts.append("\(inFlight) in flight") }
        if let sessions, sessions > 0 { parts.append(sessionWords(sessions)) }
        if inFlight == 0 {
            parts.append("nothing in flight")
            if let at = feature.updatedAt {
                let age = WorkLook.ageWords(now.timeIntervalSince(at))
                parts.append(age == "now" ? "updated now" : "updated \(age) ago")
            }
        }
        return parts.joined(separator: " · ")
    }

    /// Under an epic with nothing in flight (note 10).
    public static let nothingInFlight = "Nothing in flight"
    /// The link at the end of the rest (note 9).
    public static let openThePlan = "open the epic for the plan"
    /// In place of an epic's children while they are read (state 13).
    public static let reading = "reading…"
    /// The loose issues' heading (note 11), and *3 more not started* under their lines.
    public static let looseHeading = "Issues with no epic"

    /// When no feature is on any epic yet (states board, 10): the title, then two lines.
    public static let noFeaturesTitle = "No features yet"
    public static let noFeatures = "A feature is a feature:<name> label on an epic."
    public static let noFeaturesLabel = "Label an epic on its forge to see it here."
    /// An opened feature with no open epics or loose issues.
    public static let nothingOpen = "No open epics or issues."
}
