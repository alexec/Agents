import Foundation
@testable import AgentsKit
@testable import AgentsKitCore

/// An ACP agent that does exactly what it is told.
///
/// This is what lets the whole of the protocol, the daemon and the lifecycle be tested
/// with `swift test`: no network, no credentials, no CLI installed, and no waiting for
/// a model to think.
actor FakeACPAgent {
    struct Script: Sendable {
        var supportsResume = false
        var supportsLoad = true
        var configOptions: [ConfigOption] = []
        var updates: [JSONValue] = []
        var stopReason = "end_turn"
        /// How long a turn takes. Zero for almost every test; a real duration for the
        /// ones about what happens while the agent is still working.
        var turnDelay: Duration = .zero
        /// Hold every turn until the test opens this. What a test about "while it is
        /// still working" should use rather than `turnDelay`: the turn cannot end
        /// early on a slow machine, and the test does not wait on a clock.
        var gate: TurnGate?
        /// Send `updates` on the first turn only. A real runtime never sends the same
        /// tool call again on a later turn; one that replays its script does, and a
        /// test about tool calls then reads the replay as the call starting over (035).
        var updatesOnFirstTurnOnly = false
        /// Ask a permission part way through the turn and wait for the answer.
        var permission: JSONValue?
        /// Answer `session/resume` and `session/load` with this error instead.
        var sessionGoneError: JSONRPCError?
        /// What `session/prompt` fails with instead of taking a turn (043: a refused sign-in).
        var promptError: JSONRPCError?
        /// What the runtime calls the session, sent as a `session_info_update`.
        var title: String?
        /// What the runtime says on its way out, sent while answering `session/close`.
        /// Real ones do this — a tool call marked cancelled, a last usage line — and
        /// it is the last thing they ever say, so there is no second chance to hear it.
        var updatesOnClose: [JSONValue] = []
        var replayOnLoad: [JSONValue] = []
        /// A request to make back to the client while answering `session/load`, sent
        /// without waiting for the answer. Real runtimes do exactly this, and the
        /// comment in `JSONRPCConnection` about replaying a conversation while
        /// answering `session/load` is about this shape. Here it is what makes the
        /// replay window testable rather than a coin toss: the client serves the read
        /// on its session actor, synchronously, so everything that arrives while it is
        /// doing so has to queue up behind it.
        var requestDuringLoad: (method: String, params: JSONValue)?
        /// How long to wait after that request before sending the replay, so the
        /// client is demonstrably still serving it when the replay and the load's own
        /// answer land.
        var pauseBeforeReplay: Duration = .zero

        // MARK: Things a real agent asks of the client

        /// Requests to make back to the client during a turn, in order. Everything the
        /// client serves is tested through here, because only one runtime on this Mac
        /// uses the file methods and none sends an elicitation form.
        var clientRequests: [(method: String, params: JSONValue)] = []
        /// Notifications under a method of the runtime's own invention, sent during the
        /// turn. A real one is Cursor's `cursor/update_todos`. Nothing is expected back,
        /// which is exactly why they used to vanish without trace.
        var extensionNotifications: [(method: String, params: JSONValue)] = []
        /// How long the handshake takes. Zero for almost every test; a real duration
        /// for the ones about what the daemon is doing while a runtime is still
        /// starting — which is the only window in which "one at a time" means
        /// anything, and the only one in which a crash mid-pick-up is reproducible.
        var handshakeDelay: Duration = .zero
        /// The protocol version to answer the handshake with.
        var protocolVersion = 1
        /// Refuse `session/new` with this, for the signed-out case.
        var newSessionError: JSONRPCError?
        /// Options as raw JSON rather than typed, for the shapes a typed value cannot
        /// express: groups, booleans, a choice with no value.
        var rawConfigOptions: JSONValue?
        /// Answer `session/prompt` with this usage block.
        var usage: JSONValue?
        var sessionCapabilities: [String: JSONValue] = ["close": [:], "list": [:]]
        var agentCapabilities: [String: JSONValue] = [:]
        var sessions: [JSONValue] = []
        /// What `initialize` offers as ways to sign in.
        var authMethods: [JSONValue] = []
    }

    private var script: Script
    private var turnsTaken = 0
    private var connection: JSONRPCConnection!
    private let box = FakeBox()

    private(set) var received: [String] = []
    private(set) var setOptions: [(id: String, value: JSONValue)] = []
    private(set) var permissionOutcome: JSONValue?
    private(set) var sessionID = "fake-session-\(UUID().uuidString)"
    /// What the client answered each request with, in order, so a test can assert on
    /// what we served rather than only on what we were asked.
    private(set) var clientAnswers: [(method: String, result: Result<JSONValue, JSONRPCError>)] = []
    private(set) var promptContent: JSONValue?
    private(set) var deletedSessions: [String] = []
    /// What `session/new` was asked for, so a test can see what we attached to a
    /// session rather than only what we recorded against the agent.
    private(set) var newSessionParams: JSONValue?
    private(set) var continuedSessionParams: JSONValue?

    init(script: Script = Script(), transport: any LineTransport) {
        self.script = script
        let box = self.box
        self.connection = JSONRPCConnection(transport: transport) { method, params in
            await box.handle(method: method, params: params)
        }
        Task { await self.attach() }
    }

    private func attach() async {
        box.attach(self)
        await connection.start()
    }

    func handle(method: String, params: JSONValue?) async -> Result<JSONValue, JSONRPCError> {
        received.append(method)
        switch method {
        case ACP.Method.initialize:
            if script.handshakeDelay > .zero { try? await Task.sleep(for: script.handshakeDelay) }
            var sessionCapabilities = script.sessionCapabilities
            if script.supportsResume { sessionCapabilities["resume"] = [:] }
            var capabilities = script.agentCapabilities
            capabilities["loadSession"] = .bool(script.supportsLoad)
            capabilities["sessionCapabilities"] = .object(sessionCapabilities)
            return .success([
                "protocolVersion": .int(script.protocolVersion),
                "agentCapabilities": .object(capabilities),
                "agentInfo": ["name": "FakeACPAgent", "version": "1.0"],
                "authMethods": .array(script.authMethods),
            ])

        case ACP.Method.newSession:
            newSessionParams = params
            if let error = script.newSessionError { return .failure(error) }
            var result: [String: JSONValue] = ["sessionId": .string(sessionID)]
            if let raw = script.rawConfigOptions {
                result["configOptions"] = raw
            } else if !script.configOptions.isEmpty,
                      let options = try? JSONValue.encoding(script.configOptions) {
                result["configOptions"] = options
            }
            return .success(.object(result))

        case ACP.Method.list:
            return .success(["sessions": .array(script.sessions)])

        case ACP.Method.deleteSession:
            if let id = params?["sessionId"]?.stringValue { deletedSessions.append(id) }
            return .success([:])

        case ACP.Method.forkSession:
            return .success(["sessionId": .string("forked-" + sessionID)])

        case ACP.Method.resumeSession:
            continuedSessionParams = params
            if let error = script.sessionGoneError { return .failure(error) }
            return .success([:])

        case ACP.Method.loadSession:
            continuedSessionParams = params
            if let error = script.sessionGoneError { return .failure(error) }
            if let request = script.requestDuringLoad {
                // Fired and forgotten: a runtime does not wait for the client before
                // carrying on with the replay, and neither does this.
                let connection = self.connection!
                Task { _ = try? await connection.call(request.method, request.params) }
            }
            if script.pauseBeforeReplay > .zero { try? await Task.sleep(for: script.pauseBeforeReplay) }
            for update in script.replayOnLoad { await send(update: update) }
            return .success([:])

        case ACP.Method.setConfigOption:
            guard let id = params?["configId"]?.stringValue else {
                return .failure(JSONRPCError(code: JSONRPCError.invalidParams, message: "no configId"))
            }
            setOptions.append((id, params?["value"] ?? .null))
            let options = (try? JSONValue.encoding(script.configOptions)) ?? .array([])
            return .success(["configOptions": options])

        case ACP.Method.prompt:
            promptContent = params?["prompt"]
            if let error = script.promptError { return .failure(error) }
            return await runTurn()

        case ACP.Method.authenticate, ACP.Method.logout:
            return .success([:])

        case ACP.Method.close:
            for update in script.updatesOnClose { await send(update: update) }
            return .success([:])

        default:
            return .failure(.methodNotFound(method))
        }
    }

    private func runTurn() async -> Result<JSONValue, JSONRPCError> {
        if script.turnDelay > .zero { try? await Task.sleep(for: script.turnDelay) }
        if let gate = script.gate { await gate.pass() }
        if let title = script.title {
            await send(update: ["sessionUpdate": "session_info_update", "title": .string(title)])
        }
        turnsTaken += 1
        if !script.updatesOnFirstTurnOnly || turnsTaken == 1 {
            for update in script.updates { await send(update: update) }
        }
        for notification in script.extensionNotifications {
            try? connection.notify(notification.method, notification.params)
        }
        for request in script.clientRequests {
            var params = request.params
            if case .object(var object) = params, object["sessionId"] == nil {
                object["sessionId"] = .string(sessionID)
                params = .object(object)
            }
            do {
                let result = try await connection.call(request.method, params)
                clientAnswers.append((request.method, .success(result)))
            } catch let error as JSONRPCError {
                clientAnswers.append((request.method, .failure(error)))
            } catch {
                clientAnswers.append((request.method, .failure(.internalError("\(error)"))))
            }
        }
        if let permission = script.permission {
            permissionOutcome = try? await connection.call(ACP.ClientMethod.requestPermission, permission)
        }
        var result: [String: JSONValue] = ["stopReason": .string(script.stopReason)]
        if let usage = script.usage { result["usage"] = usage }
        return .success(.object(result))
    }

    private func send(update: JSONValue) async {
        try? connection.notify(ACP.ClientMethod.sessionUpdate,
                                     ["sessionId": .string(sessionID), "update": update])
    }

    /// Send a notification under any method at all, the way a runtime speaking its own
    /// extension does. Nothing comes back, so the only question is whether the client
    /// noticed.
    func emitNotification(_ method: String, _ params: JSONValue = [:]) async {
        try? connection.notify(method, params)
    }

    /// Send an update outside a turn, for tests that want one to arrive unprompted.
    func emit(_ update: JSONValue) async {
        await send(update: update)
    }

    func stop() async {
        await connection.close()
    }

    /// What the client answered one method with, for a test that cares.
    func answer(to method: String) -> Result<JSONValue, JSONRPCError>? {
        clientAnswers.first { $0.method == method }?.result
    }

    static func chunk(_ text: String, messageID: String? = nil) -> JSONValue {
        var value: JSONValue = ["sessionUpdate": "agent_message_chunk",
                                "content": ["type": "text", "text": .string(text)]]
        if let messageID, case .object(var o) = value {
            o["messageId"] = .string(messageID)
            value = .object(o)
        }
        return value
    }

    /// A tool call beginning, the way Claude's does: a title and no content yet.
    static func toolCall(id: String, title: String, status: String = "pending") -> JSONValue {
        ["sessionUpdate": "tool_call", "toolCallId": .string(id), "title": .string(title),
         "kind": "edit", "status": .string(status), "content": []]
    }

    /// An update carrying one diff. Claude sends one of these before the tool runs and
    /// another after, with different old text (035 research R1).
    static func diffUpdate(id: String, path: String, oldText: String?, newText: String,
                           status: String? = nil, rawInput: JSONValue? = nil) -> JSONValue {
        var diff: [String: JSONValue] = ["type": "diff", "path": .string(path),
                                         "newText": .string(newText)]
        if let oldText { diff["oldText"] = .string(oldText) }
        var update: [String: JSONValue] = ["sessionUpdate": "tool_call_update",
                                           "toolCallId": .string(id),
                                           "content": [.object(diff)]]
        if let status { update["status"] = .string(status) }
        if let rawInput { update["rawInput"] = rawInput }
        return .object(update)
    }

    /// An update carrying only how the call ended.
    static func status(id: String, _ status: String) -> JSONValue {
        ["sessionUpdate": "tool_call_update", "toolCallId": .string(id),
         "status": .string(status)]
    }

    /// The whole of one Claude edit: begun, diff from the input, diff after it ran, done.
    static func claudeEdit(id: String, path: String, oldText: String?, newText: String,
                           ending: String = "completed") -> [JSONValue] {
        [toolCall(id: id, title: "Edit \(path)"),
         diffUpdate(id: id, path: path, oldText: nil, newText: newText),
         diffUpdate(id: id, path: path, oldText: oldText, newText: newText),
         status(id: id, ending)]
    }
}

final class FakeBox: @unchecked Sendable {
    private let lock = NSLock()
    private weak var agent: FakeACPAgent?

    func attach(_ agent: FakeACPAgent) {
        lock.lock(); defer { lock.unlock() }
        self.agent = agent
    }

    /// Synchronous on purpose: a lock may not be taken from an async context.
    private var current: FakeACPAgent? {
        lock.lock(); defer { lock.unlock() }
        return agent
    }

    func handle(method: String, params: JSONValue?) async -> Result<JSONValue, JSONRPCError> {
        guard let agent = current else { return .failure(.methodNotFound(method)) }
        return await agent.handle(method: method, params: params)
    }
}
