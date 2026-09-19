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

    var broadcaster: (@Sendable (String, JSONValue?) -> Void)?
    var connectionCount = 0

    struct Draft: Sendable {
        var runtimeID: String
        var cwd: URL
        var session: ACPSession
        var sessionID: String
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
            for option in options {
                if let value = option.currentValue { agent.startOptions.values[option.id] = value }
            }
            changed(agent)

        case .titleChanged(let title):
            guard var agent = agents[agentID] else { return }
            agent.title = title
            changed(agent)

        case .permissionRequested(var request):
            request.agentID = agentID
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
        Task { [store] in await store.closeTranscript(for: agentID) }
    }

    // MARK: Shutting down

    public func shutDown() async {
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
                              environment: LoginShellPath.environment())
    }
}
