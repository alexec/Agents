import Foundation

/// The arithmetic and the words of the parts every Work page draws (#4391, `specs/4328-work-look/parts.md`):
/// the state icon, the two-line row, the label chip in its colour, the filter bar's menus, the
/// avatar with no image, and the empty states. `Shared/UI/Work` draws them for the Mac window and
/// the Remote; `Web/src/views/Work*.tsx` draws the same for the web page (#4392).
public enum WorkLook {
    // MARK: 1. The state icon

    /// The glyph at the start of a row, by the item's kind and state.
    public enum Glyph: String, Sendable, CaseIterable {
        case issueOpen, issueDone, issueNotPlanned, prOpen, prDraft, prMerged, prClosed

        /// The colour of the state, as the forge draws it: these say the item's state on its forge,
        /// not the app's (`StateTint`).
        public var tone: Tone {
            switch self {
            case .issueOpen, .prOpen: .green
            case .issueDone, .prMerged: .purple
            case .issueNotPlanned, .prDraft: .grey
            case .prClosed: .red
            }
        }

        /// What a screen reader says, so the colour is never the only sign.
        public var accessibilityLabel: String {
            switch self {
            case .issueOpen: "Open issue"
            case .issueDone: "Closed issue"
            case .issueNotPlanned: "Closed issue, not planned"
            case .prOpen: "Open pull request"
            case .prDraft: "Draft pull request"
            case .prMerged: "Merged pull request"
            case .prClosed: "Closed pull request"
            }
        }
    }

    /// The four state colours (GitHub's own, as parts.md section 1 sets them). Their values are
    /// `design/tokens.json`'s `color.forge` and `Shared/UI/Paper.swift`'s `forge…` (#4618).
    public enum Tone: String, Sendable, CaseIterable {
        case green, purple, grey, red
    }

    /// The glyph of an issue or a pull request; nil for a release, or a state no one
    /// said. `stateReason` is the forge's `not_planned` where it gives one (#4365); until then a
    /// closed issue is done.
    public static func glyph(kind: String, state: String, draft: Bool = false, stateReason: String? = nil) -> Glyph? {
        switch (kind, state) {
        case ("issue", "open"): .issueOpen
        case ("issue", "closed"), ("issue", "merged"): stateReason == "not_planned" ? .issueNotPlanned : .issueDone
        case ("pr", "open"): draft ? .prDraft : .prOpen
        case ("pr", "merged"): .prMerged
        case ("pr", "closed"): .prClosed
        default: nil
        }
    }

    // MARK: 2. The row

    /// An age as the row says it: "now", "5 min", "2 h", "3 d", "4 mo", "2 y".
    public static func ageWords(_ seconds: TimeInterval) -> String {
        let s = max(seconds, 0)
        if s < 60 { return "now" }
        if s < 3600 { return "\(Int(s / 60)) min" }
        if s < 86_400 { return "\(Int(s / 3600)) h" }
        if s < 86_400 * 30 { return "\(Int(s / 86_400)) d" }
        if s < 86_400 * 365 { return "\(Int(s / (86_400 * 30))) mo" }
        return "\(Int(s / (86_400 * 365))) y"
    }

    /// What lineage knows, short, for the row's second line: "2 sessions · $0.42"; nil with none.
    /// On a phone only the cost, or the sessions when nothing was spent.
    public static func lineageWords(_ n: DaemonAPI.ReportNode?, compact: Bool) -> String? {
        guard let n else { return nil }
        let cost = ReportValueWords.spent(n.cost.total) ? ReportValueWords.cost(n.cost.total) : nil
        let sessions = n.sessions == 0 ? nil : n.sessions == 1 ? "1 session" : "\(n.sessions) sessions"
        if compact { return cost ?? sessions }
        let parts = [sessions, cost].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "2 h ago", or "now".
    public static func ago(_ at: Date, now: Date = Date()) -> String {
        let age = ageWords(now.timeIntervalSince(at))
        return age == "now" ? age : "\(age) ago"
    }

    /// The time a row's second line says, and its verb: an open item's opening, a closed or
    /// merged one's close, where the forge says them (#4373); else the last update.
    static func rowTime(_ row: WorkList.Row) -> (verb: String, at: Date) {
        switch row.state {
        case "open": if let created = row.created { return ("opened", created) }
        case "closed", "merged": if let closed = row.closed { return (row.state, closed) }
        default: break
        }
        return ("updated", row.updated)
    }

    /// The row's second line. Wide: "#4328 · opened 2 h ago by alexec · 2 sessions · $0.42";
    /// closed: "#4328 · closed 5 d ago", and "not planned" at the end for one closed so (lists.md
    /// section 2, note 13). On a phone: "#4328 · 2 h · alexec · $0.42". With no lineage it ends
    /// after the author; a forge that gives no opened or closed time says the last update's.
    public static func rowLine(_ row: WorkList.Row, compact: Bool, now: Date = Date()) -> String {
        var parts: [String] = []
        if !WorkList.titleSaysRef(row.title, row.node.ref) { parts.append(WorkList.shortRef(row.node.ref)) }
        // A draft says so in grey after its number (lists.md section 2), as its grey glyph does.
        if row.draft, row.state == "open" { parts.append("Draft") }
        if let status = row.status, !status.isEmpty { parts.append(status) }
        let time = rowTime(row)
        if row.node.kind == "release" {
            // Lineage's links to a release are at its tag's commit time (#4421).
            parts.append(WorkReleaseLook.releasedWords(row.updated, compact: compact, now: now))
        } else if compact {
            parts.append(ageWords(now.timeIntervalSince(time.at)))
            if let author = row.author { parts.append(author) }
        } else {
            let when = "\(time.verb) \(ago(time.at, now: now))"
            // "closed 5 d ago by alexec" would name the closer: the author goes with the opening.
            let byAuthor = ["opened", "updated"].contains(time.verb)
            parts.append(byAuthor ? row.author.map { "\(when) by \($0)" } ?? when : when)
        }
        if let lineage = lineageWords(row.lineage, compact: compact) { parts.append(lineage) }
        if row.node.kind == "issue", row.state == "closed", row.stateReason == "not_planned" { parts.append("not planned") }
        return parts.joined(separator: " · ")
    }

    /// An issue's state line after its pill. Wide: "alexec opened this 3 d ago · closed 1 d ago ·
    /// 4 comments"; on a phone: "alexec · 3 d · 4 comments". With no opened time from the forge
    /// (#4373): "alexec opened this · updated 2 h ago".
    public static func issueStateWords(author: String?, state: String, updated: Date?, comments: Int, narrow: Bool,
                                       created: Date? = nil, closed: Date? = nil, now: Date = Date()) -> String {
        var parts: [String] = []
        if narrow {
            parts += [author, (created ?? updated).map { ageWords(now.timeIntervalSince($0)) }].compactMap { $0 }
        } else {
            if let author { parts.append("\(author) opened this" + (created.map { " " + ago($0, now: now) } ?? "")) }
            if state == "closed", let closed { parts.append("closed " + ago(closed, now: now)) }
            if created == nil, let updated { parts.append("updated " + ago(updated, now: now)) }
        }
        if comments > 0 { parts.append(comments == 1 ? "1 comment" : "\(comments) comments") }
        return parts.joined(separator: " · ")
    }

    /// A pull request's checks as a glyph: passing, failing or running; nil with none.
    public enum Checks: String, Sendable {
        case passing, failing, running

        public var accessibilityLabel: String {
            switch self {
            case .passing: "Checks passing"
            case .failing: "Checks failing"
            case .running: "Checks running"
            }
        }
    }

    public static func checks(_ summary: String?) -> Checks? { summary.flatMap(Checks.init(rawValue:)) }

    /// A pull request's review, as one word on its row: nil when none is asked yet.
    public static func reviewWord(_ review: String?) -> String? {
        switch review {
        case "approved": "Approved"
        case "changes_requested": "Changes requested"
        case "review_required": "Review required"
        default: nil
        }
    }

    /// The comment count beside the row's end: hidden at 0.
    public static func commentsWords(_ n: Int) -> String? { n > 0 ? "\(n)" : nil }

    // MARK: 3. The label chip

    /// A colour, red, green and blue from 0 to 1.
    public struct RGB: Sendable, Hashable {
        public var r: Double
        public var g: Double
        public var b: Double

        public init(r: Double, g: Double, b: Double) {
            self.r = r
            self.g = g
            self.b = b
        }

        public init(_ hex: UInt32) {
            self.init(r: Double((hex >> 16) & 255) / 255, g: Double((hex >> 8) & 255) / 255, b: Double(hex & 255) / 255)
        }

        /// `self` laid at `amount` over `ground`.
        public func over(_ ground: RGB, _ amount: Double) -> RGB {
            RGB(r: ground.r + (r - ground.r) * amount, g: ground.g + (g - ground.g) * amount, b: ground.b + (b - ground.b) * amount)
        }

        /// WCAG's relative luminance.
        public var luminance: Double {
            func lin(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
            return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
        }

        /// WCAG's contrast ratio, from 1 to 21.
        public func contrast(_ other: RGB) -> Double {
            let (a, b) = (luminance, other.luminance)
            return (max(a, b) + 0.05) / (min(a, b) + 0.05)
        }
    }

    /// A chip's three colours: its fill, its border and its text.
    public struct ChipColours: Sendable, Hashable {
        public var fill: RGB
        public var border: RGB
        public var text: RGB
    }

    /// The ground a chip lies on: a list's background, light and dark.
    public static let chipGround = (light: RGB(0xFFFFFF), dark: RGB(0x1C1D20))

    /// The contrast a chip's text keeps to its fill.
    public static let chipContrast = 4.5

    /// A label's chip in its colour (#2956): the colour at 18 % as the fill, so a dark label is not
    /// a dark block; at 60 % as the border; and the colour darkened (light mode) or lightened (dark
    /// mode) as the text, until it has a contrast of 4.5:1 to the fill. Nil when the forge gave
    /// no colour: the grey chip.
    public static func chip(_ color: String?, dark: Bool) -> ChipColours? {
        guard let c = WorkList.rgb(color).map({ RGB(r: $0.r, g: $0.g, b: $0.b) }) else { return nil }
        let ground = dark ? chipGround.dark : chipGround.light
        let fill = c.over(ground, 0.18)
        let border = c.over(ground, 0.6)
        let end = dark ? RGB(0xFFFFFF) : RGB(0x000000)
        var text = c
        var step = 0.0
        while text.contrast(fill) < chipContrast, step < 1 {
            step = min(step + 0.05, 1)
            text = end.over(c, step)
        }
        return ChipColours(fill: fill, border: border, text: text)
    }

    /// A scoped label's two parts, "feature:" and "work" of "feature:work", the first drawn lighter;
    /// nil scope for a label with no colon, or one that starts or ends with it.
    public static func scoped(_ name: String) -> (scope: String?, rest: String) {
        guard let colon = name.firstIndex(of: ":"), colon != name.startIndex, name.index(after: colon) != name.endIndex else {
            return (nil, name)
        }
        return (String(name[...colon]), String(name[name.index(after: colon)...]))
    }

    /// At most `limit` chips on a wide row, then "+2"; every one on a phone and on the item page.
    public static func shownLabels(_ labels: [DaemonAPI.ForgeLabel], limit: Int?) -> (shown: [DaemonAPI.ForgeLabel], more: Int) {
        guard let limit, labels.count > limit else { return (labels, 0) }
        return (Array(labels.prefix(limit)), labels.count - limit)
    }

    /// How many chips a wide row shows.
    public static let rowChips = 3

    // MARK: 4. The filter bar

    /// A menu's button: its name while it is not set ("Label"), its name and value when it is
    /// ("Label: bug"). State always shows its value ("Open"), because it always has one.
    public static func menuTitle(_ name: String, value: String?) -> String {
        guard let value, !value.isEmpty else { return name }
        return "\(name): \(value)"
    }

    /// The search field's placeholder: "Filter issues", "Filter pull requests".
    public static func searchPrompt(_ kind: WorkList.Kind) -> String { "Filter \(kind.title.lowercased())" }

    /// Whether a filter narrows the list by more than its state: the empty list then says "No
    /// issues match" and offers Clear filters.
    public static func narrows(_ f: WorkList.Filter) -> Bool {
        !(f.project.isEmpty && f.repo.isEmpty && f.label.isEmpty && f.assignee.isEmpty
            && f.text.trimmingCharacters(in: .whitespaces).isEmpty && f.board.isEmpty)
    }

    /// The filter with all but its state cleared.
    public static func cleared(_ f: WorkList.Filter) -> WorkList.Filter { WorkList.Filter(state: f.state) }

    /// The filter bar's Clear button (lists.md section 1), after the last filter while `narrows`.
    public static let clear = "Clear"

    /// The filters that are set, as the empty list says them: "Label: bug · Assignee: alexec".
    /// `project` and `board` are the names of the ones picked; nil when nothing narrows.
    public static func setFilters(_ f: WorkList.Filter, project: String? = nil, board: String? = nil) -> String? {
        let text = f.text.trimmingCharacters(in: .whitespaces)
        let parts: [String?] = [
            text.isEmpty ? nil : "“\(text)”",
            f.project.isEmpty ? nil : menuTitle("Project", value: project ?? f.project),
            f.repo.isEmpty ? nil : menuTitle("Repo", value: WorkList.repoName(f.repo)),
            f.label.isEmpty ? nil : menuTitle("Label", value: f.label),
            f.assignee.isEmpty ? nil : menuTitle("Assignee", value: f.assignee),
            f.board.isEmpty ? nil : menuTitle("Board", value: board ?? f.board),
        ]
        let set = parts.compactMap { $0 }
        return set.isEmpty ? nil : set.joined(separator: " · ")
    }

    /// The search field's widths on the Mac (lists.md section 2): 200 pt while the bar fits one
    /// line, 140 pt when it does not; then the menus with no value go into More.
    public static let filterBarSearch = (wide: 200.0, short: 140.0)

    // MARK: 6. A comment

    /// An avatar with no image: the login's first letter, upper case.
    public static func initial(_ login: String) -> String {
        login.first { $0.isLetter || $0.isNumber }.map { String($0).uppercased() } ?? "?"
    }

    /// The hue (0 to 1) of an avatar with no image, picked from the login, so one person keeps one
    /// colour on every page and every client (FNV-1a of its UTF-8 bytes).
    public static func avatarHue(_ login: String) -> Double {
        var hash: UInt32 = 2_166_136_261
        for byte in login.lowercased().utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return Double(hash % 360) / 360
    }

    /// An event on an issue's timeline (#4373), as one grey line: "alexec added the label bug",
    /// "alexec closed this in #4331". Nil for a kind this client does not know: it draws nothing.
    public static func eventWords(_ e: DaemonAPI.ForgeEvent) -> String? {
        let who = e.actor ?? "Someone"
        let source = e.source.map { " in \(WorkList.shortRef($0.ref))" } ?? ""
        switch e.kind {
        case "labeled": return e.label.map { "\(who) added the label \($0.name)" }
        case "unlabeled": return e.label.map { "\(who) removed the label \($0.name)" }
        case "assigned":
            guard let to = e.assignee else { return nil }
            return to == e.actor ? "\(who) self-assigned this" : "\(who) assigned \(to)"
        case "unassigned":
            guard let to = e.assignee else { return nil }
            return to == e.actor ? "\(who) removed their assignment" : "\(who) unassigned \(to)"
        case "closed": return "\(who) closed this\(source)"
        case "reopened": return "\(who) reopened this"
        case "referenced": return e.source.map { "\(who) mentioned this in \(WorkList.shortRef($0.ref))" }
        default: return nil
        }
    }

    /// A line of an item page's timeline after its body: a comment, or an event.
    public enum TimelineEntry: Sendable, Hashable {
        case comment(DaemonAPI.ForgeComment)
        case event(DaemonAPI.ForgeEvent)

        public var at: Date {
            switch self {
            case let .comment(c): c.at
            case let .event(e): e.at
            }
        }
    }

    /// The comments and the events in time order (#4373). While older comments are still to
    /// read (`older`), the events before the first comment read wait with them, so the timeline
    /// never shows an event out of its place. An event no words say is left out.
    public static func timeline(comments: [DaemonAPI.ForgeComment], events: [DaemonAPI.ForgeEvent]?,
                                older: Bool) -> [TimelineEntry] {
        let from = older ? comments.map(\.at).min() : nil
        let shown = (events ?? []).filter { e in eventWords(e) != nil && from.map { e.at >= $0 } != false }
        let all = comments.map(TimelineEntry.comment) + shown.map(TimelineEntry.event)
        return all.enumerated().sorted { a, b in
            a.element.at == b.element.at ? a.offset < b.offset : a.element.at < b.element.at
        }.map(\.element)
    }

    /// Whether the forge gave the item's own events: the page then draws its close from them,
    /// not from its state alone.
    public static func eventsSayClose(_ events: [DaemonAPI.ForgeEvent]?) -> Bool {
        events?.contains { $0.kind == "closed" } == true
    }

    /// "commented 20 min ago", for a comment's header.
    public static func commentedWords(_ at: Date, now: Date = Date()) -> String {
        let age = ageWords(now.timeIntervalSince(at))
        return age == "now" ? "commented now" : "commented \(age) ago"
    }

    // MARK: 7. Empty, loading and error

    /// How many placeholder rows a first read shows.
    public static let placeholderRows = 6

    /// The empty list's title, by its state: "No open issues", "No merged pull requests",
    /// "No issues" for All; "No issues match" when a filter narrows it.
    public static func emptyTitle(_ kind: WorkList.Kind, state: WorkList.State, filtered: Bool) -> String {
        let noun = kind.title.lowercased()
        if filtered { return "No \(noun) match" }
        if kind == .release { return "No releases yet" }
        guard kind.fromForge, state != .all else { return "No \(noun)" }
        return "No \(state.rawValue) \(noun)"
    }

    /// The line under it: "Issues on alexec/Agents show here." with one repo read, else
    /// "Issues from your folders’ repos show here."
    public static func emptyLine(_ kind: WorkList.Kind, repos: [String]) -> String {
        if repos.count == 1, let repo = repos.first { return "\(kind.title) on \(WorkList.repoName(repo)) show here." }
        return "\(kind.title) from your folders’ repos show here."
    }

    public static let clearFilters = "Clear filters"
    public static let tryAgain = "Try again"
    /// A page drawn from this device's copy (#4930) while its machine is asked again; the web page says the same.
    public static let fromDevice = "From this device. Reading it again."

    /// One item of a kind, or many: "1 issue", "128 issues", "2 pull requests".
    public static func count(_ kind: WorkList.Kind, _ n: Int, more: Bool = false) -> String {
        let noun = kind.title.lowercased()
        let one = n == 1 && !more ? String(noun.dropLast()) : noun
        return "\(n)\(more ? "+" : "") \(one)"
    }

    /// The footer while the next page loads (lists.md section 2): "Loading more… · 50 shown";
    /// "Loading more… · 50 of 128 shown" with the forge's total (#4396).
    public static func loadingMore(shown: Int, total: Int? = nil) -> String {
        "Loading more… · \(shown)\(total.map { " of \($0)" } ?? "") shown"
    }

    /// The end of the list, in grey: "128 issues", the forge's total where it gives one (#4396);
    /// with none, "50+ issues" while more pages are there, else the rows read.
    public static func endWords(_ kind: WorkList.Kind, shown: Int, more: Bool, total: Int? = nil) -> String {
        total.map { count(kind, $0) } ?? count(kind, shown, more: more)
    }

    /// The forge's total for a list as the person sees it, or nil: only from one machine's read
    /// (two machines read the same repos, so their counts overlap), and only while no filter
    /// narrows it on the client (the forge counts what it was asked: the state and the board).
    public static func listTotal(_ totals: [Int?], filter: WorkList.Filter) -> Int? {
        guard totals.count == 1, let total = totals[0] else { return nil }
        var f = filter
        f.board = ""
        return narrows(f) ? nil : total
    }

    /// A page after the first that did not load: one line at the end, and Try again.
    public static let couldNotLoadMore = "Could not load more."

    /// The middle of a list that read nothing: "Could not read issues", then what the forge said.
    public static func couldNotRead(_ kind: WorkList.Kind) -> String { "Could not read \(kind.title.lowercased())" }

    /// Where a person connects a forge, or gives it a new token.
    public static let connectors = "Settings ▸ Connectors"

    /// Whether what a forge said is about its credential (a token refused, ended or missing), so
    /// the error offers Settings ▸ Connectors as well as Try again.
    public static func credentialProblem(_ message: String) -> Bool {
        let m = message.lowercased()
        return ["401", "403", "bad credentials", "unauthorized", "not connected", "token", "sign in", "signed in"]
            .contains { m.contains($0) }
    }
}
