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
    /// The page as the chat draws it: chunks joined, tool calls folded into runs.
    ///
    /// Kept here, folded once as each entry lands, rather than folded by the view on
    /// every redraw. A reply arrives several chunks a second and the fold grows with
    /// the page, so folding per redraw was the page's whole length of work, again,
    /// for every word.
    public private(set) var transcriptItems: [TranscriptItem] = []
    @ObservationIgnored private var display = TranscriptDisplayBuilder()
    /// Every entry in hand, by id, so one that reaches us twice is kept once.
    @ObservationIgnored private var entryIDs: Set<UUID> = []
    /// Entries heard as they happened since the last page arrived.
    ///
    /// A page and the entries streaming past it come by two different doors — a reply
    /// and a notification — and nothing orders one against the other. An entry written
    /// after the daemon read the page can be applied before the page lands, and the
    /// page would then replace it: a chunk of a reply gone from the middle of the chat
    /// until it was next opened. These are laid back on top of the page. Bounded,
    /// because a chat watched for hours hears thousands between pages.
    @ObservationIgnored private var heardSincePage: [TranscriptEntry] = []
    private static let heardSincePageLimit = 1_000
    /// Each agent's folder in the form projects compare by, worked out once.
    ///
    /// `Project.standardize` resolves symlinks, which is the file system being asked
    /// about every component of the path. An agent's folder never changes, and every
    /// project row asks for every agent's on every redraw, so it is asked once.
    @ObservationIgnored private var folders: [UUID: URL] = [:]

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
    /// The mode last chosen for each runtime, as the Mac holds it (029). A copy, kept
    /// current by `modes/changed`, so a start form can open on it without a round trip.
    public private(set) var rememberedModes: DaemonAPI.RememberedModes = [:]
    /// Why the Mac is, or is not, being kept awake (024).
    ///
    /// Nil means *not yet heard from*, which is a different fact from *not holding* and
    /// is drawn the same way — as nothing. It stays nil against a daemon too old to
    /// know `wake/state`, which is what lets a new window work against an old daemon.
    public private(set) var wakeState: DaemonAPI.WakeState?

    public init() {}

    // MARK: What each notification means

    /// One notification from the daemon, read.
    ///
    /// Reading is the expensive half of applying one — a tool call's output can be
    /// a hundred kilobytes of JSON — and it needs nothing of the model, so a client
    /// may read off the main actor and hand over the result. What each one *means*
    /// is still written once, in `apply`.
    public enum Update: Sendable {
        case agentChanged(Agent)
        case projectChanged(DaemonAPI.ProjectSummary)
        case entry(DaemonAPI.EntryNotification)
        case permission(DaemonAPI.PermissionNotification)
        case elicitation(DaemonAPI.ElicitationNotification)
        case attention(DaemonAPI.AttentionNotification)
        case usage(DaemonAPI.UsageNotification)
        case workflowChanged(WorkflowSummary)
        case workflowRemoved(DaemonAPI.WorkflowRemovedNotification)
        case costChanged(DaemonAPI.CostState)
        case modesChanged(DaemonAPI.RememberedModes)
        case wakeChanged(DaemonAPI.WakeState)
        case showFile(DaemonAPI.ShowFileNotification)
        case resuming(DaemonAPI.ResumingNotification)
        /// Ours, and unreadable. Claimed, so nobody else guesses at it, and skipped.
        case unreadable
    }

    /// Read a notification, anywhere. Nil for anything this model does not know, so
    /// a client with notifications of its own — the Mac has shells and terminals —
    /// can go on and handle them.
    public nonisolated static func read(_ method: String, _ params: JSONValue?) -> Update? {
        func decode<T: Decodable>(_ type: T.Type, _ wrap: (T) -> Update) -> Update {
            (try? params?.decode(type)).map(wrap) ?? .unreadable
        }
        switch method {
        case DaemonAPI.Notification.agentChanged: return decode(Agent.self, Update.agentChanged)
        case DaemonAPI.Notification.projectChanged: return decode(DaemonAPI.ProjectSummary.self, Update.projectChanged)
        case DaemonAPI.Notification.agentEntry: return decode(DaemonAPI.EntryNotification.self, Update.entry)
        case DaemonAPI.Notification.agentPermission: return decode(DaemonAPI.PermissionNotification.self, Update.permission)
        case DaemonAPI.Notification.agentElicitation: return decode(DaemonAPI.ElicitationNotification.self, Update.elicitation)
        case DaemonAPI.Notification.attentionChanged: return decode(DaemonAPI.AttentionNotification.self, Update.attention)
        case DaemonAPI.Notification.agentUsage: return decode(DaemonAPI.UsageNotification.self, Update.usage)
        case DaemonAPI.Notification.workflowChanged: return decode(WorkflowSummary.self, Update.workflowChanged)
        case DaemonAPI.Notification.workflowRemoved: return decode(DaemonAPI.WorkflowRemovedNotification.self, Update.workflowRemoved)
        case DaemonAPI.Notification.costChanged: return decode(DaemonAPI.CostState.self, Update.costChanged)
        case DaemonAPI.Notification.modesChanged: return decode(DaemonAPI.RememberedModes.self, Update.modesChanged)
        case DaemonAPI.Notification.wakeChanged: return decode(DaemonAPI.WakeState.self, Update.wakeChanged)
        case DaemonAPI.Notification.agentShowFile: return decode(DaemonAPI.ShowFileNotification.self, Update.showFile)
        case DaemonAPI.Notification.agentResuming: return decode(DaemonAPI.ResumingNotification.self, Update.resuming)
        default: return nil
        }
    }

    /// Apply one notification from the daemon.
    ///
    /// Returns false for anything this does not know, so a client with notifications
    /// of its own — the Mac has shells and terminals — can go on and handle them. A
    /// notification nobody claims is skipped, never guessed at.
    @discardableResult
    public func apply(_ method: String, _ params: JSONValue?) -> Bool {
        guard let update = Self.read(method, params) else { return false }
        apply(update)
        return true
    }

    /// Apply one notification already read. See `read`.
    public func apply(_ update: Update) {
        switch update {
        case .agentChanged(let agent):
            upsert(agent)

        case .projectChanged(let summary):
            upsert(summary)

        case .entry(let notification):
            guard notification.agentID == watching else { return }
            heardSincePage.append(notification.entry)
            if heardSincePage.count > Self.heardSincePageLimit {
                heardSincePage.removeFirst(heardSincePage.count - Self.heardSincePageLimit)
            }
            // Already on the page: written before the daemon read it, and heard after.
            guard entryIDs.insert(notification.entry.id).inserted else { return }
            entries.append(notification.entry)
            display.add(notification.entry)
            transcriptItems = display.items

        case .permission(let notification):
            // One question per agent at a time, so the agent's old one goes whether
            // this is a new question or the news that it was answered.
            permissions.removeAll { $0.agentID == notification.agentID }
            if let request = notification.request { permissions.append(request) }

        case .elicitation(let notification):
            elicitations.removeAll { $0.id == notification.requestID }
            if let request = notification.request { elicitations.append(request) }

        case .attention(let notification):
            if let need = notification.need {
                needs[notification.needID] = need
                deliveries[notification.needID] = notification.to
            } else {
                needs.removeValue(forKey: notification.needID)
                deliveries.removeValue(forKey: notification.needID)
            }

        case .usage(let notification):
            if let index = agents.firstIndex(where: { $0.id == notification.agentID }) {
                agents[index].usage = notification.usage
            }

        case .workflowChanged(let summary):
            upsert(summary)

        case .workflowRemoved(let notification):
            let folder = Project.standardize(notification.folder)
            workflows.removeAll {
                $0.folder == folder && $0.workflowID == notification.workflowID
            }

        case .costChanged(let state):
            costState = state

        case .modesChanged(let modes):
            rememberedModes = modes

        case .wakeChanged(let state):
            wakeState = state

        case .showFile(let notification):
            filesToShow[notification.agentID] = notification.file

        case .resuming(let notification):
            if notification.isResuming {
                resuming.insert(notification.agentID)
            } else {
                resuming.remove(notification.agentID)
            }

        case .unreadable:
            break
        }
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
    public func replaceRememberedModes(_ modes: DaemonAPI.RememberedModes) { rememberedModes = modes }

    /// The mode last chosen for this runtime, on any device (029).
    public func rememberedMode(for runtimeID: String) -> JSONValue? { rememberedModes[runtimeID] }
    public func replaceWakeState(_ state: DaemonAPI.WakeState) { wakeState = state }

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
        // What was heard and is not on the page was written after the page was read, so
        // it goes after it, in the order it was heard.
        let onPage = Set(page.entries.map(\.id))
        entries = page.entries + heardSincePage.filter { !onPage.contains($0.id) }
        heardSincePage = []
        firstEntryIndex = page.firstIndex
        hasMoreBefore = page.hasMoreBefore
        refold()
    }

    /// An earlier page, put in front of what is already held.
    public func prepend(_ page: TranscriptPage) {
        entries.insert(contentsOf: page.entries, at: 0)
        firstEntryIndex = page.firstIndex
        hasMoreBefore = page.hasMoreBefore
        refold()
    }

    public func clearTranscript() {
        entries = []
        heardSincePage = []
        firstEntryIndex = 0
        hasMoreBefore = false
        refold()
    }

    /// The page folded again from the top: a page replaced or grown at the front is
    /// not a page grown at the end, and only the latter can be folded a step at a time.
    private func refold() {
        entryIDs = Set(entries.map(\.id))
        display = TranscriptDisplayBuilder()
        for entry in entries { display.add(entry) }
        transcriptItems = display.items
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

    /// Who started an agent another agent started, as its mark says it (028): that
    /// agent's title as it is now, or "another agent" once it has none or has gone.
    /// `nil` for every agent the person or a workflow started. Here rather than in a
    /// view so the Mac's row and the phone's card cannot word it differently.
    public func startedByAgentLabel(_ agent: Agent) -> String? {
        guard let starter = agent.startedByAgent else { return nil }
        let title = self.agent(starter)?.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        return "Started by " + (title.flatMap { $0.isEmpty ? nil : "\u{201C}\($0)\u{201D}" } ?? "another agent")
    }

    /// The symbol that mark is drawn with.
    public static let startedByAgentSymbol = "person.2"

    /// Whether a client should offer Stop for this chat: the daemon holds a runtime for
    /// it, or is about to pick it back up. The window's toolbar, the card's menu and
    /// the phone's menu all ask this, so no two of them can disagree about it.
    public func canStop(_ agent: Agent) -> Bool {
        agent.state.holdsRuntime || isComingBack(agent)
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

    /// Which runtime a new agent gets when nobody has said.
    ///
    /// Whatever the last agent used, when it is still available, because that is the
    /// one already chosen in every other sense. Here rather than in either app so that
    /// the Mac and a phone cannot offer different ones for the same work (029).
    ///
    /// - Parameter available: the runtimes that can be started now, in the Mac's order.
    ///   With no agent to go by it is the first of these — by order, not whichever a
    ///   set happened to hand back, which is what the Mac used to do.
    public func defaultRuntimeID(available: [String]) -> String? {
        let startable = Set(available)
        let recent = agents.filter { startable.contains($0.runtimeID) }
            .max { $0.lastActivityAt < $1.lastActivityAt }
        return recent?.runtimeID ?? available.first
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
        return agents.filter { self.projectFolder(of: $0) == wanted && self.group(of: $0) == group }
    }

    /// The agent's folder as projects compare it, remembered after the first ask.
    private func projectFolder(of agent: Agent) -> URL {
        if let known = folders[agent.id] { return known }
        let standardized = Project.standardize(agent.cwd)
        folders[agent.id] = standardized
        return standardized
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
        for agent in agents where projectFolder(of: agent) == wanted {
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
        return agents.filter { projectFolder(of: $0) == wanted && group(of: $0) == .finished && $0.isUnread }.count
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
