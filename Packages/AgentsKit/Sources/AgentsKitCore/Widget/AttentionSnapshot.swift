import Foundation

/// What the Home-screen widget is shown: how many sessions need a person, and the few
/// named for its rows (068).
///
/// A device-local copy, written by the app and read by the widget. It holds ids, names and
/// counts — no transcript, no credentials, no conversation — and the system removes it with
/// the app (FR-015). The widget never reaches the Mac for it, and holds no key and no
/// connection to do so with (FR-014).
public struct AttentionSnapshot: Codable, Hashable, Sendable {

    /// The widget kind this is written for. The same string as the extension's
    /// `WidgetConfiguration.kind`, so the app's `reloadTimelines` and the widget's
    /// configuration cannot name each other wrongly.
    public static let widgetKind = "AttentionWidget"

    /// The widget's sizes, each with the rows it has room for (FR-006, #192). Named here
    /// rather than as WidgetKit's families so the rule for what each draws can be tested
    /// without a widget.
    public enum Size: CaseIterable, Hashable, Sendable {
        /// The number on its own.
        case small
        /// The number and the newest four, a line each.
        case medium
        /// The newest six, each with room for its headline over two lines.
        case large
        /// The iPad's widest: the newest twelve, in two columns of six.
        case extraLarge

        /// How many rows this size draws. The rest are counted in words rather than drawn.
        public var rowLimit: Int {
            switch self {
            case .small: 0
            case .medium: 4
            case .large: 6
            case .extraLarge: 12
            }
        }
    }

    /// How many rows the app writes: enough for the largest size and no more, so the file
    /// stays a bounded handful whatever is waiting. A smaller size draws the first of them.
    public static let rowLimit = Size.allCases.map(\.rowLimit).max() ?? 0

    /// How old a snapshot may be before it has to say so (FR-017).
    public static let staleness: TimeInterval = 15 * 60

    /// When the app wrote this, which is what the widget's age is measured from.
    public var writtenAt: Date
    /// Every session needing a person across the live projects.
    public var total: Int
    /// The newest of them, capped at `rowLimit`, for the rows.
    public var sessions: [AttentionSnapshotSession]

    public init(writtenAt: Date, total: Int, sessions: [AttentionSnapshotSession]) {
        self.writtenAt = writtenAt
        self.total = total
        self.sessions = sessions
    }

    /// The rows a size draws: the newest, as many as it has room for.
    public func rows(for size: Size) -> [AttentionSnapshotSession] {
        Array(sessions.prefix(size.rowLimit))
    }

    /// How many are waiting and not drawn at a size, whether or not the file names them.
    public func leftover(for size: Size) -> Int {
        max(0, total - rows(for: size).count)
    }

    /// Whether two snapshots say the same thing, whatever time either was written.
    ///
    /// This is what stops a redraw when nothing moved: the notification loop delivers
    /// several notifications for one change, and the age in the file is then the time the
    /// count last moved, not the last time it was written — which is the more honest of
    /// the two (FR-017).
    public func saysTheSame(as other: AttentionSnapshot) -> Bool {
        total == other.total && sessions == other.sessions
    }

    /// Whether this replaces `existing` on disk: when it says something else, or says the
    /// same but `existing` is old enough that the widget would soon call it stale while
    /// the app is connected and knows it is still true (#175).
    public func needsWriting(over existing: AttentionSnapshot?) -> Bool {
        guard let existing, saysTheSame(as: existing) else { return true }
        return writtenAt.timeIntervalSince(existing.writtenAt) >= Self.staleness / 3
    }

    /// Whether this number is old enough that claiming it is current would be a lie
    /// (FR-017).
    public func isStale(at now: Date = Date()) -> Bool {
        now.timeIntervalSince(writtenAt) > Self.staleness
    }

    /// This snapshot with one push laid over it (#1046): what the push says before the app
    /// has caught up, written by whichever of the app and the notification extension the
    /// push wakes. A guess until the app next writes the whole truth: an agent already
    /// counted for an unread finish can be counted twice, and a need withdrawn that no row
    /// names leaves the count as it is.
    ///
    /// - Returns: nil when the push changes nothing the widget shows.
    public func applying(_ push: AttentionPush, at date: Date = Date()) -> AttentionSnapshot? {
        var next = self
        next.writtenAt = date
        if push.withdrawn {
            guard let row = sessions.firstIndex(where: { $0.needToken == push.token }) else { return nil }
            next.sessions.remove(at: row)
            next.total = max(0, total - 1)
            return next
        }
        if sessions.contains(where: { $0.needToken == push.token }) { return nil }
        let row = AttentionSnapshotSession(
            id: push.agentID ?? UUID(), project: push.headline?.h1 ?? "Agents",
            title: push.headline?.h2 ?? "An agent", wanted: push.headline?.h3, kind: push.kind,
            since: date, needToken: push.token, agentUnknown: push.agentID == nil ? true : nil)
        // The same session asking again is one row, and one in the count (FR-005).
        if let agentID = push.agentID, let same = sessions.firstIndex(where: { $0.id == agentID }) {
            next.sessions.remove(at: same)
        } else {
            next.total += 1
        }
        next.sessions = Array(([row] + next.sessions).prefix(Self.rowLimit))
        return next
    }

    /// The snapshot of what the app can see, at `date`.
    ///
    /// The count is the Dock badge's count and not a second rule: `AgentsModel.wantsALook`
    /// over the same live projects, so the widget cannot disagree with the badge
    /// (FR-001, FR-019). An unread finish is counted and drawn though it is no longer
    /// under Needs you (#70): it is still news.
    @MainActor
    public static func make(model: AgentsModel, at date: Date = Date(),
                            limit: Int = AttentionSnapshot.rowLimit) -> AttentionSnapshot {
        var total = 0
        var waiting: [Agent] = []
        var newestNeed: [UUID: Need] = [:]
        for need in model.needs.values {
            // A project's own question (#531) has no session to stand beside.
            guard let agentID = need.agentID,
                  newestNeed[agentID].map({ $0.raisedAt < need.raisedAt }) ?? true else { continue }
            newestNeed[agentID] = need
        }
        for summary in model.liveProjects {
            total += model.attentionCount(in: summary.folder)
            waiting += AgentGroup.allCases.flatMap { model.agents(in: summary.folder, group: $0) }
                .filter(model.wantsALook)
        }
        // One row per session. An agent that asked twice is one session waiting on you and
        // must not take two rows (FR-005).
        var seen = Set<UUID>()
        let sessions = waiting
            .filter { seen.insert($0.id).inserted }
            .map { session(for: $0, model: model, need: newestNeed[$0.id]) }
            .sorted { $0.since > $1.since }
        return AttentionSnapshot(writtenAt: date, total: total, sessions: Array(sessions.prefix(max(0, limit))))
    }

    /// One session, with what it is asking for where it is asking for something.
    ///
    /// The words are the banner's, from the need the daemon already raised — the same
    /// `Headline` a push carries, so the widget and the notification say the same thing
    /// about the same agent. A session with no need pending (a finished turn nobody has
    /// read) says nothing rather than being given a question it did not ask (FR-007).
    @MainActor
    private static func session(for agent: Agent, model: AgentsModel, need: Need?) -> AttentionSnapshotSession {
        return AttentionSnapshotSession(
            id: agent.id,
            project: model.project(agent.projectFolder)?.name ?? agent.projectFolder.lastPathComponent,
            title: agent.title ?? "Untitled",
            wanted: need?.headline.h3 ?? agent.report?.message,
            kind: need?.kind,
            since: need?.raisedAt ?? agent.lastActivityAt,
            needToken: need?.id.token)
    }
}

/// What a push about a need says, as the widget needs it (#1046): which need, whose, in
/// what words, and whether it has gone.
public struct AttentionPush: Hashable, Sendable {
    public var token: String
    public var kind: Need.Kind
    /// The session, where the need names it: a report does, a question does not.
    public var agentID: UUID?
    /// The banner's words, when the envelope could be opened.
    public var headline: Headline?
    public var withdrawn: Bool

    public init(token: String, kind: Need.Kind, agentID: UUID?, headline: Headline?, withdrawn: Bool) {
        self.token = token
        self.kind = kind
        self.agentID = agentID
        self.headline = headline
        self.withdrawn = withdrawn
    }

    public init(need: NeedID, headline: Headline?, withdrawn: Bool) {
        switch need {
        case .permission: self.init(token: need.token, kind: .permission, agentID: nil, headline: headline, withdrawn: withdrawn)
        case .elicitation: self.init(token: need.token, kind: .elicitation, agentID: nil, headline: headline, withdrawn: withdrawn)
        case .report(let agentID, _):
            self.init(token: need.token, kind: .report, agentID: agentID, headline: headline, withdrawn: withdrawn)
        case .guardedChange:
            self.init(token: need.token, kind: .guardedChange, agentID: nil, headline: headline, withdrawn: withdrawn)
        }
    }
}

/// One session as a widget row names it: which conversation, in which project, called what,
/// and what is being asked for.
public struct AttentionSnapshotSession: Codable, Hashable, Sendable, Identifiable {

    /// The agent. One session, one row, whatever it has asked (FR-005).
    public var id: UUID
    /// The project's name, as the projects list spells it.
    public var project: String
    /// The agent's own title, or `Untitled` where it has none.
    public var title: String
    /// What it wants, in the words the banner uses, where there is something to say.
    public var wanted: String?
    /// What kind of thing is being asked, so the row can say it is a permission rather than
    /// a question. Nil for a session with no need pending.
    public var kind: Need.Kind?
    /// When the need was raised, or the agent's last activity when there is no need. The
    /// rows are ordered by this, newest first, as the app's own list is.
    public var since: Date
    /// The need it is drawn for, so a push that withdraws it takes the row away (#1046).
    public var needToken: String?
    /// True for a row a push drew whose session it did not name: `id` is then no agent's,
    /// and a tap opens the need instead.
    public var agentUnknown: Bool?

    public init(id: UUID, project: String, title: String, wanted: String?, kind: Need.Kind?, since: Date,
                needToken: String? = nil, agentUnknown: Bool? = nil) {
        self.id = id
        self.project = project
        self.title = title
        self.wanted = wanted
        self.kind = kind
        self.since = since
        self.needToken = needToken
        self.agentUnknown = agentUnknown
    }

    /// Where a tap on the row goes: its conversation, or its need when the push that drew
    /// it did not say whose it is.
    public var link: AttentionLink {
        if agentUnknown == true, let needToken { return .need(needToken) }
        return .agent(id)
    }

    /// How long it has waited, as a row has room to say it: "now", "5m", "3h", "2d".
    ///
    /// Worked out against the entry's own date, so it is a fixed label and not a clock
    /// that ticks on a Home screen; the widget is redrawn often enough for it to stay true.
    public func waited(at now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(since))
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(Int(seconds / 60))m"
        case ..<86_400: return "\(Int(seconds / 3600))h"
        default: return "\(Int(seconds / 86_400))d"
        }
    }
}
