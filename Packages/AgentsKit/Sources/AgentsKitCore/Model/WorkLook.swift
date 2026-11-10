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

    /// The four state colours, light and dark (GitHub's own, as parts.md section 1 sets them).
    public enum Tone: String, Sendable, CaseIterable {
        case green, purple, grey, red

        public var light: UInt32 {
            switch self {
            case .green: 0x1A7F37
            case .purple: 0x8250DF
            case .grey: 0x6E7781
            case .red: 0xCF222E
            }
        }

        public var dark: UInt32 {
            switch self {
            case .green: 0x3FB950
            case .purple: 0xA371F7
            case .grey: 0x8B949E
            case .red: 0xF85149
            }
        }
    }

    /// The glyph of an issue or a pull request; nil for a milestone, a release, or a state no one
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

    /// The row's second line. Wide: "#4328 · updated 2 h ago by alexec · 2 sessions · $0.42".
    /// On a phone: "#4328 · 2 h · alexec · $0.42". With no lineage it ends after the author.
    /// The age is the last update's: the forges' opened and closed times come with #4373.
    public static func rowLine(_ row: WorkList.Row, compact: Bool, now: Date = Date()) -> String {
        var parts: [String] = []
        if !WorkList.titleSaysRef(row.title, row.node.ref) { parts.append(WorkList.shortRef(row.node.ref)) }
        if let status = row.status, !status.isEmpty { parts.append(status) }
        let age = ageWords(now.timeIntervalSince(row.updated))
        if compact {
            parts.append(age)
            if let author = row.author { parts.append(author) }
        } else {
            let when = age == "now" ? "updated now" : "updated \(age) ago"
            parts.append(row.author.map { "\(when) by \($0)" } ?? when)
        }
        if let lineage = lineageWords(row.lineage, compact: compact) { parts.append(lineage) }
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
}
