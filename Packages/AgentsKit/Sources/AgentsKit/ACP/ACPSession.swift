import Foundation

/// What the owner of a session hears from it.
public enum ACPSessionEvent: Sendable {
    case entry(TranscriptEntry.Kind)
    case optionsChanged([ConfigOption])
    case titleChanged(String)
    /// The agent is blocked until `answerPermission` is called with one of the options.
    case permissionRequested(PermissionRequest)
    case processExited(status: Int32)
    case standardError(String)
    /// An update kind we do not recognise. Reported rather than silently dropped.
    case unknownUpdate(String)
}

/// How a turn came to an end, including the case where a runtime invents a stop reason.
public struct TurnResult: Sendable {
    public var reason: EndedReason?
    public var rawStopReason: String?

    public init(reason: EndedReason?, rawStopReason: String?) {
        self.reason = reason
        self.rawStopReason = rawStopReason
    }
}

public enum ACPSessionError: Error, Sendable {
    case noSession
    case sessionGone(JSONRPCError)
    case cannotResumeOrLoad
}

/// One conversation with one runtime.
///
/// Works over any line transport, so the tests drive it with a fake agent in the same
/// process and never need a network, a credential or a real CLI.
public actor ACPSession {
    private let connection: JSONRPCConnection
    private let process: RuntimeProcess?
    private let box = SessionBox()

    public private(set) var sessionID: String?
    public private(set) var options: [ConfigOption] = []
    public private(set) var initializeResult: ACP.InitializeResult?

    /// True while a `session/load` replay is arriving. The replayed conversation is
    /// confirmation, not content: we already have the transcript, and recording it
    /// again would double every line.
    private var isReplaying = false

    private var pendingPermissions: [UUID: CheckedContinuation<String?, Never>] = [:]
    private var notificationTask: Task<Void, Never>?

    private let events: AsyncStream<ACPSessionEvent>
    private let eventsContinuation: AsyncStream<ACPSessionEvent>.Continuation

    public init(transport: any LineTransport, process: RuntimeProcess? = nil) {
        let box = self.box
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

    /// Handshake. Advertises no client file or terminal capabilities, so each runtime
    /// uses its own tools, which is what all three do anyway.
    @discardableResult
    public func initialize() async throws -> ACP.InitializeResult {
        await connection.start()
        startListening()
        let params: JSONValue = [
            "protocolVersion": .int(ACP.protocolVersion),
            "clientCapabilities": [
                "fs": ["readTextFile": false, "writeTextFile": false],
                "terminal": false,
            ],
        ]
        let result = try await connection.call(ACP.Method.initialize, params)
        let decoded = try result.decode(ACP.InitializeResult.self)
        initializeResult = decoded
        return decoded
    }

    /// A new conversation. The session id comes back from the runtime: the protocol has
    /// no field for one of ours, and all three ignore one offered.
    @discardableResult
    public func newSession(cwd: URL) async throws -> ACP.NewSessionResult {
        let params: JSONValue = ["cwd": .string(cwd.path), "mcpServers": []]
        let result = try await connection.call(ACP.Method.newSession, params)
        let decoded = try result.decode(ACP.NewSessionResult.self)
        sessionID = decoded.sessionId
        options = decoded.configOptions ?? []
        return decoded
    }

    /// Pick an existing conversation back up.
    ///
    /// Resume where the runtime advertises it and load where it does not, decided by
    /// what `initialize` said rather than by which runtime this is. Copilot answers
    /// `-32601` to resume, which is the advertised behaviour rather than a fault.
    public func continueSession(id: String, cwd: URL) async throws {
        let params: JSONValue = ["sessionId": .string(id), "cwd": .string(cwd.path), "mcpServers": []]
        let canResume = initializeResult?.supportsResume ?? false
        let canLoad = initializeResult?.supportsLoad ?? false
        guard canResume || canLoad else { throw ACPSessionError.cannotResumeOrLoad }

        do {
            if canResume {
                _ = try await connection.call(ACP.Method.resumeSession, params)
            } else {
                isReplaying = true
                defer { isReplaying = false }
                _ = try await connection.call(ACP.Method.loadSession, params)
            }
        } catch let error as JSONRPCError {
            throw ACPSessionError.sessionGone(error)
        }
        sessionID = id
    }

    // MARK: Working

    public func prompt(_ text: String) async throws -> TurnResult {
        guard let sessionID else { throw ACPSessionError.noSession }
        let params: JSONValue = [
            "sessionId": .string(sessionID),
            "prompt": [["type": "text", "text": .string(text)]],
        ]
        let result = try await connection.call(ACP.Method.prompt, params)
        let raw = (try? result.decode(ACP.PromptResult.self))?.stopReason
        return TurnResult(reason: raw.flatMap(EndedReason.init(stopReason:)), rawStopReason: raw)
    }

    /// A notification: the turn's own reply comes back as `cancelled` once the runtime
    /// has stopped what it was doing.
    public func cancel() async {
        guard let sessionID else { return }
        try? await connection.notify(ACP.Method.cancel, ["sessionId": .string(sessionID)])
    }

    @discardableResult
    public func setOption(id: String, value: JSONValue) async throws -> [ConfigOption] {
        guard let sessionID else { throw ACPSessionError.noSession }
        let params: JSONValue = ["sessionId": .string(sessionID), "configId": .string(id), "value": value]
        let result = try await connection.call(ACP.Method.setConfigOption, params)
        if let refreshed = (try? result.decode(ACP.SetConfigOptionResult.self))?.configOptions {
            options = refreshed
        }
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

    public var outstandingPermissionIDs: [UUID] { Array(pendingPermissions.keys) }

    // MARK: Ending, in pieces the extension can use

    func callClose(sessionID: String) async throws -> JSONValue {
        try await connection.call(ACP.Method.close, ["sessionId": .string(sessionID)])
    }

    func closeConnection() async {
        notificationTask?.cancel()
        notificationTask = nil
        await connection.close()
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
        }
    }

    private func receive(_ method: String, _ params: JSONValue?) {
        guard method == ACP.ClientMethod.sessionUpdate, let update = params?["update"] else { return }
        switch SessionUpdate.decode(update) {
        case .entry(let kind):
            guard !isReplaying else { return }
            eventsContinuation.yield(.entry(kind))
        case .options(let options):
            self.options = options
            eventsContinuation.yield(.optionsChanged(options))
        case .modeChanged(let mode):
            eventsContinuation.yield(.entry(.optionChanged(id: "mode", value: .string(mode))))
        case .title(let title):
            eventsContinuation.yield(.titleChanged(title))
        case .ignored:
            break
        case .unknown(let kind):
            eventsContinuation.yield(.unknownUpdate(kind))
        }
    }

    /// Requests from the runtime. Only one of them matters, and everything else is
    /// declined loudly rather than left to time out.
    func handleIncoming(method: String, params: JSONValue?) async -> Result<JSONValue, JSONRPCError> {
        guard method == ACP.ClientMethod.requestPermission else {
            return .failure(.methodNotFound(method))
        }
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
