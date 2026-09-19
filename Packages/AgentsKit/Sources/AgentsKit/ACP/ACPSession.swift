import Foundation

/// What the owner of a session hears from it.
public enum ACPSessionEvent: Sendable {
    case entry(TranscriptEntry.Kind)
    case optionsChanged([ConfigOption])
    case commandsChanged([SlashCommand])
    case titleChanged(String)
    /// How full the context is, sent several times a turn.
    case usageChanged(Usage)
    case planChanged(Plan)
    case planRemoved(String)
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
}

/// How a turn came to an end, including the case where a runtime invents a stop reason.
public struct TurnResult: Sendable {
    public var reason: EndedReason?
    public var rawStopReason: String?
    /// What this turn consumed, where the runtime reported it. The Claude adapter and
    /// Copilot do; Grok does not, and then this is nil rather than zero.
    public var usage: TurnUsage?

    public init(reason: EndedReason?, rawStopReason: String?, usage: TurnUsage? = nil) {
        self.reason = reason
        self.rawStopReason = rawStopReason
        self.usage = usage
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
}

/// One conversation with one runtime.
///
/// Works over any line transport, so the tests drive it with a fake agent in the same
/// process and never need a network, a credential or a real CLI.
public actor ACPSession {
    private let connection: JSONRPCConnection
    private let process: RuntimeProcess?
    private let box = SessionBox()

    /// What we tell the agent we can do. Held here because it decides what the agent
    /// will ask of us: Grok routes every file read through the client the moment this
    /// says we can serve one.
    public let capabilities: ACP.ClientCapabilities

    public private(set) var sessionID: String?
    public private(set) var options: [ConfigOption] = []
    public private(set) var commands: [SlashCommand] = []
    public private(set) var initializeResult: ACP.InitializeResult?

    /// True while a `session/load` replay is arriving. The replayed conversation is
    /// confirmation, not content: we already have the transcript, and recording it
    /// again would double every line.
    private var isReplaying = false

    /// Except when the conversation is one we never had. Adopting a session from the
    /// runtime's own list is the one case where the replay is the transcript.
    private var recordsReplay = false

    /// Whoever is waiting for a replay to have been drained, in the order they asked.
    /// Each marker coming back out of the notification stream lets one of them go, and
    /// the stream ending lets them all go. A list rather than one, because a waiter
    /// quietly dropped is a caller that never returns.
    private var replayDrains: [CheckedContinuation<Void, Never>] = []

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

    public init(transport: any LineTransport,
                process: RuntimeProcess? = nil,
                capabilities: ACP.ClientCapabilities = .none) {
        let box = self.box
        self.capabilities = capabilities
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
        let result = try await connection.call(ACP.Method.initialize, params)
        let decoded = try result.decode(ACP.InitializeResult.self)
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
                           mcpServers: [MCPServer] = []) async throws -> ACP.NewSessionResult {
        let params = sessionParams(cwd: cwd, additionalDirectories: additionalDirectories,
                                   mcpServers: mcpServers)
        let result = try await connection.call(ACP.Method.newSession, params)
        let decoded = try result.decode(ACP.NewSessionResult.self)
        sessionID = decoded.sessionId
        // Read outside the decode on purpose: a shape we cannot read inside the
        // options list costs that option, never the session.
        options = ConfigOption.list(in: result["configOptions"])
        return decoded
    }

    /// Pick an existing conversation back up.
    ///
    /// Resume where the runtime advertises it and load where it does not, decided by
    /// what `initialize` said rather than by which runtime this is. Copilot answers
    /// `-32601` to resume, which is the advertised behaviour rather than a fault.
    public func continueSession(id: String, cwd: URL,
                                additionalDirectories: [URL] = [],
                                mcpServers: [MCPServer] = []) async throws {
        var params = sessionParams(cwd: cwd, additionalDirectories: additionalDirectories,
                                   mcpServers: mcpServers)
        if case .object(var object) = params {
            object["sessionId"] = .string(id)
            params = .object(object)
        }
        let canResume = initializeResult?.supportsResume ?? false
        let canLoad = initializeResult?.supportsLoad ?? false
        guard canResume || canLoad else { throw ACPSessionError.cannotResumeOrLoad }

        do {
            if canResume {
                _ = try await connection.call(ACP.Method.resumeSession, params)
            } else {
                try await load(params)
            }
        } catch let error as JSONRPCError {
            throw ACPSessionError.sessionGone(error)
        }
        sessionID = id
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
            _ = try await connection.call(ACP.Method.loadSession, params)
        } catch {
            // Drained on the way out too: whatever the runtime managed to replay
            // before it gave up is still in the stream, and is still not ours to keep.
            await waitForReplayToDrain()
            throw error
        }
        await waitForReplayToDrain()
    }

    /// Wait until the notification consumer has worked through everything the reader
    /// handed it before now. Returns at once if the connection has gone, because then
    /// nothing is coming and there is nothing to wait for.
    private func waitForReplayToDrain() async {
        guard connection.insertMarker() else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            replayDrains.append(continuation)
        }
    }

    /// A marker arrived: the waiter it was put in for can go.
    private func releaseReplayDrain() {
        guard !replayDrains.isEmpty else { return }
        replayDrains.removeFirst().resume()
    }

    /// No marker will arrive again. Everybody waiting for one goes.
    private func releaseAllReplayDrains() {
        let waiting = replayDrains
        replayDrains.removeAll()
        for continuation in waiting { continuation.resume() }
    }

    /// What every session-making call takes. `additionalDirectories` is sent only
    /// where the runtime advertised it, because a field a runtime does not know is a
    /// refusal waiting to happen.
    private func sessionParams(cwd: URL, additionalDirectories: [URL],
                               mcpServers: [MCPServer]) -> JSONValue {
        var params: [String: JSONValue] = ["cwd": .string(cwd.path),
                                           "mcpServers": .array(mcpServers.map(\.wire))]
        if !additionalDirectories.isEmpty, initializeResult?.supportsAdditionalDirectories == true {
            params["additionalDirectories"] = .array(additionalDirectories.map { .string($0.path) })
        }
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
    public func forkSession(cwd: URL, additionalDirectories: [URL] = []) async throws -> String {
        guard let sessionID else { throw ACPSessionError.noSession }
        guard initializeResult?.supportsFork ?? false else {
            throw ACPSessionError.notSupported(ACP.Method.forkSession)
        }
        var params: [String: JSONValue] = ["sessionId": .string(sessionID), "cwd": .string(cwd.path)]
        if !additionalDirectories.isEmpty, initializeResult?.supportsAdditionalDirectories == true {
            params["additionalDirectories"] = .array(additionalDirectories.map { .string($0.path) })
        }
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
        let result = try await connection.call(ACP.Method.prompt, params)
        let decoded = try? result.decode(ACP.PromptResult.self)
        let raw = decoded?.stopReason
        return TurnResult(reason: raw.flatMap(EndedReason.init(stopReason:)),
                          rawStopReason: raw,
                          usage: Self.turnUsage(in: result["usage"]))
    }

    /// What the turn consumed, where the runtime said. Read from the raw value rather
    /// than decoded with the rest, so an unfamiliar field costs the usage and not the
    /// turn's result.
    private static func turnUsage(in value: JSONValue?) -> TurnUsage? {
        guard let value, let usage = try? value.decode(TurnUsage.self) else { return nil }
        return usage
    }

    /// A notification: the turn's own reply comes back as `cancelled` once the runtime
    /// has stopped what it was doing.
    public func cancel() async {
        guard let sessionID else { return }
        try? connection.notify(ACP.Method.cancel, ["sessionId": .string(sessionID)])
    }

    @discardableResult
    public func setOption(id: String, value: JSONValue) async throws -> [ConfigOption] {
        guard let sessionID else { throw ACPSessionError.noSession }
        var params: [String: JSONValue] = ["sessionId": .string(sessionID),
                                           "configId": .string(id),
                                           "value": value]
        // A boolean option is set with its type named, which is the protocol's own
        // shape for it. Nothing sends us one unless we advertised that we take them.
        if case .bool = value { params["type"] = "boolean" }
        let result = try await connection.call(ACP.Method.setConfigOption, .object(params))
        let refreshed = ConfigOption.list(in: result["configOptions"])
        if !refreshed.isEmpty { options = refreshed }
        return options
    }

    /// Apply everything the user chose in the start form, in one go.
    public func apply(_ startOptions: StartOptions) async {
        for (id, value) in startOptions.values {
            // One option a runtime has since stopped offering must not stop an agent
            // starting, so a refusal here is noted and passed over.
            _ = try? await setOption(id: id, value: value)
        }
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

    // MARK: Incoming

    private func startListening() {
        guard notificationTask == nil else { return }
        notificationTask = Task { [weak self] in
            guard let self else { return }
            for await notification in await self.connection.incomingNotifications() {
                await self.receive(notification.method, notification.params)
            }
            // Nothing more is coming, so a marker that has not arrived never will.
            await self.releaseAllReplayDrains()
        }
    }

    private func receive(_ method: String, _ params: JSONValue?) {
        if method == JSONRPCConnection.markerMethod {
            // Our own marker, back out of the stream behind everything that was in it
            // when we put it there. All of that has now been through here.
            releaseReplayDrain()
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
        // A notification is a method we know or a method we do not, and until now the
        // second kind left no trace at all. Cursor sends `cursor/update_todos` and two
        // others; something else will send something else next year. Nothing to act on,
        // but it is said out loud, the way an unrecognised update kind already is.
        guard method == ACP.ClientMethod.sessionUpdate else {
            eventsContinuation.yield(.unknownNotification(method))
            return
        }
        guard let update = params?["update"] else {
            eventsContinuation.yield(.unknownNotification("\(method) with no update"))
            return
        }
        switch SessionUpdate.decode(update) {
        case .entry(let kind):
            guard !isReplaying || recordsReplay else { return }
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
            eventsContinuation.yield(.usageChanged(usage))
        case .plan(let plan):
            guard !isReplaying else { return }
            eventsContinuation.yield(.planChanged(plan))
        case .planRemoved(let id):
            eventsContinuation.yield(.planRemoved(id))
        case .title(let title):
            eventsContinuation.yield(.titleChanged(title))
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
        default:
            return .failure(.methodNotFound(method))
        }
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
        // goes through, with the change itself in the question.
        let request = PermissionRequest(agentID: UUID(),
                                        toolCall: fileService.writeToolCall(path: path, contents: contents),
                                        options: PermissionOption.allowOrReject)
        let chosen = await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            pendingPermissions[request.id] = continuation
            eventsContinuation.yield(.permissionRequested(request))
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
        let request = permissionRequest(from: params)
        let chosen = await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            pendingPermissions[request.id] = continuation
            eventsContinuation.yield(.permissionRequested(request))
        }
        guard let chosen else {
            return .success(["outcome": ["outcome": "cancelled"]])
        }
        return .success(["outcome": ["outcome": "selected", "optionId": .string(chosen)]])
    }

    public var outstandingElicitationIDs: [UUID] { Array(pendingElicitations.keys) }

    private func permissionRequest(from params: JSONValue?) -> PermissionRequest {
        let toolCallValue = params?["toolCall"]
        let toolCall = ToolCall(toolCallID: toolCallValue?["toolCallId"]?.stringValue,
                                title: toolCallValue?["title"]?.stringValue ?? "Do something",
                                kind: toolCallValue?["kind"]?.stringValue,
                                status: toolCallValue?["status"]?.stringValue,
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
        eventsContinuation.yield(.standardError(standardError))
    }

    func noteExit(status: Int32) {
        for (_, continuation) in pendingPermissions { continuation.resume(returning: nil) }
        pendingPermissions.removeAll()
        for (_, continuation) in pendingElicitations { continuation.resume(returning: .cancel) }
        pendingElicitations.removeAll()
        releaseAllReplayDrains()
        eventsContinuation.yield(.processExited(status: status))
        eventsContinuation.finish()
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
