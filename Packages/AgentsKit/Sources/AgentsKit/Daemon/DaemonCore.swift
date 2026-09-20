import Foundation

/// The owner of every agent.
///
/// Holds the runtimes, writes the record, answers the app, and keeps going when there
/// is no window. Everything the app can do is a call on this.
public actor DaemonCore {
    let store: AgentStore
    let locations: StoreLocations
    let discovery: RuntimeDiscovery
    /// Swapped in tests for a fake runtime, so the whole daemon is exercised without a
    /// CLI, a credential or a network.
    let launcher: any SessionLauncher

    var agents: [UUID: Agent] = [:]
    var live: [UUID: ACPSession] = [:]
    var eventTasks: [UUID: Task<Void, Never>] = [:]
    var turnTasks: [UUID: Task<Void, Never>] = [:]
    var drafts: [UUID: Draft] = [:]
    var pendingPermissions: [UUID: Pending] = [:]
    /// Forms an agent is blocked on, held here for the same reason permissions are:
    /// the question can arrive while no window is open.
    var elicitations: [UUID: PendingElicitation] = [:]
    /// The commands we are running for each agent.
    var terminalServices: [UUID: TerminalService] = [:]
    /// Which agent each live suggestion token speaks for. See `DaemonCore+Suggestions`.
    var appTokens: [String: UUID] = [:]
    /// Agents whose next prompt carries the `Briefing`: the few things about this app
    /// an agent is told in words. Set when a conversation starts, and again only if a
    /// runtime loses one and we have to begin a new one — the briefing lives in the
    /// runtime's history, so that is the only time it is gone.
    var needsBriefing: Set<UUID> = []
    /// What each agent found dead on start-up was doing when the last daemon went, held
    /// only until it has been told. See `DaemonCore+Recovery`.
    var interrupted: [UUID: AgentState] = [:]
    /// Agents being picked back up after a restart. Work in hand as far as
    /// `isHoldingAgents` is concerned, from before their runtimes exist.
    var resuming: Set<UUID> = []
    /// Agents whose next queued prompt is already on its way to a runtime. See
    /// `sendNextQueued`: without this the same words can go twice.
    var sending: Set<UUID> = []
    /// What each runtime last told us about itself: signed in or not, how to sign in,
    /// which provider is answering. One per runtime, shared by every agent using it.
    var accounts: [String: RuntimeAccount] = [:]
    /// The two facts about a project that its folder cannot tell us. Everything else
    /// about a project is derived from the agents in it.
    lazy var projectStore = ProjectStore(locations: locations)
    /// What each runtime last advertised, so a start form does not wait for a runtime
    /// to say what it said last time. Read from disk the first time it is wanted.
    lazy var optionCache = OptionCache(locations: locations)
    var rememberedOptions: [String: OptionCache.Entry]?

    // MARK: Money

    /// The two limits the reader set. Read from disk each time rather than cached:
    /// "at its limit" is computed and never stored, and a limit lowered in the
    /// Settings window has to be true of every agent on the next turn end.
    lazy var limitStore = LimitStore(locations: locations)
    /// What each of the last few local days cost. The day's total has to survive a
    /// restart, and it counts agents that have since ended or been archived, so it
    /// cannot be derived from the agents that happen to still be about.
    lazy var spendLedger = SpendLedger(locations: locations)
    /// The local day the last tick saw, so the heartbeat can notice a rollover
    /// without a timer of its own. Nil until the first tick.
    var lastSeenDay: String?
    /// Agents that have been told once that a limit is why their queue is not
    /// draining. In memory and not on the record: it exists only to keep an agent at
    /// its limit from filling its own transcript saying so on every drain attempt.
    var held: Set<UUID> = []
    /// What time it is, for everything about money.
    ///
    /// One clock rather than a `Date()` at each of the five places that bank, gate,
    /// report and prune — which is also what lets a test walk past midnight instead
    /// of waiting for it. The day a limit is measured against is the machine's, and
    /// this is where the machine is asked.
    let now: @Sendable () -> Date

    // MARK: Workflows

    /// What the app remembers about workflows, which is nothing their files can say.
    lazy var workflowStore = WorkflowStore(locations: locations)
    /// Every project's workflows, by folder and then by id. Read from disk, kept here
    /// so a tick does not touch the file system once per workflow per fifteen seconds.
    var workflows: [URL: [String: Workflow]] = [:]
    /// One watcher per live project. What makes a file written by hand appear without
    /// the app being restarted.
    var workflowWatchers: [URL: FolderWatch] = [:]
    /// Rescans waiting out their debounce, by project folder.
    var workflowRescans: [URL: Task<Void, Never>] = [:]
    /// The runs in flight, by `Workflow.id`. This is what a second fire collides with,
    /// and what a fired agent's own events read to work out how deep they are.
    var workflowRuns: [String: WorkflowRun] = [:]
    /// The single ticker. One for the daemon, not one per workflow: see
    /// `tickWorkflows` for why it reads the wall clock rather than sleeping until due.
    var workflowTicker: Task<Void, Never>?

    /// Where notifications go, in a box rather than in a stored closure.
    ///
    /// Anything that broadcasts from off the actor — a terminal's reader, say — holds
    /// the box and reads the door out of it as it sends, rather than copying whatever
    /// was set when it was made. Recovery runs before the socket is open, so a
    /// terminal made during recovery would otherwise have copied nothing and stayed
    /// mute for the rest of the daemon's life.
    let broadcaster = BroadcastBox()
    var connectionCount = 0

    /// The daemon's one way out to the windows, settable once the socket exists and
    /// readable from any thread.
    public final class BroadcastBox: @unchecked Sendable {
        private let lock = NSLock()
        private var send: (@Sendable (String, JSONValue?) -> Void)?

        var isSet: Bool { lock.withLock { send != nil } }

        func set(_ send: @escaping @Sendable (String, JSONValue?) -> Void) {
            lock.withLock { self.send = send }
        }

        func callAsFunction(_ method: String, _ params: JSONValue?) {
            lock.withLock { send }?(method, params)
        }
    }

    /// The user's shells, one per agent. Not the agent's terminals, which are 003's.
    /// Held here so a build outlives the window that started it (FR-026).
    let shells = ShellHost()
    /// Everything the shells have printed, in the order they printed it, on its way to
    /// the windows. See `connectShells` for why it is a stream and not a task each.
    var shellEvents: AsyncStream<(UUID, ShellHost.ShellEvent)>.Continuation?
    var shellPump: Task<Void, Never>?

    struct Draft: Sendable {
        var runtimeID: String
        var cwd: URL
        /// What this session was made with. MCP servers are only read at `session/new`,
        /// so a draft made before the user attached one cannot be used for it.
        var mcpServers: [MCPServer]
        /// The session being made, which may not exist yet.
        ///
        /// A draft is handed out the moment it is asked for, because a remembered form
        /// is shown while its runtime is still starting. Whoever needs the session —
        /// the start, or the refresh behind the form — waits here for it.
        var pending: Task<MadeSession, any Error>
    }

    struct Pending: Sendable {
        var request: PermissionRequest
        var agentID: UUID
    }

    public init(store: AgentStore,
                locations: StoreLocations,
                discovery: RuntimeDiscovery = RuntimeDiscovery(),
                launcher: (any SessionLauncher)? = nil,
                now: (@Sendable () -> Date)? = nil) {
        self.store = store
        self.locations = locations
        self.discovery = discovery
        self.launcher = launcher ?? ProcessSessionLauncher()
        self.now = now ?? { Date() }
    }

    /// Record what a handshake said about a runtime, and tell the windows if it moved.
    func noteAccount(runtimeID: String, from handshake: ACP.InitializeResult) {
        var account = RuntimeAccount(runtimeID: runtimeID, handshake: handshake)
        // Providers are asked for separately, so a previous answer is kept.
        account.providers = accounts[runtimeID]?.providers ?? []
        account.currentProviderID = accounts[runtimeID]?.currentProviderID
        guard accounts[runtimeID] != account else { return }
        accounts[runtimeID] = account
        broadcast(DaemonAPI.Notification.runtimeAccountChanged, account)
    }

    /// A runtime that just refused for want of a sign-in.
    func markNeedsSignIn(runtimeID: String) {
        var account = accounts[runtimeID] ?? RuntimeAccount(runtimeID: runtimeID)
        account.state = .needsSignIn
        account.checkedAt = Date()
        accounts[runtimeID] = account
        broadcast(DaemonAPI.Notification.runtimeAccountChanged, account)
    }

    public func account(for runtimeID: String) -> RuntimeAccount {
        accounts[runtimeID] ?? RuntimeAccount(runtimeID: runtimeID)
    }

    /// Everything known about every runtime's account, for a window that has just
    /// connected and knows nothing yet.
    public func allAccounts() -> [RuntimeAccount] {
        RuntimeCatalog.builtIn.map { account(for: $0.id) }
    }

    public func setBroadcaster(_ broadcaster: @escaping @Sendable (String, JSONValue?) -> Void) {
        self.broadcaster.set(broadcaster)
    }

    public func setConnectionCount(_ count: Int) {
        connectionCount = count
    }

    // MARK: Telling the windows

    func broadcast(_ method: String, _ value: (some Encodable)?) {
        guard broadcaster.isSet else { return }
        let params = value.flatMap { try? JSONValue.encoding($0) }
        broadcaster(method, params)
    }

    func changed(_ agent: Agent) {
        agents[agent.id] = agent
        try? saveQuietly(agent)
        broadcast(DaemonAPI.Notification.agentChanged, agent)
        // An agent changing state is what moves its project's counts. Sending the
        // project after the agent is what lets a sidebar row say a project needs you
        // in a window that is looking at a different one.
        projectChanged(forAgentIn: agent.cwd)
    }

    private func saveQuietly(_ agent: Agent) throws {
        Task { [store] in try? await store.save(agent) }
    }

    /// Append to the record first, then tell the windows. That order is the whole
    /// reason a daemon killed mid-turn still leaves something true behind.
    func record(_ kind: TranscriptEntry.Kind, for agentID: UUID) async {
        let entry = TranscriptEntry(kind: kind)
        try? await store.append(entry, for: agentID)
        if var agent = agents[agentID] {
            agent.lastActivityAt = entry.at
            agents[agentID] = agent
        }
        broadcast(DaemonAPI.Notification.agentEntry,
                  DaemonAPI.EntryNotification(agentID: agentID, entry: entry))
    }

    func move(_ agentID: UUID, on event: AgentEvent, endedReason: EndedReason? = nil) async {
        guard var agent = agents[agentID] else { return }
        guard let next = agent.state.applying(event, endedReason: agent.endedReason) else { return }
        agent.state = next
        if let endedReason { agent.endedReason = endedReason }
        // Any ending that is not the daemon dying — finished, out of tokens, stopped
        // by hand — is evidence this chat can reach the end of a turn without taking
        // the daemon with it, which is the only question the count asks. `recover`
        // sets `daemonGone` directly rather than through here, so it can never clear
        // the count on its way past.
        if next == .finished || next == .stopped, agent.endedReason != .daemonGone {
            agent.restartPickUps = 0
        }
        if next == .archived { agent.archivedReason = .byUser }
        if next == .running { agent.archivedReason = nil }
        agent.lastActivityAt = Date()
        changed(agent)
        await record(.stateChanged(next, reason: endedReason), for: agentID)

        // The whole of the lifecycle trigger surface, in the one place every state
        // change already passes through. `applying` returns nil for a transition that
        // must not happen, so nothing here can fire on a non-event.
        //
        // The run is released before anything is told, so a workflow chained off this
        // one does not collide with a run that has in fact finished.
        switch next {
        case .finished, .stopped:
            // Read the depth before the run is released: releasing it is what makes a
            // finished agent's depth unfindable, and a depth that quietly resets to
            // zero is a loop the limit never stops.
            let depth = workflowChainDepth(causedBy: agentID)
            workflowRunFinished(agentID: agentID)
            workflowsRespond(to: next == .finished ? .finished : .stopped,
                             agentID: agentID, depth: depth)
        case .waitingOnUser, .running, .archived:
            break
        }
    }

    // MARK: Reading

    public func loadFromDisk() async {
        let loaded = await store.loadAll()
        for agent in loaded.agents { agents[agent.id] = agent }
    }

    public func allAgents(includeArchived: Bool = true) -> [Agent] {
        agents.values
            .filter { includeArchived || $0.state != .archived }
            .sorted { $0.lastActivityAt > $1.lastActivityAt }
    }

    public func agent(_ id: UUID) -> Agent? { agents[id] }

    public func runtimeStatuses() -> [RuntimeStatus] {
        discovery.statuses()
    }

    public func pendingPermissionRequests() -> [PermissionRequest] {
        pendingPermissions.values.map(\.request).sorted { $0.askedAt < $1.askedAt }
    }

    // MARK: Listening to a session

    func listen(to session: ACPSession, agentID: UUID) {
        eventTasks[agentID]?.cancel()
        let stream = session.eventStream()
        eventTasks[agentID] = Task { [weak self] in
            for await event in stream {
                await self?.handle(event, agentID: agentID)
            }
        }
    }

    private func handle(_ event: ACPSessionEvent, agentID: UUID) async {
        switch event {
        case .entry(let kind):
            await record(kind, for: agentID)

        case .optionsChanged(let options):
            guard var agent = agents[agentID] else { return }
            agent.advertisedOptions = options
            for option in options {
                if let value = option.currentValue { agent.startOptions.values[option.id] = value }
            }
            changed(agent)

        case .commandsChanged(let commands):
            guard var agent = agents[agentID] else { return }
            agent.availableCommands = commands
            changed(agent)

        case .titleChanged(let title):
            guard var agent = agents[agentID] else { return }
            agent.title = title
            changed(agent)

        case .usageChanged(let usage):
            guard var agent = agents[agentID] else { return }
            agent.usage = usage
            agents[agentID] = agent
            // Usage arrives several times a turn, so it is broadcast on its own rather
            // than as a whole agent, and the record is written at the end of the turn.
            broadcast(DaemonAPI.Notification.agentUsage,
                      DaemonAPI.UsageNotification(agentID: agentID, usage: usage))

        case .planChanged(let plan):
            guard var agent = agents[agentID] else { return }
            agent.plans = Plan.applying(plan, to: agent.plans)
            changed(agent)
            await record(.planUpdated(plan), for: agentID)

        case .planRemoved(let planID):
            guard var agent = agents[agentID] else { return }
            agent.plans = Plan.withdrawing(planID, in: agent.plans)
            changed(agent)
            if let withdrawn = agent.plans.first(where: { $0.id == planID }) {
                await record(.planUpdated(withdrawn), for: agentID)
            }

        case .elicitationRequested(let request):
            await holdElicitation(request, agentID: agentID)
            workflowsRespond(to: .askedForm, agentID: agentID)

        case .elicitationWithdrawn(let requestID):
            withdrawElicitation(requestID, agentID: agentID)

        case .served(let request):
            await record(.servedRequest(request), for: agentID)

        case .permissionRequested(var request):
            request.agentID = agentID
            // Our own tool, answered by us. Nobody is asked whether the app may show
            // the app's own suggestions.
            if let option = autoAllowed(request) {
                await live[agentID]?.answerPermission(id: request.id, optionID: option.optionID)
                return
            }
            pendingPermissions[request.id] = Pending(request: request, agentID: agentID)
            await record(.permissionAsked(request), for: agentID)
            await move(agentID, on: .permissionAsked)
            broadcast(DaemonAPI.Notification.agentPermission,
                      DaemonAPI.PermissionNotification(agentID: agentID, request: request))
            // After the request is held and broadcast, so a workflow that fires on this
            // runs while the question is still outstanding.
            workflowsRespond(to: .askedPermission, agentID: agentID)

        case .processExited:
            for (id, pending) in pendingPermissions where pending.agentID == agentID {
                pendingPermissions.removeValue(forKey: id)
                broadcast(DaemonAPI.Notification.agentPermission,
                          DaemonAPI.PermissionNotification(agentID: agentID, request: nil))
            }
            if agents[agentID]?.state.holdsRuntime == true {
                await move(agentID, on: .processDied, endedReason: .processDied)
            }
            forget(agentID)

        case .standardError(let text):
            DaemonLog.shared.write("agent \(agentID) stderr: \(text)")

        case .unknownUpdate(let kind):
            DaemonLog.shared.write("agent \(agentID) sent an update we do not know: \(kind)")

        // A runtime's own extension. Not the user's conversation, so it stays out of the
        // transcript and out of agent.json, exactly like an update kind we do not know.
        case .unknownNotification(let method):
            DaemonLog.shared.write("agent \(agentID) sent a notification we do not know: \(method)")
        }
    }

    /// Let go of a runtime. The agent is not going anywhere: its session can be picked
    /// up again whenever it is next prompted.
    ///
    /// The listener is handed back rather than cancelled, and that is the whole point
    /// of returning anything at all. Cancelling a task reading an `AsyncStream` ends
    /// the stream: what is already buffered still arrives, but every event yielded
    /// afterwards is dropped on the floor with nothing to say it existed. This is
    /// called *before* the session is closed, and closing one is a conversation of
    /// its own — cancel the turn, close the session, wait for the process — so a
    /// runtime with anything left to say says it into that dead stream.
    ///
    /// Left alone, the listener finishes on its own as soon as the session ends its
    /// stream: `ACPSession.closeConnection` for a session being closed, `noteExit`
    /// for a process that died. Whoever is also ending the session should wait on
    /// what comes back; see `releaseRuntime`.
    @discardableResult
    func forget(_ agentID: UUID) -> Task<Void, Never>? {
        let draining = eventTasks.removeValue(forKey: agentID)
        live.removeValue(forKey: agentID)
        // The MCP helper the runtime started dies with it. Its token stops working
        // here at the same moment, rather than whenever that process gets round to it.
        dropAppTokens(for: agentID)
        // Nothing we started for this agent outlives it.
        Task { [weak self] in await self?.killTerminals(for: agentID) }
        Task { [store] in await store.closeTranscript(for: agentID) }
        return draining
    }

    // MARK: Shutting down

    public func shutDown() async {
        workflowTicker?.cancel()
        workflowTicker = nil
        for (_, task) in workflowRescans { task.cancel() }
        workflowRescans.removeAll()
        stopWatchingAllWorkflows()

        // Two different things, both going. The agent's terminals are 003's and are
        // killed because the agent owning them is stopping. The user's shells are this
        // feature's: each is remembered as gone with a reason, so the next window that
        // looks is told rather than handed a new shell in silence (FR-029). Neither
        // knows about the other, which is the point of keeping them apart.
        await killAllTerminals()
        shells.shutDown()
        for (_, task) in turnTasks { task.cancel() }
        for (_, session) in live { await session.end(gracePeriod: .seconds(2)) }
        // Waited on, not cancelled. Every session above has just been closed, which
        // ends its event stream, so each listener is already working through the last
        // of its buffer. The daemon going is not a reason for the final words of a
        // conversation to go with it.
        for (_, task) in eventTasks { await task.value }
        eventTasks.removeAll()
        live.removeAll()
        await store.closeAll()
    }
}

/// How a session is made. The daemon does not care whether there is a process behind
/// it, which is what lets every test drive the real daemon.
public protocol SessionLauncher: Sendable {
    func launch(runtime: Runtime, path: String, cwd: URL) throws -> ACPSession
}

public struct ProcessSessionLauncher: SessionLauncher {
    public init() {}

    public func launch(runtime: Runtime, path: String, cwd: URL) throws -> ACPSession {
        try ACPSession.launch(executable: URL(fileURLWithPath: path),
                              arguments: runtime.arguments,
                              cwd: cwd,
                              environment: LoginShellPath.environment(),
                              capabilities: .app)
    }
}
