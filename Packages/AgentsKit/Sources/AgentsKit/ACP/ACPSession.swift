import Foundation

/// What the owner of a session hears from it.
public enum ACPSessionEvent: Sendable {
    case entry(TranscriptEntry.Kind)
    case optionsChanged([ConfigOption])
    case commandsChanged([SlashCommand])
    case titleChanged(String)
    /// A typed failure that arrived while no turn was running, so there is no turn's
    /// answer to carry it (052). One arriving during a turn rides on `TurnResult.failure`.
    case sessionFailure(SessionFailure)
    /// How full the context is, sent several times a turn.
    case usageChanged(Usage)
    case planChanged(Plan)
    case planRemoved(String)
    /// Something the agent said or did from inside one of its subagents (057): the
    /// subagent's id, and the entry. Kept apart from `.entry` so the chat is the agent's.
    case subagentEntry(String, TranscriptEntry.Kind)
    /// A shell or subagent started, moved on or ended in the background (057).
    case background(BackgroundUpdate)
    /// The agent is blocked until `answerPermission` is called with one of the options.
    case permissionRequested(PermissionRequest)
    /// The agent is blocked until `answerElicitation` is called. A permission question
    /// with a shape.
    case elicitationRequested(ElicitationRequest)
    /// Answered somewhere else, or abandoned by the agent.
    case elicitationWithdrawn(UUID)
    /// The agent asked us to do something: read a file, write one, run a command.
    case served(ServedRequest)
    case processExited(status: Int32)
    case standardError(String)
    /// An update kind we do not recognise. Reported rather than silently dropped.
    case unknownUpdate(String)
    /// A notification whose method we do not recognise, which is a runtime speaking an
    /// extension of its own. Nothing to act on, but reported for the same reason as
    /// `unknownUpdate`: an agent is never quietly poorer for what it was sent.
    case unknownNotification(String)
    /// A request whose method we do not recognise, declined with `-32601`. Said out
    /// loud for the same reason: a runtime falls back quietly, and the next vendor
    /// method is otherwise invisible.
    case unknownRequest(String)
}

/// How a turn came to an end, including the case where a runtime invents a stop reason.
public struct TurnResult: Sendable {
    public var reason: EndedReason?
    public var rawStopReason: String?
    /// What this turn consumed, where the runtime reported it. The Claude adapter and
    /// Copilot do; Grok does not, and then this is nil rather than zero.
    public var usage: TurnUsage?
    /// The turn's own words said it failed, for a runtime that says so in words and then
    /// ends the turn normally (049). Nil for every other turn.
    public var runtimeError: RuntimeLaunch.TurnError?
    /// A failure the runtime reported in a shape (052, R1): from the answer's `_meta`, or
    /// from a `session_info_update` that came during the turn. An error-severity one
    /// means the turn did not do its work, whatever `reason` says.
    public var failure: SessionFailure?
    /// The latest plan window the runtime reported during the turn (052, R2). Carried on
    /// the result because the update that brought it and the turn's answer arrive by two
    /// different roads, and the answer can get there first.
    public var rateLimit: RateLimitInfo?
    /// What the turn's commands printed and what it said (064, R11), for a sandbox that
    /// could not be set up part way through it.
    public var evidence = TurnEvidence()

    public init(reason: EndedReason?, rawStopReason: String?, usage: TurnUsage? = nil,
                runtimeError: RuntimeLaunch.TurnError? = nil, failure: SessionFailure? = nil,
                rateLimit: RateLimitInfo? = nil) {
        self.rateLimit = rateLimit
        self.reason = reason
        self.rawStopReason = rawStopReason
        self.usage = usage
        self.runtimeError = runtimeError
        self.failure = failure
    }
}

public enum ACPSessionError: Error, Sendable {
    case noSession
    case sessionGone(JSONRPCError)
    case cannotResumeOrLoad
    /// The agent answered the handshake with a version we do not speak. Reported
    /// rather than carried on with: everything after this would be a guess.
    case unsupportedProtocolVersion(Int)
    /// The runtime is there and will not work until somebody signs in. `-32000`.
    case needsSignIn
    /// The runtime did not advertise the thing we were about to ask it for.
    case notSupported(String)
    /// The runtime said yes to a value for this option and is using another (#143).
    case notKept(String)
}

/// One conversation with one runtime.
///
/// Works over any line transport, so the tests drive it with a fake agent in the same
/// process and never need a network, a credential or a real CLI.
public actor ACPSession {
    /// The last `standardErrorKept` characters of the runtime's stderr (064).
    private(set) var recentStandardError = ""

    private let connection: JSONRPCConnection
    private let process: RuntimeProcess?
    private let box = SessionBox()

    /// What we tell the agent we can do. Held here because it decides what the agent
    /// will ask of us: Grok routes every file read through the client the moment this
    /// says we can serve one.
    public let capabilities: ACP.ClientCapabilities

    /// Signed in with this method when picking a conversation back up is refused as not
    /// signed in, then tried once more (046). Gemini CLI answers `session/load` with
    /// "Authentication required" until `authenticate` has been called, key in the
    /// environment or not, where `session/new` needs no such call.
    public let authMethodBeforeContinuing: String?

    public private(set) var sessionID: String?
    public private(set) var options: [ConfigOption] = []
    public private(set) var commands: [SlashCommand] = []
    public private(set) var initializeResult: ACP.InitializeResult?
    /// The last account the runtime said it was using, for a runtime that says.
    public private(set) var authStatus: AuthStatus?
    /// Cursor's todo list as it stands, so a merging update has something to merge into.
    private var todos = TodoList()
    /// Who hears `authStatus` change. A handler rather than an event, because a session
    /// only asked a question has no listener, and the account is still worth hearing.
    private var authStatusHandler: (@Sendable (AuthStatus) async -> Void)?

    /// Be told whenever the runtime says which account it is using. Set before
    /// `initialize`: the first push follows the handshake.
    public func whenAuthStatusChanges(_ handler: @escaping @Sendable (AuthStatus) async -> Void) {
        authStatusHandler = handler
    }

    /// True while a `session/load` replay is arriving. The replayed conversation is
    /// confirmation, not content: we already have the transcript, and recording it
    /// again would double every line.
    /// What the runtime needs beyond its command (049), for reading a turn that fails
    /// in words.
    private let launch: RuntimeLaunch?
    /// How long it is given (#166): the launch's, unless whoever made the session said.
    public nonisolated let deadlines: RuntimeDeadlines
    /// The agent's words in the turn under way, only while `launch` has a
    /// `turnErrorPrefix` to look for in them, and only the start of them.
    private var turnText = ""
    /// This turn's finished tool calls and words, bounded (064).
    private(set) var turnEvidence = TurnEvidence()
    /// Whether a `session/prompt` is out, so a failure reported alongside it belongs to
    /// the turn rather than to the session at large (052).
    private var turnInFlight = false
    private var turnFailure: SessionFailure?
    private var turnRateLimit: RateLimitInfo?
    /// When the runtime last said anything at all, or the app last finished serving it.
    private var lastHeard = ContinuousClock.now
    /// The turn's tool calls not yet said to have ended, by id. A tool call open is work
    /// in hand, however long it is quiet (#166).
    private var openToolCalls: Set<String> = []
    /// Requests of the runtime's the app is still answering: a question for the person, a
    /// command it asked us to run.
    private var serving = 0

    private var isReplaying = false

    /// The subagents the runtime has announced, by the session id their updates come
    /// under, with their names for the questions they ask (057).
    private var subagents: [String: String] = [:]

    /// Whose update this is: nil for the agent's own, or the subagent's id.
    ///
    /// Only a subagent the runtime announced. Any other session id is taken as the
    /// agent's, exactly as before 057: a runtime picking a conversation back up may say
    /// it under an id that is not the one we asked for, and none of that is a subagent.
    /// Both runtimes that send subagents announce one before anything it says (Claude
    /// holds a child's updates until then; Codex replays them after).
    private func owner(of params: JSONValue?) -> String? {
        guard let from = params?["sessionId"]?.stringValue, from != sessionID,
              subagents[from] != nil else { return nil }
        return from
    }

    /// The session a request or update came under, when it is not the agent's own.
    private func foreignSession(of params: JSONValue?) -> String? {
        guard let from = params?["sessionId"]?.stringValue, let sessionID, from != sessionID
        else { return nil }
        return from
    }

    /// Except when the conversation is one we never had. Adopting a session from the
    /// runtime's own list is the one case where the replay is the transcript.
    private var recordsReplay = false

    /// Whoever is waiting for a replay to have been drained, in the order they asked.
    /// Each marker coming back out of the notification stream lets one of them go, and
    /// the stream ending lets them all go. A list rather than one, because a waiter
    /// quietly dropped is a caller that never returns.
    private var notificationDrains: [CheckedContinuation<Void, Never>] = []

    public func setReplayRecorded(_ recorded: Bool) {
        recordsReplay = recorded
    }

    private var pendingPermissions: [UUID: CheckedContinuation<String?, Never>] = [:]
    private var pendingElicitations: [UUID: CheckedContinuation<ElicitationOutcome, Never>] = [:]
    /// Their id against ours, so `elicitation/complete` can find the form again.
    private var elicitationIDs: [UUID: String] = [:]
    /// Set once by the daemon so served requests can be judged against the folders the
    /// agent was actually given.
    private var folderScope = FolderScope(folders: [])
    private var fileService: FileService?
    private var terminalService: TerminalService?
    private var notificationTask: Task<Void, Never>?

    private let events: AsyncStream<ACPSessionEvent>
    private let eventsContinuation: AsyncStream<ACPSessionEvent>.Continuation

    /// The file this session's runtime was started from, when the app started it: a sign-in
    /// command that names it by its bare name is pointed back at it.
    let program: URL?

    public init(transport: any LineTransport,
                process: RuntimeProcess? = nil,
                program: URL? = nil,
                capabilities: ACP.ClientCapabilities = .none,
                launch: RuntimeLaunch? = nil,
                authMethodBeforeContinuing: String? = nil,
                deadlines: RuntimeDeadlines? = nil) {
        let box = self.box
        self.deadlines = deadlines ?? launch?.deadlines ?? .standard
        self.program = program
        self.capabilities = capabilities
        self.launch = launch
        self.authMethodBeforeContinuing = authMethodBeforeContinuing
        self.connection = JSONRPCConnection(transport: transport) { method, params in
            await box.handle(method: method, params: params)
        }
        self.process = process
        var c: AsyncStream<ACPSessionEvent>.Continuation!
        self.events = AsyncStream { c = $0 }
        self.eventsContinuation = c
        box.attach(self)
    }

    public nonisolated func eventStream() -> AsyncStream<ACPSessionEvent> { events }

    // MARK: Starting

    /// A call given this runtime's deadline for the phase it belongs to (#166). The process
    /// is left as it is: whoever asked ends it, as they end one that refused.
    private func call(_ method: String, _ params: JSONValue?,
                      within phase: RuntimeDeadlines.Phase) async throws -> JSONValue {
        let after = deadlines[phase]
        do {
            return try await connection.call(method, params, timeout: after)
        } catch is JSONRPCTimeout {
            throw RuntimeDidNotAnswer(phase: phase, after: after)
        }
    }

    /// Handshake. What we advertise is whatever this session was built with, which is
    /// a promise about what we will answer rather than a hint.
    @discardableResult
    public func initialize() async throws -> ACP.InitializeResult {
        await connection.start()
        startListening()
        let params: JSONValue = [
            "protocolVersion": .int(ACP.protocolVersion),
            "clientCapabilities": capabilities.wire,
        ]
        let result = try await call(ACP.Method.initialize, params, within: .handshake)
        var decoded = try result.decode(ACP.InitializeResult.self)
        if let program {
            decoded.authMethods = decoded.authMethods?.map { $0.naming(program: program) }
        }
        initializeResult = decoded
        guard decoded.speaksOurVersion else {
            throw ACPSessionError.unsupportedProtocolVersion(decoded.protocolVersion ?? 0)
        }
        return decoded
    }

    /// A new conversation. The session id comes back from the runtime: the protocol has
    /// no field for one of ours, and all three ignore one offered.
    @discardableResult
    public func newSession(cwd: URL,
                           additionalDirectories: [URL] = [],
                           mcpServers: [MCPServer] = [],
                           meta: JSONValue? = nil) async throws -> ACP.NewSessionResult {
        let params = sessionParams(cwd: cwd, additionalDirectories: additionalDirectories,
                                   mcpServers: mcpServers, meta: meta)
        let result = try await call(ACP.Method.newSession, params, within: .start)
        let decoded = try result.decode(ACP.NewSessionResult.self)
        sessionID = decoded.sessionId
        // Read outside the decode on purpose: a shape we cannot read inside the
        // options list costs that option, never the session.
        adoptOptions(from: result)
        return decoded
    }

    /// Pick an existing conversation back up.
    ///
    /// Resume where the runtime advertises it and load where it does not, decided by
    /// what `initialize` said rather than by which runtime this is. Copilot answers
    /// `-32601` to resume, which is the advertised behaviour rather than a fault.
    public func continueSession(id: String, cwd: URL,
                                additionalDirectories: [URL] = [],
                                mcpServers: [MCPServer] = [],
                                meta: JSONValue? = nil) async throws {
        var params = sessionParams(cwd: cwd, additionalDirectories: additionalDirectories,
                                   mcpServers: mcpServers, meta: meta)
        if case .object(var object) = params {
            object["sessionId"] = .string(id)
            params = .object(object)
        }
        let canResume = initializeResult?.supportsResume ?? false
        let canLoad = initializeResult?.supportsLoad ?? false
        guard canResume || canLoad else { throw ACPSessionError.cannotResumeOrLoad }
        do {
            try await pickUp(params, resuming: canResume)
        } catch let error as JSONRPCError where error.code == -32000 && authMethodBeforeContinuing != nil {
            // Signed in only when refused, and then once (Alex, 2026-09-25): Gemini records
            // the sign-in type in its own settings when asked to sign in, so someone who
            // never needed it is never touched.
            do {
                _ = try await call(ACP.Method.authenticate, ["methodId": .string(authMethodBeforeContinuing!)],
                                   within: .load)
                try await pickUp(params, resuming: canResume)
            } catch let error as JSONRPCError {
                throw ACPSessionError.sessionGone(error)
            }
        } catch let error as JSONRPCError {
            throw ACPSessionError.sessionGone(error)
        }
        sessionID = id
    }

    private func pickUp(_ params: JSONValue, resuming: Bool) async throws {
        if resuming {
            let result = try await call(ACP.Method.resumeSession, params, within: .load)
            adoptOptions(from: result)
        } else {
            try await load(params)
        }
    }

    /// Load, with the replay it brings suppressed until the last of it has been dealt
    /// with rather than until the answer comes back.
    ///
    /// Those are not the same moment, and the difference was a bug somebody could see.
    /// The replay arrives as notifications, handled on the reader's own task; the
    /// answer resumes this one. Clearing the flag when the answer lands therefore
    /// closes the window while the last chunk is still queued behind it, and that
    /// chunk is recorded — a resumed conversation with the end of its history written
    /// into it twice. Always the last chunk, never an earlier one, because an earlier
    /// one is never the thing still in the queue.
    ///
    /// So the window closes on the replay having been drained. The marker goes into
    /// the same stream the replay came down, once the answer is here, and the stream
    /// keeps the reader's order: everything the answer arrived behind is ahead of the
    /// marker, and hearing the marker is hearing that all of it has been handled.
    /// Ordered by construction rather than by how long anything takes.
    private func load(_ params: JSONValue) async throws {
        isReplaying = true
        defer { isReplaying = false }
        do {
            let result = try await call(ACP.Method.loadSession, params, within: .load)
            adoptOptions(from: result)
        } catch {
            // Drained on the way out too: whatever the runtime managed to replay
            // before it gave up is still in the stream, and is still not ours to keep.
            await waitForNotificationsToDrain()
            throw error
        }
        await waitForNotificationsToDrain()
    }

    /// Wait until the notification consumer has worked through everything the reader
    /// handed it before now: after a replay, and after a turn's reply. Returns at once if the connection has gone, because then
    /// nothing is coming and there is nothing to wait for.
    private func waitForNotificationsToDrain() async {
        guard connection.insertMarker() else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            notificationDrains.append(continuation)
        }
    }

    /// A marker arrived: the waiter it was put in for can go.
    private func releaseNotificationDrain() {
        guard !notificationDrains.isEmpty else { return }
        notificationDrains.removeFirst().resume()
    }

    /// No marker will arrive again. Everybody waiting for one goes.
    private func releaseAllNotificationDrains() {
        let waiting = notificationDrains
        notificationDrains.removeAll()
        for continuation in waiting { continuation.resume() }
    }

    /// What every session-making call takes. `additionalDirectories` is sent only
    /// where the runtime advertised it, because a field a runtime does not know is a
    /// refusal waiting to happen.
    ///
    /// `meta` is where the app's tool scoping rides, handed in by the daemon rather
    /// than worked out here: nothing in this file knows which runtime it is talking to,
    /// and a runtime with nothing to say sends no `_meta` at all, exactly as before.
    private func sessionParams(cwd: URL, additionalDirectories: [URL],
                               mcpServers: [MCPServer], meta: JSONValue?) -> JSONValue {
        var params: [String: JSONValue] = ["cwd": .string(cwd.path),
                                           "mcpServers": .array(mcpServers.map(\.wire))]
        if !additionalDirectories.isEmpty, initializeResult?.supportsAdditionalDirectories == true {
            params["additionalDirectories"] = .array(additionalDirectories.map { .string($0.path) })
        }
        if let meta { params["_meta"] = meta }
        return .object(params)
    }

    // MARK: Signing in, signing out, and who answers

    /// Carry out one of the runtime's own sign-in methods.
    ///
    /// A method that needs a terminal is not run here: the runtime names the command
    /// and the app shows it, because inventing that advice ourselves would be worse.
    public func authenticate(methodID: String) async throws {
        _ = try await connection.call(ACP.Method.authenticate, ["methodId": .string(methodID)])
    }

    public func logOut() async throws {
        guard initializeResult?.supportsLogout ?? false else {
            throw ACPSessionError.notSupported(ACP.Method.logout)
        }
        _ = try await connection.call(ACP.Method.logout, .object([:]))
    }

    public func providers() async throws -> ACP.ProvidersResult {
        guard initializeResult?.supportsProviders ?? false else {
            throw ACPSessionError.notSupported(ACP.Method.listProviders)
        }
        let result = try await connection.call(ACP.Method.listProviders, .object([:]))
        return try result.decode(ACP.ProvidersResult.self)
    }

    public func setProvider(id: String) async throws {
        guard initializeResult?.supportsProviders ?? false else {
            throw ACPSessionError.notSupported(ACP.Method.setProvider)
        }
        _ = try await connection.call(ACP.Method.setProvider, ["providerId": .string(id)])
    }

    public func disableProvider(id: String) async throws {
        guard initializeResult?.supportsProviders ?? false else {
            throw ACPSessionError.notSupported(ACP.Method.disableProvider)
        }
        _ = try await connection.call(ACP.Method.disableProvider, ["providerId": .string(id)])
    }

    // MARK: The allowance

    /// Grok's plan usage (`_x.ai/billing`), read as a reading. Nil from a runtime
    /// that answered but said nothing we can use; a runtime without it throws.
    public func grokAllowance(at: Date) async throws -> AllowanceReading? {
        let result = try await connection.call(ACP.Method.grokBilling, .object([:]))
        return AllowanceReading.grokBilling(result, at: at)
    }

    // MARK: The sessions a runtime is holding

    /// Every conversation this runtime has in this folder, including ones this app did
    /// not start. Paged, because a runtime may be holding a great many.
    public func listSessions(cwd: URL?) async throws -> [ACP.SessionSummary] {
        guard initializeResult?.supportsList ?? false else {
            throw ACPSessionError.notSupported(ACP.Method.list)
        }
        var summaries: [ACP.SessionSummary] = []
        var cursor: String?
        repeat {
            var params: [String: JSONValue] = [:]
            if let cwd { params["cwd"] = .string(cwd.path) }
            if let cursor { params["cursor"] = .string(cursor) }
            let result = try await connection.call(ACP.Method.list, .object(params))
            let page = try result.decode(ACP.SessionListResult.self)
            summaries += page.sessions ?? []
            cursor = page.nextCursor
        } while cursor != nil && summaries.count < 500
        return summaries
    }

    /// Branch this conversation. The original is untouched.
    ///
    /// `meta` is taken here too, and is the reason this method has a parameter it looks
    /// like it does not need: a branch is a new conversation by any other name, and it
    /// builds its own parameters rather than going through `sessionParams`, so leaving
    /// it out would have made it the one door out of the app's scoping.
    public func forkSession(cwd: URL, additionalDirectories: [URL] = [],
                            meta: JSONValue? = nil) async throws -> String {
        guard let sessionID else { throw ACPSessionError.noSession }
        guard initializeResult?.supportsFork ?? false else {
            throw ACPSessionError.notSupported(ACP.Method.forkSession)
        }
        var params: [String: JSONValue] = ["sessionId": .string(sessionID), "cwd": .string(cwd.path)]
        if !additionalDirectories.isEmpty, initializeResult?.supportsAdditionalDirectories == true {
            params["additionalDirectories"] = .array(additionalDirectories.map { .string($0.path) })
        }
        if let meta { params["_meta"] = meta }
        let result = try await connection.call(ACP.Method.forkSession, .object(params))
        return try result.decode(ACP.ForkSessionResult.self).sessionId
    }

    /// Remove a conversation from the runtime. The only thing here that cannot be
    /// undone, which is why the daemon will not do it without being told twice.
    public func deleteSession(id: String) async throws {
        guard initializeResult?.supportsDelete ?? false else {
            throw ACPSessionError.notSupported(ACP.Method.deleteSession)
        }
        _ = try await connection.call(ACP.Method.deleteSession, ["sessionId": .string(id)])
    }

    // MARK: Working

    public func prompt(_ text: String) async throws -> TurnResult {
        try await prompt([.text(text)])
    }

    /// A prompt is a list of blocks: the words, and whatever was attached to them.
    public func prompt(_ blocks: [ContentBlock]) async throws -> TurnResult {
        guard let sessionID else { throw ACPSessionError.noSession }
        let params: JSONValue = [
            "sessionId": .string(sessionID),
            "prompt": blocks.wire,
        ]
        turnText = ""
        turnEvidence = TurnEvidence()
        turnFailure = nil
        turnRateLimit = nil
        openToolCalls = []
        lastHeard = .now
        turnInFlight = true
        defer { turnInFlight = false }
        let result = try await connection.call(ACP.Method.prompt, params)
        // The reply resumes this at once, but the turn's own words, its failure and its
        // rate limit arrive as notifications, drained elsewhere. A runtime that says its
        // quota is spent in the chat (Copilot, Antigravity) sends those words just
        // before the reply, and read now they may not be in `turnText` yet: the turn
        // then looked like one that worked, about half the time (065).
        await waitForNotificationsToDrain()
        let decoded = try? result.decode(ACP.PromptResult.self)
        let raw = decoded?.stopReason
        var failure = turnFailure
        if let answered = SessionFailure.from(meta: result["_meta"]) {
            failure = failure?.superseded(by: answered) ?? answered
        }
        var turn = TurnResult(reason: raw.flatMap(EndedReason.init(stopReason:)),
                              rawStopReason: raw,
                              usage: Self.turnUsage(in: result["usage"]) ?? Self.quotaUsage(in: result["_meta"]?["quota"]),
                              runtimeError: launch?.turnError(in: turnText),
                              failure: failure,
                              rateLimit: turnRateLimit)
        turn.evidence = turnEvidence
        return turn
    }

    /// What the turn consumed, where the runtime said. Read from the raw value rather
    /// than decoded with the rest, so an unfamiliar field costs the usage and not the
    /// turn's result.
    private static func turnUsage(in value: JSONValue?) -> TurnUsage? {
        guard let value, let usage = try? value.decode(TurnUsage.self) else { return nil }
        return usage
    }

    /// Gemini's way (046, R7): no `usage`, but `_meta.quota.token_count` with its input and
    /// output tokens on every ending. Tokens only; Gemini names no cost, so none is made up.
    static func quotaUsage(in quota: JSONValue?) -> TurnUsage? {
        guard let count = quota?["token_count"],
              let input = count["input_tokens"]?.intValue,
              let output = count["output_tokens"]?.intValue else { return nil }
        // A slash command Gemini handled itself reports zeros: nothing was consumed.
        guard input + output > 0 else { return nil }
        return TurnUsage(totalTokens: input + output, inputTokens: input, outputTokens: output)
    }

    /// Stop one thing running in the background, leaving the turn and everything else
    /// alone (057). True when the runtime stopped it; false when it had already gone,
    /// which the runtime says rather than failing.
    public func stopBackgroundTask(_ id: String) async throws -> Bool {
        guard let sessionID else { throw ACPSessionError.noSession }
        guard capabilities.backgroundTasks else { throw ACPSessionError.notSupported(ACP.Method.stopAsyncTask) }
        let result = try await connection.call(ACP.Method.stopAsyncTask,
                                               ["sessionId": .string(sessionID), "asyncTaskId": .string(id)])
        return result["stopped"]?.boolValue ?? false
    }

    /// A notification: the turn's own reply comes back as `cancelled` once the runtime
    /// has stopped what it was doing.
    /// Put words into the turn that is running (`_session/steering`).
    ///
    /// Always with `idleBehavior: promptRequired`: if no turn is running the words
    /// stay ours, and go as an ordinary `session/prompt` whose turn the daemon owns.
    /// An outcome that cannot be read is `failed`, so the caller keeps the words.
    public func steer(_ blocks: [ContentBlock]) async throws -> ACP.SteeringOutcome {
        guard initializeResult?.supportsSteering ?? false else {
            throw ACPSessionError.notSupported(ACP.Method.steering)
        }
        guard let sessionID else { throw ACPSessionError.noSession }
        let params: JSONValue = [
            "sessionId": .string(sessionID),
            "prompt": blocks.wire,
            "_meta": ["steering": ["idleBehavior": "promptRequired"]],
        ]
        let result = try await connection.call(ACP.Method.steering, params)
        return (try? result.decode(ACP.SteeringResult.self))?.outcome ?? .failed
    }

    public func cancel() async {
        guard let sessionID else { return }
        try? connection.notify(ACP.Method.cancel, ["sessionId": .string(sessionID)])
    }

    /// The options a session answer carries: its `configOptions`, or, from a runtime that
    /// sends none, its older `models` and `modes` made into the same two menus (046:
    /// Gemini CLI advertises only those, and sets them with `session/set_model` and
    /// `session/set_mode`).
    private func adoptOptions(from result: JSONValue) {
        let advertised = ConfigOption.list(in: result["configOptions"])
        if !advertised.isEmpty {
            options = advertised
            olderStyle = []
            return
        }
        let older = Self.olderStyleOptions(in: result)
        if !older.isEmpty {
            options = older
            olderStyle = Set(older.map(\.id))
        }
    }

    /// The ids in `options` that are set the older way, not with `set_config_option`.
    private var olderStyle: Set<String> = []

    static let modelOption = "model"
    static let modeOption = "mode"

    /// A session answer's `models` and `modes` as options, for a runtime that advertises
    /// no `configOptions`. Keyed `model` and `mode`, in those categories, as the menus
    /// and the workflow settings already look for.
    static func olderStyleOptions(in result: JSONValue) -> [ConfigOption] {
        var made: [ConfigOption] = []
        if let modes = result["modes"], case .array(let available)? = modes["availableModes"] {
            let choices = available.compactMap { mode -> ConfigChoice? in
                guard let id = mode["id"]?.stringValue else { return nil }
                return ConfigChoice(value: .string(id), name: mode["name"]?.stringValue ?? id,
                                    description: mode["description"]?.stringValue)
            }
            if !choices.isEmpty {
                made.append(ConfigOption(id: modeOption, name: "Mode", category: "mode", type: "select",
                                         currentValue: modes["currentModeId"], options: choices))
            }
        }
        if let models = result["models"], case .array(let available)? = models["availableModels"] {
            let choices = available.compactMap { model -> ConfigChoice? in
                guard let id = model["modelId"]?.stringValue else { return nil }
                return ConfigChoice(value: .string(id), name: model["name"]?.stringValue ?? id,
                                    description: model["description"]?.stringValue)
            }
            if !choices.isEmpty {
                made.append(ConfigOption(id: modelOption, name: "Model", category: "model", type: "select",
                                         currentValue: models["currentModelId"], options: choices))
            }
        }
        return made
    }

    @discardableResult
    public func setOption(id: String, value: JSONValue) async throws -> [ConfigOption] {
        guard let sessionID else { throw ACPSessionError.noSession }
        if olderStyle.contains(id), let chosen = value.stringValue {
            let (method, key) = id == Self.modelOption ? (ACP.Method.setSessionModel, "modelId")
                                                           : (ACP.Method.setSessionMode, "modeId")
            _ = try await call(method, ["sessionId": .string(sessionID), key: .string(chosen)], within: .start)
            if let index = options.firstIndex(where: { $0.id == id }) { options[index].currentValue = value }
            // Said the way a runtime's own `config_option_update` would be: the older calls
            // answer with nothing, so the menus hear of the change from here.
            eventsContinuation.yield(.optionsChanged(options))
            return options
        }
        var params: [String: JSONValue] = ["sessionId": .string(sessionID),
                                           "configId": .string(id),
                                           "value": value]
        // A boolean option is set with its type named, which is the protocol's own
        // shape for it. Nothing sends us one unless we advertised that we take them.
        if case .bool = value { params["type"] = "boolean" }
        let result = try await call(ACP.Method.setConfigOption, .object(params), within: .start)
        let refreshed = ConfigOption.list(in: result["configOptions"])
        if !refreshed.isEmpty { options = refreshed }
        return options
    }

    /// Apply everything the user chose in the start form, in one go.
    /// Applies each remembered choice, and returns the ones the runtime refused.
    ///
    /// The model first and the mode last (#143). What a runtime offers can hang on the
    /// model: Claude's adapter has no effort and no Auto for haiku, and switching to it
    /// drops the effort and turns an Auto already set into Accept edits without an
    /// error. Set before the model, both looked taken and were not.
    @discardableResult
    public func apply(_ startOptions: StartOptions) async -> [RefusedOption] {
        var refused: [RefusedOption] = []
        for (id, value) in Self.applyOrder(startOptions.values, advertised: options) {
            // One option a runtime has since stopped offering must not stop an agent
            // starting, so a refusal here is handed back to be noted, and passed over.
            do { _ = try await setOption(id: id, value: value) } catch {
                refused.append(RefusedOption(id: id, value: value, error: error))
            }
        }
        // A mode taken and swapped for another is refused as well: Claude's adapter
        // answers Auto on a model without it with success, and Accept edits as the
        // current value. Only the mode is read back. A model may come back under its
        // full id for the alias it was set with, and that is the same model.
        if let mode = ModeMemory.modeOption(in: options), let asked = startOptions.values[mode.id],
           let current = mode.currentValue, current != asked,
           !refused.contains(where: { $0.id == mode.id }) {
            refused.append(RefusedOption(id: mode.id, value: asked,
                                         error: ACPSessionError.notKept(mode.id),
                                         instead: current))
        }
        return refused
    }

    /// The order `apply` sets options in: the model, then the rest by id, then the mode.
    static func applyOrder(_ values: [String: JSONValue],
                           advertised: [ConfigOption]) -> [(key: String, value: JSONValue)] {
        let model = WorkflowSettings.modelOption(in: advertised)?.id ?? modelOption
        let mode = ModeMemory.modeOption(in: advertised)?.id ?? modeOption
        func rank(_ id: String) -> Int { id == model ? 0 : id == mode ? 2 : 1 }
        return values.sorted { (rank($0.key), $0.key) < (rank($1.key), $1.key) }
    }

    /// A remembered choice the runtime would not take when the agent started.
    public struct RefusedOption: Sendable {
        public var id: String
        public var value: JSONValue
        public var error: any Error
        /// What the runtime put in its place, when it answered with success and another
        /// value rather than with an error.
        public var instead: JSONValue?
    }

    /// The user's answer to a question the agent is blocked on. `nil` cancels it.
    public func answerPermission(id: UUID, optionID: String?) {
        pendingPermissions.removeValue(forKey: id)?.resume(returning: optionID)
    }

    /// The user's answer to a form. Declining is an answer; the agent carries on.
    public func answerElicitation(id: UUID, outcome: ElicitationOutcome) {
        pendingElicitations.removeValue(forKey: id)?.resume(returning: outcome)
    }

    /// What this agent may reach, and the services that will serve it. Set by the
    /// daemon, because the folders belong to the agent rather than to the session.
    public func serve(scope: FolderScope, terminals: TerminalService?) {
        folderScope = scope
        fileService = FileService(scope: scope)
        terminalService = terminals
    }

    public var outstandingPermissionIDs: [UUID] { Array(pendingPermissions.keys) }

    // MARK: Ending, in pieces the extension can use

    func callClose(sessionID: String) async throws -> JSONValue {
        try await connection.call(ACP.Method.close, ["sessionId": .string(sessionID)])
    }

    /// Shut the connection and end the event stream.
    ///
    /// Three steps, in this order, and the order is the point. Closing the connection
    /// stops anything new arriving and ends the connection's own notification stream.
    /// Waiting on the reader then lets it turn everything already read off the wire
    /// into events — a runtime says its last words and ends the turn in the same
    /// breath, so at this moment that buffer holds the end of the conversation.
    /// Finishing the event stream last tells our listener there is no more, which it
    /// only hears after draining what it has.
    ///
    /// Cancelling the reader instead — which is what this used to do, first thing —
    /// ends the stream it is reading, so anything the runtime says between here and
    /// the connection actually closing is dropped with nothing to say it existed.
    /// A runtime's last words are said exactly there.
    ///
    /// The other ending is `noteExit`, for a runtime whose process dies on its own.
    /// Whichever comes first, `finish()` is idempotent and the second is a no-op.
    func closeConnection() async {
        await connection.close()
        await notificationTask?.value
        notificationTask = nil
        eventsContinuation.finish()
    }

    /// The runtime, for the extension that has to terminate it.
    var runtimeProcess: RuntimeProcess? { process }

    // MARK: Silence (#166)

    /// How long the turn under way has said nothing with nothing pending; nil when no turn
    /// is, or while a tool call is open or the app is answering one of its requests.
    public func silence() -> Duration? {
        guard turnInFlight, serving == 0, openToolCalls.isEmpty else { return nil }
        return ContinuousClock.now - lastHeard
    }

    /// A tool call opening or closing, the agent's or a subagent's. One that never says it
    /// ended keeps the turn from ever counting as silent, which errs on the side of the work.
    private func noteToolCall(_ kind: TranscriptEntry.Kind, of subagent: String?) {
        guard turnInFlight else { return }
        switch kind {
        case .toolCall(let call), .toolCallUpdate(let call):
            guard let id = call.toolCallID.map({ (subagent ?? "") + "/" + $0 }) else { return }
            if call.status == "completed" || call.status == "failed" {
                openToolCalls.remove(id)
            } else {
                openToolCalls.insert(id)
            }
        default:
            break
        }
    }

    // MARK: Incoming

    /// The command lines of calls asked to run in the background, by the call's id and
    /// by its description, until the task they start is announced. Only the last few:
    /// a task is announced straight after the call that started it.
    private var backgroundCommands: [(keys: Set<String>, command: String)] = []

    /// A tool call that says `run_in_background` and carries a `command` is a shell
    /// about to be announced without one. Keyed on those two fields, not on a runtime.
    private func noteBackgroundCommand(in update: JSONValue) {
        guard let input = update["rawInput"], input["run_in_background"]?.boolValue == true,
              let command = input["command"]?.stringValue, !command.isEmpty else { return }
        var keys: Set<String> = []
        if let id = update["toolCallId"]?.stringValue { keys.insert(id) }
        if let description = input["description"]?.stringValue { keys.insert(description) }
        guard !keys.isEmpty else { return }
        backgroundCommands.removeAll { !$0.keys.isDisjoint(with: keys) }
        backgroundCommands.append((keys, command))
        if backgroundCommands.count > 8 { backgroundCommands.removeFirst() }
    }

    private func backgroundCommand(for item: BackgroundItem) -> String? {
        let wanted = Set([item.toolCallID, item.detail, item.name].compactMap { $0 })
        guard let index = backgroundCommands.lastIndex(where: { !$0.keys.isDisjoint(with: wanted) }) else {
            return nil
        }
        return backgroundCommands.remove(at: index).command
    }

    private func startListening() {
        guard notificationTask == nil else { return }
        notificationTask = Task { [weak self] in
            guard let self else { return }
            for await notification in self.connection.incomingNotifications() {
                await self.receive(notification.method, notification.params)
            }
            // Nothing more is coming, so a marker that has not arrived never will.
            await self.releaseAllNotificationDrains()
        }
    }

    private func receive(_ method: String, _ params: JSONValue?) async {
        if method == JSONRPCConnection.markerMethod {
            // Our own marker, back out of the stream behind everything that was in it
            // when we put it there. All of that has now been through here.
            releaseNotificationDrain()
            return
        }
        lastHeard = .now
        if method == LineSplitter.cutMethod {
            // A message too long to read, left out (#209). Said in the conversation, as
            // the gap it leaves there would otherwise be a silence.
            let bytes = params?["bytes"]?.intValue ?? 0
            eventsContinuation.yield(.entry(.runtimeNote(RuntimeNote.messageCut(bytes: bytes))))
            return
        }
        if method == ACP.ClientMethod.completeElicitation {
            // Finished somewhere else. The form comes down.
            if let id = params?["elicitationId"]?.stringValue {
                for (requestID, continuation) in pendingElicitations where elicitationIDs[requestID] == id {
                    continuation.resume(returning: .cancel)
                    pendingElicitations.removeValue(forKey: requestID)
                    eventsContinuation.yield(.elicitationWithdrawn(requestID))
                }
            }
            return
        }
        if method == ACP.ExtensionMethod.authStatusUpdate, initializeResult?.pushesAuthStatus == true {
            if let status = AuthStatus(wire: params), status != authStatus {
                authStatus = status
                await authStatusHandler?(status)
            }
            return
        }
        // A notification is a method we know or a method we do not, and until now the
        // second kind left no trace at all. Something will send something new next
        // year. Nothing to act on, but it is said out loud, the way an unrecognised
        // update kind already is.
        guard method == ACP.ClientMethod.sessionUpdate else {
            eventsContinuation.yield(.unknownNotification(method))
            return
        }
        guard let update = params?["update"] else {
            eventsContinuation.yield(.unknownNotification("\(method) with no update"))
            return
        }
        let decoded = SessionUpdate.decode(update)
        noteBackgroundCommand(in: update)
        if case .background(var background) = decoded {
            guard !isReplaying || recordsReplay else { return }
            if case .spawned(var item) = background {
                item.parentID = owner(of: params)
                if item.kind == .task, item.command == nil {
                    item.command = backgroundCommand(for: item)
                }
                if item.kind == .subagent { subagents[item.id] = item.name }
                background = .spawned(item)
            }
            eventsContinuation.yield(.background(background))
            return
        }
        if let subagent = owner(of: params) {
            // A subagent's words and work are its own; its context meter, its plan and
            // its title are not the agent's, and are not taken as though they were.
            guard case .entry(let kind) = decoded, !isReplaying || recordsReplay else { return }
            if !isReplaying { noteToolCall(kind, of: subagent) }
            eventsContinuation.yield(.subagentEntry(subagent, kind))
            return
        }
        switch decoded {
        case .background:
            break
        case .entry(let kind):
            guard !isReplaying || recordsReplay else { return }
            if !isReplaying, launch?.turnErrorPrefix != nil, turnText.count < 4096,
               case .agentMessage(_, let text, _) = kind {
                turnText += text
            }
            if !isReplaying, turnInFlight { turnEvidence.take(kind) }
            if !isReplaying { noteToolCall(kind, of: nil) }
            eventsContinuation.yield(.entry(kind))
        case .options(let options):
            self.options = options
            eventsContinuation.yield(.optionsChanged(options))
        case .commands(let commands):
            self.commands = commands
            eventsContinuation.yield(.commandsChanged(commands))
        case .modeChanged(let mode):
            eventsContinuation.yield(.entry(.optionChanged(id: "mode", value: .string(mode))))
        case .usage(let usage):
            if turnInFlight, let window = usage.rateLimit { turnRateLimit = window }
            eventsContinuation.yield(.usageChanged(usage))
        case .plan(let plan):
            guard !isReplaying else { return }
            eventsContinuation.yield(.planChanged(plan))
        case .planRemoved(let id):
            eventsContinuation.yield(.planRemoved(id))
        case .title(let title):
            eventsContinuation.yield(.titleChanged(title))
        case .failure(let failure, let title):
            if let title { eventsContinuation.yield(.titleChanged(title)) }
            guard !isReplaying else { return }
            if turnInFlight {
                turnFailure = turnFailure?.superseded(by: failure) ?? failure
            } else {
                eventsContinuation.yield(.sessionFailure(failure))
            }
        case .ignored:
            break
        case .unknown(let kind):
            eventsContinuation.yield(.unknownUpdate(kind))
        }
    }

    /// Requests from the runtime.
    ///
    /// What we answer is exactly what we advertised. Anything else is declined loudly
    /// rather than left to time out, which is what the protocol asks for and what lets
    /// a runtime fall back to its own tools.
    func handleIncoming(method: String, params: JSONValue?) async -> Result<JSONValue, JSONRPCError> {
        serving += 1
        lastHeard = .now
        defer {
            serving -= 1
            lastHeard = .now
        }
        switch method {
        case ACP.ClientMethod.requestPermission:
            return await askPermission(params)
        case ACP.ClientMethod.readTextFile where capabilities.readTextFile:
            return serveFileRead(params)
        case ACP.ClientMethod.writeTextFile where capabilities.writeTextFile:
            return await serveFileWrite(params)
        case ACP.ClientMethod.createTerminal, ACP.ClientMethod.terminalOutput,
             ACP.ClientMethod.waitForTerminalExit, ACP.ClientMethod.releaseTerminal,
             ACP.ClientMethod.killTerminal:
            guard capabilities.terminal, let terminalService else {
                return .failure(.methodNotFound(method))
            }
            return await serveTerminal(method: method, params: params, service: terminalService)
        case ACP.ClientMethod.createElicitation where capabilities.elicitationForm || capabilities.elicitationURL:
            return await askElicitation(params)
        case ACP.ExtensionMethod.updateTodos where capabilities.plan:
            return takeTodos(params)
        case ACP.ExtensionMethod.askQuestion where capabilities.elicitationForm:
            return await askQuestions(params)
        default:
            eventsContinuation.yield(.unknownRequest(method))
            return .failure(.methodNotFound(method))
        }
    }

    /// Cursor's todo list, as the session's plan. Answered with `{}` whatever it held:
    /// Cursor does not wait for or read the answer, only for an error to log.
    private func takeTodos(_ params: JSONValue?) -> Result<JSONValue, JSONRPCError> {
        guard todos.apply(params) else { return .success(.object([:])) }
        // Kept through a replay but not said: the plan the daemon holds already says
        // what the replay would, which is why a replayed `plan` update is not said either.
        if !isReplaying { eventsContinuation.yield(.planChanged(todos.plan)) }
        return .success(.object([:]))
    }

    /// Cursor's questions, on the same card as a form elicitation, answered in Cursor's
    /// own shape. Empty options become free text; only a payload with no questions at
    /// all is refused.
    private func askQuestions(_ params: JSONValue?) async -> Result<JSONValue, JSONRPCError> {
        guard let request = CursorQuestion.request(from: params, agentID: UUID()) else {
            eventsContinuation.yield(.unknownRequest(ACP.ExtensionMethod.askQuestion))
            return .failure(.methodNotFound(ACP.ExtensionMethod.askQuestion))
        }
        let outcome = await withCheckedContinuation { (continuation: CheckedContinuation<ElicitationOutcome, Never>) in
            pendingElicitations[request.id] = continuation
            eventsContinuation.yield(.elicitationRequested(request))
        }
        return .success(CursorQuestion.reply(to: outcome))
    }

    // MARK: Serving what an agent asks of us

    private func serveFileRead(_ params: JSONValue?) -> Result<JSONValue, JSONRPCError> {
        guard let fileService, let path = params?["path"]?.stringValue else {
            return .failure(JSONRPCError(code: JSONRPCError.invalidParams, message: "no path"))
        }
        let outcome = fileService.read(path: path,
                                       line: params?["line"]?.intValue,
                                       limit: params?["limit"]?.intValue)
        // A read is recorded, not asked about: it changes nothing, and Grok issues
        // several of them for one small edit.
        eventsContinuation.yield(.served(ServedRequest(kind: .readFile(path: path),
                                                       outcome: outcome.record)))
        switch outcome {
        case .read(let contents): return .success(["content": .string(contents)])
        case .refused(let reason): return .failure(JSONRPCError(code: JSONRPCError.authRequired, message: reason))
        case .failed(let message): return .failure(JSONRPCError(code: JSONRPCError.resourceNotFound, message: message))
        }
    }

    private func serveFileWrite(_ params: JSONValue?) async -> Result<JSONValue, JSONRPCError> {
        guard let fileService, let path = params?["path"]?.stringValue else {
            return .failure(JSONRPCError(code: JSONRPCError.invalidParams, message: "no path"))
        }
        let contents = params?["content"]?.stringValue ?? ""
        if let refusal = fileService.refusal(forWriting: path) {
            eventsContinuation.yield(.served(ServedRequest(kind: .writeFile(path: path, byteCount: contents.utf8.count),
                                                           outcome: .refused(reason: refusal))))
            return .failure(JSONRPCError(code: JSONRPCError.authRequired, message: refusal))
        }
        // A write is a change, so it goes through the same question any other change
        // goes through, with the change itself in the question — unless the person has
        // just answered that question on the runtime's own card for this file.
        let chosen: String?
        if takeAllowedEdit(path) {
            chosen = "allow"
        } else {
            let request = PermissionRequest(agentID: UUID(),
                                            toolCall: fileService.writeToolCall(path: path, contents: contents),
                                            options: PermissionOption.allowOrReject)
            chosen = await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
                pendingPermissions[request.id] = continuation
                eventsContinuation.yield(.permissionRequested(request))
            }
        }
        guard let chosen, chosen.hasPrefix("allow") else {
            eventsContinuation.yield(.served(ServedRequest(kind: .writeFile(path: path, byteCount: contents.utf8.count),
                                                           outcome: .refused(reason: "You said no"))))
            return .failure(JSONRPCError(code: JSONRPCError.authRequired, message: "The user said no"))
        }
        let outcome = fileService.write(path: path, contents: contents)
        eventsContinuation.yield(.served(ServedRequest(kind: .writeFile(path: path, byteCount: contents.utf8.count),
                                                       outcome: outcome.record)))
        if case .failed(let message) = outcome {
            return .failure(JSONRPCError(code: JSONRPCError.internalError, message: message))
        }
        return .success(.object([:]))
    }

    private func serveTerminal(method: String, params: JSONValue?,
                               service: TerminalService) async -> Result<JSONValue, JSONRPCError> {
        do {
            switch method {
            case ACP.ClientMethod.createTerminal:
                let command = params?["command"]?.stringValue ?? ""
                let args = (params?["args"]?.arrayValue ?? []).compactMap(\.stringValue)
                let id = try await service.create(command: command,
                                                  args: args,
                                                  cwd: params?["cwd"]?.stringValue,
                                                  env: params?["env"])
                eventsContinuation.yield(.served(ServedRequest(kind: .runCommand(command: command, args: args),
                                                               outcome: .served)))
                return .success(["terminalId": .string(id)])
            case ACP.ClientMethod.terminalOutput:
                guard let id = params?["terminalId"]?.stringValue else {
                    return .failure(JSONRPCError(code: JSONRPCError.invalidParams, message: "no terminalId"))
                }
                return .success(await service.output(id: id))
            case ACP.ClientMethod.waitForTerminalExit:
                guard let id = params?["terminalId"]?.stringValue else {
                    return .failure(JSONRPCError(code: JSONRPCError.invalidParams, message: "no terminalId"))
                }
                return .success(["exitStatus": await service.waitForExit(id: id)])
            case ACP.ClientMethod.releaseTerminal:
                await service.release(id: params?["terminalId"]?.stringValue ?? "")
                return .success(.object([:]))
            case ACP.ClientMethod.killTerminal:
                await service.kill(id: params?["terminalId"]?.stringValue ?? "")
                return .success(.object([:]))
            default:
                return .failure(.methodNotFound(method))
            }
        } catch let error as TerminalService.Failure {
            eventsContinuation.yield(.served(ServedRequest(kind: .runCommand(command: params?["command"]?.stringValue ?? "",
                                                                             args: []),
                                                           outcome: .refused(reason: error.message))))
            return .failure(JSONRPCError(code: JSONRPCError.authRequired, message: error.message))
        } catch {
            return .failure(.internalError("\(error)"))
        }
    }

    private func askElicitation(_ params: JSONValue?) async -> Result<JSONValue, JSONRPCError> {
        guard let request = ElicitationRequest(wire: params, agentID: UUID()) else {
            // A form we cannot draw is declined rather than half-answered.
            return .success(["action": "decline"])
        }
        if let theirs = request.elicitationID { elicitationIDs[request.id] = theirs }
        let outcome = await withCheckedContinuation { (continuation: CheckedContinuation<ElicitationOutcome, Never>) in
            pendingElicitations[request.id] = continuation
            eventsContinuation.yield(.elicitationRequested(request))
        }
        elicitationIDs.removeValue(forKey: request.id)
        return .success(outcome.wire)
    }

    private func askPermission(_ params: JSONValue?) async -> Result<JSONValue, JSONRPCError> {
        var request = permissionRequest(from: params)
        if let foreign = foreignSession(of: params) {
            // A request is served as it arrives and a notification is not, so the
            // subagent's announcement can still be queued behind this. Everything the
            // runtime said before asking is let through first, which is how it is named.
            if subagents[foreign] == nil { await waitForNotificationsToDrain() }
            request.subagent = subagents[foreign]
        }
        let chosen = await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            pendingPermissions[request.id] = continuation
            eventsContinuation.yield(.permissionRequested(request))
        }
        guard let chosen else {
            return .success(["outcome": ["outcome": "cancelled"]])
        }
        noteAllowedEdit(request, chosen: chosen)
        return .success(["outcome": ["outcome": "selected", "optionId": .string(chosen)]])
    }

    /// An edit the person just allowed on the runtime's own card, by the file it names
    /// (049, T025a). Antigravity asks "Run client_create_file?" with the diff, and then
    /// writes through `fs/write_text_file`; asking again there is the same question twice.
    /// Only an edit, only with a diff or location naming the file, and only once.
    private var allowedEdits: [String: ContinuousClock.Instant] = [:]
    static let allowedEditWindow: Duration = .seconds(60)

    private func noteAllowedEdit(_ request: PermissionRequest, chosen: String) {
        let kind = request.options.first { $0.optionID == chosen }?.kind
        guard kind == .allowOnce || kind == .allowAlways || (kind == nil && chosen.hasPrefix("allow")) else { return }
        let diffs = request.toolCall.content.compactMap { content -> String? in
            if case .diff(let diff) = content { return diff.path } else { return nil }
        }
        let named = request.toolCall.kind == "edit" ? diffs + request.toolCall.locations.map(\.path) : diffs
        for path in named { allowedEdits[Self.samePath(path)] = .now }
    }

    /// Whether this write was already allowed on the runtime's own card, which it then uses up.
    private func takeAllowedEdit(_ path: String) -> Bool {
        let key = Self.samePath(path)
        guard let at = allowedEdits.removeValue(forKey: key) else { return false }
        return ContinuousClock.now - at < Self.allowedEditWindow
    }

    /// `/tmp/x` and `/private/tmp/x` are one file.
    static func samePath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    public var outstandingElicitationIDs: [UUID] { Array(pendingElicitations.keys) }

    private func permissionRequest(from params: JSONValue?) -> PermissionRequest {
        let toolCallValue = params?["toolCall"]
        let toolCall = ToolCall(toolCallID: toolCallValue?["toolCallId"]?.stringValue,
                                title: toolCallValue?["title"]?.stringValue ?? "Do something",
                                name: toolCallValue?["name"]?.stringValue
                                    ?? toolCallValue?["_meta"]?["x.ai/tool"]?["name"]?.stringValue,
                                kind: toolCallValue?["kind"]?.stringValue,
                                status: toolCallValue?["status"]?.stringValue,
                                rawInput: toolCallValue?["rawInput"],
                                rawOutput: toolCallValue?["rawOutput"],
                                raw: toolCallValue)
        let options = (params?["options"]?.arrayValue ?? []).compactMap { option -> PermissionOption? in
            guard let id = option["optionId"]?.stringValue else { return nil }
            return PermissionOption(optionID: id,
                                    name: option["name"]?.stringValue ?? id,
                                    kind: .init(wire: option["kind"]?.stringValue))
        }
        return PermissionRequest(agentID: UUID(), toolCall: toolCall, options: options)
    }

    func note(standardError: String) {
        recentStandardError = String((recentStandardError + standardError).suffix(Self.standardErrorKept))
        eventsContinuation.yield(.standardError(standardError))
    }

    /// How much of what the runtime printed to stderr is kept (064): enough for the lines a
    /// runtime says before it exits, such as Grok refusing to start without its sandbox.
    static let standardErrorKept = 8 * 1024

    /// The last of the runtime's stderr, after giving a process that has just failed a
    /// moment to finish saying why: its words arrive on their own pipe, and can land just
    /// after the failure they explain.
    public func standardErrorTail(settling: Duration = .milliseconds(300)) async -> String {
        if settling > .zero { try? await Task.sleep(for: settling) }
        return recentStandardError
    }

    func noteExit(status: Int32) {
        for (_, continuation) in pendingPermissions { continuation.resume(returning: nil) }
        pendingPermissions.removeAll()
        for (_, continuation) in pendingElicitations { continuation.resume(returning: .cancel) }
        pendingElicitations.removeAll()
        releaseAllNotificationDrains()
        eventsContinuation.yield(.processExited(status: status))
        eventsContinuation.finish()
        Task { await letGoOfTheGoneProcess() }
    }

    /// How long a runtime that has died is given for the last of its output to be read.
    /// Its stdout reaches the end at once unless something it started still holds it.
    static let lastWordsAfterExit: Duration = .seconds(2)

    /// A runtime that dies by itself is never `end`ed: the daemon only forgets it. So
    /// what `end` would let go of is let go of here (#163): the connection, which fails
    /// a turn still waiting on it, and the pipes.
    ///
    /// The connection is closed once its reader has reached the end of stdout, so
    /// whatever the runtime said before dying is still read; or after a short wait, for
    /// a child of the runtime (npx's node) that outlives it holding stdout open, which
    /// would otherwise leave the turn waiting for good.
    func letGoOfTheGoneProcess() async {
        let deadline = ContinuousClock.now.advanced(by: Self.lastWordsAfterExit)
        while !connection.isClosed, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        await closeConnection()
        process?.cleanUp()
    }
}

/// Lets the connection's handler reach the actor that owns it, which does not exist yet
/// when the connection is made.
final class SessionBox: @unchecked Sendable {
    private let lock = NSLock()
    private weak var session: ACPSession?

    func attach(_ session: ACPSession) {
        lock.lock(); defer { lock.unlock() }
        self.session = session
    }

    private var current: ACPSession? {
        lock.lock(); defer { lock.unlock() }
        return session
    }

    func handle(method: String, params: JSONValue?) async -> Result<JSONValue, JSONRPCError> {
        guard let session = current else { return .failure(.methodNotFound(method)) }
        return await session.handleIncoming(method: method, params: params)
    }

    func noteExit(status: Int32) async {
        await current?.noteExit(status: status)
    }

    func note(standardError: String) async {
        await current?.note(standardError: standardError)
    }
}

/// What one turn's commands printed and what it said, kept while it runs (064, R11): where
/// a sandbox that could not be set up shows up, since the runtime carries on after it.
public struct TurnEvidence: Sendable, Hashable {
    /// Each finished tool call's output, and whether it completed doing work: a command
    /// or an edit, not a search or the app's own tools, which change nothing to repeat.
    public var outputs: [(didWork: Bool, text: String)] = []
    public var reply = ""
    private var seen: Set<String> = []

    public init() {}

    public static func == (a: TurnEvidence, b: TurnEvidence) -> Bool {
        a.reply == b.reply && a.outputs.map(\.text) == b.outputs.map(\.text)
    }
    public func hash(into hasher: inout Hasher) { hasher.combine(reply) }

    mutating func take(_ kind: TranscriptEntry.Kind) {
        switch kind {
        case .toolCall(let call), .toolCallUpdate(let call):
            guard call.status == "completed" || call.status == "failed",
                  let id = call.toolCallID, seen.insert(id).inserted, outputs.count < 200 else { return }
            let changes = ["execute", "edit", "delete", "move"].contains(call.kind ?? "")
            outputs.append((call.status == "completed" && changes, String(call.printedText.suffix(8 * 1024))))
        case .agentMessage(_, let text, _):
            reply = String((reply + text).suffix(8 * 1024))
        default:
            break
        }
    }
}
