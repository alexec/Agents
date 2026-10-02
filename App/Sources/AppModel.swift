import AgentsKitCore
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
    /// Its wait, and the control plane watch's, both cut short by a wake or a network
    /// change (#82).
    @ObservationIgnored private let backoff = Backoff()
    @ObservationIgnored private let controlBackoff = Backoff(first: .seconds(2), longest: .seconds(2))
    @ObservationIgnored private let wakeAndNetwork = WakeAndNetwork()
    @ObservationIgnored private var checkingAfterWake = false
    private(set) var problem: String?
    /// A runtime of this Mac's that refused for want of a sign-in: the window answers
    /// with its sign-in sheet rather than an error nobody can act on.
    var signInRuntimeID: String?
    /// Sheets put away without signing in, so that the agents a restart picks back up
    /// do not each raise it again. Forgotten when the runtime says it is signed in.
    private var signInsPutAway: Set<String> = []
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
    var transcriptHasMore: Bool { work.hasMoreOfTheConversation }
    var filesToShow: [UUID: ShownFile] { work.filesToShow }
    /// What the reader will allow and what today has cost. Nil until the daemon has
    /// said, which is how every surface knows to show nothing rather than a zero.
    var costState: DaemonAPI.CostState? { work.costState }
    /// Every resource an agent can lease and who holds it (036).
    var leases: DaemonAPI.LeaseSnapshot? { work.leases }
    var costLimits: CostLimits { work.costState?.limits ?? CostLimits() }
    /// How long archived agents are kept (051). Nil until the daemon has said.
    var retentionState: DaemonAPI.RetentionState? { work.retentionState }
    var runtimeAllowances: RuntimeAllowances? { work.runtimeAllowances }
    /// Cursor and Grok permission mode (061). Defaults until the daemon answers.
    private(set) var clientPermissions = ClientPermissionSettings()
    /// Each runtime's command sandbox default (064).
    private(set) var sandboxSettings = SandboxSettings()

    /// Why the Mac is, or is not, being kept awake (024). Nil until the daemon has
    /// said — and for ever against one too old to know the method, which is drawn the
    /// same way as nothing to say.
    var wakeState: DaemonAPI.WakeState? { work.wakeState }
    /// The switch and the hours (Settings ▸ General ▸ Sleep). Nil until the daemon has
    /// said, including a daemon too old to know the method.
    private(set) var wakeSettings: WakeSettings?

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
            showsRuntimes = false
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
            showsRuntimes = false
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
            showsRuntimes = false
            selection = nil
            openWorkflow = nil
        }
    }

    /// Whether the window is showing Runtimes: each runtime and where its allowance
    /// stands (065). A page like Events, and not persisted for the same reason.
    ///
    /// It used to be in Settings, which is where a control belongs. What it says is
    /// the state of the machine, and it changes without anybody touching a setting.
    var showsRuntimes = false {
        didSet {
            guard showsRuntimes, showsRuntimes != oldValue else { return }
            showsSpending = false
            showsResources = false
            showsEvents = false
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

    /// Runtimes, from the prompt bar's warning about starting on one that is out.
    func showRuntimes() {
        showsRuntimes = true
    }

    /// An agent's chat, from the Resources page or a capsule naming its holder: its
    /// own project first, as a banner does, so the sidebar and the page agree.
    func openAgent(_ agentID: UUID) {
        showsSpending = false
        showsResources = false
        showsEvents = false
        showsRuntimes = false
        if let agent = agents.first(where: { $0.id == agentID }) {
            select(ProjectKey(host: agent.host, folder: agent.projectFolder))
        } else if let gone = work.tombstones[agentID] {
            select(ProjectKey(host: gone.host, folder: Project.standardize(gone.project)))
        } else {
            // Perhaps retired (051): ask, and open its project once the answer is in.
            Task { [weak self] in
                guard let self, let gone = await self.tombstone(for: agentID),
                      self.selection == agentID else { return }
                self.select(ProjectKey(host: gone.host, folder: Project.standardize(gone.project)))
                self.selection = agentID
            }
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
            showsEvents ? .events : showsResources ? .resources : showsRuntimes ? .runtimes
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
            case .runtimes:
                showRuntimes()
            case .project(let key):
                showsSpending = false
                showsResources = false
                showsEvents = false
                showsRuntimes = false
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
        let timing = Perf.begin("project-switch")
        defer { Perf.endWhenDrawn(timing) }
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
            // A session picked is the session shown, not a workflow left open over it.
            if selection != nil { openWorkflow = nil }
            chatOpening = selection.map { (agent: $0, timing: Perf.begin("chat-open")) }
            Task { await loadTranscript() }
        }
    }

    /// The chat being opened and since when, until its transcript is on screen (073).
    @ObservationIgnored private var chatOpening: (agent: UUID, timing: Perf.Interval)?

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
    /// Each open agent's project's worktrees, for the Worktree choice on its page (053).
    /// Asked when the page opens and after each move, never polled.
    private(set) var agentWorktrees: [URL: DaemonAPI.WorktreesListResponse] = [:]
    /// Why the last move asked for an agent was refused, shown under its choice until
    /// the next one. A move that fails later, when it is made, says so in the chat.
    private(set) var moveProblems: [UUID: String] = [:]
    private(set) var draftOptions: [ConfigOption] = []
    private(set) var draftCommands: [SlashCommand] = []
    var draftChosen: [String: JSONValue] = [:]
    /// The next agent's own sandbox choice (064). Nil follows its runtime's default.
    var draftSandbox: SandboxChoice? { didSet { draftSandboxRefusal = nil } }
    /// Why the last start of a new agent did not happen, when its sandbox is why (064):
    /// shown over the prompt with **Start without sandbox**.
    var draftSandboxRefusal: DaemonAPI.SandboxWillNotStart?
    /// A new agent is on its way to its host (#87): a worktree to make and a runtime to
    /// start can take seconds, and the bar shows it rather than nothing. One at a time,
    /// so a second Return is not a second agent.
    private(set) var isStarting = false
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

    /// This Mac's host: through the control plane when the window has one (058). Set
    /// once more when first run chooses one.
    private var client = ControlConfig.macClient()
    /// The one connection to the control plane every host's client is carried on (058).
    private var controlLink: ControlLink? = ControlConfig.endpoint.flatMap(ControlConfig.link)
    /// Every host the control plane has besides this Mac's, each with a client of its own
    /// over `controlLink` (058, US3): what `HostSet` is for servers reached by ssh from
    /// here, with the ssh on the control plane's side.
    @ObservationIgnored private var controlHosts: [HostID: DaemonClient] = [:]
    @ObservationIgnored private var controlWatch: Task<Void, Never>?
    /// Every host the control plane last listed, this Mac's included. Nil when the
    /// window is not its client; empty until the first list arrives (058, R11).
    private(set) var controlPlaneHosts: [DaemonAPI.ControlHost]? = ControlConfig.endpoint == nil ? nil : []
    /// The control plane's list has arrived at least once, so an empty one means none.
    private var controlPlaneListed = false

    /// Whether this window has a host on this Mac (058, T093a). Always without a control
    /// plane, and until its first list arrives; after that, only if it lists `.mac`. A
    /// control plane of servers alone, the review demo's, has none, and nothing in the
    /// window waits on one or sends to one.
    var hasMacHost: Bool {
        guard let listed = controlPlaneHosts, controlPlaneListed else { return true }
        return listed.contains { $0.id == .mac }
    }

    /// Where an agent lives: the host it was listed from, or, for one not yet listed
    /// (just started, say), the selected project's host when there is no Mac host.
    private func host(ofAgent id: UUID?) -> HostID {
        work.agent(id)?.host ?? (hasMacHost ? .mac : selectedProjectHost)
    }
    /// The name `control/status` last gave, so the away strip can still say it.
    private(set) var controlPlaneName: String?
    /// The control plane's own client has answered. Distinct from `isConnected`, which
    /// is this Mac's host: a host can be offline while the control plane is up.
    private(set) var controlPlaneReachable = false
    /// A try to reach the control plane failed. Stays quiet during the first try.
    private(set) var controlPlaneMissed = false
    /// No control plane and nothing of the old way: the window asks how to work, and
    /// starts nothing until it is told (058, FR-017).
    private(set) var needsFirstRun = ControlConfig.needsFirstRun
    /// The servers (037). This Mac is `client`, as it always was.
    let hosts = HostSet(locations: .default)
    /// What this window may lend to servers (043). Never to this Mac's own daemon (D5).
    let credentials = ServerCredentials(locations: .default)
    /// A server asked for a credential there is none of; the window asks the person (043).
    var tokenAsk: TokenAsk?
    /// A server asked for a sign-in this Mac relays; the window asks the person (T091).
    var signInLendAsk: SignInLendAsk?
    /// What a server with no connection answers through: nothing, at once.
    private static let unreachable = DaemonClient(link: UnreachableLink())

    /// The client for work on a host. A server that is not connected answers with an
    /// error straight away, never with the Mac's daemon.
    func client(for host: HostID) -> DaemonClient {
        if host == .mac { return client }
        if let through = controlHosts[host] { return through }
        // A control plane's host is never reached by this window's own ssh (T024).
        if controlLink != nil { return Self.unreachable }
        return hosts.client(for: host) ?? Self.unreachable
    }

    /// Whether `host` is one of the control plane's, reached through it.
    func reachesThroughControl(_ host: HostID) -> Bool { controlHosts[host] != nil }

    /// A connection to the control plane's own methods, for one call (T091); nil with none.
    func controlPlaneClient() -> DaemonClient? {
        controlLink.map { DaemonClient(link: $0.controlLink) }
    }

    /// The host on this Mac, when there is one. `.mac` until the window has a control plane.
    var thisMacHostID: HostID? {
        ThisMacHost.resolve(controlPlaneHosts)
    }

    /// Whether this window may read `host`'s folders off this disk (058, R11).
    func isOnThisMac(_ host: HostID) -> Bool { thisMacHostID == host }

    /// The window cannot ask this host right now: the control plane is away, or the host is.
    func hostUnreachable(_ host: HostID) -> Bool {
        controlPlaneAway || hosts.isOffline(host)
    }

    /// Lend to a host the control plane reaches (058, FR-020). Nil when this window
    /// still reaches that host over its own ssh, so the caller uses that path.
    func lendThroughControl(_ id: HostID, runtime: String, secret: Secret, offered: Bool) async -> Bool? {
        guard controlHosts[id] != nil else { return nil }
        if !offered {
            _ = try? await client(for: id).call(DaemonAPI.Method.credentialsOffer, credentialOffer(id))
        }
        return (try? await client(for: id).call(
            DaemonAPI.Method.credentialsLend,
            DaemonAPI.CredentialsLend(runtime: runtime, secret: secret))) != nil
    }

    /// The control plane was reached and then was not, or the first try failed (frame H).
    var controlPlaneAway: Bool { controlLink != nil && controlPlaneMissed && !controlPlaneReachable }

    /// Frame H's sentence, naming where the window expected the control plane.
    var controlPlaneAwayLine: String? {
        guard controlPlaneAway else { return nil }
        switch ControlConfig.endpoint {
        case .remote(let membership):
            return HostProblem.controlPlaneUnreachable(name: membership.name,
                                                       address: membership.url ?? membership.addresses.first ?? "no address")
        case nil:
            return nil
        }
    }

    /// This Mac's host strip's Try Again: the same as the control plane's (#83).
    func tryMacHostAgain() { tryControlPlaneAgain() }

    /// The away strip's Try Again: one attempt now, then the usual backoff.
    func tryControlPlaneAgain() {
        reconnecting?.cancel()
        reconnecting = nil
        backoff.settle()
        controlWatch?.cancel()
        controlWatch = nil
        Task {
            await connect()
            if !isConnected { await reconnect() }
        }
    }

    /// An agent on `host` whose folders include `folder`, so `files/read` can be scoped.
    func anAgent(in folder: URL, on host: HostID) -> UUID? {
        let wanted = Project.standardize(folder)
        return agents.first { $0.host == host && Project.standardize($0.projectFolder) == wanted }?.id
    }

    /// The text of a file, from its host: `files/read`, or `files/readText` with no agent (R11).
    func textFile(at url: URL, on host: HostID, agentID: UUID?) async -> String? {
        if agentID == nil { return await readText(url, on: host) }
        guard let agentID else { return nil }
        guard let reading = try? await serverFiles(host).read(agentID: agentID,
                                                              path: url.path(percentEncoded: false)) else { return nil }
        if case .text(let text, _, _, _) = reading { return text }
        return nil
    }

    /// Whether a path is there: `files/browse` on its host, and a host that cannot be
    /// asked is left as still there.
    func pathIsThere(_ url: URL, on host: HostID) async -> Bool {
        if controlPlaneAway || hosts.isOffline(host) { return true }
        do {
            _ = try await client(for: host).call(DaemonAPI.Method.filesBrowse,
                                                  DaemonAPI.FilesBrowseRequest(path: url.path(percentEncoded: false)),
                                                  returning: DirectoryListing.self)
            return true
        } catch let error as JSONRPCError where error.code == DaemonAPI.Failure.fileGone {
            return false
        } catch let error as JSONRPCError where error.message == "That is a file." {
            return true
        } catch {
            return true
        }
    }

    private func client(forAgent id: UUID?) -> DaemonClient {
        client(for: host(ofAgent: id))
    }

    /// Where a new agent, a draft, a worktree or a session list for the selected
    /// project goes: that project's host.
    private var selectedHostClient: DaemonClient { client(for: selectedProjectHost) }
    private var listening: Task<Void, Never>?

    /// The panes listening for shell output, one per shell in this window: an agent
    /// has one per terminal tab (055). Shell notifications are broadcast to every
    /// window, so each one keeps only the shells it is actually showing and ignores
    /// the rest.
    @ObservationIgnored private var shellClients: [ShellKey: ShellClient] = [:]

    struct ShellKey: Hashable {
        var agentID: UUID
        var shell: Int
    }

    /// What each agent had already spent when this window first laid eyes on it.
    ///
    /// An agent's `costToDate` is its whole life, and agents outlive the window, so
    /// adding them up would be an all-time figure wearing the word "session". Taking
    /// away what was spent before we were watching leaves what this sitting cost.
    var selectedAgent: Agent? { work.agent(selection) }
    /// What is left of an agent that has been retired, when this window has asked (051).
    func retiredTombstone(_ id: UUID) -> Tombstone? { work.tombstones[id] }
    /// "Started by …" for a retired agent, named as a live one's would be.
    func retiredStarterLabel(_ tombstone: Tombstone) -> String? {
        guard let starter = tombstone.startedByAgent else { return nil }
        let title = work.agent(starter)?.title ?? work.tombstones[starter]?.title
        return LeaseWords.agentName(title).replacingOccurrences(of: "another agent", with: "Another agent")
    }

    var permissionsForSelection: [PermissionRequest] { work.permissions(for: selection) }

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

    /// How many sessions across every project want a look: Needs you, Blocked, and
    /// unread finishes (#70). Drives the Dock badge.
    var needsPersonCount: Int {
        liveProjects.reduce(0) { $0 + work.attentionCount(in: $1.key) }
    }

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

    func refreshWorkflows() async {
        do {
            work.replaceWorkflows(try await client.call(DaemonAPI.Method.workflowsList,
                                                        DaemonAPI.WorkflowsListRequest(),
                                                        returning: [WorkflowSummary].self))
        } catch {
            // Same as the projects above: the next notification brings it back.
        }
    }

    /// Run one now. The daemon still applies the in-flight, ceiling and archive rules,
    /// and says so on the summary, which is why nothing here second-guesses it first.
    func runWorkflow(_ summary: WorkflowSummary) async {
        // Its refusal is said, not swallowed: a Run now that does nothing looked broken (073).
        await attempt {
            try await self.client.call(DaemonAPI.Method.workflowsRun,
                                       DaemonAPI.WorkflowRequest(folder: summary.folder,
                                                                 workflowID: summary.workflowID))
        }
    }

    /// Put one away, or bring it back. The person's answer to a workflow an agent
    /// wrote, which is what makes writing one not need asking first.
    func setWorkflowArchived(_ summary: WorkflowSummary, _ archived: Bool) async {
        await attempt {
            try await self.client.call(DaemonAPI.Method.workflowsArchive,
                                       DaemonAPI.WorkflowArchiveRequest(folder: summary.folder,
                                                                        workflowID: summary.workflowID,
                                                                        archived: archived))
        }
    }

    /// Turn one on or off, keeping its place on the list (#100).
    func setWorkflowEnabled(_ summary: WorkflowSummary, _ enabled: Bool) async {
        _ = try? await client.call(DaemonAPI.Method.workflowsEnable,
                                   DaemonAPI.WorkflowEnableRequest(folder: summary.folder,
                                                                   workflowID: summary.workflowID,
                                                                   enabled: enabled))
    }

    /// A project's plugins, asked for when its page opens; kept current after that by
    /// `plugins/changed`.
    func plugins(in folder: URL?) -> [ProjectPlugin] { work.plugins(in: folder) }

    func refreshPlugins(in folder: URL) async {
        guard let list: DaemonAPI.PluginsList = try? await client.call(
            DaemonAPI.Method.pluginsList, DaemonAPI.PluginsListRequest(folder: folder),
            returning: DaemonAPI.PluginsList.self) else { return }
        work.replacePlugins(list)
    }

    /// Approve a plugin's folder as the row showed it. Said when it fails: most likely the
    /// folder changed after the person looked.
    func approvePlugin(_ plugin: ProjectPlugin) async {
        guard let waiting = plugin.awaitingApproval else { return }
        do {
            let list: DaemonAPI.PluginsList = try await client.call(
                DaemonAPI.Method.pluginsApprove,
                DaemonAPI.PluginApproveRequest(plugin: plugin.folder, digest: waiting.digest),
                returning: DaemonAPI.PluginsList.self)
            work.replacePlugins(list)
        } catch {
            problem = describe(error)
            await refreshPlugins(in: plugin.project)
        }
    }

    /// Approve a workflow's file as the row showed it. Said when it fails: the likely
    /// reason is that the file changed after the person looked, and they should look again.
    func approveWorkflow(_ summary: WorkflowSummary) async {
        guard let waiting = summary.awaitingApproval else { return }
        do {
            let updated: WorkflowSummary = try await client.call(
                DaemonAPI.Method.workflowsApprove,
                DaemonAPI.WorkflowApproveRequest(folder: summary.folder, workflowID: summary.workflowID,
                                                 digest: waiting.digest),
                returning: WorkflowSummary.self)
            work.upsert(updated)
        } catch {
            problem = describe(error)
            await refreshWorkflows()
        }
    }

    /// Change what a workflow is allowed to do. The daemon writes the file.
    ///
    /// The one call in this section that does **not** swallow its error, and the
    /// difference matters: every other one here is asking for something the daemon
    /// will do or will not, and the next notification puts the window right either way.
    /// This one is asking for somebody's own file to be changed, and a refusal — front
    /// matter it will not touch, a file it cannot write — has to reach them, or the
    /// app has silently kept a change it never made (FR-025).
    /// `cooldown` is the file's `cooldown:` to write (#103), empty to remove it; left
    /// `nil`, the file's is left as it is.
    func setWorkflowSettings(_ summary: WorkflowSummary, _ settings: WorkflowSettings,
                             cooldown: String? = nil) async {
        do {
            let updated: WorkflowSummary = try await client.call(
                DaemonAPI.Method.workflowsSettings,
                DaemonAPI.WorkflowSettingsRequest(folder: summary.folder,
                                                  workflowID: summary.workflowID,
                                                  settings: settings, cooldown: cooldown),
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

    /// The switch and the hours. A daemon too old to know the method leaves this nil,
    /// and Settings ▸ General draws Appearance alone.
    func refreshWakeSettings() async {
        wakeSettings = try? await client.call(DaemonAPI.Method.wakeSettings,
                                              Optional<String>.none,
                                              returning: WakeSettings.self)
    }

    /// The person changed Sleep. The daemon clamps the hours and answers with what it kept.
    func setWakeSettings(_ settings: WakeSettings) async {
        await attempt {
            self.wakeSettings = try await self.client.call(DaemonAPI.Method.wakeSet, settings,
                                                           returning: WakeSettings.self)
        }
    }

    /// Every resource and who holds it (036). A daemon too old to know the method
    /// leaves `leases` nil, and nothing about leases is drawn.
    func refreshLeases() async {
        guard let snapshot = try? await client.call(DaemonAPI.Method.leasesSnapshot,
                                                    Optional<String>.none,
                                                    returning: DaemonAPI.LeaseSnapshot.self) else { return }
        work.replaceLeases(snapshot)
    }

    /// The newest page of events and who is waiting (042), narrowed by `filter`, or as
    /// the page last narrowed it. A daemon too old to know the method leaves the list
    /// empty, and the Events page says there is nothing yet.
    func refreshEvents(_ filter: EventFilter? = nil) async {
        let filter = filter ?? work.eventsFilter
        work.eventsFilter = filter
        guard let page = try? await client.call(DaemonAPI.Method.eventsList, DaemonAPI.EventsListRequest(filter),
                                                returning: DaemonAPI.EventsPage.self) else { return }
        work.takeEvents(page, for: filter)
    }

    /// The page before the oldest event the window has, for scrolling back.
    func loadOlderEvents() async {
        let filter = work.eventsFilter
        guard work.moreEvents, let oldest = work.recentEvents.last?.position else { return }
        guard let page = try? await client.call(DaemonAPI.Method.eventsList,
                                                DaemonAPI.EventsListRequest(before: oldest, filter),
                                                returning: DaemonAPI.EventsPage.self) else { return }
        work.takeEvents(page, for: filter, appending: true)
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
    // MARK: Retiring archived agents (051)

    /// A Settings pane to open on, asked for by a link elsewhere (052): read and cleared
    /// by the Settings window.
    var settingsPaneAsked: SettingsPane?

    /// Every runtime's state on this Mac (065, US4). Asking also asks Grok what is left.
    func refreshRuntimeAllowances() async {
        guard let allowances = try? await client.call(DaemonAPI.Method.runtimesAllowances, Optional<String>.none,
                                                      returning: RuntimeAllowances.self) else { return }
        work.replaceRuntimeAllowances(allowances)
    }

    /// The person says a runtime is back, by its credential (065).
    func markRuntimeAvailable(_ credentialKey: String) async {
        guard let allowances = try? await client.call(DaemonAPI.Method.runtimesMarkAvailable,
                                                      DaemonAPI.MarkRuntimeAvailable(credentialKey: credentialKey),
                                                      returning: RuntimeAllowances.self) else { return }
        work.replaceRuntimeAllowances(allowances)
    }

    /// The Mac's word on the plans it relays, to every connected server (052, R6).
    private func sendSharedAllowances(_ allowances: RuntimeAllowances) async {
        let shared = allowances.shared ?? []
        guard !shared.isEmpty else { return }
        for host in hosts.hosts.all where !hosts.isOffline(host.id) {
            _ = try? await client(for: host.id).call(DaemonAPI.Method.poolApplyAllowances,
                                                     DaemonAPI.ApplyAllowances(states: shared), returning: Bool.self)
        }
    }

    func refreshRetentionState() async {
        guard let state = try? await client.call(DaemonAPI.Method.retentionState,
                                                 Optional<String>.none,
                                                 returning: DaemonAPI.RetentionState.self) else { return }
        work.replaceRetentionState(state)
    }

    /// The person changing how long archived agents are kept. Unconfirmed, a change that
    /// would retire agents at once comes back unapplied with what it would retire, for
    /// the confirmation; confirmed, it is applied here and then on every server, which
    /// keeps to the Mac's settings the way it keeps to its limits (037 R7).
    func setRetention(_ settings: RetentionSettings, confirmed: Bool) async -> DaemonAPI.RetentionSetResult? {
        guard let result = try? await client.call(
            DaemonAPI.Method.retentionSet,
            DaemonAPI.RetentionSetRequest(settings: settings, confirmed: confirmed),
            returning: DaemonAPI.RetentionSetResult.self) else { return nil }
        if let state = result.state { work.replaceRetentionState(state) }
        if result.applied { await pushRetentionToServers(settings) }
        return result
    }

    func pushRetentionToServers(_ settings: RetentionSettings) async {
        for host in hosts.hosts.all where !hosts.isOffline(host.id) {
            _ = try? await client(for: host.id).call(
                DaemonAPI.Method.retentionSet,
                DaemonAPI.RetentionSetRequest(settings: settings, confirmed: true),
                returning: DaemonAPI.RetentionSetResult.self)
        }
    }

    func refreshClientPermissions() async {
        guard let settings = try? await client.call(DaemonAPI.Method.clientPermissionsState,
                                                    Optional<String>.none,
                                                    returning: ClientPermissionSettings.self) else { return }
        clientPermissions = settings
    }

    /// Save Cursor/Grok permission mode and copy it to every connected server (061).
    func setClientPermissions(_ settings: ClientPermissionSettings) async {
        var saved: ClientPermissionSettings?
        await attempt {
            saved = try await self.client.call(DaemonAPI.Method.clientPermissionsSet, settings,
                                               returning: ClientPermissionSettings.self)
        }
        guard let saved else { return }
        clientPermissions = saved
        await pushClientPermissionsToServers(saved)
    }

    func pushClientPermissionsToServers(_ settings: ClientPermissionSettings) async {
        for host in hosts.hosts.all where !hosts.isOffline(host.id) {
            _ = try? await client(for: host.id).call(DaemonAPI.Method.clientPermissionsSet, settings,
                                                     returning: ClientPermissionSettings.self)
        }
    }

    /// One agent's own sandbox choice, nil to follow its runtime's default (064).
    /// The agent comes back by `agent/changed`, as for any other change to it.
    func setAgentSandbox(_ agentID: UUID, _ choice: SandboxChoice?) async {
        _ = await attempt {
            try await self.client(forAgent: agentID).call(DaemonAPI.Method.agentsSetSandbox,
                                                           DaemonAPI.SetSandboxRequest(agentID: agentID, choice: choice))
        }
    }

    /// The sandbox card's answer (064, FR-007a): only this agent is changed.
    func answerSandbox(_ agentID: UUID, carryOn: Bool) async {
        _ = await attempt {
            try await self.client(forAgent: agentID).call(DaemonAPI.Method.agentsAnswerSandbox,
                                                           DaemonAPI.AnswerSandboxRequest(agentID: agentID, carryOn: carryOn))
        }
    }

    func refreshSandboxSettings() async {
        guard let settings = try? await client.call(DaemonAPI.Method.sandboxState, Optional<String>.none,
                                                    returning: SandboxSettings.self) else { return }
        sandboxSettings = settings
    }

    /// Save a runtime's sandbox default and copy it to every connected server (064): each
    /// server applies it to the runtimes installed there, as the Mac does.
    func setSandboxDefault(_ choice: SandboxChoice, for runtimeID: String) async {
        let before = sandboxSettings
        let wanted = sandboxSettings.setting(choice, for: runtimeID)
        sandboxSettings = wanted
        var saved: SandboxSettings?
        await attempt {
            saved = try await self.client.call(DaemonAPI.Method.sandboxSet, wanted,
                                               returning: SandboxSettings.self)
        }
        // Not kept, so not shown: the picker goes back to what the host still has (073).
        guard let saved else { sandboxSettings = before; return }
        sandboxSettings = saved
        for host in hosts.hosts.all where !hosts.isOffline(host.id) {
            _ = try? await client(for: host.id).call(DaemonAPI.Method.sandboxSet, saved,
                                                     returning: SandboxSettings.self)
        }
    }

    /// Retire one archived agent now (051, US7). Unconfirmed, the size it frees, or why it
    /// cannot go yet; confirmed, it is retired and leaves the list by `agent/removed`.
    func retireNow(_ agentID: UUID, confirmed: Bool) async -> Result<DaemonAPI.RetirePreview, JSONRPCError> {
        do {
            let preview = try await client(for: work.agent(agentID)?.host ?? .mac).call(
                DaemonAPI.Method.agentsRetire, DaemonAPI.RetireRequest(agentID: agentID, confirmed: confirmed),
                returning: DaemonAPI.RetirePreview.self)
            if confirmed, selection == agentID { selection = nil }
            return .success(preview)
        } catch let error as JSONRPCError {
            return .failure(error)
        } catch {
            return .failure(JSONRPCError(code: -1, message: error.localizedDescription))
        }
    }

    /// What is left of a retired agent, asked of the daemon once and then remembered.
    func tombstone(for agentID: UUID, on host: HostID = .mac) async -> Tombstone? {
        if let known = work.tombstones[agentID] { return known }
        guard let found = try? await client(for: host).call(
            DaemonAPI.Method.agentsRetired,
            DaemonAPI.RetiredRequest(ids: [agentID]),
            returning: [Tombstone].self) else { return nil }
        let stamped = found.map { var t = $0; t.host = host; return t }
        work.takeTombstones(stamped)
        return stamped.first
    }

    func setCostLimits(perAgent: Cost?? = nil, daily: Cost?? = nil) async {
        var set: DaemonAPI.CostState?
        // A limit that did not take is said, not left looking set (073).
        await attempt {
            set = try await self.client.call(DaemonAPI.Method.costSetLimits,
                                             DaemonAPI.SetLimitsRequest(perAgent: perAgent, daily: daily),
                                             returning: DaemonAPI.CostState.self)
        }
        guard let state = set else { return }
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
        var changed: Agent?
        await attempt {
            changed = try await self.client(forAgent: agentID).call(
                DaemonAPI.Method.agentsSetCeiling,
                DaemonAPI.SetCeilingRequest(agentID: agentID, ceiling: ceiling),
                returning: Agent.self)
        }
        guard let agent = changed else { return }
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
        // `host|path`.
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

    /// The person's helper limits for a project (#64). Through the window only: the
    /// daemon refuses the method to agents and phones.
    func setHelperLimits(_ limits: HelperLimits, for key: ProjectKey) async {
        do {
            var summary = try await client(for: key.host).call(
                DaemonAPI.Method.projectsSetHelperLimits,
                DaemonAPI.SetHelperLimitsRequest(folder: key.folder, limits: limits),
                returning: DaemonAPI.ProjectSummary.self)
            summary.host = key.host
            upsert(summary)
        } catch {
            problem = describe(error)
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
        // Said at once, everywhere this Mac's host is the target (#83), rather than
        // when the next action has waited out a connect.
        if hosts.macDownSince == nil { hosts.macDownSince = Date() }
        listening = nil
        await reconnect()
    }

    /// Connect, and keep trying if that fails, which is what the window does when it
    /// opens.
    func stayConnected() async {
        routeSharedFiles()
        // Nothing to connect to, and nothing to start: the first run says where.
        guard !needsFirstRun else { return }
        wakeAndNetwork.start { [weak self] reason in self?.goBackNow(reason) }
        await connect()
        if !isConnected { await reconnect() }
    }

    /// The Mac woke or the network changed (#82): a wait in progress ends now, and a
    /// connection the window still believes in is asked whether it is alive, since a
    /// sleep can leave one dead without a word. A try already in flight is left alone.
    private func goBackNow(_ reason: ReconnectTriggers.Reason) {
        let host = backoff.nudge()
        let control = controlBackoff.nudge()
        WakeAndNetwork.log.info("reconnect: \(reason.rawValue, privacy: .public): host \(String(describing: host), privacy: .public), control plane \(String(describing: control), privacy: .public)")
        guard host == .idle, isConnected, !checkingAfterWake else { return }
        checkingAfterWake = true
        Task {
            // One that does not answer is closed; with a control plane, the connection
            // under every host's goes too, so nothing dials back over the dead one.
            if await !client.answers(within: .seconds(4)) { controlLink?.disconnect() }
            checkingAfterWake = false
        }
    }

    /// The move across (058, US6) is letting the old daemon go: the window does not go
    /// back for it, or it would start it again under the host launchd is starting.
    @ObservationIgnored private var holdingForMove = false

    /// A window working the old way, with something to move, and no control plane yet:
    /// the strip that offers the move (frame I).
    var offersMoveAcross: Bool { ControlConfig.endpoint == nil && !needsFirstRun && !moved }
    private var moved = false

    /// Step two of the move: the window's own daemon quits, leaving its agents to be
    /// picked up by the host that replaces it, and the window does not start another.
    /// A turn in flight refuses the quit, and nothing has changed.

    /// The move stopped before the window adopted the control plane: back to the old way.
    func resumeTheOldWay() async {
        holdingForMove = false
        guard ControlConfig.endpoint == nil else { return }
        await stayConnected()
    }

    /// First run has a control plane (058): from here the window is its client, and
    /// this Mac's host is reached through it.

    /// First run has paired with a control plane elsewhere (058, frame C).
    func adopt(_ endpoint: ControlConfig.Endpoint) async {
        guard let link = ControlConfig.link(endpoint) else { return }
        controlLink = link
        client = DaemonClient(link: link.link(for: .mac))
        // Made with the client just replaced, they would ask it for ever (#62).
        serverFilesByHost[.mac] = nil
        serverPicturesByHost[.mac] = nil
        needsFirstRun = false
        await stayConnected()
    }

    /// Keep going back until the daemon answers.
    ///
    /// One try used to be all there was, and a daemon slow to come back left a window
    /// that looked alive and never would be again. The same loop as the phone's:
    /// backing off to half a minute, and only one of it at a time.
    private func reconnect() async {
        guard reconnecting == nil else { return }
        let backoff = backoff
        backoff.trying()
        reconnecting = Task { [weak self] in
            while !Task.isCancelled {
                await backoff.wait()
                guard let self else { return }
                if self.isConnected { break }
                WakeAndNetwork.log.info("reconnect: trying")
                await self.connect()
                if self.isConnected {
                    WakeAndNetwork.log.info("reconnect: connected")
                    break
                }
            }
            if !Task.isCancelled { backoff.settle() }
            self?.reconnecting = nil
        }
        await reconnecting?.value
    }

    func connect() async {
        // Never the old way's daemon while first run is still deciding the new way, or
        // while the move across is handing it to launchd.
        guard !needsFirstRun, !holdingForMove else { return }
        // The control plane's own client, started whether or not this Mac's host
        // answers: a host can be down while the control plane is up (frame H).
        if controlLink != nil { watchControlHosts() }
        do {
            try await client.connect()
            isConnected = true
            hosts.macDownSince = nil
            problem = nil
            await client.setCredentialLender { [weak self] wanted in
                await self?.answerMacCredentialWanted(wanted) ?? false
            }
            await lendToThisMac()
            listen()
            // A new connection watches nothing; what the files pane was watching is asked
            // for again, and what it shows is read again (#62).
            startPresence()
            presence?.connected()
            // With a deadline on each call: this runs inside the reconnect loop, and a reply
            // lost to the host restarting held the loop, and the window, for good (073).
            await DaemonClient.$patience.withValue(.seconds(20)) {
                await serverFilesByHost[.mac]?.reconnected()
                await refreshEverything()
            }
            // Servers the control plane reaches are its clients. HostSet is the old
            // path, and it stays only while this window has no control plane (R7).
            if controlLink == nil { startHosts() }
            watchControlHosts()
        } catch {
            isConnected = false
            if hosts.macDownSince == nil { hosts.macDownSince = Date() }
            // A control plane that cannot be reached is the strip, not an alert.
            if controlLink == nil { problem = describe(error) }
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
            // And the other way: every server hears what the Mac learned about a plan it
            // relays (052, R6). Only a newer word changes anything there.
            if case .runtimeAllowancesChanged(let allowances) = update { await sendSharedAllowances(allowances) }
            if case .attention(let change) = update { await notifier.apply(change) }
            return
        }

        switch method {
        case DaemonAPI.Notification.shellOutput:
            // Read rather than decoded: this one arrives whenever a shell prints, and
            // the general path would re-encode every byte of it here on the main
            // actor before decoding it again. See `ShellOutputNotification`.
            guard let params, let notification = DaemonAPI.ShellOutputNotification(params: params) else { return }
            shellClients[ShellKey(agentID: notification.agentID, shell: notification.shell)]?.received(notification.bytes)

        case DaemonAPI.Notification.shellStateChanged:
            guard let notification = try? params?.decode(DaemonAPI.ShellStateNotification.self) else { return }
            shellClients[ShellKey(agentID: notification.agentID, shell: notification.shell)]?.received(notification.state)

        case DaemonAPI.Notification.draftOptions:
            guard let notification = try? params?.decode(DaemonAPI.DraftOptionsNotification.self) else { return }
            settleDraft(notification)

        case DaemonAPI.Notification.filesChanged:
            // This Mac's host is read through `files/*` too (058, R11), and says so here
            // when a watched folder changes. Dropped, its pane never followed the agent.
            guard let change = try? params?.decode(DaemonAPI.FilesChangedNotification.self) else { return }
            serverFiles(.mac).apply(change)

        case DaemonAPI.Notification.runtimeChanged:
            await refreshRuntimes()

        case DaemonAPI.Notification.runtimeAccountChanged:
            guard let account = try? params?.decode(RuntimeAccount.self) else { return }
            accounts[account.runtimeID] = account
            if account.state == .ready { signInsPutAway.remove(account.runtimeID) }

        case DaemonAPI.Notification.signInNeeded:
            // A turn, a queued prompt or a pick-up refused with nobody waiting on the
            // call, so this is the only place the window hears it.
            guard let needed = try? params?.decode(DaemonAPI.SignInNeeded.self),
                  !signInsPutAway.contains(needed.runtimeID), signInRuntimeID == nil else { return }
            signInRuntimeID = needed.runtimeID

        case DaemonAPI.Notification.cloneChanged:
            guard let change = try? params?.decode(DaemonAPI.CloneNotification.self) else { return }
            clones.removeAll { $0.id == change.clone.id }
            if !change.finished { clones.append(change.clone) }

        case DaemonAPI.Notification.clientPermissionsChanged:
            guard let settings = try? params?.decode(ClientPermissionSettings.self) else { return }
            clientPermissions = settings

        case DaemonAPI.Notification.sandboxChanged:
            guard let settings = try? params?.decode(SandboxSettings.self) else { return }
            sandboxSettings = settings

        case DaemonAPI.Notification.writeFailed:
            // Something nobody was waiting on was not kept: a full disk, or a folder
            // refusing writes. Said, so it is not found out at the next restart (#88).
            guard let failure = try? params?.decode(WriteFailure.self) else { return }
            problem = failure.message

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
        hosts.toolsetWanted = { [weak self] id, runtimeID in
            guard let self else { return false }
            // One that works with no sign-in goes wherever this Mac has it (049: OpenCode's free
            // models); on an "own sign-in only" server too, since nothing is lent to install it.
            if RuntimeLaunchCatalog.launch(for: runtimeID).lentSignIn != nil { return self.hasOnThisMac(runtimeID) }
            guard !(self.hosts.host(id)?.ownSignInOnly ?? false) else { return false }
            // A key in Settings, or this Mac's own sign-in relayed (047).
            return self.credentials.record(runtimeID) != nil
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

    /// Follow the control plane's hosts: a client for each one other than this Mac's,
    /// listed now and kept as hosts come and go (058, US3).
    private func watchControlHosts() {
        guard let controlLink, controlWatch == nil else { return }
        let backoff = controlBackoff
        controlWatch = Task { [weak self] in
            let control = DaemonClient(link: controlLink.controlLink)
            while !Task.isCancelled {
                backoff.trying()
                if (try? await control.connect(startIfNeeded: false, timeout: .seconds(3))) != nil {
                    backoff.settle()
                    self?.controlPlaneDidAnswer()
                    await self?.syncControlHosts(control)
                    for await note in control.notifications() where note.method == DaemonAPI.Notification.controlHostChanged {
                        await self?.syncControlHosts(control)
                    }
                    if !Task.isCancelled { self?.controlPlaneWent() }
                } else if !Task.isCancelled {
                    self?.controlPlaneWent()
                }
                await backoff.wait()
            }
        }
    }

    private func controlPlaneDidAnswer() {
        controlPlaneReachable = true
        controlPlaneMissed = false
    }

    private func controlPlaneWent() {
        guard controlLink != nil else { return }
        controlPlaneReachable = false
        controlPlaneMissed = true
    }

    private func syncControlHosts(_ control: DaemonClient) async {
        guard let controlLink,
              let listed = try? await control.call(DaemonAPI.Method.hostsList, returning: [DaemonAPI.ControlHost].self),
              let status = try? await control.call(DaemonAPI.Method.controlStatus, returning: DaemonAPI.ControlStatus.self)
        else { return }
        controlPlaneHosts = listed
        controlPlaneListed = true
        controlPlaneName = status.name
        // `.mac` is `client`, already. Every other host, including another machine's
        // home host, gets a client of its own on the same link.
        // A relay host (`agents-relay`) runs no agents: nothing to reach there.
        let others = listed.filter { $0.id != .mac && $0.relay != true }
        hosts.controlled = Dictionary(uniqueKeysWithValues: others.map { ($0.id, (label: $0.name, online: $0.state == "online")) })
        for host in others where host.state == "online" {
            let server = controlHosts[host.id] ?? DaemonClient(link: controlLink.link(for: host.id))
            controlHosts[host.id] = server
            guard await !server.isConnected else { continue }
            guard (try? await server.connect(startIfNeeded: false, timeout: .seconds(5))) != nil else { continue }
            let id = host.id
            await server.setCredentialLender { [weak self] wanted in
                await self?.answerCredentialWanted(wanted, on: id) ?? false
            }
            _ = try? await server.call(DaemonAPI.Method.credentialsOffer, credentialOffer(id))
            Task.detached(priority: .userInitiated) { [weak self] in
                for await note in server.notifications() {
                    await self?.receivedFromServer(id, note.method, note.params)
                }
            }
            await refreshServer(id)
            // Presence starts with this Mac's host; a control plane with none starts it
            // with its first other host.
            startPresence()
            presence?.connected()
        }
        // A host removed from the control plane leaves the window too: its projects and
        // agents are no longer anybody's to show here (FR-014; they carry on where they are).
        for id in controlHosts.keys where !others.contains(where: { $0.id == id }) {
            await controlHosts.removeValue(forKey: id)?.disconnect()
            work.replaceProjects([], from: id)
            work.replaceAgents([], from: id)
        }
    }

    /// Whether this Mac's own runtime is installed and can start (049: what puts OpenCode on
    /// its servers).
    func hasOnThisMac(_ runtimeID: String) -> Bool {
        runtimes.first { $0.id == runtimeID }?.availability.isAvailable ?? false
    }

    private func receivedFromServer(_ host: HostID, _ method: String, _ params: JSONValue?) async {
        // What is about the whole of a daemon rather than its work is the Mac's alone in
        // the model: a server's spending is kept beside it, and a server's wakefulness,
        // modes and notices have no place in this window (037).
        switch method {
        case DaemonAPI.Notification.runtimesAllowancesChanged:
            // A server's runtimes are its own; this window shows the Mac's (065). What it
            // learned about a plan the Mac relays is the Mac's to know too (052, R6): its
            // Codex spends the Mac's ChatGPT plan, so a refusal there is the Mac's plan out.
            let shared = (try? params?.decode(RuntimeAllowances.self))?.shared ?? []
            if !shared.isEmpty {
                _ = try? await client.call(DaemonAPI.Method.poolApplyAllowances,
                                           DaemonAPI.ApplyAllowances(states: shared), returning: Bool.self)
            }
            return
        case DaemonAPI.Notification.costChanged:
            serverCosts[host] = try? params?.decode(DaemonAPI.CostState.self)
            noteServerSpent(host)
            return
        case DaemonAPI.Notification.credentialRefused:
            // The key in Settings was refused: Settings turns red, and says why (043).
            if let refused = try? params?.decode(DaemonAPI.CredentialRefused.self) {
                if refused.lent { credentials.markRefused(refused.runtime) }
                // This Mac's own sign-in was refused through the relay (056): sign in here.
                if refused.relayed == true { signInRuntimeID = refused.runtime }
                // A key this Mac's sign-in file lent (049): its sheet names the command.
                if refused.borrowed == true { signInRuntimeID = refused.runtime }
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
             DaemonAPI.Notification.draftOptions, DaemonAPI.Notification.writeFailed:
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
        // And its retention settings (051).
        if let settings = work.retentionState?.settings {
            _ = try? await server.call(DaemonAPI.Method.retentionSet,
                                       DaemonAPI.RetentionSetRequest(settings: settings, confirmed: true),
                                       returning: DaemonAPI.RetentionSetResult.self)
        }
        // And Cursor/Grok permission mode (061).
        _ = try? await server.call(DaemonAPI.Method.clientPermissionsSet, clientPermissions,
                                   returning: ClientPermissionSettings.self)
        // And each runtime's sandbox default (064).
        _ = try? await server.call(DaemonAPI.Method.sandboxSet, sandboxSettings,
                                   returning: SandboxSettings.self)
        // And what the Mac knows of the plans it relays (052, R6): a server's Codex
        // spends the Mac's ChatGPT plan, so the Mac's word that it is out is the server's.
        if let allowances = work.runtimeAllowances {
            let shared = allowances.shared ?? []
            if !shared.isEmpty {
                _ = try? await server.call(DaemonAPI.Method.poolApplyAllowances,
                                           DaemonAPI.ApplyAllowances(states: shared), returning: Bool.self)
            }
        }
        // The Mac's limits hold on every server too; each keeps to them on its own.
        if let limits = work.costState?.limits {
            serverCosts[host] = try? await server.call(
                DaemonAPI.Method.costSetLimits,
                DaemonAPI.SetLimitsRequest(perAgent: .some(limits.perAgent), daily: .some(limits.daily)),
                returning: DaemonAPI.CostState.self)
        } else {
            serverCosts[host] = try? await server.call(DaemonAPI.Method.costState, returning: DaemonAPI.CostState.self)
        }
        if let listed = try? await server.call(DaemonAPI.Method.agentsList, DaemonAPI.ListRequest(lean: true),
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
        async let permissions: Void = refreshPermissions()
        async let elicitations: Void = refreshElicitations()
        async let attention: Void = refreshAttention()
        async let resuming: Void = refreshResuming()
        async let cost: Void = refreshCostState()
        async let retention: Void = refreshRetentionState()
        async let clientPermissions: Void = refreshClientPermissions()
        async let sandbox: Void = refreshSandboxSettings()
        async let runtimeStates: Void = refreshRuntimeAllowances()
        async let cloning: Void = refreshClones()
        async let wake: Void = refreshWakeState()
        async let leases: Void = refreshLeases()
        async let events: Void = refreshEvents()
        async let modes: Void = refreshModes()
        async let transcript: Void = loadTranscript()
        _ = await (runtimes, accounts, workflows, permissions,
                   elicitations, attention, resuming, cost, retention, clientPermissions, cloning, wake, leases, events, modes,
                   transcript, runtimeStates, sandbox)
        #if DEBUG
        openFromLaunchArguments()
        #endif
    }

    #if DEBUG
    /// `-open-agent <id>` opens that agent once the window has its lists, as the phone's
    /// `-agent` does: a way to put a screen in front of a test that no accessibility
    /// action reaches, such as a link inside an event's card. Debug builds only.
    private func openFromLaunchArguments() {
        // Once: this runs on every reconnect, and a window yanked back to the same agent
        // each time would be a test hook getting in the way of the test.
        guard !Self.launchArgumentsOpened else { return }
        Self.launchArgumentsOpened = true
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-open-agent"), index + 1 < arguments.endIndex,
              let id = UUID(uuidString: arguments[index + 1]) else { return }
        openAgent(id)
    }
    private static var launchArgumentsOpened = false
    #endif

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
        guard hasMacHost else { return }
        await attempt {
            // Lean: the sessions column reads none of the option and command lists, and
            // they were 4 MB of 200 agents (#107). The open chat's come with `loadWholeAgent`.
            let listed = try await self.client.call(DaemonAPI.Method.agentsList,
                                                    DaemonAPI.ListRequest(lean: true),
                                                    returning: [Agent].self)
            self.work.replaceAgents(listed, from: .mac)
            Perf.sinceLaunch("first-list")
            // Whatever the list already shows was spent before this window opened, so
            // the session total starts from here rather than from the beginning of time.
        }
    }

    /// What every agent shares, for Settings ▸ Shared (054). Nil when it could not be read;
    /// the tab then keeps what it last had.
    func sharedSnapshot() async -> DaemonAPI.SharedSnapshot? {
        var snapshot: DaemonAPI.SharedSnapshot?
        _ = await attempt {
            snapshot = try await self.client.call(DaemonAPI.Method.personalShared, Optional<String>.none,
                                                  returning: DaemonAPI.SharedSnapshot.self)
        }
        return snapshot
    }

    // MARK: The catalogue (059)

    /// What a catalogue call said, or why it could not: the sheet shows either, so these
    /// do not go through `attempt`, which would put a failure in the window's banner too.
    func catalogSearch(_ query: String) async -> DaemonAPI.CatalogSearchAnswer {
        do {
            return try await client.call(DaemonAPI.Method.catalogSearch, DaemonAPI.CatalogSearchRequest(query: query),
                                         returning: DaemonAPI.CatalogSearchAnswer.self)
        } catch {
            return .init(results: [], error: Self.catalogError(error))
        }
    }

    func catalogPreview(_ result: DaemonAPI.CatalogResult,
                        for destination: DaemonAPI.SkillDestination) async -> DaemonAPI.CatalogPreviewAnswer {
        do {
            return try await client.call(DaemonAPI.Method.catalogPreview,
                                         DaemonAPI.CatalogPreviewRequest(result: result, destination: destination),
                                         returning: DaemonAPI.CatalogPreviewAnswer.self)
        } catch {
            return .init(preview: nil, error: Self.catalogError(error))
        }
    }

    func catalogDestinationState(_ previewID: UUID,
                                 for destination: DaemonAPI.SkillDestination) async -> DaemonAPI.DestinationState? {
        try? await client.call(DaemonAPI.Method.catalogDestinationState,
                               DaemonAPI.DestinationStateRequest(previewID: previewID, destination: destination),
                               returning: DaemonAPI.DestinationStateAnswer.self).destinationState
    }

    func addSkill(_ previewID: UUID, to destination: DaemonAPI.SkillDestination,
                  replace: Bool) async -> Result<DaemonAPI.ManagedSkill, DaemonAPI.CatalogError> {
        do {
            let answer = try await client.call(DaemonAPI.Method.skillsAdd,
                                               DaemonAPI.SkillAddRequest(previewID: previewID, destination: destination,
                                                                         replace: replace),
                                               returning: DaemonAPI.SkillAddAnswer.self)
            return .success(answer.skill)
        } catch {
            return .failure(Self.catalogError(error))
        }
    }

    /// A project's (or worktree's) own skills, for its page (frame D). Nil when they could
    /// not be read, so the section keeps what it last had.
    func projectSkills(_ folder: URL) async -> [DaemonAPI.ListedSkill]? {
        await skills(at: .project(folder: folder.path))
    }

    /// Skills in `~/.agents/skills` or a project's `.agents/skills`.
    func skills(at destination: DaemonAPI.SkillDestination) async -> [DaemonAPI.ListedSkill]? {
        try? await client.call(DaemonAPI.Method.skillsList,
                               DaemonAPI.SkillsListRequest(destination: destination),
                               returning: DaemonAPI.SkillsListAnswer.self).skills
    }

    /// Whether each added skill at a destination has an update (FR-018). Nil when it could
    /// not be asked; the page then shows no marks rather than wrong ones.
    func skillUpdates(at destination: DaemonAPI.SkillDestination) async -> [String: DaemonAPI.UpdateState]? {
        try? await client.call(DaemonAPI.Method.skillsCheckUpdates, DaemonAPI.SkillsListRequest(destination: destination),
                               returning: DaemonAPI.SkillUpdatesAnswer.self).updates
    }

    func skillUpdatePreview(_ name: String, at destination: DaemonAPI.SkillDestination)
        async -> Result<DaemonAPI.SkillUpdatePreviewAnswer, DaemonAPI.CatalogError> {
        do {
            return .success(try await client.call(DaemonAPI.Method.skillsUpdatePreview,
                                                  DaemonAPI.SkillNameRequest(destination: destination, name: name),
                                                  returning: DaemonAPI.SkillUpdatePreviewAnswer.self))
        } catch {
            return .failure(Self.catalogError(error))
        }
    }

    /// Take out a skill the app or the skills tool added; its folder goes to the Trash.
    func removeSkill(_ name: String, at destination: DaemonAPI.SkillDestination) async -> DaemonAPI.CatalogError? {
        do {
            _ = try await client.call(DaemonAPI.Method.skillsRemove,
                                      DaemonAPI.SkillNameRequest(destination: destination, name: name),
                                      returning: DaemonAPI.SkillRemoveAnswer.self)
            return nil
        } catch {
            return Self.catalogError(error)
        }
    }

    /// The daemon's own reason when it gave one, and "can't reach" the daemon otherwise.
    private static func catalogError(_ error: any Error) -> DaemonAPI.CatalogError {
        if let rpc = error as? JSONRPCError, rpc.code == DaemonAPI.Failure.catalogRefused,
           let reason = try? rpc.data?.decode(DaemonAPI.CatalogError.self) {
            return reason
        }
        return .failed(String(describing: error))
    }

    // MARK: MCP catalogue (060)

    func mcpSearch(_ query: String) async -> DaemonAPI.MCPSearchAnswer {
        do {
            return try await client.call(DaemonAPI.Method.catalogSearch,
                                         DaemonAPI.CatalogSearchRequest(query: query, kind: .mcp),
                                         returning: DaemonAPI.MCPSearchAnswer.self)
        } catch {
            return .init(results: [], error: Self.mcpError(error))
        }
    }

    func mcpPreview(_ result: DaemonAPI.MCPCatalogResult,
                    for destination: DaemonAPI.SkillDestination,
                    run: DaemonAPI.MCPRunKind?) async -> DaemonAPI.MCPPreviewAnswer {
        do {
            return try await client.call(DaemonAPI.Method.mcpPreview,
                                         DaemonAPI.MCPPreviewRequest(result: result, destination: destination, run: run),
                                         returning: DaemonAPI.MCPPreviewAnswer.self)
        } catch {
            return .init(error: Self.mcpError(error))
        }
    }

    func mcpServers(at destination: DaemonAPI.SkillDestination) async -> DaemonAPI.MCPListAnswer? {
        try? await client.call(DaemonAPI.Method.mcpList,
                               DaemonAPI.MCPListRequest(destination: destination),
                               returning: DaemonAPI.MCPListAnswer.self)
    }

    /// Write one name into `secrets.env`. The value is not kept here.
    func mcpSetSecret(name: String, value: String) async -> DaemonAPI.MCPCatalogError? {
        do {
            _ = try await client.call(DaemonAPI.Method.mcpSetSecret,
                                     DaemonAPI.MCPSetSecretRequest(name: name, value: value),
                                     returning: DaemonAPI.MCPSetSecretAnswer.self)
            return nil
        } catch {
            return Self.mcpError(error)
        }
    }

    func mcpRemove(_ name: String, at destination: DaemonAPI.SkillDestination,
                   forgetSecret: String?) async -> DaemonAPI.MCPCatalogError? {
        do {
            _ = try await client.call(DaemonAPI.Method.mcpRemove,
                                     DaemonAPI.MCPRemoveRequest(destination: destination, name: name,
                                                               forgetSecret: forgetSecret),
                                     returning: DaemonAPI.MCPRemoveAnswer.self)
            return nil
        } catch {
            return Self.mcpError(error)
        }
    }

    /// Approve the entry the row showed. A digest that no longer matches comes back as an error.
    func approveProjectMCP(_ name: String, digest: String, in folder: URL) async -> DaemonAPI.MCPCatalogError? {
        do {
            _ = try await client.call(DaemonAPI.Method.mcpApprove,
                                      DaemonAPI.MCPApproveRequest(destination: .project(folder: folder.path),
                                                                  name: name, digest: digest),
                                      returning: DaemonAPI.MCPListAnswer.self)
            return nil
        } catch {
            return Self.mcpError(error)
        }
    }

    func mcpAdd(_ previewID: UUID, to destination: DaemonAPI.SkillDestination,
                secrets: [String: String], plain: [String: String],
                replace: Bool) async -> Result<DaemonAPI.ManagedMCPServer, DaemonAPI.MCPCatalogError> {
        do {
            let answer = try await client.call(DaemonAPI.Method.mcpAdd,
                                               DaemonAPI.MCPAddRequest(previewID: previewID, destination: destination,
                                                                       secrets: secrets, plain: plain, replace: replace),
                                               returning: DaemonAPI.MCPAddAnswer.self)
            if let server = answer.server { return .success(server) }
            return .failure(answer.error ?? .failed("no server"))
        } catch {
            return .failure(Self.mcpError(error))
        }
    }

    private static func mcpError(_ error: any Error) -> DaemonAPI.MCPCatalogError {
        if let rpc = error as? JSONRPCError, rpc.code == DaemonAPI.Failure.mcpCatalogRefused,
           let reason = try? rpc.data?.decode(DaemonAPI.MCPCatalogError.self) {
            return reason
        }
        return .failed(String(describing: error))
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
            // Every host hears whether the person is here; only the one the open
            // conversation lives on hears which it is, since that is what marks it read
            // there (058, T093a). A control plane's hosts used to hear nothing, so their
            // finished turns stayed under Needs you however often they were opened.
            let owner = watching.map { self.host(ofAgent: $0) }
            if self.hasMacHost {
                _ = try? await self.client.call(DaemonAPI.Method.presenceReport,
                                                DaemonAPI.PresenceReport(watching: owner == .mac ? watching : nil, active: active))
            }
            for (id, server) in self.controlHosts {
                _ = try? await server.call(DaemonAPI.Method.presenceReport,
                                           DaemonAPI.PresenceReport(watching: owner == id ? watching : nil, active: active))
            }
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

    /// How many finished turns a chat opens with (#90).
    static let firstTurns = 12

    /// The open chat's record whole, with the menus and plan a lean list leaves out (#107).
    /// A host too old to know `agentID` lists its newest instead, which is not this one.
    func loadWholeAgent(_ id: UUID) async {
        let host = host(ofAgent: id)
        guard let listed = try? await client(for: host).call(DaemonAPI.Method.agentsList, DaemonAPI.ListRequest.whole(id),
                                                             returning: [Agent].self),
              var whole = listed.first(where: { $0.id == id }) else { return }
        whole.host = host
        work.takeListed([whole])
    }

    func loadTranscript() async {
        guard let selection else { work.clearTranscript(); return }
        // Beside the transcript rather than before it: neither waits on the other.
        async let whole: Void = loadWholeAgent(selection)
        await attempt {
            let client = self.client(forAgent: selection)
            // The finished turns first, as summaries; then the transcript from where the
            // turn in progress starts. A daemon too old to keep turns gives the lot.
            // A few turns rather than a full page: a screen holds two or three, the rest
            // come as the reader nears the top, and fifty replies were a quarter of a
            // megabyte to carry and decode before anything could be drawn (#90).
            let turns = (try? await client.call(DaemonAPI.Method.agentsTurns,
                                                DaemonAPI.TurnsRequest(agentID: selection,
                                                                       limit: Self.firstTurns),
                                                returning: TurnsPage.self))
                ?? TurnsPage(turns: [], firstTurn: 0, openStart: 0)
            let page = try await client.call(DaemonAPI.Method.agentsTranscript,
                                             DaemonAPI.TranscriptRequest(agentID: selection, from: turns.openStart),
                                             returning: TranscriptPage.self)
            // Clicking through chats quickly can have the answer for the last one
            // arrive after the next was picked. It is dropped, not shown under the
            // wrong name.
            guard self.selection == selection else { return }
            let dataIn = self.chatOpening.map { Perf.elapsed($0.timing) }
            self.work.replaceTurns(with: turns)
            self.work.replaceTranscript(with: page)
            if let opening = self.chatOpening, opening.agent == selection {
                self.chatOpening = nil
                Perf.endWhenDrawn(opening.timing, "\(turns.turns.count) turns, \(page.entries.count) entries, "
                                  + "data in \(dataIn ?? 0) ms")
            }
        }
        await whole
    }

    /// Every entry of a finished turn, for the chat to open it.
    func turnEntries(_ agentID: UUID, _ range: Range<Int>) async -> [TranscriptEntry] {
        let page = try? await client(forAgent: agentID).call(
            DaemonAPI.Method.agentsTranscript,
            DaemonAPI.TranscriptRequest(agentID: agentID, before: range.upperBound,
                                        limit: range.count, from: range.lowerBound),
            returning: TranscriptPage.self)
        return page?.entries ?? []
    }

    /// The window only ever asks for a page. A transcript that has been going for hours
    /// is not something to load whole.
    func loadEarlier() async {
        guard let selection, work.hasMoreOfTheConversation else { return }
        // Past the start of the turn in progress, the turns before it.
        if !work.hasMoreBefore {
            await attempt {
                let turns = try await self.client(forAgent: selection).call(
                    DaemonAPI.Method.agentsTurns,
                    DaemonAPI.TurnsRequest(agentID: selection, before: self.work.firstTurn),
                    returning: TurnsPage.self)
                guard self.selection == selection else { return }
                self.work.prependTurns(turns)
            }
            return
        }
        await attempt {
            let page = try await self.client(forAgent: selection).call(
                DaemonAPI.Method.agentsTranscript,
                DaemonAPI.TranscriptRequest(agentID: selection, before: self.work.firstEntryIndex,
                                            from: self.work.openTurnStart),
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

    /// What the open agent's project has, for the Worktree choice on its page (053).
    func loadAgentWorktrees(of agent: Agent) async {
        let folder = agent.projectFolder
        let answer = (try? await client(forAgent: agent.id).call(DaemonAPI.Method.worktreesList,
                                                                DaemonAPI.WorktreesListRequest(folder: folder),
                                                                returning: DaemonAPI.WorktreesListResponse.self))
            ?? .notARepository
        agentWorktrees[folder] = answer
    }

    /// Move an agent, or with no target take back the move that is waiting (053). Made
    /// at once when it is between turns; otherwise when its turn ends.
    func move(_ agent: Agent, to target: MoveTarget?) async {
        moveProblems[agent.id] = nil
        do {
            _ = try await client(forAgent: agent.id).call(DaemonAPI.Method.agentsMove,
                                                          DaemonAPI.MoveRequest(agentID: agent.id, target: target),
                                                          returning: DaemonAPI.MoveAnswer.self)
        } catch let error as JSONRPCError {
            moveProblems[agent.id] = error.message
        } catch {
            moveProblems[agent.id] = "Could not move: \(error.localizedDescription)"
        }
        await loadAgentWorktrees(of: agent)
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
    func startDraft(prompt: String, attachments: [Attachment] = [], labels: [String] = []) async -> Bool {
        guard !isStarting, let runtimeID = draftRuntimeID, let cwd = draftCwd else { return false }
        isStarting = true
        defer { isStarting = false }
        let request = DaemonAPI.StartRequest(runtimeID: runtimeID,
                                             cwd: cwd,
                                             prompt: prompt,
                                             attachments: attachments,
                                             startOptions: StartOptions(values: draftChosen),
                                             draftID: draftID,
                                             additionalDirectories: draftFolders,
                                             mcpServers: draftServers,
                                             worktree: draftWorktree,
                                             sandbox: draftSandbox, labels: labels)
        do {
            let id = try await selectedHostClient.call(DaemonAPI.Method.agentsStart, request, returning: UUID.self)
            draftID = nil
            // Back to the project folder, and the list fetched again: the start may
            // have made a worktree, and it has put an agent in one.
            draftWorktree = nil
            Task { await loadDraftWorktrees() }
            if selectedProjectHost == .mac {
                await refreshAgents()
                await refreshProjects()
            } else {
                await refreshServer(selectedProjectHost)
            }
            // Gone to, as the phone does: what you just asked for is what you want to
            // see start. Once the list has it, so the chat opens on a row that is there.
            selection = id
            draftSandboxRefusal = nil
            return true
        } catch let error as JSONRPCError where error.code == DaemonAPI.Failure.sandboxWillNotStart {
            // Said over the prompt, which keeps what was typed, with the way on (064).
            draftSandboxRefusal = try? error.data?.decode(DaemonAPI.SandboxWillNotStart.self)
            if draftSandboxRefusal == nil { fail(error, on: selectedProjectHost) }
            return false
        } catch {
            fail(error, on: selectedProjectHost)
            return false
        }
    }

    /// Sent now if the agent is free, and queued by the daemon if it is not. Either
    /// way this is the same call: whether there is room for it is not the window's
    /// question to answer.
    @discardableResult
    func send(_ text: String, attachments: [Attachment] = []) async -> Bool {
        guard let selection, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let host = host(ofAgent: selection)
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
        await attempt(on: work.agent(id)?.host ?? .mac) {
            try await self.client(forAgent: id).call(DaemonAPI.Method.agentsPrompt,
                                       DaemonAPI.PromptRequest(agentID: id, text: Block.carryOnPrompt))
        }
    }

    /// Start an agent on this, in this project's folder.
    ///
    /// What the prompt at the top of a project does. There is no separate button for
    /// it because there is nothing else the prompt could mean: you are looking at a
    /// folder and saying what you want done in it.
    func startAgent(in folder: URL, prompt: String, labels: [String] = []) async {
        let words = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty, let runtimeID = defaultRuntimeID else { return }
        await attempt {
            let id = try await self.selectedHostClient.call(
                DaemonAPI.Method.agentsStart,
                DaemonAPI.StartRequest(runtimeID: runtimeID, cwd: folder, prompt: words,
                                       labels: labels),
                returning: UUID.self)
            self.selection = id
        }
    }

    func setLabels(on id: UUID, add: [String] = [], remove: [String] = []) async {
        await attempt(on: work.agent(id)?.host ?? .mac) {
            try await self.client(forAgent: id).call(
                DaemonAPI.Method.agentsSetLabels,
                DaemonAPI.SetLabelsRequest(agentID: id, add: add, remove: remove))
        }
    }

    func labelSuggestions(in folder: URL, on host: HostID) -> [String] {
        SessionLabelPolicy.vocabulary(
            in: folder, agents: work.agents.filter { $0.host == host }).map(\.value)
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

    /// Send a queued prompt into the turn that is running, where the runtime takes one.
    /// Once: the row shows it going, and a second press is not a second send (#87).
    func sendNow(_ prompt: QueuedPrompt, to agentID: UUID) async {
        await act(.sendNow(prompt.id), on: agentID) {
            try await self.client(forAgent: agentID).call(DaemonAPI.Method.agentsSendNow,
                                       DaemonAPI.UnqueueRequest(agentID: agentID, promptID: prompt.id))
        }
    }

    /// Something asked of a whole agent, sent once (#87). Held in `work.acting` until the
    /// host has answered, so whichever control sent it shows it on its way, and the menu,
    /// the row, the swipe and the key all refuse a second until it is back. False when it
    /// did not go, or was a second press of something already going.
    @discardableResult
    private func act(_ act: AgentAct, on id: UUID, _ call: () async throws -> Void) async -> Bool {
        guard work.begin(act, on: id) else { return false }
        defer { work.end(act, on: id) }
        return await attempt(on: work.agent(id)?.host ?? .mac, call)
    }

    /// What is on its way to this agent, if anything: for the control that sent it to
    /// show, and the others to hold.
    func acting(_ id: UUID) -> AgentAct? { work.acting[id] }

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
        await act(.stop, on: id) {
            try await self.client(forAgent: id).call(DaemonAPI.Method.agentsStop, DaemonAPI.AgentRequest(agentID: id))
        }
    }

    /// Stop one shell an agent left running, and nothing else it is doing (057).
    func stopBackground(_ item: BackgroundItem, of agentID: UUID) async {
        await attempt {
            try await self.client(forAgent: agentID).call(DaemonAPI.Method.agentsStopBackground,
                                                           DaemonAPI.StopBackgroundRequest(agentID: agentID, itemID: item.id))
        }
    }

    func archive(_ id: UUID, andLeave: Bool = false) async {
        let archived = await act(.archive, on: id) {
            try await self.client(forAgent: id).call(DaemonAPI.Method.agentsArchive, DaemonAPI.AgentRequest(agentID: id))
        }
        // One path for menu, strip, swipe, ⌫ and the row: leave the chat when asked,
        // so Archive always means the same thing wherever it is pressed. Not when it
        // failed: the chat stays in front, under the reason why (073).
        if archived, andLeave, selection == id { selection = nil }
    }

    func unarchive(_ id: UUID) async {
        await attempt { try await self.client(forAgent: id).call(DaemonAPI.Method.agentsUnarchive, DaemonAPI.AgentRequest(agentID: id)) }
    }

    /// Mark as Unread / Mark as Read, from the row's menu (#70).
    func setUnread(_ id: UUID, _ unread: Bool) async {
        await attempt {
            try await self.client(forAgent: id).call(DaemonAPI.Method.agentsSetUnread,
                                                     DaemonAPI.SetUnreadRequest(agentID: id, unread: unread))
        }
    }

    /// Park or unpark, whichever `Agent.parkAction` offers (040).
    @discardableResult
    func perform(_ action: ParkAction, on id: UUID) async -> Bool {
        let method = action == .park ? DaemonAPI.Method.agentsPark : DaemonAPI.Method.agentsUnpark
        return await act(AgentAct(action), on: id) {
            try await self.client(forAgent: id).call(method, DaemonAPI.AgentRequest(agentID: id))
        }
    }

    /// Whether the answer went, so the card can give its buttons back when it did not.
    /// One `sendID` for every try, so the retry through a fresh connection is the same
    /// answer and not a second one (#86).
    @discardableResult
    func answer(_ request: PermissionRequest, optionID: String) async -> Bool {
        let host = work.agent(request.agentID)?.host ?? .mac
        let sendID = UUID()
        if host != .mac {
            return await sendToServer(host) { client in
                try await client.call(DaemonAPI.Method.permissionsAnswer,
                                      DaemonAPI.AnswerRequest(permissionID: request.id, optionID: optionID,
                                                              sendID: sendID))
            }
        }
        return await attempt {
            try await self.client(forAgent: request.agentID).call(DaemonAPI.Method.permissionsAnswer,
                                       DaemonAPI.AnswerRequest(permissionID: request.id, optionID: optionID,
                                                               sendID: sendID))
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

    /// The daemon's memory. A daemon too old to know the method leaves the form opening
    /// on the runtime's own current mode, which is what it did before anything was
    /// remembered.
    func refreshModes() async {
        let modes = try? await client.call(DaemonAPI.Method.modesRemembered, Optional<Int>.none,
                                           returning: DaemonAPI.RememberedModes.self)
        if let modes { work.replaceRememberedModes(modes) }
    }

    // MARK: The user's shells

    /// The pane's end of one of an agent's shells, made once per shell per window.
    func shellClient(for agentID: UUID, shell: Int = 0) -> ShellClient {
        let key = ShellKey(agentID: agentID, shell: shell)
        if let existing = shellClients[key] { return existing }
        let fresh = ShellClient(agentID: agentID, shell: shell, client: client(forAgent: agentID),
                                describe: { [weak self] error in self?.describeForShell(error) ?? "\(error)" })
        shellClients[key] = fresh
        return fresh
    }

    /// The shells the daemon holds for an agent, so the pane opens with the tabs it
    /// had (055). Nil from a daemon too old to hold more than one — a server not yet
    /// updated — and the pane then offers only the one.
    func shellNumbers(for agentID: UUID) async -> [Int]? {
        let response = try? await client(forAgent: agentID).call(
            DaemonAPI.Method.shellList, DaemonAPI.AgentRequest(agentID: agentID),
            returning: DaemonAPI.ShellListResponse.self)
        return response?.shells
    }

    /// The user closed a terminal tab: the shell ends, and this window forgets it.
    func closeShell(agentID: UUID, shell: Int) async {
        let client = shellClient(for: agentID, shell: shell)
        shellClients[ShellKey(agentID: agentID, shell: shell)] = nil
        await client.close()
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

    func disableProvider(runtimeID: String, providerID: String) async {
        await attempt {
            _ = try await self.client.call(DaemonAPI.Method.runtimeDisableProvider,
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
            fail(error, on: selectedProjectHost)
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

    /// Whether the answer went, as `answer(_:optionID:)` (#86).
    @discardableResult
    func answerElicitation(_ request: ElicitationRequest,
                           action: DaemonAPI.AnswerElicitationRequest.Action,
                           content: [String: JSONValue] = [:]) async -> Bool {
        let sendID = UUID()
        let sent = await attempt {
            try await self.client(forAgent: request.agentID).call(DaemonAPI.Method.elicitationsAnswer,
                                       DaemonAPI.AnswerElicitationRequest(requestID: request.id,
                                                                          action: action,
                                                                          content: content,
                                                                          sendID: sendID))
        }
        await refreshElicitations()
        return sent
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
                  FileManager.default.fileExists(atPath: url.path) else {  // store-ok: a file the person attached: picked or dropped, so the sandbox lets it be read
                carried.append(attachment)
                continue
            }
            let data: Data
            do {
                data = try Data(contentsOf: url)  // store-ok: a file the person attached: picked or dropped
            } catch {
                // Not "too big": a file this window may not read, or one gone, says so (073).
                problem = "\(name) could not be read to send to \(hosts.label(host)): \(error.localizedDescription)"
                return nil
            }
            guard data.count <= DaemonAPI.attachmentLimit else {
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
                fail(refused, on: host)
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

    @discardableResult
    func attempt(on host: HostID = .mac, _ work: () async throws -> Void) async -> Bool {
        // Already known to be down: said now, not after waiting out a connect that
        // the reconnect loop is already making (#83). The strip has Try Again.
        if host == .mac, hosts.isOffline(.mac), !controlPlaneAway {
            problem = HostSet.macDownProblem
            return false
        }
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
            fail(error, on: host)
            return false
        }
    }

    /// A failure put in front of the person. A runtime of this Mac's that needs signing
    /// in gets its sign-in sheet; everything else is said in words. A server's runtime
    /// is signed in on the server, which this sheet cannot do, so it stays words.
    private func fail(_ error: any Error, on host: HostID) {
        if host == .mac, let error = error as? JSONRPCError, error.code == DaemonAPI.Failure.needsSignIn,
           let runtimeID = error.data?["runtimeID"]?.stringValue {
            signInRuntimeID = runtimeID
            return
        }
        // A server's Claude signs in through this Mac's own sign-in (056): with none to
        // relay, the sheet that signs it in on this Mac, and a sentence saying so.
        if host != .mac, let error = error as? JSONRPCError, error.code == DaemonAPI.Failure.signInWanted,
           let wanted = try? error.data?.decode(DaemonAPI.SignInWanted.self) {
            problem = error.message + " Sign it in on this Mac, or use \(hosts.label(host))’s own sign-in in Settings ▸ Servers."
            signInRuntimeID = wanted.runtime
            return
        }
        problem = describe(error)
    }

    /// The sign-in sheet, put away. Signed in or not, it does not come back for this
    /// runtime by itself until the runtime has been signed in once more.
    func putAwaySignIn() {
        if let runtimeID = signInRuntimeID, accounts[runtimeID]?.state != .ready {
            signInsPutAway.insert(runtimeID)
        }
        signInRuntimeID = nil
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
            case .couldNotConnect:
                return HostSet.macDownProblem
            case .socketPathTooLong(let path):
                // Only ever seen by somebody who passed `--root`, and the fix is in
                // their hands: a shorter path.
                return "That folder is too deep to run a daemon in: \(path) is past the 104 bytes a socket may be named with."
            }
        }
        // This window's own writes: a full disk or a refused folder, in words (#88).
        if let failure = WriteFailure(error, keeping: "that") { return failure.message }
        return String(describing: error)
    }
}
