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
    /// What each runtime last said about itself: signed in or not, what it takes in a
    /// prompt, which provider is answering.
    private(set) var accounts: [String: RuntimeAccount] = [:]
    /// What the terminals the daemon is running for an agent have printed so far.
    private(set) var terminalOutput: [String: String] = [:]
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
            UserDefaults.standard.set(selectedProject?.path, forKey: Self.selectedProjectKey)
            // Picking a project shows the project, not a conversation, and not a
            // workflow either. Both are things you go into from here, and come back
            // out of.
            selection = nil
            openWorkflow = nil
        }
    }

    static let selectedProjectKey = "selectedProjectFolder"

    /// Whether the window is showing Spending rather than a project.
    ///
    /// Not persisted, unlike the selected project. Spending is somewhere you go to
    /// answer a question — what has this cost — and a window that reopens on the bill
    /// rather than on the work would be answering a question nobody asked twice.
    var showsSpending = false {
        didSet {
            guard showsSpending, showsSpending != oldValue else { return }
            // The same rule as picking a project: what you picked is what you see,
            // and a conversation or a workflow left open underneath would be waiting
            // to reappear when the bill is closed, which is a place nobody chose to
            // come back to.
            selection = nil
            openWorkflow = nil
        }
    }

    /// What is picked in the sidebar, as one value.
    ///
    /// The projects and Spending share a column, so they have to share a selection:
    /// two bindings would let both look picked at once. `selectedProject` stays the
    /// stored fact — it is what the window reopens on — and this is the view of it
    /// the list is driven by.
    var sidebarItem: SidebarItem? {
        get { showsSpending ? .spending : selectedProject.map(SidebarItem.project) }
        set {
            switch newValue {
            case .spending:
                showsSpending = true
            case .project(let folder):
                showsSpending = false
                showProject(folder)
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
    func showProject(_ folder: URL) {
        // Going to a project is going away from Spending, wherever the ask came from
        // — a new project being added, a menu item, the list itself.
        showsSpending = false
        selectedProject = folder
        selection = nil
        openWorkflow = nil
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
    var draftCwd: URL?
    var draftRuntimeID: String?
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

    var availableRuntimes: [RuntimeStatus] {
        runtimes.filter { $0.availability.isAvailable }
    }

    // MARK: Projects

    /// The ones the sidebar lists.
    var liveProjects: [DaemonAPI.ProjectSummary] { work.liveProjects }

    var archivedProjects: [DaemonAPI.ProjectSummary] { work.archivedProjects }

    var selectedProjectSummary: DaemonAPI.ProjectSummary? { work.project(selectedProject) }

    /// A project's agents in one group, newest first.
    func agents(in folder: URL?, group: AgentGroup) -> [Agent] {
        work.agents(in: folder, group: group)
    }

    /// This window's own counts for a project, from the grouping its panel uses.
    func counts(in folder: URL?) -> [AgentGroup: Int] { work.counts(in: folder) }
    func unreadCount(in folder: URL?) -> Int { work.unreadCount(in: folder) }

    /// Whether the daemon is bringing this chat back by itself after a restart.
    func isComingBack(_ agent: Agent) -> Bool { work.isComingBack(agent) }

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
        (try? await client.call(DaemonAPI.Method.optionsRemembered,
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
    }

    /// Letting one agent carry on past the per-agent limit, or giving it one of its
    /// own. Does not resume it — continuing is the reader's second, deliberate act.
    func setCostCeiling(_ agentID: UUID, to ceiling: Cost?) async {
        guard let agent = try? await client.call(
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
        let ceiling = agent.ceiling(under: costLimits)
        let currency = ceiling?.currency ?? "USD"
        let already = agent.costToDate[currency] ?? 0
        let step = ceiling?.amount ?? already
        await setCostCeiling(agent.id, to: Cost(amount: already + step, currency: currency))
    }

    func refreshProjects() async {
        do {
            work.replaceProjects(try await client.call(DaemonAPI.Method.projectsList,
                                                       DaemonAPI.ProjectsListRequest(),
                                                       returning: [DaemonAPI.ProjectSummary].self))
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
        if let selectedProject, live.contains(where: { $0.folder == selectedProject }) { return }
        let stored = UserDefaults.standard.string(forKey: Self.selectedProjectKey)
            .map { Project.standardize(URL(filePath: $0)) }
        if let stored, live.contains(where: { $0.folder == stored }) {
            selectedProject = stored
        } else {
            selectedProject = live.first?.folder
        }
    }

    func addProject(_ folder: URL) async {
        await callProject(DaemonAPI.Method.projectsAdd, folder) { [weak self] summary in
            self?.selectedProject = summary.folder
        }
    }

    func archiveProject(_ folder: URL) async {
        await callProject(DaemonAPI.Method.projectsArchive, folder)
    }

    func unarchiveProject(_ folder: URL) async {
        await callProject(DaemonAPI.Method.projectsUnarchive, folder) { [weak self] summary in
            self?.selectedProject = summary.folder
        }
    }

    private func callProject(_ method: String, _ folder: URL,
                             then: ((DaemonAPI.ProjectSummary) -> Void)? = nil) async {
        do {
            let summary = try await client.call(method, DaemonAPI.ProjectRequest(folder: folder),
                                                returning: DaemonAPI.ProjectSummary.self)
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

        case DaemonAPI.Notification.agentTerminalOutput:
            guard let notification = try? params?.decode(DaemonAPI.TerminalOutputNotification.self) else { return }
            terminalOutput[notification.terminalID, default: ""] += notification.chunk

        default:
            break
        }
    }

    // MARK: Asking

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
        async let wake: Void = refreshWakeState()
        async let transcript: Void = loadTranscript()
        _ = await (runtimes, accounts, workflows, devices, permissions,
                   elicitations, attention, resuming, cost, wake, transcript)
    }

    func refreshElicitations() async {
        guard let list = try? await client.call(DaemonAPI.Method.elicitationsPending,
                                                Optional<Int>.none,
                                                returning: [ElicitationRequest].self) else { return }
        work.replaceElicitations(list)
    }

    /// The form waiting for this agent, if there is one. Held by the daemon, so it is
    /// here whether or not this window was open when it was asked.
    var elicitationForSelection: ElicitationRequest? { work.elicitation(for: selection) }

    func refreshAgents() async {
        await attempt {
            let listed = try await self.client.call(DaemonAPI.Method.agentsList,
                                                    DaemonAPI.ListRequest(),
                                                    returning: [Agent].self)
            self.work.replaceAgents(listed)
            // Whatever the list already shows was spent before this window opened, so
            // the session total starts from here rather than from the beginning of time.
        }
    }

    func refreshRuntimes() async {
        await attempt {
            self.runtimes = try await self.client.call(DaemonAPI.Method.runtimesList,
                                                       Optional<String>.none,
                                                       returning: [RuntimeStatus].self)
        }
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
            self.showsSpending = false
            // Its own project first, because picking a project empties the selection:
            // a chat opened from a banner under some other project's heading is a
            // sidebar and a page that disagree about where you are.
            if let agent = self.agents.first(where: { $0.id == agentID }) {
                self.selectedProject = Project.standardize(agent.cwd)
            }
            self.openWorkflow = nil
            self.selection = agentID
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
            self.work.replacePermissions(
                try await self.client.call(DaemonAPI.Method.permissionsPending,
                                           Optional<String>.none,
                                           returning: [PermissionRequest].self))
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
            let page = try await self.client.call(DaemonAPI.Method.agentsTranscript,
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
            let page = try await self.client.call(
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

    /// A session has to exist before its options do, so choosing a folder and a
    /// runtime starts one. It is kept and used by the start that follows.
    func loadDraftOptions() async {
        guard let runtimeID = draftRuntimeID, let cwd = draftCwd else { return }
        draftOptionsGeneration += 1
        let generation = draftOptionsGeneration
        isLoadingDraftOptions = true
        draftOptionsFailure = nil
        draftOptions = []
        draftCommands = []
        draftChosen = [:]
        draftID = nil
        do {
            let response = try await client.call(DaemonAPI.Method.agentsOptions,
                                                 DaemonAPI.OptionsRequest(runtimeID: runtimeID, cwd: cwd,
                                                                          mcpServers: draftServers),
                                                 returning: DaemonAPI.OptionsResponse.self)
            // An answer for a folder or runtime the user has since moved away from is
            // not an answer to the question now being asked.
            guard generation == draftOptionsGeneration else { return }
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
                                             mcpServers: draftServers)
        do {
            _ = try await client.call(DaemonAPI.Method.agentsStart, request, returning: UUID.self)
            draftID = nil
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
        return await attempt {
            try await self.client.call(DaemonAPI.Method.agentsPrompt,
                                       DaemonAPI.PromptRequest(agentID: selection, text: text,
                                                               attachments: attachments))
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
            let id = try await self.client.call(
                DaemonAPI.Method.agentsStart,
                DaemonAPI.StartRequest(runtimeID: runtimeID, cwd: folder, prompt: words),
                returning: UUID.self)
            self.selection = id
        }
    }

    /// Which runtime a new agent gets when nobody has said.
    ///
    /// Whatever the last agent used, when it is still available, because that is the
    /// one already chosen in every other sense. It can be changed from the chat.
    var defaultRuntimeID: String? {
        let available = Set(availableRuntimes.map(\.runtime.id))
        let recent = agents.sorted { $0.lastActivityAt > $1.lastActivityAt }
            .first { available.contains($0.runtimeID) }?.runtimeID
        return recent ?? available.first
    }

    /// Take something back off the queue before it goes.
    func unqueue(_ prompt: QueuedPrompt, from agentID: UUID) async {
        await attempt {
            try await self.client.call(DaemonAPI.Method.agentsUnqueue,
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
        await attempt { try await self.client.call(DaemonAPI.Method.agentsStop, DaemonAPI.AgentRequest(agentID: id)) }
    }

    func archive(_ id: UUID) async {
        await attempt { try await self.client.call(DaemonAPI.Method.agentsArchive, DaemonAPI.AgentRequest(agentID: id)) }
    }

    func unarchive(_ id: UUID) async {
        await attempt { try await self.client.call(DaemonAPI.Method.agentsUnarchive, DaemonAPI.AgentRequest(agentID: id)) }
    }

    func answer(_ request: PermissionRequest, optionID: String) async {
        await attempt {
            try await self.client.call(DaemonAPI.Method.permissionsAnswer,
                                       DaemonAPI.AnswerRequest(permissionID: request.id, optionID: optionID))
        }
    }

    /// A choice the person has made and the runtime has not yet confirmed.
    ///
    /// The sequence is which write this was. A call that completes clears the entry
    /// only if it is still the one it wrote, so two clicks in a row settle on the
    /// later choice whatever order the answers come back in.
    struct PendingOption: Equatable {
        var value: JSONValue
        var sequence: Int
    }

    /// Held only while the change is in flight, and never written into
    /// `agent.startOptions`: that is the daemon's record mirrored here, and a client
    /// that edits it is a client that can disagree with the daemon with no way to
    /// notice.
    private(set) var pendingOptions: [UUID: [String: PendingOption]] = [:]
    private var pendingOptionSequence = 0

    /// What an option control should read: the choice just made, else what is in
    /// force, else what the runtime says is current.
    func chosenOption(_ optionID: String, for agent: Agent, advertised: ConfigOption) -> JSONValue? {
        pendingOptions[agent.id]?[optionID]?.value
            ?? agent.startOptions.values[optionID]
            ?? advertised.currentValue
    }

    /// Set an option on a live agent, and show the choice at once.
    ///
    /// The control used to read `agent.startOptions` while this wrote only to a
    /// `Task`, so the menu closed over the old value and stayed there for a JSON-RPC
    /// hop, an ACP call to a separate process, a broadcast and a client apply. The
    /// optimistic value closes that gap; it is dropped when the answer arrives, so a
    /// runtime that refuses settles the control on what is really in force.
    /// Deliberately not `async`. The optimistic value has to be written on the same
    /// turn as the click, and the body of a `Task` does not start until the next one.
    func setOption(agentID: UUID, optionID: String, value: JSONValue) {
        pendingOptionSequence += 1
        let sequence = pendingOptionSequence
        pendingOptions[agentID, default: [:]][optionID] = PendingOption(value: value, sequence: sequence)
        Task { await send(option: optionID, value: value, to: agentID, sequence: sequence) }
    }

    private func send(option optionID: String, value: JSONValue,
                      to agentID: UUID, sequence: Int) async {
        await attempt {
            try await self.client.call(DaemonAPI.Method.agentsSetOption,
                                       DaemonAPI.SetOptionRequest(agentID: agentID, optionID: optionID, value: value))
        }
        // Dropped whether it succeeded or threw: the record is what is in force, and
        // a refusal must settle the control on that rather than on what was asked
        // for. Only if this call is still the last word — a slower earlier call
        // finishing must not drop a later choice.
        guard pendingOptions[agentID]?[optionID]?.sequence == sequence else { return }
        pendingOptions[agentID]?[optionID] = nil
        if pendingOptions[agentID]?.isEmpty == true { pendingOptions[agentID] = nil }
    }

    // MARK: The mode you keep choosing

    /// What was last chosen for this runtime, if it is still readable.
    ///
    /// A stored value we cannot decode is treated as nothing remembered, and the key
    /// is left where it is: a later version may understand it, and throwing away
    /// something we merely do not recognise is not ours to do.
    func rememberedMode(for runtimeID: String) -> JSONValue? {
        guard let data = UserDefaults.standard.data(forKey: ModeMemory.defaultsKey(runtimeID: runtimeID))
        else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// Remember it, for chats after this one. Called for a draft and for a live agent
    /// alike: changing the mode on a conversation says what you want next time too.
    func rememberMode(_ value: JSONValue, for runtimeID: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        UserDefaults.standard.set(data, forKey: ModeMemory.defaultsKey(runtimeID: runtimeID))
    }

    // MARK: The user's shells

    /// The pane's end of one agent's shell, made once per agent per window.
    func shellClient(for agentID: UUID) -> ShellClient {
        if let existing = shellClients[agentID] { return existing }
        let fresh = ShellClient(agentID: agentID, model: self)
        shellClients[agentID] = fresh
        return fresh
    }

    func attachShell(agentID: UUID, rows: Int, cols: Int) async throws -> DaemonAPI.ShellAttachResponse {
        try await client.call(DaemonAPI.Method.shellAttach,
                              DaemonAPI.ShellAttachRequest(agentID: agentID, rows: rows, cols: cols),
                              returning: DaemonAPI.ShellAttachResponse.self)
    }

    func restartShell(agentID: UUID, rows: Int, cols: Int) async throws -> DaemonAPI.ShellAttachResponse {
        try await client.call(DaemonAPI.Method.shellRestart,
                              DaemonAPI.ShellAttachRequest(agentID: agentID, rows: rows, cols: cols),
                              returning: DaemonAPI.ShellAttachResponse.self)
    }

    /// What the person typed on a live page, sent to the daemon to put on disk (022).
    /// The daemon writes rather than the window so that it knows the person did. Nil
    /// on success; on failure, the sentence to show beside the passage, with the draft
    /// kept.
    func writeArtifact(agentID: UUID, path: String, text: String) async -> String? {
        do {
            try await client.call(DaemonAPI.Method.artifactWrite,
                                  DaemonAPI.ArtifactWriteRequest(agentID: agentID, path: path, text: text))
            return nil
        } catch let error as JSONRPCError {
            return error.message
        } catch {
            return error.localizedDescription
        }
    }

    /// Detaching never stops anything. A build carries on (FR-026).
    func detachShell(agentID: UUID) async {
        try? await client.call(DaemonAPI.Method.shellDetach, DaemonAPI.AgentRequest(agentID: agentID))
    }

    func sendToShell(agentID: UUID, bytes: Data) async {
        try? await client.call(DaemonAPI.Method.shellInput,
                               DaemonAPI.ShellInputRequest(agentID: agentID, bytes: bytes))
    }

    func resizeShell(agentID: UUID, rows: Int, cols: Int) async {
        try? await client.call(DaemonAPI.Method.shellResize,
                               DaemonAPI.ShellResizeRequest(agentID: agentID, rows: rows, cols: cols))
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
            return try await client.call(DaemonAPI.Method.sessionsList,
                                         DaemonAPI.SessionsListRequest(runtimeID: runtimeID, cwd: cwd),
                                         returning: [RuntimeSession].self)
        } catch {
            problem = describe(error)
            return []
        }
    }

    func adopt(runtimeID: String, session: RuntimeSession) async {
        do {
            let id = try await client.call(DaemonAPI.Method.sessionsAdopt,
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
            try await self.client.call(DaemonAPI.Method.sessionsDelete,
                                       DaemonAPI.DeleteSessionRequest(runtimeID: runtimeID,
                                                                      sessionID: sessionID,
                                                                      confirmed: true))
        }
    }

    func fork(_ id: UUID) async {
        do {
            let branch = try await client.call(DaemonAPI.Method.agentsFork,
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
            try await self.client.call(DaemonAPI.Method.elicitationsAnswer,
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
