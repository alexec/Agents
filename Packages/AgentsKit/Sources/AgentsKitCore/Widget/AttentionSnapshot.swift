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

    /// How many rows a medium widget draws. Four fits legibly; the rest are counted in
    /// words rather than drawn (FR-006).
    public static let rowLimit = 4

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

    /// How many are waiting and not drawn.
    public var leftover: Int { max(0, total - sessions.count) }

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
            .map { session(for: $0, model: model) }
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
    private static func session(for agent: Agent, model: AgentsModel) -> AttentionSnapshotSession {
        let need = model.needs.values
            .filter { $0.agentID == agent.id }
            .max { $0.raisedAt < $1.raisedAt }
        return AttentionSnapshotSession(
            id: agent.id,
            project: model.project(agent.projectFolder)?.name ?? agent.projectFolder.lastPathComponent,
            title: agent.title ?? "Untitled",
            wanted: need?.headline.h3 ?? agent.report?.message,
            kind: need?.kind,
            since: need?.raisedAt ?? agent.lastActivityAt)
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

    public init(id: UUID, project: String, title: String, wanted: String?, kind: Need.Kind?, since: Date) {
        self.id = id
        self.project = project
        self.title = title
        self.wanted = wanted
        self.kind = kind
        self.since = since
    }
}
