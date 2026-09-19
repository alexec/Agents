import Foundation
@testable import AgentsKit

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
        /// Ask a permission part way through the turn and wait for the answer.
        var permission: JSONValue?
        /// Answer `session/resume` and `session/load` with this error instead.
        var sessionGoneError: JSONRPCError?
        /// What the runtime calls the session, sent as a `session_info_update`.
        var title: String?
        var replayOnLoad: [JSONValue] = []

        // MARK: Things a real agent asks of the client

        /// Requests to make back to the client during a turn, in order. Everything the
        /// client serves is tested through here, because only one runtime on this Mac
        /// uses the file methods and none sends an elicitation form.
        var clientRequests: [(method: String, params: JSONValue)] = []
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
            return await runTurn()

        case ACP.Method.authenticate, ACP.Method.logout:
            return .success([:])

        case ACP.Method.close:
            return .success([:])

        default:
            return .failure(.methodNotFound(method))
        }
    }

    private func runTurn() async -> Result<JSONValue, JSONRPCError> {
        if script.turnDelay > .zero { try? await Task.sleep(for: script.turnDelay) }
        if let title = script.title {
            await send(update: ["sessionUpdate": "session_info_update", "title": .string(title)])
        }
        for update in script.updates { await send(update: update) }
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
        try? await connection.notify(ACP.ClientMethod.sessionUpdate,
                                     ["sessionId": .string(sessionID), "update": update])
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
