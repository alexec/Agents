import AgentsKit
import Foundation
import Observation

/// The window's state, which is a view of the daemon's and never a copy of it.
///
/// Everything here either came from the daemon or is on its way to it. Nothing about an
/// agent is decided in this process, which is what makes two windows agree and makes
/// reconnecting after a crash the same three steps as opening for the first time:
/// connect, list, subscribe.
@MainActor
@Observable
final class AppModel {
    /// The work, as any client sees it: the agents, the projects, the questions
    /// waiting, and the page of transcript being read.
    ///
    /// Held rather than copied, and shared with the phone. What each notification does
    /// to it is written once, in `AgentsKitCore`, because two clients that disagreed
    /// about what `agent/permission` with no request means would be two clients that
    /// disagree about whether the user has already answered.
    ///
    /// Everything below this line is about the window: what it is showing, what it has
    /// half typed, and what it has cost since it opened. None of that is the daemon's
    /// and none of it is the phone's.
    let work = AgentsModel()

    private(set) var runtimes: [RuntimeStatus] = []
    /// The start-up sheet offering to install what is missing (048). Raised once per
    /// launch, and only for a runtime not already offered on this root.
    var isOfferingInstall = false
    private var hasWeighedInstallOffer = false
    /// What each runtime last said about itself: signed in or not, what it takes in a
    /// prompt, which provider is answering.
    private(set) var accounts: [String: RuntimeAccount] = [:]
    /// What the terminals the daemon is running for an agent have printed so far. The
    /// kit's, so a phone shows the same (033).
    var terminalOutput: [String: String] { work.terminalOutput }
    private(set) var isConnected = false
    /// Whether the daemon's list of projects has arrived at least once. Until it has,
    /// an empty sidebar means "not yet", not "none".
    private(set) var hasLoadedProjects = false
    /// 021: the Mac's banner, and the window's report of where the person is. Neither
    /// decides anything; the daemon routes and these two obey.
    private let notifier = MacNotifier()
    private var presence: PresenceReporter?
    /// The loop going back for a lost daemon, while there is one.
    private var reconnecting: Task<Void, Never>?
    private(set) var problem: String?
    /// Clones under way on this Mac, from whichever window started them (027). Each is
    /// a row in the Projects column until it becomes a project or fails.
    private(set) var clones: [DaemonAPI.CloneSummary] = []

    // What the window reads, which is the shared model under another name. Forwarded
    // rather than mirrored: a copy is a thing that can fall behind.
    var agents: [Agent] { work.agents }
    var projects: [DaemonAPI.ProjectSummary] { work.projects }
    var permissions: [PermissionRequest] { work.permissions }
    var elicitations: [ElicitationRequest] { work.elicitations }
    var entries: [TranscriptEntry] { work.entries }
    var transcriptItems: [TranscriptItem] { work.transcriptItems }
    var transcriptHasMore: Bool { work.hasMoreBefore }
    var filesToShow: [UUID: ShownFile] { work.filesToShow }
    /// What the reader will allow and what today has cost. Nil until the daemon has
    /// said, which is how every surface knows to show nothing rather than a zero.
    var costState: DaemonAPI.CostState? { work.costState }
    /// Every resource an agent can lease and who holds it (036).
    var leases: DaemonAPI.LeaseSnapshot? { work.leases }
    var costLimits: CostLimits { work.costState?.limits ?? CostLimits() }

    /// Why the Mac is, or is not, being kept awake (024). Nil until the daemon has
    /// said — and for ever against one too old to know the method, which is drawn the
    /// same way as nothing to say.
    var wakeState: DaemonAPI.WakeState? { work.wakeState }

    /// Which project this window is looking at.
    ///
    /// Kept here and in `UserDefaults` rather than in the daemon: the daemon owns what
    /// is true about the work, and which of it somebody happens to be reading is not
    /// that. It is also what keeps two windows independent.
    var selectedProject: URL? {
        didSet {
            guard selectedProject != oldValue else { return }
            UserDefaults.standard.set(selectedProjectKey?.stored, forKey: Self.selectedProjectDefault)
            // Picking a project shows the project, not a conversation, and not a
            // workflow either. Both are things you go into from here, and come back
            // out of.
            selection = nil
            openWorkflow = nil
        }
    }

    static let selectedProjectDefault = "selectedProjectFolder"

    /// Which machine the selected project is on (037). Set with it, by `select`, never
    /// on its own: a folder names a project only together with its host.
    private(set) var selectedProjectHost: HostID = .mac

    /// The selected project as the window identifies projects now that a server can
    /// have the same path as this Mac.
    var selectedProjectKey: ProjectKey? {
        selectedProject.map { ProjectKey(host: selectedProjectHost, folder: $0) }
    }

    /// Whether the window is showing Spending rather than a project.
    ///
    /// Not persisted, unlike the selected project. Spending is somewhere you go to
    /// answer a question — what has this cost — and a window that reopens on the bill
    /// rather than on the work would be answering a question nobody asked twice.
    var showsSpending = false {
        didSet {
            guard showsSpending, showsSpending != oldValue else { return }
            showsResources = false
            showsEvents = false
            // The same rule as picking a project: what you picked is what you see,
            // and a conversation or a workflow left open underneath would be waiting
            // to reappear when the bill is closed, which is a place nobody chose to
            // come back to.
            selection = nil
            openWorkflow = nil
        }
    }

    /// Whether the window is showing Resources: who holds the Mac's shared things
    /// and who is waiting (036). A page like Spending, and not persisted for the same
    /// reason: it is somewhere you go to answer a question.
    var showsResources = false {
        didSet {
            guard showsResources, showsResources != oldValue else { return }
            showsSpending = false
            showsEvents = false
            selection = nil
            openWorkflow = nil
        }
    }

    /// Whether the window is showing Events: what happened, what came of it, and who
    /// is waiting (042). A page like Resources, and not persisted for the same reason.
    var showsEvents = false {
        didSet {
            guard showsEvents, showsEvents != oldValue else { return }
            showsSpending = false
            showsResources = false
            selection = nil
            openWorkflow = nil
        }
    }

    /// The event a workflow row asked to be shown, or `waitingNow` for the strip a
    /// chat's waiting capsule asked for. Scrolled to, once.
    var eventsFocus: EventsFocus?

    enum EventsFocus: Equatable {
        case event(EventPosition)
        case waitingNow
    }

    /// Events, at one event or at Waiting now if something asked for it.
    func showEvents(at focus: EventsFocus? = nil) {
        eventsFocus = focus
        showsEvents = true
    }

    /// A workflow's page, from an event that fired or was refused by it.
    func showWorkflow(folder: URL, workflowID: String) {
        showProject(ProjectKey(folder: folder))
        openWorkflow = Project.standardize(folder).path + "/" + workflowID
    }

    /// The resource a capsule in a chat asked to be shown. Scrolled to, once.
    var resourcesFocus: ResourceName?

    /// Resources, at one resource if a chat's capsule asked for it.
    func showResources(at name: ResourceName? = nil) {
        resourcesFocus = name
        showsResources = true
    }

    /// An agent's chat, from the Resources page or a capsule naming its holder: its
    /// own project first, as a banner does, so the sidebar and the page agree.
    func openAgent(_ agentID: UUID) {
        showsSpending = false
        showsResources = false
        showsEvents = false
        if let agent = agents.first(where: { $0.id == agentID }) {
            select(ProjectKey(host: agent.host, folder: agent.projectFolder))
        }
        openWorkflow = nil
        selection = agentID
    }

    /// What is picked in the sidebar, as one value.
    ///
    /// The projects and Spending share a column, so they have to share a selection:
    /// two bindings would let both look picked at once. `selectedProject` stays the
    /// stored fact — it is what the window reopens on — and this is the view of it
    /// the list is driven by.
    var sidebarItem: SidebarItem? {
        get {
            showsEvents ? .events : showsResources ? .resources
                : showsSpending ? .spending : selectedProjectKey.map(SidebarItem.project)
        }
        set {
            switch newValue {
            case .spending:
                showsSpending = true
            case .resources:
                showResources()
            case .events:
                showEvents()
            case .project(let key):
                showsSpending = false
                showsResources = false
                showsEvents = false
                showProject(key)
            case nil:
                // A list that clears its own selection — which macOS does while rows
                // come and go — must not empty the detail column. Nothing is picked
                // is not a thing this window can show.
                break
            }
        }
    }

    /// Go to a project's page, whether or not it was already the selected one.
    ///
    /// `selectedProject`'s `didSet` says the rule — picking a project shows the
    /// project, not a conversation — but it can only fire on a change, and macOS drives
    /// a `List` selection binding from a selection-*changed* notification. Clicking the
    /// row that is already highlighted never calls the setter at all. From inside a
    /// conversation the highlighted row is that conversation's own project, so the one
    /// click a person would make to go back up was the one the framework discarded.
    ///
    /// This is that rule as something callable. It touches no agent: `selection` only
    /// decides which transcript this window is watching, and the turn belongs to the
    /// daemon.
    func showProject(_ key: ProjectKey) {
        // Going to a project is going away from Spending, wherever the ask came from
        // — a new project being added, a menu item, the list itself. And from
        // Resources, for the same reason.
        showsSpending = false
        showsResources = false
        showsEvents = false
        select(key)
        selection = nil
        openWorkflow = nil
    }

    /// Pick a project on a host. The host goes first, so the folder's `didSet` stores
    /// and compares the pair rather than a folder paired with the last host (037).
    func select(_ key: ProjectKey?) {
        if let key, key.host != selectedProjectHost {
            selectedProjectHost = key.host
            // The same folder on another host is another project.
            if selectedProject == key.folder { selectedProject = nil }
        }
        selectedProject = key?.folder
    }

    /// Bumped when something asks the conversation to go to its end.
    ///
    /// A counter rather than a flag, so two asks in a row both land. The end of a
    /// transcript is not an entry, which is why this is not `focusedEntry`.
    private(set) var scrollToEndToken = 0

    func scrollToEnd() { scrollToEndToken += 1 }

    var selection: UUID? {
        didSet {
            guard selection != oldValue else { return }
            // Which conversation is being read is what decides whether an arriving
            // transcript entry is ours to keep, so the shared model is told first.
            work.watching = selection
            presence?.watching(selection)
            Task { await loadTranscript() }
        }
    }

    /// Which workflow is open, if one is instead of a conversation.
    ///
    /// `selection`'s sibling rather than a widening of it. Making that field an enum
    /// of agent-or-workflow would have been the tidier model and the worse change:
    /// its `didSet` sets `work.watching` and reloads the transcript, and it is
    /// threaded through the view tree as a binding in some forty places, every one of
    /// which would have had to learn about a case it has nothing to say about. One
    /// more field costs one line. The two are exclusive, and `ContentView`'s `page`
    /// binding is the single place navigation sets either.
    var openWorkflow: Workflow.ID?

    // What the prompt bar is holding before there is an agent to hold it. It lives
    // here rather than in the view so that starting an agent does not throw it away
    // half way through the bar moving down the pane.
    var draftCwd: URL? {
        didSet {
            guard draftCwd != oldValue else { return }
            // A worktree belongs to one repository, so a new folder is a new question.
            draftWorktree = nil
            draftWorktrees = .notARepository
            Task { await loadDraftWorktrees() }
        }
    }
    var draftRuntimeID: String?
    /// Where in the project the next agent works, when not the project folder (030).
    /// Deliberately not kept with the rest of the form: a worktree is decided per
    /// agent, so it goes back to the project folder after every start (FR-004).
    var draftWorktree: WorktreeChoice?
    /// What the draft folder's repository has, for the Worktree chooser. Not a
    /// repository until the daemon says otherwise, which keeps the chooser hidden.
    private(set) var draftWorktrees: DaemonAPI.WorktreesListResponse = .notARepository
    private var draftWorktreesGeneration = 0
    /// The branch each project folder is on, for the chat's folder chip. Missing until
    /// asked, and for a folder in no repository.
    private(set) var projectFolderBranches: [URL: String] = [:]
    private(set) var draftOptions: [ConfigOption] = []
    private(set) var draftCommands: [SlashCommand] = []
    var draftChosen: [String: JSONValue] = [:]
    /// Folders beyond the working one, and MCP servers, for the agent about to start.
    var draftFolders: [URL] = []
    var draftServers: [MCPServer] = []
    /// Words handed to the prompt bar from elsewhere on the page — the workflows
    /// section's example, today. Offered and then taken: the bar puts them in the
    /// field and clears this, because the prompt itself is still the bar's own and
    /// sending it is still the person's move.
    var offeredPrompt: String?
    private(set) var isLoadingDraftOptions = false
    /// Why the last fetch of a runtime's options failed, if it did.
    ///
    /// Its own thing rather than the global `problem` banner: the row under the prompt
    /// has to say this, and offer to try again, and a modal alert can be dismissed
    /// leaving the row looking like a runtime with nothing to adjust.
    private(set) var draftOptionsFailure: String?
    /// Which fetch is the current one.
    ///
    /// Changing the folder and then the runtime issues two calls, and without this the
    /// first to answer wins and is shown as settled while the right one is still in
    /// flight.
    private var draftOptionsGeneration = 0
    private var draftID: UUID?

    private let client = DaemonClient()
    /// The servers (037). This Mac is `client`, as it always was.
    let hosts = HostSet(locations: .default)
    /// What this window may lend to servers (043). Never to this Mac's own daemon (D5).
    let credentials = ServerCredentials(locations: .default)
    /// A server asked for a credential there is none of; the window asks the person (043).
    var tokenAsk: TokenAsk?
    /// What a server with no connection answers through: nothing, at once.
    private static let unreachable = DaemonClient(link: UnreachableLink())

    /// The client for work on a host. A server that is not connected answers with an
    /// error straight away, never with the Mac's daemon.
    func client(for host: HostID) -> DaemonClient {
        host == .mac ? client : hosts.client(for: host) ?? Self.unreachable
    }

    private func client(forAgent id: UUID?) -> DaemonClient {
        client(for: work.agent(id)?.host ?? .mac)
    }

    /// Where a new agent, a draft, a worktree or a session list for the selected
    /// project goes: that project's host.
    private var selectedHostClient: DaemonClient { client(for: selectedProjectHost) }
    private var listening: Task<Void, Never>?

    /// The panes listening for shell output, one per agent in this window. Shell
    /// notifications are broadcast to every window, so each one keeps only the agents
    /// it is actually showing and ignores the rest.
    @ObservationIgnored private var shellClients: [UUID: ShellClient] = [:]

    /// What each agent had already spent when this window first laid eyes on it.
    ///
    /// An agent's `costToDate` is its whole life, and agents outlive the window, so
    /// adding them up would be an all-time figure wearing the word "session". Taking
    /// away what was spent before we were watching leaves what this sitting cost.
    var selectedAgent: Agent? { work.agent(selection) }

    var permissionForSelection: PermissionRequest? { work.permission(for: selection) }

    /// What a new agent can be started with, on the machine it would start on: the
    /// selected project's (037). A server's runtimes are the ones installed there.
    var availableRuntimes: [RuntimeStatus] {
        runtimes(on: selectedProjectHost).filter { $0.availability.isAvailable }
    }

    /// This Mac's, whatever is selected: for saying nothing is installed on this Mac.
    var macRuntimesAvailable: [RuntimeStatus] {
        runtimes.filter { $0.availability.isAvailable }
    }

    /// Each server's runtimes, as it last listed them (037).
    private(set) var serverRuntimes: [HostID: [RuntimeStatus]] = [:]

    func runtimes(on host: HostID) -> [RuntimeStatus] {
        host == .mac ? runtimes : serverRuntimes[host] ?? []
    }

    func refreshServerRuntimes(_ host: HostID) async {
        if let listed = try? await client(for: host).call(DaemonAPI.Method.runtimesList, Optional<String>.none,
                                                          returning: [RuntimeStatus].self) {
            serverRuntimes[host] = listed
        }
    }

    // MARK: Projects

    /// The ones the sidebar lists.
    var liveProjects: [DaemonAPI.ProjectSummary] { work.liveProjects }

    var archivedProjects: [DaemonAPI.ProjectSummary] { work.archivedProjects }

    var selectedProjectSummary: DaemonAPI.ProjectSummary? { work.project(selectedProjectKey) }

    /// A project's agents in one group, newest first.
    func agents(in key: ProjectKey?, group: AgentGroup) -> [Agent] {
        work.agents(in: key, group: group)
    }

    /// This window's own counts for a project, from the grouping its panel uses.
    func counts(in key: ProjectKey?) -> [AgentGroup: Int] { work.counts(in: key) }
    func unreadCount(in key: ProjectKey?) -> Int { work.unreadCount(in: key) }

    /// Whether the daemon is bringing this chat back by itself after a restart.
    func isComingBack(_ agent: Agent) -> Bool { work.isComingBack(agent) }

    /// "Started by …" for an agent another agent started, and nil otherwise (028).
    func startedByAgentLabel(_ agent: Agent) -> String? { work.startedByAgentLabel(agent) }

    /// Whether Stop is offered for this chat, in the toolbar and on the card alike.
    func canStop(_ agent: Agent) -> Bool { work.canStop(agent) }
    func blockLines(_ agent: Agent) -> [String] { work.blockLines(agent) }
    func isBlocked(_ agent: Agent) -> Bool { work.openBlock(agent) != nil }

    // MARK: Workflows

    func workflows(in folder: URL?) -> [WorkflowSummary] { work.workflows(in: folder) }

    // MARK: Paired devices (021)

    /// The paired devices, announced first. Read by the Devices pane. Refreshed on
    /// connect and kept by `device/changed`.
    private(set) var devices: [Device] = []

    func refreshDevices() async {
        guard let listed = try? await client.call(DaemonAPI.Method.devicesList, Optional<String>.none,
                                                  returning: [Device].self) else { return }
        devices = listed
    }

    private func deviceChanged(_ change: DaemonAPI.DeviceNotification) {
        devices.removeAll { $0.id == change.id }
        devices.append(change.device)
        devices.sort { $0.announcedAt < $1.announcedAt }
    }

    func refreshWorkflows() async {
        do {
            work.replaceWorkflows(try await client.call(DaemonAPI.Method.workflowsList,
                                                        DaemonAPI.WorkflowsListRequest(),
                                                        returning: [WorkflowSummary].self))
        } catch {
            // Same as the projects above: the next notification brings it back.
        }
    }

    // MARK: Pull requests (038)

    /// Each GitHub project's Pull requests section, by folder. Absent for a project
    /// that is not on GitHub, which is how the section is absent there (SC-006).
    private(set) var pullRequestLists: [URL: PullRequestList] = [:]
    /// Pull requests being checked out now, by folder and number.
    private(set) var checkingOut: Set<PullRequestKey> = []
    /// The last check-out that failed, with its reason, until the next list replaces it.
    private(set) var checkoutFailures: [PullRequestKey: String] = [:]

    struct PullRequestKey: Hashable {
        var folder: URL
        var number: Int
    }

    /// What the daemon has, at once, then a refresh. Asked for when a project page
    /// opens; never polled. The daemon's own clock keeps it current after that.
    func loadPullRequests(for folder: URL) async {
        let folder = Project.standardize(folder)
        if let list = try? await client.call(DaemonAPI.Method.pullRequestsList,
                                             DaemonAPI.PullRequestsRequest(folder: folder),
                                             returning: PullRequestList?.self) {
            setPullRequests(list, for: folder)
        } else {
            pullRequestLists[folder] = nil
            return
        }
        await refreshPullRequests(for: folder)
    }

    /// The ↻: refresh now, which the daemon holds to once a minute (FR-008).
    func refreshPullRequests(for folder: URL) async {
        let folder = Project.standardize(folder)
        guard let list = try? await client.call(DaemonAPI.Method.pullRequestsRefresh,
                                                DaemonAPI.PullRequestsRequest(folder: folder),
                                                returning: PullRequestList?.self) else { return }
        setPullRequests(list, for: folder)
    }

    /// Check a pull request's branch out into a worktree of its own (FR-007). A failure
    /// stays on its row rather than in an alert: each reason says what to do.
    func checkOut(_ number: Int, in folder: URL) async {
        let key = PullRequestKey(folder: Project.standardize(folder), number: number)
        checkingOut.insert(key)
        checkoutFailures[key] = nil
        defer { checkingOut.remove(key) }
        do {
            let list = try await client.call(DaemonAPI.Method.pullRequestsCheckout,
                                             DaemonAPI.PullRequestRequest(folder: key.folder, number: number),
                                             returning: PullRequestList.self)
            setPullRequests(list, for: key.folder)
            // The new worktree belongs in the Worktrees section below too.
            await loadDraftWorktrees()
        } catch {
            checkoutFailures[key] = describe(error)
        }
    }

    /// Why Babysit my pull requests was refused, by folder, until it is tried again.
    private(set) var babysitterRefusals: [URL: String] = [:]

    /// Babysit my pull requests: write the starter workflow (FR-026). A ceiling is said
    /// under the button rather than in an alert (wireframe G).
    func addBabysitter(in folder: URL) async {
        let folder = Project.standardize(folder)
        babysitterRefusals[folder] = nil
        do {
            let summary = try await client.call(DaemonAPI.Method.pullRequestsAddBabysitter,
                                                DaemonAPI.PullRequestsRequest(folder: folder),
                                                returning: WorkflowSummary.self)
            work.upsert(summary)
            if var list = pullRequestLists[folder] {
                list.babysitterWorkflowID = summary.workflowID
                pullRequestLists[folder] = list
            }
        } catch {
            babysitterRefusals[folder] = describe(error)
        }
    }

    /// Resume: start babysitting a stopped pull request again (FR-024).
    func resume(_ number: Int, in folder: URL) async {
        let folder = Project.standardize(folder)
        do {
            let list = try await client.call(DaemonAPI.Method.pullRequestsResume,
                                             DaemonAPI.PullRequestRequest(folder: folder, number: number),
                                             returning: PullRequestList.self)
            setPullRequests(list, for: folder)
        } catch {
            problem = describe(error)
        }
    }

    private func setPullRequests(_ list: PullRequestList?, for folder: URL) {
        pullRequestLists[folder] = list
        // A failure is true until the list next changes, and no longer.
        checkoutFailures = checkoutFailures.filter { $0.key.folder != folder }
    }

    /// Run one now. The daemon still applies the in-flight, ceiling and archive rules,
    /// and says so on the summary, which is why nothing here second-guesses it first.
    func runWorkflow(_ summary: WorkflowSummary) async {
        try? await client.call(DaemonAPI.Method.workflowsRun,
                               DaemonAPI.WorkflowRequest(folder: summary.folder,
                                                         workflowID: summary.workflowID))
    }

    /// Put one away, or bring it back. The person's answer to a workflow an agent
    /// wrote, which is what makes writing one not need asking first.
    func setWorkflowArchived(_ summary: WorkflowSummary, _ archived: Bool) async {
        try? await client.call(DaemonAPI.Method.workflowsArchive,
                               DaemonAPI.WorkflowArchiveRequest(folder: summary.folder,
                                                                workflowID: summary.workflowID,
                                                                archived: archived))
    }

    /// Change what a workflow is allowed to do. The daemon writes the file.
    ///
    /// The one call in this section that does **not** swallow its error, and the
    /// difference matters: every other one here is asking for something the daemon
    /// will do or will not, and the next notification puts the window right either way.
    /// This one is asking for somebody's own file to be changed, and a refusal — front
    /// matter it will not touch, a file it cannot write — has to reach them, or the
    /// app has silently kept a change it never made (FR-025).
    func setWorkflowSettings(_ summary: WorkflowSummary, _ settings: WorkflowSettings) async {
        do {
            let updated: WorkflowSummary = try await client.call(
                DaemonAPI.Method.workflowsSettings,
                DaemonAPI.WorkflowSettingsRequest(folder: summary.folder,
                                                  workflowID: summary.workflowID,
                                                  settings: settings),
                returning: WorkflowSummary.self)
            work.upsert(updated)
        } catch {
            problem = describe(error)
            // What the file still says, so the control goes back to the truth rather
            // than sitting on a value that was never written.
            await refreshWorkflows()
        }
    }

    /// What a runtime last advertised for a folder, for the menus on the workflow page.
    ///
    /// Empty is an answer, not a failure: it means nothing has been remembered for this
    /// runtime here yet, and the page says so rather than offering a menu it made up.
    func rememberedOptions(runtimeID: String, cwd: URL) async -> [ConfigOption] {
        (try? await selectedHostClient.call(DaemonAPI.Method.optionsRemembered,
                                DaemonAPI.RememberedOptionsRequest(runtimeID: runtimeID, cwd: cwd),
                                returning: [ConfigOption].self)) ?? []
    }

    /// What today has cost and what the reader will allow. A daemon too old to know
    /// the method answers method-not-found, which leaves `costState` nil and every
    /// surface showing what it showed before this feature.
    /// Whether the Mac is being kept awake, asked once on connecting.
    ///
    /// A window that opens while a hold is already in place has heard no broadcast, and
    /// for a long turn would otherwise say nothing about it for half an hour.
    ///
    /// Tolerates method-not-found exactly as `refreshCostState` does: a daemon too old
    /// to know `wake/state` leaves `wakeState` nil, and the window simply says nothing
    /// about sleep rather than failing to open.
    func refreshWakeState() async {
        guard let state = try? await client.call(DaemonAPI.Method.wakeState,
                                                 Optional<String>.none,
                                                 returning: DaemonAPI.WakeState.self) else { return }
        work.replaceWakeState(state)
    }

    /// Every resource and who holds it (036). A daemon too old to know the method
    /// leaves `leases` nil, and nothing about leases is drawn.
    func refreshLeases() async {
        guard let snapshot = try? await client.call(DaemonAPI.Method.leasesSnapshot,
                                                    Optional<String>.none,
                                                    returning: DaemonAPI.LeaseSnapshot.self) else { return }
        work.replaceLeases(snapshot)
    }

    /// The newest page of events and who is waiting (042). A daemon too old to know the
    /// method leaves the list empty, and the Events page says there is nothing yet.
    func refreshEvents() async {
        guard let page = try? await client.call(DaemonAPI.Method.eventsList, DaemonAPI.EventsListRequest(),
                                                returning: DaemonAPI.EventsPage.self) else { return }
        work.takeEvents(page)
    }

    /// The page before the oldest event the window has, for scrolling back.
    func loadOlderEvents() async {
        guard work.moreEvents, let oldest = work.recentEvents.last?.position else { return }
        guard let page = try? await client.call(DaemonAPI.Method.eventsList,
                                                DaemonAPI.EventsListRequest(before: oldest),
                                                returning: DaemonAPI.EventsPage.self) else { return }
        work.takeEvents(page, appending: true)
    }

    /// The person cancelling an agent's wait (042 FR-013). The Mac only.
    func cancelWait(of agentID: UUID) async {
        _ = try? await client.call(DaemonAPI.Method.eventsCancelWait, DaemonAPI.CancelWaitRequest(agentID: agentID),
                                   returning: [DaemonAPI.WaitingAgent].self)
    }

    /// The person ending whoever holds a resource (036 US4). Never a way to take one.
    func endLease(_ name: ResourceName) async {
        guard let snapshot = try? await client.call(DaemonAPI.Method.leasesEnd,
                                                    DaemonAPI.PersonEndRequest(name: name.key),
                                                    returning: DaemonAPI.LeaseSnapshot.self) else { return }
        work.replaceLeases(snapshot)
    }

    /// The person taking one agent out of one line (036 US4).
    func removeFromLine(_ name: ResourceName, agentID: UUID) async {
        guard let snapshot = try? await client.call(
            DaemonAPI.Method.leasesRemoveWaiter,
            DaemonAPI.PersonRemoveRequest(name: name.key, agentID: agentID.uuidString),
            returning: DaemonAPI.LeaseSnapshot.self) else { return }
        work.replaceLeases(snapshot)
    }

    func refreshCostState() async {
        guard let state = try? await client.call(DaemonAPI.Method.costState,
                                                 Optional<String>.none,
                                                 returning: DaemonAPI.CostState.self) else { return }
        work.replaceCostState(state)
    }

    /// The reader setting or clearing a limit. Theirs alone: nothing an agent or a
    /// workflow can reach calls this.
    func setCostLimits(perAgent: Cost?? = nil, daily: Cost?? = nil) async {
        guard let state = try? await client.call(
            DaemonAPI.Method.costSetLimits,
            DaemonAPI.SetLimitsRequest(perAgent: perAgent, daily: daily),
            returning: DaemonAPI.CostState.self) else { return }
        work.replaceCostState(state)
        // Every connected server keeps to the same limits, each on its own (037, R7).
        for host in hosts.hosts.all where !hosts.isOffline(host.id) {
            serverCosts[host.id] = try? await client(for: host.id).call(
                DaemonAPI.Method.costSetLimits,
                DaemonAPI.SetLimitsRequest(perAgent: .some(state.limits.perAgent), daily: .some(state.limits.daily)),
                returning: DaemonAPI.CostState.self)
        }
    }

    /// Each server's spending, as it last said (037).
    private(set) var serverCosts: [HostID: DaemonAPI.CostState] = [:]

    /// What the servers have spent today, together, per currency. Empty when nothing.
    var serversToday: [String: Decimal] {
        serverCosts.values.reduce(into: [:]) { sum, state in
            for (currency, amount) in state.today { sum[currency, default: 0] += amount }
        }
    }

    /// Letting one agent carry on past the per-agent limit, or giving it one of its
    /// own. Does not resume it — continuing is the reader's second, deliberate act.
    func setCostCeiling(_ agentID: UUID, to ceiling: Cost?) async {
        guard let agent = try? await client(forAgent: agentID).call(
            DaemonAPI.Method.agentsSetCeiling,
            DaemonAPI.SetCeilingRequest(agentID: agentID, ceiling: ceiling),
            returning: Agent.self) else { return }
        work.upsert(agent)
    }

    /// Let one agent that has reached the per-agent limit carry on.
    ///
    /// Raises that agent's own ceiling by the app-wide limit again — a concrete,
    /// bounded allowance rather than removing the cap, so an agent let go on once is
    /// still stopped eventually. Applies to that agent alone, and does not resume it.
    func letThisAgentGoOn(_ agent: Agent) async {
        await setCostCeiling(agent.id, to: agent.ceilingToGoOn(under: costLimits))
    }

    func refreshProjects() async {
        do {
            let listed = try await client.call(DaemonAPI.Method.projectsList, DaemonAPI.ProjectsListRequest(),
                                               returning: [DaemonAPI.ProjectSummary].self)
            work.replaceProjects(listed, from: .mac)
            hasLoadedProjects = true
            settleProjectSelection()
        } catch {
            // A list that failed is not worth an alert: the notification that follows
            // the next change will bring it back.
        }
    }

    /// Pick a project when there is none, or when the one we had has gone or been
    /// archived. Falls back to the most recently active, which is what the sidebar
    /// puts at the top.
    private func settleProjectSelection() {
        let live = liveProjects
        if let selectedProjectKey, live.contains(where: { $0.key == selectedProjectKey }) { return }
        // `host|path`, or a bare path from before servers, which is this Mac's.
        let stored = UserDefaults.standard.string(forKey: Self.selectedProjectDefault)
            .flatMap(ProjectKey.init(stored:))
            .map { ProjectKey(host: $0.host, folder: Project.standardize($0.folder)) }
        if let stored, live.contains(where: { $0.key == stored }) {
            select(stored)
        } else {
            select(live.first?.key)
        }
    }

    func addProject(_ folder: URL, on host: HostID = .mac) async {
        await callProject(DaemonAPI.Method.projectsAdd, ProjectKey(host: host, folder: folder)) { [weak self] summary in
            self?.select(summary.key)
        }
    }

    /// Clone a Git URL into the home folder and select the project it becomes (027).
    ///
    /// Returns as soon as the daemon answers, which is when the clone has finished; the
    /// row the window draws meanwhile comes from `clone/changed`, not from waiting here.
    func cloneProject(_ url: String, on host: HostID = .mac) async {
        do {
            var summary = try await client(for: host).call(DaemonAPI.Method.projectsClone,
                                                DaemonAPI.CloneRequest(url: url),
                                                returning: DaemonAPI.ProjectSummary.self)
            summary.host = host
            upsert(summary)
            select(summary.key)
            settleProjectSelection()
        } catch {
            // Written for the person already: which host, which folder, what to do.
            problem = describe(error)
        }
    }

    func refreshClones() async {
        guard let running = try? await client.call(DaemonAPI.Method.projectsClones,
                                                   returning: [DaemonAPI.CloneSummary].self) else { return }
        clones = running
    }

    func archiveProject(_ key: ProjectKey) async {
        await callProject(DaemonAPI.Method.projectsArchive, key)
    }

    func unarchiveProject(_ key: ProjectKey) async {
        await callProject(DaemonAPI.Method.projectsUnarchive, key) { [weak self] summary in
            self?.select(summary.key)
        }
    }

    private func callProject(_ method: String, _ key: ProjectKey,
                             then: ((DaemonAPI.ProjectSummary) -> Void)? = nil) async {
        do {
            var summary = try await client(for: key.host).call(method, DaemonAPI.ProjectRequest(folder: key.folder),
                                                                returning: DaemonAPI.ProjectSummary.self)
            summary.host = key.host
            upsert(summary)
            then?(summary)
            settleProjectSelection()
        } catch {
            // A refusal here is the daemon naming the agents to stop, which is exactly
            // what the user needs to read.
            problem = describe(error)
        }
    }

    func upsert(_ summary: DaemonAPI.ProjectSummary) {
        work.upsert(summary)
        // The one thing filing a project means to a window and to nothing else: the
        // project being read may have just been archived, or may have just arrived.
        settleProjectSelection()
    }

    // MARK: Connecting

    /// The daemon exits when it has nothing in hand and nobody watching, so a window
    /// that has been sitting idle will outlive it. Noticing and going back is ordinary,
    /// not an error worth showing.
    private func lostConnection() async {
        isConnected = false
        listening = nil
        await reconnect()
    }

    /// Connect, and keep trying if that fails, which is what the window does when it
    /// opens.
    func stayConnected() async {
        await connect()
        if !isConnected { await reconnect() }
    }

    /// Keep going back until the daemon answers.
    ///
    /// One try used to be all there was, and a daemon slow to come back left a window
    /// that looked alive and never would be again. The same loop as the phone's:
    /// backing off to half a minute, and only one of it at a time.
    private func reconnect() async {
        guard reconnecting == nil else { return }
        reconnecting = Task { [weak self] in
            var wait = Duration.seconds(1)
            while !Task.isCancelled {
                try? await Task.sleep(for: wait)
                guard let self else { return }
                if self.isConnected { break }
                await self.connect()
                if self.isConnected { break }
                wait = min(wait * 2, .seconds(30))
            }
            self?.reconnecting = nil
        }
        await reconnecting?.value
    }

    func connect() async {
        do {
            try await client.connect()
            isConnected = true
            problem = nil
            listen()
            startPresence()
            presence?.connected()
            await refreshEverything()
            startHosts()
        } catch {
            isConnected = false
            problem = describe(error)
        }
    }

    private func listen() {
        listening?.cancel()
        let notifications = client.notifications()
        // Detached, so that reading each notification — the JSON of a tool call's
        // output can be a hundred kilobytes — happens off the main actor, and only
        // what it means is applied there. Each one is applied before the next is
        // read, so the order the daemon said them in is the order they land.
        listening = Task.detached(priority: .userInitiated) { [weak self] in
            for await notification in notifications {
                let update = AgentsModel.read(notification.method, notification.params)
                await self?.received(notification.method, notification.params, update)
            }
            // The daemon went, or the connection did. A list that has quietly stopped
            // being true is worse than an empty one, so the window says so and goes
            // back for another connection, starting the daemon again if it has to.
            await self?.lostConnection()
        }
    }

    private func received(_ method: String, _ params: JSONValue?, _ update: AgentsModel.Update?) async {
        // What every notification about the work means is written once, in the kit,
        // so the window and the phone cannot drift apart. What is left here is the
        // Mac's own: the shells and terminals a phone has no business with.
        if let update {
            work.apply(update)
            if case .projectChanged = update { settleProjectSelection() }
            if case .attention(let change) = update { await notifier.apply(change) }
            return
        }

        switch method {
        case DaemonAPI.Notification.deviceChanged:
            // The Mac's own, like the shells: a phone is never told about other phones.
            guard let change = try? params?.decode(DaemonAPI.DeviceNotification.self) else { return }
            deviceChanged(change)

        case DaemonAPI.Notification.shellOutput:
            // Read rather than decoded: this one arrives whenever a shell prints, and
            // the general path would re-encode every byte of it here on the main
            // actor before decoding it again. See `ShellOutputNotification`.
            guard let params, let notification = DaemonAPI.ShellOutputNotification(params: params) else { return }
            shellClients[notification.agentID]?.received(notification.bytes)

        case DaemonAPI.Notification.shellStateChanged:
            guard let notification = try? params?.decode(DaemonAPI.ShellStateNotification.self) else { return }
            shellClients[notification.agentID]?.received(notification.state)

        case DaemonAPI.Notification.draftOptions:
            guard let notification = try? params?.decode(DaemonAPI.DraftOptionsNotification.self) else { return }
            settleDraft(notification)

        case DaemonAPI.Notification.runtimeChanged:
            await refreshRuntimes()

        case DaemonAPI.Notification.runtimeAccountChanged:
            guard let account = try? params?.decode(RuntimeAccount.self) else { return }
            accounts[account.runtimeID] = account

        case DaemonAPI.Notification.pullRequestsChanged:
            // The Mac's own, like the shells (038 FR-010).
            guard let list = try? params?.decode(PullRequestList.self) else { return }
            setPullRequests(list, for: list.folder)

        case DaemonAPI.Notification.cloneChanged:
            guard let change = try? params?.decode(DaemonAPI.CloneNotification.self) else { return }
            clones.removeAll { $0.id == change.clone.id }
            if !change.finished { clones.append(change.clone) }

        default:
            break
        }
    }

    // MARK: Asking

    // MARK: Servers (037)

    @ObservationIgnored private var hostsStarted = false
    /// Each server's end of `files/*`, made when first wanted (037).
    @ObservationIgnored private var serverFilesByHost: [HostID: RemoteFiles] = [:]

    @ObservationIgnored private var serverPicturesByHost: [HostID: ServerPictures] = [:]

    /// A server's pictures for its live pages, kept while the app runs (037).
    func serverPictures(_ host: HostID) -> ServerPictures {
        if let known = serverPicturesByHost[host] { return known }
        let made = ServerPictures(files: serverFiles(host))
        serverPicturesByHost[host] = made
        return made
    }

    /// How the files pane reads a server agent's folder: through that server's daemon,
    /// because the folder is not on this Mac.
    func serverFiles(_ host: HostID) -> RemoteFiles {
        if let known = serverFilesByHost[host] { return known }
        let made = RemoteFiles(client: client(for: host))
        serverFilesByHost[host] = made
        return made
    }

    /// Once, after the Mac's own daemon has answered: the servers come after the Mac,
    /// so a slow server never holds up the window's first list.
    private func startHosts() {
        guard !hostsStarted else { return }
        hostsStarted = true
        hosts.onNotification = { [weak self] host, method, params in
            await self?.receivedFromServer(host, method, params)
        }
        hosts.offerFor = { [weak self] id in self?.credentialOffer(id) }
        hosts.lenderFor = { [weak self] id in
            { [weak self] wanted in
                guard let model = self else { return false }
                return await model.answerCredentialWanted(wanted, on: id)
            }
        }
        hosts.claudeWanted = { [weak self] id in
            guard let self else { return false }
            return self.credentials.record("claude") != nil && !(self.hosts.host(id)?.ownSignInOnly ?? false)
        }
        hosts.onConnected = { [weak self] host in
            await self?.refreshServer(host)
        }
        hosts.onReachability = { [weak self] server, online in
            guard let self else { return }
            _ = try? await self.client.call(DaemonAPI.Method.eventsServer,
                                            DaemonAPI.ServerReachabilityChange(server: server, online: online),
                                            returning: Event.self)
        }
        hosts.start()
    }

    private func receivedFromServer(_ host: HostID, _ method: String, _ params: JSONValue?) async {
        // What is about the whole of a daemon rather than its work is the Mac's alone in
        // the model: a server's spending is kept beside it, and a server's wakefulness,
        // modes and notices have no place in this window (037).
        switch method {
        case DaemonAPI.Notification.costChanged:
            serverCosts[host] = try? params?.decode(DaemonAPI.CostState.self)
            noteServerSpent(host)
            return
        case DaemonAPI.Notification.credentialRefused:
            // The token in Settings was refused: Settings turns red, and says why (043).
            if let refused = try? params?.decode(DaemonAPI.CredentialRefused.self), refused.lent {
                credentials.markRefused(refused.runtime)
            }
            return
        case DaemonAPI.Notification.wakeChanged, DaemonAPI.Notification.modesChanged,
             DaemonAPI.Notification.attentionChanged:
            return
        default:
            break
        }
        if work.apply(method, params, from: host) {
            if method == DaemonAPI.Notification.projectChanged { settleProjectSelection() }
            return
        }
        // A server's shells print to this window the same way the Mac's do. Nothing
        // else a server says is about this window: its devices, runtimes and clones
        // are asked for when they are wanted.
        switch method {
        case DaemonAPI.Notification.runtimeChanged:
            await refreshServerRuntimes(host)
        case DaemonAPI.Notification.filesChanged:
            guard let change = try? params?.decode(DaemonAPI.FilesChangedNotification.self) else { return }
            serverFiles(host).apply(change)
        case DaemonAPI.Notification.shellOutput, DaemonAPI.Notification.shellStateChanged,
             DaemonAPI.Notification.draftOptions:
            await received(method, params, nil)
        default:
            break
        }
    }

    /// Everything a server has, after it connects or comes back. Replaces only that
    /// server's own, so the Mac's list is never emptied by a server re-listing, and
    /// whatever happened while the Mac was away is simply what the server now says.
    /// Remove a server, and everything the window held from it (037 US5).
    func removeServer(_ host: HostID, purge: Bool) async {
        await hosts.remove(host, purge: purge)
        work.replaceAgents([], from: host)
        work.replaceProjects([], from: host)
        serverRuntimes[host] = nil
        serverFilesByHost[host] = nil
        if selectedProjectHost == host { select(liveProjects.first?.key) }
    }

    func refreshServer(_ host: HostID) async {
        let server = client(for: host)
        // A new connection watches nothing; what the files pane was watching is asked
        // for again, and everything it shows is read again.
        await serverFilesByHost[host]?.reconnected()
        await refreshServerRuntimes(host)
        // The Mac's limits hold on every server too; each keeps to them on its own.
        if let limits = work.costState?.limits {
            serverCosts[host] = try? await server.call(
                DaemonAPI.Method.costSetLimits,
                DaemonAPI.SetLimitsRequest(perAgent: .some(limits.perAgent), daily: .some(limits.daily)),
                returning: DaemonAPI.CostState.self)
        } else {
            serverCosts[host] = try? await server.call(DaemonAPI.Method.costState, returning: DaemonAPI.CostState.self)
        }
        if let listed = try? await server.call(DaemonAPI.Method.agentsList, DaemonAPI.ListRequest(),
                                               returning: [Agent].self) {
            work.replaceAgents(listed, from: host)
        }
        if let listed = try? await server.call(DaemonAPI.Method.projectsList, DaemonAPI.ProjectsListRequest(),
                                               returning: [DaemonAPI.ProjectSummary].self) {
            work.replaceProjects(listed, from: host)
            hosts.noteProjects(host, listed: listed)
            settleProjectSelection()
        }
        let theirs = Set(work.agents.filter { $0.host == host }.map(\.id))
        if let listed = try? await server.call(DaemonAPI.Method.permissionsPending,
                                               returning: [PermissionRequest].self) {
            work.replacePermissions(work.permissions.filter { !theirs.contains($0.agentID) } + listed)
        }
        if let listed = try? await server.call(DaemonAPI.Method.elicitationsPending,
                                               returning: [ElicitationRequest].self) {
            work.replaceElicitations(work.elicitations.filter { !theirs.contains($0.agentID) } + listed)
        }
        if let watching = selection, theirs.contains(watching) { await loadTranscript() }
    }

    func refreshEverything() async {
        await refreshAgents()
        // After the agents, because a project's counts are worked out from them and a
        // sidebar drawn before them would say every project is empty.
        await refreshProjects()
        // The rest at once. Each is its own round trip to the daemon and none
        // depends on another, so one after the other was ten waits where the window
        // sat with a list and no conversation.
        async let runtimes: Void = refreshRuntimes()
        async let accounts: Void = refreshAccounts()
        async let workflows: Void = refreshWorkflows()
        async let devices: Void = refreshDevices()
        async let permissions: Void = refreshPermissions()
        async let elicitations: Void = refreshElicitations()
        async let attention: Void = refreshAttention()
        async let resuming: Void = refreshResuming()
        async let cost: Void = refreshCostState()
        async let cloning: Void = refreshClones()
        async let wake: Void = refreshWakeState()
        async let leases: Void = refreshLeases()
        async let events: Void = refreshEvents()
        async let modes: Void = refreshModes()
        async let transcript: Void = loadTranscript()
        _ = await (runtimes, accounts, workflows, devices, permissions,
                   elicitations, attention, resuming, cost, cloning, wake, leases, events, modes, transcript)
    }

    func refreshElicitations() async {
        guard let list = try? await client.call(DaemonAPI.Method.elicitationsPending,
                                                Optional<Int>.none,
                                                returning: [ElicitationRequest].self) else { return }
        work.replaceElicitations(elicitationsOnServers + list)
    }

    /// What is held for the servers' agents, kept when the Mac's own are re-listed (037).
    private var elicitationsOnServers: [ElicitationRequest] {
        work.elicitations.filter { work.agent($0.agentID).map { $0.host != .mac } ?? false }
    }

    private var permissionsOnServers: [PermissionRequest] {
        work.permissions.filter { work.agent($0.agentID).map { $0.host != .mac } ?? false }
    }

    /// The form waiting for this agent, if there is one. Held by the daemon, so it is
    /// here whether or not this window was open when it was asked.
    var elicitationForSelection: ElicitationRequest? { work.elicitation(for: selection) }

    func refreshAgents() async {
        await attempt {
            let listed = try await self.client.call(DaemonAPI.Method.agentsList,
                                                    DaemonAPI.ListRequest(),
                                                    returning: [Agent].self)
            self.work.replaceAgents(listed, from: .mac)
            // Whatever the list already shows was spent before this window opened, so
            // the session total starts from here rather than from the beginning of time.
        }
    }

    func refreshRuntimes() async {
        let listed = await attempt {
            self.runtimes = try await self.client.call(DaemonAPI.Method.runtimesList,
                                                       Optional<String>.none,
                                                       returning: [RuntimeStatus].self)
        }
        if listed { weighInstallOffer() }
    }

    /// Install a missing runtime on this Mac (048). Answers at once; the rest arrives on
    /// `runtime/changed`, which refreshes the list, so every view drawing a runtime moves
    /// with it and the new-agent menu has it the moment it is there.
    func installRuntime(_ runtimeID: String) async {
        await attempt {
            let status = try await self.client.call(DaemonAPI.Method.runtimesInstall,
                                                    DaemonAPI.RuntimeRequest(runtimeID: runtimeID),
                                                    returning: RuntimeStatus.self)
            if let index = self.runtimes.firstIndex(where: { $0.id == status.id }) {
                self.runtimes[index] = status
            }
        }
    }

    /// The runtimes the start-up sheet is about: not on this Mac, installing, or failed.
    var missingRuntimes: [RuntimeStatus] {
        runtimes.filter { InstallOffer.isMissing($0.availability) }
    }

    /// Whatever is missing now has been offered, whichever way the sheet was closed.
    func rememberInstallOffer() {
        InstallOffer.remember(missingRuntimes.map(\.id))
        isOfferingInstall = false
    }

    private func weighInstallOffer() {
        guard !hasWeighedInstallOffer, !runtimes.isEmpty else { return }
        hasWeighedInstallOffer = true
        let offered = InstallOffer.offered
        if missingRuntimes.contains(where: { !offered.contains($0.id) }) { isOfferingInstall = true }
    }

    /// What wants a person and where each is showing, on connect and on coming to the
    /// front: the daemon's list is the truth, and a banner it no longer lists is stale.
    func refreshAttention() async {
        let pending: DaemonAPI.AttentionPending
        do {
            pending = try await client.call(DaemonAPI.Method.attentionPending, Optional<String>.none,
                                            returning: DaemonAPI.AttentionPending.self)
        } catch {
            note("attention: pending failed: \(error)")
            return
        }
        work.replaceAttention(pending)
        await notifier.sweep(keeping: pending)
    }

    /// The window's own report of where the person is, started once and kept for the
    /// life of the window. Opening a banner selects the conversation it names.
    private func startPresence() {
        guard presence == nil else { return }
        notifier.open = { [weak self] agentID in
            guard let self else { return }
            // Its own project first, because picking a project empties the selection:
            // a chat opened from a banner under some other project's heading is a
            // sidebar and a page that disagree about where you are.
            self.openAgent(agentID)
        }
        let reporter = PresenceReporter { [weak self] watching, active in
            guard let self else { return }
            _ = try? await self.client.call(DaemonAPI.Method.presenceReport,
                                            DaemonAPI.PresenceReport(watching: watching, active: active))
            // Coming to the front is also the moment to drop any banner that has gone
            // stale while nobody was looking.
            if active { await self.refreshAttention() }
        }
        reporter.start()
        presence = reporter
    }

    func refreshPermissions() async {
        await attempt {
            self.work.replacePermissions(self.permissionsOnServers
                + (try await self.client.call(DaemonAPI.Method.permissionsPending,
                                              Optional<String>.none,
                                              returning: [PermissionRequest].self)))
        }
    }

    /// What the daemon is still bringing back after a restart.
    ///
    /// Asked without `attempt`: a daemon too old to know the method answers
    /// method-not-found, and nothing coming back is the right answer to that, not a
    /// connection the window should report as broken.
    func refreshResuming() async {
        let response = try? await client.call(DaemonAPI.Method.agentsResuming,
                                              Optional<String>.none,
                                              returning: DaemonAPI.ResumingResponse.self)
        work.setResuming(response?.agentIDs ?? [])
    }

    func loadTranscript() async {
        guard let selection else { work.clearTranscript(); return }
        await attempt {
            let page = try await self.client(forAgent: selection).call(DaemonAPI.Method.agentsTranscript,
                                                  DaemonAPI.TranscriptRequest(agentID: selection),
                                                  returning: TranscriptPage.self)
            // Clicking through chats quickly can have the answer for the last one
            // arrive after the next was picked. It is dropped, not shown under the
            // wrong name.
            guard self.selection == selection else { return }
            self.work.replaceTranscript(with: page)
        }
    }

    /// The window only ever asks for a page. A transcript that has been going for hours
    /// is not something to load whole.
    func loadEarlier() async {
        guard let selection, work.hasMoreBefore else { return }
        await attempt {
            let page = try await self.client(forAgent: selection).call(
                DaemonAPI.Method.agentsTranscript,
                DaemonAPI.TranscriptRequest(agentID: selection, before: self.work.firstEntryIndex),
                returning: TranscriptPage.self)
            // The same as `loadTranscript`: an earlier page of a chat no longer open
            // does not belong on top of the one that is.
            guard self.selection == selection else { return }
            self.work.prepend(page)
        }
    }

    // MARK: Doing

    /// Where the draft session is made: in a worktree already there when one is chosen,
    /// so the start can use it (research R2). A new worktree has no folder until the
    /// start makes it, so its draft is the project folder's and the start lets it go.
    private var draftOptionsFolder: URL? {
        if case .existing(let root) = draftWorktree { return root }
        return draftCwd
    }

    /// Choose where the next agent works, and make the draft there if that moved it.
    func chooseWorktree(_ choice: WorktreeChoice?) {
        let before = draftOptionsFolder
        draftWorktree = choice
        if draftOptionsFolder != before, draftRuntimeID != nil {
            Task { await loadDraftOptions() }
        }
    }

    /// What removing one of the project's worktrees would lose, or nil when it could
    /// not be asked (and `problem` says why).
    func checkWorktreeRemoval(_ root: URL) async -> DaemonAPI.RemovalCheck? {
        guard let project = draftCwd else { return nil }
        do {
            return try await selectedHostClient.call(DaemonAPI.Method.worktreesCheck,
                                         DaemonAPI.WorktreeRemovalRequest(project: project, root: root),
                                         returning: DaemonAPI.RemovalCheck.self)
        } catch {
            problem = describe(error)
            return nil
        }
    }

    /// Remove one of the project's worktrees. `confirmed` is the person having seen
    /// what would be lost; the daemon checks again either way.
    func removeWorktree(_ root: URL, confirmed: Bool) async {
        guard let project = draftCwd else { return }
        do {
            _ = try await selectedHostClient.call(DaemonAPI.Method.worktreesRemove,
                                      DaemonAPI.WorktreeRemovalRequest(project: project, root: root,
                                                                       confirmed: confirmed),
                                      returning: DaemonAPI.WorktreeRemoved.self)
        } catch {
            problem = describe(error)
        }
        await loadDraftWorktrees()
    }

    /// What an agent changed (035). Asked by the Changes pane on its own triggers —
    /// shown, an edit finished, the turn ended — and never polled.
    func changes(for agentID: UUID) async throws -> ChangesList {
        try await client.call(DaemonAPI.Method.changesList,
                              DaemonAPI.ChangesListRequest(agentID: agentID),
                              returning: ChangesList.self)
    }

    /// One file from `changes(for:)`: its edits, and with `whole` the file as it stands.
    func changeDetail(for agentID: UUID, path: String, whole: Bool = false) async throws -> ChangedFileDetail {
        try await client.call(DaemonAPI.Method.changesFile,
                              DaemonAPI.ChangesFileRequest(agentID: agentID, path: path, whole: whole),
                              returning: ChangedFileDetail.self)
    }

    /// What the draft folder's repository has. Asked once each time the folder
    /// changes or an agent starts, never polled; an answer for a folder since left is
    /// dropped.
    func loadDraftWorktrees() async {
        draftWorktreesGeneration += 1
        let generation = draftWorktreesGeneration
        guard let folder = draftCwd else { return }
        let answer = (try? await selectedHostClient.call(DaemonAPI.Method.worktreesList,
                                             DaemonAPI.WorktreesListRequest(folder: folder),
                                             returning: DaemonAPI.WorktreesListResponse.self))
            ?? .notARepository
        guard generation == draftWorktreesGeneration else { return }
        draftWorktrees = answer
    }

    /// Ask which branch an agent's project folder is on. Asked when its chat opens and
    /// when its turn ends, since someone may have checked out another branch meanwhile.
    func loadProjectFolderBranch(of agent: Agent) async {
        guard agent.worktree == nil else { return }
        let folder = agent.projectFolder
        let answer = try? await client(forAgent: agent.id).call(DaemonAPI.Method.worktreesList,
                                            DaemonAPI.WorktreesListRequest(folder: folder),
                                            returning: DaemonAPI.WorktreesListResponse.self)
        projectFolderBranches[folder] = answer?.projectFolderBranch
    }

    /// A session has to exist before its options do, so choosing a folder and a
    /// runtime starts one. It is kept and used by the start that follows.
    func loadDraftOptions() async {
        guard let runtimeID = draftRuntimeID, let cwd = draftOptionsFolder else { return }
        draftOptionsGeneration += 1
        let generation = draftOptionsGeneration
        isLoadingDraftOptions = true
        draftOptionsFailure = nil
        draftOptions = []
        draftCommands = []
        draftChosen = [:]
        letGo(draft: draftID)
        draftID = nil
        do {
            let response = try await selectedHostClient.call(DaemonAPI.Method.agentsOptions,
                                                 DaemonAPI.OptionsRequest(runtimeID: runtimeID, cwd: cwd,
                                                                          mcpServers: draftServers),
                                                 returning: DaemonAPI.OptionsResponse.self)
            // An answer for a folder or runtime the user has since moved away from is
            // not an answer to the question now being asked — and its runtime is one
            // nobody will talk to.
            guard generation == draftOptionsGeneration else { letGo(draft: response.draftID); return }
            draftID = response.draftID
            show(options: response.options, commands: response.commands, opening: true)
        } catch {
            guard generation == draftOptionsGeneration else { return }
            // Said in the row rather than only in the banner, because the row is where
            // the person is looking and where the retry lives.
            draftOptionsFailure = describe(error)
        }
        if generation == draftOptionsGeneration { isLoadingDraftOptions = false }
    }

    /// A draft this window has replaced is a runtime nobody will talk to. Not waited
    /// on, and a daemon too old to know the method has nothing to be told (029).
    private func letGo(draft: UUID?) {
        guard let draft else { return }
        Task {
            _ = try? await selectedHostClient.call(DaemonAPI.Method.agentsDiscardDraft,
                                       DaemonAPI.DiscardDraftRequest(draftID: draft))
        }
    }

    /// Draw the form.
    ///
    /// The first answer may be what the runtime offered last time, with what it
    /// actually offers arriving a few seconds later, so this runs more than once for
    /// one draft and keeps every choice already made that is still on offer.
    private func show(options: [ConfigOption], commands: [SlashCommand], opening: Bool) {
        draftOptions = PromptControlsState.drawable(agentOptions: nil, draftOptions: options)
        draftCommands = commands
        for option in draftOptions {
            // A choice already made stands, as long as it is still one of the choices.
            if let chosen = draftChosen[option.id],
               option.isBoolean || (option.options ?? []).contains(where: { $0.value == chosen }) {
                continue
            }
            draftChosen[option.id] = option.currentValue
        }
        // Options that have gone are not choices anybody can unmake.
        let offered = Set(draftOptions.map(\.id))
        draftChosen = draftChosen.filter { offered.contains($0.key) }
        // The mode you chose last time for this runtime, if it still offers it.
        // Seeding the draft is enough: `startDraft` sends these as `StartOptions`
        // and the daemon applies each one to the session before the first prompt.
        //
        // What the control opens on, so only on the first draw: a correction arriving
        // behind a form drawn from memory must not undo a mode chosen since.
        if opening, let runtimeID = draftRuntimeID,
           let mode = ModeMemory.modeOption(in: draftOptions) {
            draftChosen[mode.id] = ModeMemory.startingValue(
                remembered: rememberedMode(for: runtimeID), for: mode)
        }
    }

    /// The runtime starting behind a form drawn from memory has answered at last, and
    /// either offers something else or will not start at all.
    private func settleDraft(_ notification: DaemonAPI.DraftOptionsNotification) {
        guard notification.draftID == draftID else { return }
        if let failure = notification.failure {
            // Said in the row rather than the banner, the same as a form that failed to
            // load, because the row is where the person is looking and where the retry
            // lives. The controls go with it: they were what this runtime offered last
            // time, and there is no runtime this time.
            draftOptionsFailure = failure
            draftOptions = []
            draftCommands = []
            draftChosen = [:]
            draftID = nil
            return
        }
        show(options: notification.options, commands: notification.commands, opening: false)
    }

    /// Whether the agent was started, so the prompt bar can give back what it sent
    /// when it was not.
    @discardableResult
    func startDraft(prompt: String, attachments: [Attachment] = []) async -> Bool {
        guard let runtimeID = draftRuntimeID, let cwd = draftCwd else { return false }
        let request = DaemonAPI.StartRequest(runtimeID: runtimeID,
                                             cwd: cwd,
                                             prompt: prompt,
                                             attachments: attachments,
                                             startOptions: StartOptions(values: draftChosen),
                                             draftID: draftID,
                                             additionalDirectories: draftFolders,
                                             mcpServers: draftServers,
                                             worktree: draftWorktree)
        do {
            _ = try await selectedHostClient.call(DaemonAPI.Method.agentsStart, request, returning: UUID.self)
            draftID = nil
            // Back to the project folder, and the list fetched again: the start may
            // have made a worktree, and it has put an agent in one.
            draftWorktree = nil
            Task { await loadDraftWorktrees() }
            await refreshAgents()
            await refreshProjects()
            // Deliberately not selected. Saying what you want done is not the same as
            // asking to watch it: the agent appears in the project's list and you stay
            // where you were, free to say the next thing. Starting three pieces of work
            // in a row should not mean coming back twice.
            return true
        } catch {
            problem = describe(error)
            return false
        }
    }

    /// Sent now if the agent is free, and queued by the daemon if it is not. Either
    /// way this is the same call: whether there is room for it is not the window's
    /// question to answer.
    @discardableResult
    func send(_ text: String, attachments: [Attachment] = []) async -> Bool {
        guard let selection, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let host = work.agent(selection)?.host ?? .mac
        if host != .mac {
            guard let carried = await carry(attachments, to: host, for: selection) else { return false }
            let sendID = UUID()
            return await sendToServer(host) { client in
                try await client.call(DaemonAPI.Method.agentsPrompt,
                                      DaemonAPI.PromptRequest(agentID: selection, text: text,
                                                              attachments: carried, sendID: sendID))
            }
        }
        return await attempt {
            try await self.client(forAgent: selection).call(DaemonAPI.Method.agentsPrompt,
                                       DaemonAPI.PromptRequest(agentID: selection, text: text,
                                                               attachments: attachments))
        }
    }

    /// End a block by hand (039): the prompt Carry on sends, as the person, to an agent
    /// that need not be the one selected. A person's prompt is what clears a block, so
    /// this is an ordinary prompt and nothing else.
    func carryOn(_ id: UUID) async {
        await attempt {
            try await self.client(forAgent: id).call(DaemonAPI.Method.agentsPrompt,
                                       DaemonAPI.PromptRequest(agentID: id, text: Block.carryOnPrompt))
        }
    }

    /// Start an agent on this, in this project's folder.
    ///
    /// What the prompt at the top of a project does. There is no separate button for
    /// it because there is nothing else the prompt could mean: you are looking at a
    /// folder and saying what you want done in it.
    func startAgent(in folder: URL, prompt: String) async {
        let words = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty, let runtimeID = defaultRuntimeID else { return }
        await attempt {
            let id = try await self.selectedHostClient.call(
                DaemonAPI.Method.agentsStart,
                DaemonAPI.StartRequest(runtimeID: runtimeID, cwd: folder, prompt: words),
                returning: UUID.self)
            self.selection = id
        }
    }

    /// Which runtime a new agent gets when nobody has said. The rule is the kit's, so
    /// a phone offers the same one (029). It can be changed from the chat.
    var defaultRuntimeID: String? {
        work.defaultRuntimeID(available: availableRuntimes.map(\.runtime.id))
    }

    /// Take something back off the queue before it goes.
    func unqueue(_ prompt: QueuedPrompt, from agentID: UUID) async {
        await attempt {
            try await self.client(forAgent: agentID).call(DaemonAPI.Method.agentsUnqueue,
                                       DaemonAPI.UnqueueRequest(agentID: agentID, promptID: prompt.id))
        }
    }

    /// What the runtime behind the current agent, or the draft, says it will take.
    /// Nothing is refused on a guess: this is what the runtime advertised.
    var promptCapabilities: ACP.PromptCapabilities {
        let runtimeID = selectedAgent?.runtimeID ?? draftRuntimeID
        return runtimeID.flatMap { accounts[$0]?.promptCapabilities } ?? ACP.PromptCapabilities()
    }

    func refreshAccounts() async {
        guard let list = try? await client.call(DaemonAPI.Method.runtimesAccounts,
                                                Optional<Int>.none,
                                                returning: [RuntimeAccount].self) else { return }
        accounts = Dictionary(uniqueKeysWithValues: list.map { ($0.runtimeID, $0) })
    }

    func stop(_ id: UUID) async {
        await attempt { try await self.client(forAgent: id).call(DaemonAPI.Method.agentsStop, DaemonAPI.AgentRequest(agentID: id)) }
    }

    func archive(_ id: UUID) async {
        await attempt { try await self.client(forAgent: id).call(DaemonAPI.Method.agentsArchive, DaemonAPI.AgentRequest(agentID: id)) }
    }

    func unarchive(_ id: UUID) async {
        await attempt { try await self.client(forAgent: id).call(DaemonAPI.Method.agentsUnarchive, DaemonAPI.AgentRequest(agentID: id)) }
    }

    /// Park or unpark, whichever `Agent.parkAction` offers (040).
    func perform(_ action: ParkAction, on id: UUID) async {
        let method = action == .park ? DaemonAPI.Method.agentsPark : DaemonAPI.Method.agentsUnpark
        await attempt { try await self.client(forAgent: id).call(method, DaemonAPI.AgentRequest(agentID: id)) }
    }

    func answer(_ request: PermissionRequest, optionID: String) async {
        let host = work.agent(request.agentID)?.host ?? .mac
        if host != .mac {
            let sendID = UUID()
            _ = await sendToServer(host) { client in
                try await client.call(DaemonAPI.Method.permissionsAnswer,
                                      DaemonAPI.AnswerRequest(permissionID: request.id, optionID: optionID,
                                                              sendID: sendID))
            }
            return
        }
        await attempt {
            try await self.client(forAgent: request.agentID).call(DaemonAPI.Method.permissionsAnswer,
                                       DaemonAPI.AnswerRequest(permissionID: request.id, optionID: optionID))
        }
    }

    /// What an option control should read: the choice just made, else what is in
    /// force, else what the runtime says is current. The bookkeeping is the kit's, so a
    /// phone's control settles the same way (033).
    func chosenOption(_ optionID: String, for agent: Agent, advertised: ConfigOption) -> JSONValue? {
        work.chosenOption(optionID, for: agent, advertised: advertised)
    }

    /// Set an option on a live agent, and show the choice at once.
    ///
    /// Deliberately not `async`. The optimistic value has to be written on the same
    /// turn as the click, and the body of a `Task` does not start until the next one.
    func setOption(agentID: UUID, optionID: String, value: JSONValue) {
        let sequence = work.beginOption(agentID: agentID, optionID: optionID, value: value)
        Task {
            await attempt {
                try await self.client(forAgent: agentID).call(DaemonAPI.Method.agentsSetOption,
                                           DaemonAPI.SetOptionRequest(agentID: agentID, optionID: optionID, value: value))
            }
            work.settleOption(agentID: agentID, optionID: optionID, sequence: sequence)
        }
    }

    // MARK: The mode you keep choosing

    /// What was last chosen for this runtime, on this Mac or a phone. The daemon keeps
    /// it now — it writes on a start and on a conversation's mode changing — and this
    /// reads the copy `modes/changed` keeps current (029).
    func rememberedMode(for runtimeID: String) -> JSONValue? {
        work.rememberedMode(for: runtimeID)
    }

    /// The daemon's memory, after giving it whatever this window remembered from
    /// before the daemon kept one. The daemon only fills gaps, so this is safe on
    /// every connection and from every copy of the app; the keys are left in place.
    /// A daemon too old to know the methods leaves the form opening on the runtime's
    /// own current mode, which is what it did before anything was remembered.
    func refreshModes() async {
        let prefix = ModeMemory.defaultsKey(runtimeID: "")
        var held: DaemonAPI.RememberedModes = [:]
        for (key, stored) in UserDefaults.standard.dictionaryRepresentation() where key.hasPrefix(prefix) {
            guard let data = stored as? Data,
                  let mode = try? JSONDecoder().decode(JSONValue.self, from: data) else { continue }
            held[String(key.dropFirst(prefix.count))] = mode
        }
        let modes: DaemonAPI.RememberedModes?
        if held.isEmpty {
            modes = try? await client.call(DaemonAPI.Method.modesRemembered, Optional<Int>.none,
                                           returning: DaemonAPI.RememberedModes.self)
        } else {
            modes = try? await client.call(DaemonAPI.Method.modesImport,
                                           DaemonAPI.ModesImportRequest(modes: held),
                                           returning: DaemonAPI.RememberedModes.self)
        }
        if let modes { work.replaceRememberedModes(modes) }
    }

    // MARK: The user's shells

    /// The pane's end of one agent's shell, made once per agent per window.
    func shellClient(for agentID: UUID) -> ShellClient {
        if let existing = shellClients[agentID] { return existing }
        let fresh = ShellClient(agentID: agentID, client: client(forAgent: agentID),
                                describe: { [weak self] error in self?.describeForShell(error) ?? "\(error)" })
        shellClients[agentID] = fresh
        return fresh
    }

    /// What the person typed on a live page, sent to the daemon to put on disk (022).
    /// The daemon writes rather than the window so that it knows the person did. Nil
    /// on success; on failure, the sentence to show beside the passage, with the draft
    /// kept.
    func writeArtifact(agentID: UUID, path: String, text: String) async -> String? {
        do {
            try await client(forAgent: agentID).call(DaemonAPI.Method.artifactWrite,
                                  DaemonAPI.ArtifactWriteRequest(agentID: agentID, path: path, text: text))
            return nil
        } catch let error as JSONRPCError {
            return error.message
        } catch {
            return error.localizedDescription
        }
    }

    /// A shell that will not start is shown inside the pane, not in the window's alert:
    /// it is about that pane, and an alert over the whole window would be out of
    /// proportion to it.
    func describeForShell(_ error: any Error) -> String {
        describe(error)
    }

    /// Which transcript entry the conversation should bring into view.
    ///
    /// Set by the artifacts pane so that getting from a thing back to the message it
    /// came from is one tap (FR-042). Cleared once the transcript has scrolled to it.
    var focusedEntry: UUID?

    func focusEntry(_ id: UUID) {
        focusedEntry = id
    }

    func clearFocus() {
        focusedEntry = nil
    }

    /// What this agent last asked the user to look at, taken rather than read: a file
    /// that has been put in front of somebody is not still waiting to be.
    func takeFileToShow(for agentID: UUID) -> ShownFile? {
        work.takeFileToShow(for: agentID)
    }

    // MARK: Runtimes

    func signIn(runtimeID: String, methodID: String) async -> String? {
        do {
            let account = try await client.call(DaemonAPI.Method.runtimeAuthenticate,
                                                DaemonAPI.AuthenticateRequest(runtimeID: runtimeID,
                                                                              methodID: methodID),
                                                returning: RuntimeAccount.self)
            accounts[runtimeID] = account
            await refreshRuntimes()
            return nil
        } catch let error as JSONRPCError {
            // A method that needs a terminal comes back as the command to run, which is
            // the runtime's own advice rather than ours.
            if let command = error.data?["command"]?.stringValue { return command }
            problem = describe(error)
            return nil
        } catch {
            problem = describe(error)
            return nil
        }
    }

    func signOut(runtimeID: String) async {
        await attempt {
            _ = try await self.client.call(DaemonAPI.Method.runtimeLogOut,
                                           DaemonAPI.RuntimeRequest(runtimeID: runtimeID),
                                           returning: [UUID].self)
        }
        await refreshAccounts()
        await refreshAgents()
    }

    func setProvider(runtimeID: String, providerID: String) async {
        await attempt {
            _ = try await self.client.call(DaemonAPI.Method.runtimeSetProvider,
                                           DaemonAPI.SetProviderRequest(runtimeID: runtimeID,
                                                                        providerID: providerID),
                                           returning: RuntimeAccount.self)
        }
        await refreshAccounts()
    }

    /// Which agents a sign-out would stop, so the user is told before it happens.
    func agentsHolding(runtimeID: String) -> [Agent] {
        agents.filter { $0.runtimeID == runtimeID && $0.state.holdsRuntime }
    }

    // MARK: Sessions the app did not start

    func runtimeSessions(runtimeID: String, cwd: URL) async -> [RuntimeSession] {
        do {
            return try await selectedHostClient.call(DaemonAPI.Method.sessionsList,
                                         DaemonAPI.SessionsListRequest(runtimeID: runtimeID, cwd: cwd),
                                         returning: [RuntimeSession].self)
        } catch {
            problem = describe(error)
            return []
        }
    }

    func adopt(runtimeID: String, session: RuntimeSession) async {
        do {
            let id = try await selectedHostClient.call(DaemonAPI.Method.sessionsAdopt,
                                           DaemonAPI.AdoptRequest(runtimeID: runtimeID,
                                                                  sessionID: session.sessionID,
                                                                  cwd: session.cwd),
                                           returning: UUID.self)
            await refreshAgents()
            selection = id
        } catch {
            problem = describe(error)
        }
    }

    func deleteRuntimeSession(runtimeID: String, sessionID: String) async {
        await attempt {
            try await self.selectedHostClient.call(DaemonAPI.Method.sessionsDelete,
                                       DaemonAPI.DeleteSessionRequest(runtimeID: runtimeID,
                                                                      sessionID: sessionID,
                                                                      confirmed: true))
        }
    }

    func fork(_ id: UUID) async {
        do {
            let branch = try await client(forAgent: id).call(DaemonAPI.Method.agentsFork,
                                               DaemonAPI.AgentRequest(agentID: id),
                                               returning: UUID.self)
            await refreshAgents()
            selection = branch
        } catch {
            problem = describe(error)
        }
    }

    // MARK: Forms

    func answerElicitation(_ request: ElicitationRequest,
                           action: DaemonAPI.AnswerElicitationRequest.Action,
                           content: [String: JSONValue] = [:]) async {
        await attempt {
            try await self.client(forAgent: request.agentID).call(DaemonAPI.Method.elicitationsAnswer,
                                       DaemonAPI.AnswerElicitationRequest(requestID: request.id,
                                                                          action: action,
                                                                          content: content))
        }
        await refreshElicitations()
    }

    func dismissProblem() { problem = nil }

    /// Something the window worked out for itself, said the same way as anything the
    /// daemon says.
    func show(problem: String) { self.problem = problem }

    /// Whether the work went through, for the callers that must undo something when
    /// it did not.
    @discardableResult
    /// Files attached from this Mac, copied to the server first (037, FR-015). A path
    /// on the Mac means nothing to an agent on a server, so each file that exists here
    /// is written into the agent's folder there, and the attachment points at that
    /// copy. Pictures already travel as bytes, and a file named from the server's own
    /// files pane is already a path there. Nil, with the reason said, when a file
    /// cannot go: the prompt then stays in the field.
    private func carry(_ attachments: [Attachment], to host: HostID, for agentID: UUID) async -> [Attachment]? {
        var carried: [Attachment] = []
        for attachment in attachments {
            guard case .resourceLink(let uri, let name, let mimeType, _, _) = attachment.block,
                  let url = URL(string: uri), url.isFileURL,
                  let agent = work.agent(agentID),
                  !url.path.hasPrefix(agent.cwd.path),
                  FileManager.default.fileExists(atPath: url.path) else {
                carried.append(attachment)
                continue
            }
            guard let data = try? Data(contentsOf: url), data.count <= DaemonAPI.attachmentLimit else {
                problem = "\(name) is too big to send to \(hosts.label(host))."
                return nil
            }
            do {
                let written = try await client(for: host).call(
                    DaemonAPI.Method.filesWrite, DaemonAPI.FilesWriteRequest(agentID: agentID, name: name, data: data),
                    returning: DaemonAPI.FilesWriteResponse.self)
                carried.append(Attachment(block: .resourceLink(uri: URL(filePath: written.path).absoluteString,
                                                               name: name, mimeType: mimeType, size: data.count),
                                          displayName: attachment.displayName, byteCount: data.count))
            } catch {
                problem = "\(name) could not be sent to \(hosts.label(host))."
                return nil
            }
        }
        return carried
    }

    /// A send to a server, delivered once or reported as not sent (037, FR-020).
    ///
    /// The caller makes the `sendID` once, so every retry here is the same send: a
    /// daemon that acted on the first try and lost its reply with the connection answers
    /// the retry as it did, and acts once. A transport error is retried as the server
    /// comes back, for up to 30 seconds; a refusal from the daemon is its answer and is
    /// not retried.
    private func sendToServer(_ host: HostID,
                              _ work: @escaping (DaemonClient) async throws -> Void) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while true {
            do {
                try await work(client(for: host))
                return true
            } catch let refused as JSONRPCError {
                problem = describe(refused)
                return false
            } catch {
                guard ContinuousClock.now < deadline else {
                    problem = "Not sent — \(hosts.label(host)) went offline."
                    return false
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func attempt(_ work: () async throws -> Void) async -> Bool {
        do {
            try await work()
            return true
        } catch {
            // One retry through a fresh connection: the daemon having gone idle is not
            // something the user should have to know about.
            if !isConnected {
                await connect()
                if isConnected, (try? await work()) != nil { return true }
            }
            problem = describe(error)
            return false
        }
    }

    /// What a person can read. The daemon's errors are already written for someone
    /// looking at a screen, so they are shown as they are.
    private func describe(_ error: any Error) -> String {
        if let error = error as? JSONRPCError {
            // A runtime that needs signing in says so, and says how. The command is
            // the runtime's own, which is better advice than any we could invent.
            if error.code == DaemonAPI.Failure.needsSignIn,
               let methods = try? error.data?["authMethods"]?.decode([ACP.AuthMethod].self),
               let command = methods.compactMap(\.terminalCommand).first {
                return "\(error.message). Run: \(command)"
            }
            return error.message
        }
        if let error = error as? DaemonClient.ConnectError {
            switch error {
            case .noHelper(let lookedIn):
                return "The helper that runs the agents is missing. Looked in \(lookedIn.joined(separator: ", "))."
            case .couldNotStartHelper(let reason):
                return "The helper would not start: \(reason)"
            case .couldNotConnect:
                return "Could not reach the helper that runs the agents."
            case .socketPathTooLong(let path):
                // Only ever seen by somebody who passed `--root`, and the fix is in
                // their hands: a shorter path.
                return "That folder is too deep to run a daemon in: \(path) is past the 104 bytes a socket may be named with."
            }
        }
        return String(describing: error)
    }
}
