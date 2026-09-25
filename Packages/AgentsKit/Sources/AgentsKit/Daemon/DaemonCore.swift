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
    /// How long a draft outlives the connection that asked for it (029).
    let draftGracePeriod: Duration
    /// Starts still under way, by the request id their caller sent (029). A repeat
    /// that arrives while the first is still making its session waits on this rather
    /// than making a second; one that arrives after finds the agent by
    /// `Agent.startRequestID`, which is also what survives a restart.
    var startsByRequest: [UUID: Task<UUID, any Error>] = [:]
    /// Places taken by agents being started for another agent, and not yet made
    /// (028), by project. The start's checks run before its first `await`, but making
    /// the session takes seconds of them, and a second start weighed in that time
    /// has to see the first's place as taken. In memory only: a start does not
    /// survive a restart, so neither does its reservation.
    var reservedStarts: [URL: Int] = [:]
    /// Worktree names chosen by starts that have not finished making them, as
    /// `<worktrees folder>/<name>` (030). Held the same way and for the same reason as
    /// `reservedStarts`: two starts from the same words must not both take one name.
    var reservedWorktreeNames: Set<String> = []
    var pendingPermissions: [UUID: Pending] = [:]
    /// Forms an agent is blocked on, held here for the same reason permissions are:
    /// the question can arrive while no window is open.
    var elicitations: [UUID: PendingElicitation] = [:]
    /// 021: where the person is, per connection. Held in memory and never written down —
    /// what somebody is doing right now is not a fact worth keeping, and a remembered one
    /// could only mislead the next daemon. See `DaemonCore+Attention`.
    var presences: [UUID: Presence] = [:]
    /// What has already been put in front of the person, and where.
    ///
    /// Written down since 025, in `attention.json`. It used to live and die with the
    /// process, which meant every restart — and this app restarts on every build of it —
    /// decided afresh that an outstanding need had never been delivered, and buzzed the
    /// person again about something that had not changed.
    var deliveries: [NeedID: Delivery] = [:]
    /// When each need was first seen, so a re-routed need keeps its `raisedAt`.
    ///
    /// Written down beside the deliveries and for the same reason. This is the one fact
    /// about a need that must not move, and a restart used to move it — which restarted
    /// the settling pause and the re-alert clock along with it.
    var needRaisedAt: [NeedID: Date] = [:]
    /// Banners that have to come down on a device, waiting for something to carry them.
    /// On disk in `attention.json`, so a daemon that goes before a bridge arrives hands
    /// the debt to the next one. See `DaemonCore+Attention`.
    var pendingWithdrawals: [PendingWithdrawal] = []
    /// The connections that have said they carry mail — in practice the bridge, and at
    /// most one. In memory only: a carrier is a live connection, and the next daemon
    /// learns of its own when the bridge reconnects and says so again.
    var carriers: Set<UUID> = []
    /// The last thing written to `attention.json`, so `writeAttentionIfMoved` can do
    /// nothing when nothing moved. `nil` until `loadAttention()` has read the file, and
    /// nothing is written while it is: a core that never read the notes must not
    /// overwrite them. `reconsider()` runs on every presence report from
    /// every window and device — several times a second with nobody doing anything — and
    /// an unconditional write there would be a file rewritten for no reason all day.
    var lastWrittenAttention: AttentionRecords?
    var settlingTimers: [NeedID: Task<Void, Never>] = [:]
    /// The paired devices, read from `devices.json` the first time they are wanted and
    /// written whole on every change. The daemon is the only writer. See
    /// `DaemonCore+Devices`.
    lazy var deviceStore = DeviceStore(locations: locations)
    var loadedDevices: [UUID: Device]?
    /// What has already been told to whom, read once by `loadAttention()` and written
    /// whenever it moves. See `DaemonCore+Attention`.
    lazy var attentionStore = AttentionStore(locations: locations)
    /// Where a sealed headline goes for a device the LAN cannot reach. `nil` — the
    /// daemon's own case — means it is
    /// broadcast as `mailbox/post` for the bridge to carry: the daemon has no CloudKit
    /// and must not. A test hands in a `FakeMailbox` and reads what was posted.
    let mailbox: (any Mailbox)?
    /// Posts to the mailbox in the order they were decided: a withdrawal must not
    /// overtake the banner it withdraws.
    var mailboxTail: Task<Void, Never>?
    /// The last write of an agent's record, so the next one goes after it.
    var saveTail: Task<Void, Never>?
    /// What the machine says about its own power, and the claim on its idle sleep.
    /// Injected together so a test can cross the battery floor without a laptop and
    /// assert on holds without touching the real one (024).
    let power: any PowerSource
    let wakefulness: any Wakefulness
    /// The last verdict acted on, so `reviseWakefulness` can do nothing when nothing
    /// moved. It is called from `changed(_:)`, which runs on every token of streamed
    /// output. In memory and nowhere else: a hold does not survive this process, and a
    /// remembered one could only mislead the next daemon (FR-013, FR-014).
    var lastWakeVerdict: WakeVerdict?
    /// When the current hold was taken, for `WakeState.since`. Moved only when a hold
    /// is taken, not on every revise, so it means what it says.
    var holdingSince: Date?
    /// The last power reading actually taken, so reporting the charge to a window that
    /// has just connected costs nothing. Readings happen rarely by design — see the
    /// guard in `reviseWakefulness`.
    var lastPowerReading: PowerReading?

    /// The four numbers routing turns on. Injected so a test names its own and sleeps
    /// for none of the real ones.
    let thresholds: AttentionThresholds
    /// The commands we are running for each agent.
    var terminalServices: [UUID: TerminalService] = [:]
    /// Which agent each live suggestion token speaks for. See `DaemonCore+Suggestions`.
    var appTokens: [String: UUID] = [:]
    /// Agents whose next prompt carries the `Briefing`: the few things about this app
    /// an agent is told in words. Set when a conversation starts, and again only if a
    /// runtime loses one and we have to begin a new one — the briefing lives in the
    /// runtime's history, so that is the only time it is gone.
    var needsBriefing: Set<UUID> = []
    /// The passages the person changed on a live page since the agent last took a
    /// turn, keyed by agent. Handed to the agent as a block after the person's next
    /// words, then cleared. Not persisted: the edit itself is on disk in the file,
    /// and a daemon that restarts has nothing to apologise for (022 FR-016).
    var artifactEdits: [UUID: [ArtifactEdit]] = [:]
    /// Each agent's reported edits, folded from its transcript the first time the
    /// Changes pane asks and caught up on every ask after (035). Not persisted: the
    /// transcript is the record, and folding it again costs one read.
    var reportedChanges: [UUID: HeldChanges] = [:]
    /// One folder watch per watched root, shared by every connection watching under
    /// it, and who is watching what (034). Nothing here outlives its connection.
    var fileWatches: [URL: FolderWatch] = [:]
    var fileInterests: [UUID: Set<FileInterest>] = [:]
    /// The phones and iPads that have an agent's shell open, by agent (034). A device
    /// hears a shell's output only while it is here; a window on the Mac hears them all.
    var shellWatchers: [UUID: Set<UUID>] = [:]
    /// What each agent found dead on start-up was doing when the last daemon went, held
    /// only until it has been told. See `DaemonCore+Recovery`.
    var interrupted: [UUID: AgentState] = [:]
    /// Agents being picked back up after a restart. Work in hand as far as
    /// `isHoldingAgents` is concerned, from before their runtimes exist.
    var resuming: Set<UUID> = []
    /// Agents whose next queued prompt is already on its way to a runtime. See
    /// `sendNextQueued`: without this the same words can go twice.
    var sending: Set<UUID> = []
    /// How many times each agent has been stopped or archived. A start is a long
    /// await, and one that finds this moved while it waited was overtaken by the
    /// person saying stop: it hands its runtime back rather than beginning a turn.
    var stops: [UUID: Int] = [:]
    /// What each runtime last told us about itself: signed in or not, how to sign in,
    /// which provider is answering. One per runtime, shared by every agent using it.
    var accounts: [String: RuntimeAccount] = [:]
    /// The two facts about a project that its folder cannot tell us. Everything else
    /// about a project is derived from the agents in it.
    lazy var projectStore = ProjectStore(locations: locations)
    /// The kept project records, read from disk once and held. The daemon is their
    /// only writer, and `allProjects` — which runs each time any agent changes —
    /// used to read the file every time.
    var projectRecordsCache: [URL: Project]?
    /// Clones under way, by id (027). Memory only: a clone the daemon did not live to
    /// finish is not resumed, and its staging folder is removed on the next start.
    var clones: [UUID: RunningClone] = [:]
    /// Where a clone becomes a project: the home folder, unless `AGENTS_CLONE_PARENT`
    /// says otherwise — which only tests and scratch runs do, so that trying the
    /// feature never writes into somebody's real home folder.
    var cloneParent: URL = DaemonCore.defaultCloneParent()
    /// Tests only: turns the URL a person would paste into one git can reach offline.
    /// The URL is still checked as pasted; only what git is handed changes.
    var cloneURLRewrite: (@Sendable (String) -> String)?
    /// What each runtime last advertised, so a start form does not wait for a runtime
    /// to say what it said last time. Read from disk the first time it is wanted.
    lazy var optionCache = OptionCache(locations: locations)
    /// The mode last chosen for each runtime (029).
    lazy var modeStore = ModeStore(locations: locations, now: now)
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
    /// The last cost figure each agent's runtime quoted, per currency.
    ///
    /// A runtime's cost is a **running total for its session**, not what the last turn
    /// added: the SDK's `total_cost_usd` is documented as "cumulative across turns …
    /// read the latest result rather than summing across results". So a reading is
    /// banked by its increase over the previous one, and this is the previous one.
    ///
    /// In memory rather than on the record, because it is about a live runtime session
    /// and not about the work: a reading that dropped is a session that started afresh
    /// — a resume, or a `/clear` — and the whole of that new reading is new spend on
    /// top of what the agent had already cost. That rule is what makes this safe to
    /// lose on restart, and it is also the only thing that catches a mid-session
    /// `/clear`, which no lifecycle hook would see.
    ///
    /// Keyed by the **session** that quoted it — one id per listener — not by the agent. A turn's last usage
    /// update is sent just before its reply, and can still be in the listener's buffer
    /// when the turn ends and the runtime is let go; handled then, it used to put the
    /// old process's figure back under the agent after `forget` had cleared it, and the
    /// next process's spend was banked only for what it exceeded that — often nothing.
    /// Per session, a late reading lands on its own process and nowhere else, and the
    /// entry goes when that session's listener has heard the last of it.
    var costReadings: [UUID: [String: Decimal]] = [:]
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
    /// Whether the workflow layer may act on a lifecycle event now, or has to hold it.
    ///
    /// Open by default, and closed by `Daemon.start()` for exactly the window that
    /// needs it — from before `recover()` until `startWorkflows()`. Defaulting it
    /// *open* rather than closed matters: a `DaemonCore` driven directly, which is
    /// every test and any future embedder, adopts workflows through `rescanWorkflows`
    /// and never calls `startWorkflows` at all. Defaulting closed made those queue
    /// their triggers forever with nothing to drain them — the silent failure D4 is
    /// about, reintroduced by the fix for it.
    var workflowsAreStarted = true
    /// Lifecycle events that happened before the workflow layer could act on them,
    /// kept in the order they happened.
    ///
    /// This exists because of one deliberate ordering: `Daemon.start()` runs
    /// `recover()` first and `startWorkflows()` only afterwards, so that a workflow is
    /// never fired at an agent the daemon has not yet worked out is dead. That
    /// ordering is why `recover` used to write the state by hand and go round `move`
    /// entirely — routing it through the funnel without this queue would call
    /// `workflowsRespond` before a single workflow had been read, and it would
    /// silently do nothing. That trades a bypass somebody can see for one nobody can,
    /// which is worse than the bypass.
    ///
    /// So `move` always emits. Whether the emission can be acted on now, or has to
    /// wait a moment, is the workflow layer's business and not the funnel's (FR-014).
    var deferredLifecycleEvents: [(event: WorkflowAgentEvent, agentID: UUID, depth: Int)] = []

    /// Where notifications go, in a box rather than in a stored closure.
    ///
    /// Anything that broadcasts from off the actor — a terminal's reader, say — holds
    /// the box and reads the door out of it as it sends, rather than copying whatever
    /// was set when it was made. Recovery runs before the socket is open, so a
    /// terminal made during recovery would otherwise have copied nothing and stayed
    /// mute for the rest of the daemon's life.
    let broadcaster = BroadcastBox()
    /// The other way out: to the connections a predicate picks (034). What a device
    /// watches, and the shells it has open, go this way.
    let addressed = AddressedBox()
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

    /// `BroadcastBox`'s twin, for notifications that belong to some connections only.
    public final class AddressedBox: @unchecked Sendable {
        public typealias Wanted = @Sendable (DaemonServer.ConnectionContext) -> Bool
        private let lock = NSLock()
        private var send: (@Sendable (String, JSONValue?, @escaping Wanted) -> Void)?

        var isSet: Bool { lock.withLock { send != nil } }

        func set(_ send: @escaping @Sendable (String, JSONValue?, @escaping Wanted) -> Void) {
            lock.withLock { self.send = send }
        }

        func callAsFunction(_ method: String, _ params: JSONValue?, to wanted: @escaping Wanted) {
            lock.withLock { send }?(method, params, wanted)
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
        /// Whether the session's MCP server offers the tools for starting agents (028).
        /// Fixed when the session is made, so a draft made for an agent that may not
        /// start others cannot be used for one that may, or the other way round.
        var managesAgents = true
        /// The connection that asked for it (029). `nil` for a draft the daemon made
        /// for itself — a workflow's — which no connection going can orphan.
        var connection: UUID?
        /// When that connection went. The draft is let go once the grace period has
        /// passed without anyone using it; a phone that drops and comes back inside it
        /// still finds its runtime waiting.
        var orphanedAt: Date?
    }

    struct Pending: Sendable {
        var request: PermissionRequest
        var agentID: UUID
    }

    public init(store: AgentStore,
                locations: StoreLocations,
                discovery: RuntimeDiscovery = RuntimeDiscovery(),
                launcher: (any SessionLauncher)? = nil,
                now: (@Sendable () -> Date)? = nil,
                thresholds: AttentionThresholds = .standard,
                mailbox: (any Mailbox)? = nil,
                power: (any PowerSource)? = nil,
                wakefulness: (any Wakefulness)? = nil,
                draftGracePeriod: Duration = .seconds(30)) {
        self.store = store
        self.draftGracePeriod = draftGracePeriod
        self.locations = locations
        self.discovery = discovery
        self.launcher = launcher ?? ProcessSessionLauncher(locations: locations)
        self.now = now ?? { Date() }
        self.thresholds = thresholds
        self.mailbox = mailbox
        self.power = power ?? IOKitPowerSource()
        self.wakefulness = wakefulness ?? ProcessInfoWakefulness()
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

    public func setAddressedBroadcaster(
        _ send: @escaping @Sendable (String, JSONValue?, @escaping AddressedBox.Wanted) -> Void
    ) {
        addressed.set(send)
    }

    /// Hold lifecycle events rather than acting on them, until `startWorkflows`.
    ///
    /// Called by `Daemon.start()` before `recover()`. Nothing else should need it: it
    /// exists for the one ordering where endings are discovered before any workflow
    /// has been read.
    func holdWorkflowEventsUntilStarted() {
        workflowsAreStarted = false
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

    /// Tell only the connections `wanted` picks (034).
    func send(_ method: String, _ value: (some Encodable)?, to wanted: @escaping AddressedBox.Wanted) {
        guard addressed.isSet else { return }
        let params = value.flatMap { try? JSONValue.encoding($0) }
        addressed(method, params, to: wanted)
    }

    func changed(_ agent: Agent) {
        agents[agent.id] = agent
        saveQuietly(agent)
        broadcast(DaemonAPI.Notification.agentChanged, agent)
        // An agent changing state is what moves its project's counts. Sending the
        // project after the agent is what lets a sidebar row say a project needs you
        // in a window that is looking at a different one.
        projectChanged(forAgentIn: agent.projectFolder)
        // Here and **not** in `move(_:on:)`, though that is the single transition
        // writer and the tidier-looking hook. An agent is created with
        // `agents[agent.id] = agent` directly in `start(_:)` before any transition
        // exists, so a hook on `move` alone would miss every agent's `starting`
        // moments — which FR-002 counts as work in flight.
        //
        // This runs on every token of streamed output, which is why
        // `reviseWakefulness` compares before acting and returns doing nothing when
        // nothing has moved (024 FR-001, FR-004).
        reviseWakefulness()
    }

    /// Each write waits for the one before it. Separate tasks reach the store in no
    /// promised order, and an older copy landing last is a record that says an agent
    /// is running when it finished, or still has words queued that already went — both
    /// of which the next daemon acts on.
    func saveQuietly(_ agent: Agent) {
        let previous = saveTail
        saveTail = Task { [store] in
            await previous?.value
            try? await store.save(agent)
        }
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

    /// The one way an agent's state changes.
    ///
    /// There is no `endedReason:` parameter any more, and that is the point: the reason
    /// an agent ended comes from the event that ended it, so a caller can no longer say
    /// `.stoppedByUser` and hand it a reason that contradicts itself. Everything the
    /// resulting record needs is in the `Transition` the table returns, including the
    /// rule about the pick-up count, which used to be an inline `if` here.
    func move(_ agentID: UUID, on event: AgentEvent) async {
        guard var agent = agents[agentID] else { return }
        guard let transition = agent.state.applying(event, endedReason: agent.endedReason)
        else { return }
        let next = transition.next
        agent.state = next
        // The one place the string a newer build wrote is allowed to die. Keeping it
        // past this point would write the agent back out still claiming a state it no
        // longer has — the round trip outliving the truth it was preserving.
        agent.rawState = nil
        // Held separately from `agent.endedReason` because they are different facts: an
        // agent that was already stopped and is being unarchived keeps the ending it
        // had, and the transcript line is about *this* change, not about that one. The
        // line the transcript gets is the reason this event set, or none.
        var reasonThisEventSet: EndedReason?
        switch transition.endedReason {
        case .set(let reason):
            agent.endedReason = reason
            reasonThisEventSet = reason
        case .leave:
            break
        }
        switch transition.archivedReason {
        case .set(let reason): agent.archivedReason = reason
        case .clear: agent.archivedReason = nil
        case .leave: break
        }
        if transition.clearsPickUpCount { agent.restartPickUps = 0 }
        agent.lastActivityAt = Date()
        // Unread is a fact about finishing: a chat that ends with nobody watching waits
        // to be looked at, and one that ends in front of the person does not. Any
        // other move — picked up again, stopped, archived — is not a finish, so the
        // flag goes.
        agent.isUnread = next == .finished && !isWatched(agentID)
        // Parking (040). A chat marked while its turn was in flight is parked the moment
        // that turn ends, by whatever means, and before anything is told — so the
        // ending never counts as a need and no banner goes out (FR-006). Not when a
        // restarting daemon is about to pick it back up: that turn has not ended, and
        // it parks when it does. Archiving takes the mark away, and unarchiving does
        // not put it back (FR-010). The triggers below read `next`, never the mark, so
        // a workflow sees the ending it always did (FR-015).
        switch next {
        case .finished, .stopped:
            if case .whenTurnEnds = agent.parking,
               !(event == .foundDead && agent.mayBePickedUpAfterRestart) {
                agent.parking = .parked(at: now())
                agent.isUnread = false
            }
        case .archived:
            agent.parking = nil
        case .starting, .running, .waitingOnUser:
            break
        }
        changed(agent)
        await record(.stateChanged(next, reason: reasonThisEventSet), for: agentID)

        // The whole of the lifecycle trigger surface, in the one place every state
        // change already passes through. `applying` returns nil for a transition that
        // must not happen, so nothing here can fire on a non-event.
        //
        // The run is released before anything is told, so a workflow chained off this
        // one does not collide with a run that has in fact finished.
        switch next {
        case .finished, .stopped:
            // Held back when the app is about to ask this agent how the work went.
            // That question is a turn of its own and ends of its own accord, so firing
            // here as well would run every agent-finished workflow twice per agent —
            // and the run held until the second ending is the better one anyway: by
            // then the agent's outcome is on the record for the workflow's row to show.
            if next == .finished, willAskForOutcome(agentID: agentID, reason: reasonThisEventSet) {
                break
            }
            // An agent a restarting daemon is about to bring back has not finished
            // stopping — it is about to carry on. Saying "an agent stopped" about it
            // would be false, and would race the pick-up that is seconds away (011,
            // FR-016).
            //
            // Gated on the **event**, not only on the resulting record. An agent
            // unarchived back to `stopped`/`daemonGone` also answers true to
            // `mayBePickedUpAfterRestart`, and nothing is about to pick that one up —
            // suppressing its trigger would be a silent change to what unarchiving
            // does, for a reason that does not apply to it.
            //
            // The agent that will *not* be picked back up does fire, and that is the
            // behaviour this feature adds: before it, a daemon restart fired nothing
            // at all, because recovery never reached this line.
            if next == .stopped, event == .foundDead, agent.mayBePickedUpAfterRestart {
                break
            }
            // Read the depth before the run is released: releasing it is what makes a
            // finished agent's depth unfindable, and a depth that quietly resets to
            // zero is a loop the limit never stops.
            let depth = workflowChainDepth(causedBy: agentID)
            workflowRunFinished(agentID: agentID)
            workflowsRespond(to: next == .finished ? .finished : .stopped,
                             agentID: agentID, depth: depth)
        // An agent that has started has neither finished nor stopped, so it fires
        // nothing. Named rather than folded in with `.running`, because it is not
        // running — it is about to be.
        case .starting, .waitingOnUser, .running, .archived:
            break
        }
        // Anything blocked on this agent (039). Closing is one write per blocked agent;
        // the resume it may clear is queued in that same moment and sent behind this
        // call, so this agent's own ending is not held up by another's runtime starting.
        if let how = waitEnding(for: agent, next: next, event: event,
                                reasonThisEventSet: reasonThisEventSet) {
            let at = now()
            for blocked in closeWaits(on: agentID, how: how) {
                guard let promptID = queueResume(blocked, now: at) else { continue }
                Task { await self.sendResume(blocked, promptID: promptID) }
            }
        }

        // Every way a need begins or ends is a state change or passes through one, and
        // this is the one place every state change passes through. Cheap, and it says
        // nothing unless something changed (021, FR-002).
        reconsider()
    }

    // MARK: Reading

    public func loadFromDisk() async {
        let loaded = await store.loadAll()
        for agent in loaded.agents { agents[agent.id] = seedingCost(agent) }
        // A record the rules forbid was brought to one they allow on the way in, and
        // the person is told so here, in the transcript, which is where this app
        // already explains itself.
        //
        // This is a write nobody asked for, against a convention this app otherwise
        // keeps — it does not quietly change a person's records. It is taken because
        // the alternative is worse than the bug: `loadAll` already drops a record it
        // cannot decode, and an agent somebody cannot see is one they can do nothing
        // about. Announcing it is what makes the mend honest rather than silent
        // (FR-020).
        for (id, mend) in loaded.mends {
            await record(.runtimeNote(mend.summary), for: id)
            DaemonLog.shared.write("mended agent \(id) on read: \(mend)")
            // Written back, or the mend is not a mend. Nothing else will ever save a
            // settled agent — `changed` is only reached when the agent does something
            // — so without this the same record is re-mended and re-announced on every
            // daemon start, and `record` bumping `lastActivityAt` floats it to the top
            // of the list each time.
            if let mended = agents[id] { try? await store.save(mended) }
        }
    }

    /// Give a record written before the cost was banked its total back.
    ///
    /// Every chat run before this was fixed holds its price in `usage.cost` — the last
    /// figure its runtime quoted, which is that session's running total — and an empty
    /// `costToDate`, because the banking watched the turn's reply, where no price ever
    /// arrived. The figure is right there and is the right figure, so it is seeded
    /// rather than left as a hole in every project total.
    ///
    /// Only into an empty total, so this can never touch a record that has been banked
    /// properly and can never run twice on the same one. Nothing is written here: the
    /// record is rewritten the next time the agent changes for a reason of its own,
    /// and until then the seeded value is simply what the daemon serves.
    ///
    /// Not added to `spendLedger`: the ledger is what *today* cost, and none of this
    /// was spent today. The day would be wrong for a week and then right again, which
    /// is worse than a day that only counts from here.
    private func seedingCost(_ agent: Agent) -> Agent {
        guard agent.costToDate.isEmpty, let cost = agent.usage?.cost else { return agent }
        var seeded = agent
        seeded.costToDate[cost.currency] = cost.amount
        return seeded
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
        // A fresh id per listener rather than the session's address, which the next
        // session can be handed once this one is freed.
        let reader = UUID()
        eventTasks[agentID] = Task { [weak self] in
            for await event in stream {
                await self?.handle(event, agentID: agentID, reader: reader)
            }
            // Nothing more will come from this session, so nothing more will be read.
            await self?.forgetCostReadings(reader)
        }
    }

    func forgetCostReadings(_ reader: UUID) {
        costReadings.removeValue(forKey: reader)
    }

    private func handle(_ event: ACPSessionEvent, agentID: UUID, reader: UUID) async {
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
            // The agent's own name for the work wins. Claude's adapter generates a
            // title when the turn goes idle — after the agent's last tool call — so
            // without this the name the agent just gave would be replaced a moment
            // later by one it did not choose. A runtime title still fills in until the
            // agent has named the conversation itself.
            guard !agent.titledByAgent else { return }
            agent.title = title
            changed(agent)

        case .usageChanged(let usage):
            guard var agent = agents[agentID] else { return }
            agent.usage = usage
            // The only place a cost ever arrives. The turn's own reply carries tokens
            // and no price — `claude-agent-acp` builds it from `sessionUsage()`, which
            // has no cost field at all — so banking at the end of the turn, as 010
            // research §2 chose to, banked nothing and left every agent reading
            // "Not measured". Here is where the money is.
            let spentBefore = agent.costToDate
            if let cost = usage.cost { bank(cost, into: &agent, readBy: reader) }
            agents[agentID] = agent
            // Money is written down as it is spent, not at the end of the turn. The
            // ledger already has it; a daemon killed mid-turn must not come back with
            // an agent that spent less than the day did.
            if agent.costToDate != spentBefore { saveQuietly(agent) }
            // Usage arrives several times a turn, so it is broadcast on its own rather
            // than as a whole agent, and the record is written at the end of the turn.
            broadcast(DaemonAPI.Notification.agentUsage,
                      DaemonAPI.UsageNotification(agentID: agentID, usage: usage))
            if usage.cost != nil { broadcastCostState() }

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
            await withdrawElicitation(requestID, agentID: agentID)

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
            // And the mirror of it: a tool this app wishes were gone, on a runtime that
            // would not let us take it away. The app answers its own tools yes and
            // these no, and the person is not asked either question.
            //
            // Second line, never the first. A runtime that auto-approves its own tools
            // never asks at all — Grok's configuration on this Mac does exactly that —
            // so the policy leans on the briefing for residue and treats this as the
            // catch when a runtime happens to be polite about it.
            if let refusal = autoRefused(request) {
                await live[agentID]?.answerPermission(id: request.id, optionID: refusal.option.optionID)
                await record(.runtimeNote(refusal.note), for: agentID)
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
            reconsider()

        case .processExited:
            await closeQuestionsOfAGoneRuntime(agentID)
            if agents[agentID]?.state.holdsRuntime == true {
                await move(agentID, on: .processDied)
            }
            forget(agentID)
            reconsider()

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
        // A runtime's cost reading is let go by its own listener, once it has heard the
        // last of that session — not here, where the listener may still have a reading
        // to get through. See `costReadings`.
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
        // A clone cut short is deleted on the next start, which is the same whether it
        // was stopped here or the daemon simply died (027 FR-011).
        for clone in clones.values { clone.process?.terminate() }
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
        // Every record written, in order, before the daemon goes.
        await saveTail?.value
        await store.closeAll()
        // Last, so the Mac is held for as long as there is shutting down to do. See
        // `letGoOfTheMac` for why this is not `reviseWakefulness()` (024 US2-5).
        letGoOfTheMac()
    }
}

/// How a session is made. The daemon does not care whether there is a process behind
/// it, which is what lets every test drive the real daemon.
public protocol SessionLauncher: Sendable {
    func launch(runtime: Runtime, path: String, cwd: URL) throws -> ACPSession
}

/// Two of the three places the app's tool scoping is applied are here: the arguments
/// the process is started with, and the environment it is started in. The third is the
/// `_meta` on the session, which the daemon sends once the process is talking.
///
/// It takes the root because one runtime is scoped by a file rather than by a flag, and
/// that file belongs under the daemon's own root like everything else the app writes.
public struct ProcessSessionLauncher: SessionLauncher {
    let locations: StoreLocations

    public init(locations: StoreLocations) {
        self.locations = locations
    }

    public func launch(runtime: Runtime, path: String, cwd: URL) throws -> ACPSession {
        let policy = ToolPolicyCatalog.policy(for: runtime.id)
        let environment = RuntimePolicyFiles(locations: locations)
            .environment(for: policy, onto: LoginShellPath.environment())
        return try ACPSession.launch(executable: URL(fileURLWithPath: path),
                                     arguments: runtime.arguments + policy.launchArguments,
                                     cwd: cwd,
                                     environment: environment,
                                     capabilities: .app)
    }
}
