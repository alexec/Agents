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
    var suggestionTokens: [String: UUID] = [:]
    /// The two facts about a project that its folder cannot tell us. Everything else
    /// about a project is derived from the agents in it.
    lazy var projectStore = ProjectStore(locations: locations)
    /// What each runtime last told us about itself: signed in or not, how to sign in,
    /// which provider is answering. One per runtime, shared by every agent using it.
    var accounts: [String: RuntimeAccount] = [:]

    var broadcaster: (@Sendable (String, JSONValue?) -> Void)?
    var connectionCount = 0

    /// The user's shells, one per agent. Not the agent's terminals, which are 003's.
    /// Held here so a build outlives the window that started it (FR-026).
    let shells = ShellHost()

    struct Draft: Sendable {
        var runtimeID: String
        var cwd: URL
        var session: ACPSession
        var sessionID: String
        /// What this session was made with. MCP servers are only read at `session/new`,
        /// so a draft made before the user attached one cannot be used for it.
        var mcpServers: [MCPServer]
        /// Minted with the session, bound to the agent once the start makes one.
        var suggestionToken: String
    }

    struct Pending: Sendable {
        var request: PermissionRequest
        var agentID: UUID
    }

    public init(store: AgentStore,
                locations: StoreLocations,
                discovery: RuntimeDiscovery = RuntimeDiscovery(),
                launcher: (any SessionLauncher)? = nil) {
        self.store = store
        self.locations = locations
        self.discovery = discovery
        self.launcher = launcher ?? ProcessSessionLauncher()
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
        self.broadcaster = broadcaster
    }

    public func setConnectionCount(_ count: Int) {
        connectionCount = count
    }

    // MARK: Telling the windows

    func broadcast(_ method: String, _ value: (some Encodable)?) {
        guard let broadcaster else { return }
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
        if next == .archived { agent.archivedReason = .byUser }
        if next == .running { agent.archivedReason = nil }
        agent.lastActivityAt = Date()
        changed(agent)
        await record(.stateChanged(next, reason: endedReason), for: agentID)
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
        }
    }

    /// Let go of a runtime. The agent is not going anywhere: its session can be picked
    /// up again whenever it is next prompted.
    func forget(_ agentID: UUID) {
        eventTasks.removeValue(forKey: agentID)?.cancel()
        live.removeValue(forKey: agentID)
        // The MCP helper the runtime started dies with it. Its token stops working
        // here at the same moment, rather than whenever that process gets round to it.
        dropSuggestionTokens(for: agentID)
        // Nothing we started for this agent outlives it.
        Task { [weak self] in await self?.killTerminals(for: agentID) }
        Task { [store] in await store.closeTranscript(for: agentID) }
    }

    // MARK: Shutting down

    public func shutDown() async {
        // Two different things, both going. The agent's terminals are 003's and are
        // killed because the agent owning them is stopping. The user's shells are this
        // feature's: each is remembered as gone with a reason, so the next window that
        // looks is told rather than handed a new shell in silence (FR-029). Neither
        // knows about the other, which is the point of keeping them apart.
        await killAllTerminals()
        shells.shutDown()
        for (_, task) in turnTasks { task.cancel() }
        for (_, session) in live { await session.end(gracePeriod: .seconds(2)) }
        for (_, task) in eventTasks { task.cancel() }
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
