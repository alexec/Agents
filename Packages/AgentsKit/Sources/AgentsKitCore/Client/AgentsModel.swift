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

    /// Every project's workflows, newest state winning. Here rather than in the Mac's
    /// own model because a workflow is about the work, and the phone will want them.
    public private(set) var workflows: [WorkflowSummary] = []
    /// A write an agent has asked for that nobody has answered. At most one is shown at
    /// a time, the way a permission is.
    public private(set) var workflowConfirmation: DaemonAPI.WorkflowConfirmation?

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

        case DaemonAPI.Notification.workflowConfirmation:
            guard let notification = try? params?.decode(DaemonAPI.WorkflowConfirmationNotification.self) else { return true }
            workflowConfirmation = notification.confirmation

        case DaemonAPI.Notification.agentShowFile:
            guard let notification = try? params?.decode(DaemonAPI.ShowFileNotification.self) else { return true }
            filesToShow[notification.agentID] = notification.file

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

    public func replacePermissions(_ listed: [PermissionRequest]) { permissions = listed }

    public func replaceElicitations(_ listed: [ElicitationRequest]) { elicitations = listed }

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
        AgentGroup(for: agent.state, wantsEyes: filesToShow[agent.id] != nil)
    }

    /// Whether any agent in this folder has asked to be looked at and not been.
    public func wantsEyes(in folder: URL?) -> Bool {
        guard let folder, !filesToShow.isEmpty else { return false }
        let wanted = Project.standardize(folder)
        return agents.contains { Project.standardize($0.cwd) == wanted && filesToShow[$0.id] != nil }
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
