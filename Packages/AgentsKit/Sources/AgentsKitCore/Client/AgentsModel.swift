import Foundation
import Observation

/// What the work looks like to anything watching it: the Mac's window, and a phone on
/// a train.
///
/// Neither of them owns any of this. The daemon does. This is the view of it a client
/// keeps in hand — the agents, the projects, the questions waiting, and the page of
/// transcript being read — together with what each notification means, which is the
/// part that must not be written twice. Two clients that disagreed about what
/// `agent/permission` with a nil request means would be two clients that disagree
/// about whether the user has already answered, which is the one thing this feature
/// cannot get wrong.
///
/// Nothing is decided here. Every method either files what arrived or replaces what
/// was there. Anything that needs a decision belongs to the daemon.
@MainActor
@Observable
public final class AgentsModel {
    public private(set) var agents: [Agent] = []
    public private(set) var projects: [DaemonAPI.ProjectSummary] = []
    public private(set) var permissions: [PermissionRequest] = []
    public private(set) var elicitations: [ElicitationRequest] = []
    /// What wants a person and where each is showing, as the daemon last said (021).
    /// The model stores the fact; it posts nothing and decides nothing.
    public private(set) var needs: [NeedID: Need] = [:]
    public private(set) var deliveries: [NeedID: Surface] = [:]

    /// Every project's workflows, newest state winning. Here rather than in the Mac's
    /// own model because a workflow is about the work, and the phone will want them.
    public private(set) var workflows: [WorkflowSummary] = []

    /// The transcript of the agent being read, and only that one. A client holds one
    /// page of one conversation, because an hour of transcript is not something to
    /// carry around, least of all over a mobile connection.
    public private(set) var entries: [TranscriptEntry] = []
    public private(set) var firstEntryIndex = 0
    public private(set) var hasMoreBefore = false

    /// Which agent's transcript is in hand. Entries for anything else are not ours to
    /// keep: the reader is not looking at them and the next selection reloads anyway.
    public var watching: UUID? {
        didSet {
            guard watching != oldValue else { return }
            clearTranscript()
        }
    }

    /// Files an agent has asked be put in front of the user, one per agent, newest
    /// winning. Held rather than acted on, because the client hearing this may be
    /// showing another conversation.
    public private(set) var filesToShow: [UUID: ShownFile] = [:]

    /// Chats the daemon is queueing to pick back up after a restart, held only while
    /// it is doing it. Not on any record: the queue lives and dies with the daemon
    /// that made it, and a client that was not listening asks `agents/resuming` on
    /// connect rather than inferring it.
    public private(set) var resuming: Set<UUID> = []

    /// What the reader will allow, what today has cost, and which local day that is.
    ///
    /// Seeded by `cost/state` on connect and kept current by `cost/changed`, the way
    /// projects are seeded by `projects/list` and kept current by `project/changed`.
    /// Nil until the daemon has said, so a window shows nothing rather than a zero
    /// it invented. Everything derived from it — whether the day's limit is reached,
    /// what is left, whether it is close — is computed on `CostState` and never sent.
    ///
    /// A window notices the day rolling over by `day` changing here. It must never
    /// consult its own clock: it may be in a different time zone from the daemon's,
    /// and the daemon's is the one the limit uses.
    public private(set) var costState: DaemonAPI.CostState?

    public init() {}

    // MARK: What each notification means

    /// Apply one notification from the daemon.
    ///
    /// Returns false for anything this does not know, so a client with notifications
    /// of its own — the Mac has shells and terminals — can go on and handle them. A
    /// notification nobody claims is skipped, never guessed at.
    @discardableResult
    public func apply(_ method: String, _ params: JSONValue?) -> Bool {
        switch method {
        case DaemonAPI.Notification.agentChanged:
            guard let agent = try? params?.decode(Agent.self) else { return true }
            upsert(agent)

        case DaemonAPI.Notification.projectChanged:
            guard let summary = try? params?.decode(DaemonAPI.ProjectSummary.self) else { return true }
            upsert(summary)

        case DaemonAPI.Notification.agentEntry:
            guard let notification = try? params?.decode(DaemonAPI.EntryNotification.self) else { return true }
            if notification.agentID == watching { entries.append(notification.entry) }

        case DaemonAPI.Notification.agentPermission:
            guard let notification = try? params?.decode(DaemonAPI.PermissionNotification.self) else { return true }
            // One question per agent at a time, so the agent's old one goes whether
            // this is a new question or the news that it was answered.
            permissions.removeAll { $0.agentID == notification.agentID }
            if let request = notification.request { permissions.append(request) }

        case DaemonAPI.Notification.agentElicitation:
            guard let notification = try? params?.decode(DaemonAPI.ElicitationNotification.self) else { return true }
            elicitations.removeAll { $0.id == notification.requestID }
            if let request = notification.request { elicitations.append(request) }

        case DaemonAPI.Notification.attentionChanged:
            guard let notification = try? params?.decode(DaemonAPI.AttentionNotification.self) else { return true }
            if let need = notification.need {
                needs[notification.needID] = need
                deliveries[notification.needID] = notification.to
            } else {
                needs.removeValue(forKey: notification.needID)
                deliveries.removeValue(forKey: notification.needID)
            }

        case DaemonAPI.Notification.agentUsage:
            guard let notification = try? params?.decode(DaemonAPI.UsageNotification.self) else { return true }
            if let index = agents.firstIndex(where: { $0.id == notification.agentID }) {
                agents[index].usage = notification.usage
            }

        case DaemonAPI.Notification.workflowChanged:
            guard let summary = try? params?.decode(WorkflowSummary.self) else { return true }
            upsert(summary)

        case DaemonAPI.Notification.workflowRemoved:
            guard let notification = try? params?.decode(DaemonAPI.WorkflowRemovedNotification.self) else { return true }
            let folder = Project.standardize(notification.folder)
            workflows.removeAll {
                $0.folder == folder && $0.workflowID == notification.workflowID
            }

        case DaemonAPI.Notification.costChanged:
            guard let state = try? params?.decode(DaemonAPI.CostState.self) else { return true }
            costState = state

        case DaemonAPI.Notification.agentShowFile:
            guard let notification = try? params?.decode(DaemonAPI.ShowFileNotification.self) else { return true }
            filesToShow[notification.agentID] = notification.file

        case DaemonAPI.Notification.agentResuming:
            guard let notification = try? params?.decode(DaemonAPI.ResumingNotification.self) else { return true }
            if notification.isResuming {
                resuming.insert(notification.agentID)
            } else {
                resuming.remove(notification.agentID)
            }

        default:
            return false
        }
        return true
    }

    // MARK: Filing what arrives

    public func upsert(_ agent: Agent) {
        if let index = agents.firstIndex(where: { $0.id == agent.id }) {
            agents[index] = agent
        } else {
            agents.append(agent)
        }
        agents.sort { $0.lastActivityAt > $1.lastActivityAt }
    }

    public func upsert(_ summary: WorkflowSummary) {
        if let index = workflows.firstIndex(where: { $0.id == summary.id }) {
            workflows[index] = summary
        } else {
            workflows.append(summary)
        }
        workflows.sort {
            $0.workflow.name.localizedCaseInsensitiveCompare($1.workflow.name) == .orderedAscending
        }
    }

    public func replaceWorkflows(_ summaries: [WorkflowSummary]) {
        workflows = summaries.sorted {
            $0.workflow.name.localizedCaseInsensitiveCompare($1.workflow.name) == .orderedAscending
        }
    }

    /// The workflows of one project, which is what a project page shows.
    public func workflows(in folder: URL?) -> [WorkflowSummary] {
        guard let folder else { return [] }
        let standardized = Project.standardize(folder)
        return workflows.filter { $0.folder == standardized }
    }

    public func upsert(_ summary: DaemonAPI.ProjectSummary) {
        if let index = projects.firstIndex(where: { $0.folder == summary.folder }) {
            projects[index] = summary
        } else {
            projects.append(summary)
        }
        projects.sort { $0.lastActivityAt > $1.lastActivityAt }
    }

    public func replaceAgents(_ listed: [Agent]) {
        agents = listed.sorted { $0.lastActivityAt > $1.lastActivityAt }
    }

    public func replaceProjects(_ listed: [DaemonAPI.ProjectSummary]) {
        projects = listed.sorted { $0.lastActivityAt > $1.lastActivityAt }
    }

    public func replaceCostState(_ state: DaemonAPI.CostState) { costState = state }

    /// What this agent has left before it stops, under the limits as they stand.
    /// Nil when uncapped, when unmeasured, or before the daemon has said.
    public func costHeadroom(for agent: Agent) -> Decimal? {
        guard let limits = costState?.limits else { return nil }
        return agent.costHeadroom(under: limits)
    }

    public func isAtCostLimit(_ agent: Agent) -> Bool {
        guard let limits = costState?.limits else { return false }
        return agent.isAtCostLimit(under: limits)
    }

    public func replacePermissions(_ listed: [PermissionRequest]) { permissions = listed }

    public func replaceElicitations(_ listed: [ElicitationRequest]) { elicitations = listed }

    /// What `attention/pending` said on connect: the outstanding needs and where each
    /// is showing, replacing whatever this surface believed while it was not listening.
    public func replaceAttention(_ pending: DaemonAPI.AttentionPending) {
        needs = Dictionary(uniqueKeysWithValues: pending.needs.map { ($0.id, $0) })
        deliveries = Dictionary(uniqueKeysWithValues: pending.deliveries.map { ($0.needID, $0.to) })
            .compactMapValues { $0 }
    }

    /// The first page of the conversation being read: the end of it.
    public func replaceTranscript(with page: TranscriptPage) {
        entries = page.entries
        firstEntryIndex = page.firstIndex
        hasMoreBefore = page.hasMoreBefore
    }

    /// An earlier page, put in front of what is already held.
    public func prepend(_ page: TranscriptPage) {
        entries.insert(contentsOf: page.entries, at: 0)
        firstEntryIndex = page.firstIndex
        hasMoreBefore = page.hasMoreBefore
    }

    public func clearTranscript() {
        entries = []
        firstEntryIndex = 0
        hasMoreBefore = false
    }

    /// Taken out once it has been acted on. This is "look at this now", and a client
    /// opened tomorrow has missed it.
    public func takeFileToShow(for agentID: UUID) -> ShownFile? {
        filesToShow.removeValue(forKey: agentID)
    }

    /// Everything the daemon said was on its way back when we connected. A window
    /// that arrives mid-batch is told the set rather than piecing it together from
    /// notifications it was not there to hear.
    public func setResuming(_ ids: [UUID]) {
        resuming = Set(ids)
    }

    /// Whether the daemon is bringing this chat back by itself.
    public func isComingBack(_ agent: Agent) -> Bool {
        resuming.contains(agent.id)
    }

    /// The one thing every client says about a chat on its way back, so the window
    /// and the phone cannot drift apart saying it.
    public static let comingBackDescription = "Coming back after a restart"
    public static let comingBackSymbol = "arrow.clockwise.circle"

    // MARK: Reading it back

    public func agent(_ id: UUID?) -> Agent? {
        guard let id else { return nil }
        return agents.first { $0.id == id }
    }

    /// The projects worth showing, newest activity first.
    public var liveProjects: [DaemonAPI.ProjectSummary] {
        projects.filter { !$0.project.isArchived }
    }

    public var archivedProjects: [DaemonAPI.ProjectSummary] {
        projects.filter(\.project.isArchived)
    }

    public func project(_ folder: URL?) -> DaemonAPI.ProjectSummary? {
        guard let folder else { return nil }
        return projects.first { $0.folder == folder }
    }

    /// The agents of one project, in one group, newest activity first.
    ///
    /// Grouped by `AgentGroup(for:)`, so no client can put an agent under a heading
    /// another client would not. Filtered from what is already held, so the archived
    /// list's "show more" is a number in a view rather than a fetch.
    ///
    /// The folder is standardised on the way in, because an agent's `cwd` is whatever
    /// it was started with and a project's folder is the resolved form. Comparing them
    /// raw is how a project ends up looking empty while its agents are plainly running.
    public func agents(in folder: URL?, group: AgentGroup) -> [Agent] {
        guard let folder else { return [] }
        let wanted = Project.standardize(folder)
        return agents.filter { Project.standardize($0.cwd) == wanted && self.group(of: $0) == group }
    }

    /// Where an agent sits, counting a file it has asked the person to look at.
    ///
    /// `filesToShow` is the unseen flag already: it is keyed by agent, it is put there
    /// when the agent asks, and `takeFileToShow` removes it when that conversation is
    /// opened. Nothing new is stored, and nothing outlives the window — which matches
    /// the daemon, which stores nothing for this and refuses to show a file when no
    /// window is open.
    public func group(of agent: Agent) -> AgentGroup {
        agent.group(wantsEyes: filesToShow[agent.id] != nil)
    }

    /// How many agents of one project are in each group, by this window's own grouping.
    ///
    /// This is what FR-009 means by a count being completed by something that knows.
    /// The daemon's `ProjectSummary.counts` are computed without knowing whether an
    /// agent asked to be looked at, because the daemon has no window; this one does,
    /// and the same `group(of:)` that files an agent under a heading counts it here —
    /// so the number on a project row is the number of rows under the heading, at the
    /// same moment, by construction (FR-006, FR-007). "Wants a person" is then
    /// `counts[.needsAttention] > 0` and nothing else, which consults the agent's state
    /// the way the check it replaced never did: a stopped agent that once asked to be
    /// looked at is under Stopped, and wants nobody (FR-008, FR-011, FR-012).
    public func counts(in folder: URL?) -> [AgentGroup: Int] {
        guard let folder else { return [:] }
        let wanted = Project.standardize(folder)
        var counts: [AgentGroup: Int] = [:]
        for agent in agents where Project.standardize(agent.cwd) == wanted {
            counts[group(of: agent), default: 0] += 1
        }
        return counts
    }

    /// How many finished conversations in this project nobody has looked at since.
    /// The number a project row shows in place of "complete": a complete chat that
    /// has been read is not news.
    public func unreadCount(in folder: URL?) -> Int {
        guard let folder else { return 0 }
        let wanted = Project.standardize(folder)
        return agents.filter { Project.standardize($0.cwd) == wanted && group(of: $0) == .finished && $0.isUnread }.count
    }

    /// The question this agent is blocked on, if it still is.
    public func permission(for agentID: UUID?) -> PermissionRequest? {
        guard let agentID else { return nil }
        return permissions.first { $0.agentID == agentID }
    }

    /// The form this agent is waiting on, if there is one.
    public func elicitation(for agentID: UUID?) -> ElicitationRequest? {
        guard let agentID else { return nil }
        return elicitations.first { $0.agentID == agentID }
    }
}
