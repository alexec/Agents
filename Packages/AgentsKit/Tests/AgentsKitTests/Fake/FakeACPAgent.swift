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
        /// Ask a permission part way through the turn and wait for the answer.
        var permission: JSONValue?
        /// Answer `session/resume` and `session/load` with this error instead.
        var sessionGoneError: JSONRPCError?
        /// What the runtime calls the session, sent as a `session_info_update`.
        var title: String?
        var replayOnLoad: [JSONValue] = []
    }

    private var script: Script
    private var connection: JSONRPCConnection!
    private let box = FakeBox()

    private(set) var received: [String] = []
    private(set) var setOptions: [(id: String, value: JSONValue)] = []
    private(set) var permissionOutcome: JSONValue?
    private(set) var sessionID = "fake-session-\(UUID().uuidString)"

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
            var sessionCapabilities: [String: JSONValue] = ["close": [:], "list": [:]]
            if script.supportsResume { sessionCapabilities["resume"] = [:] }
            return .success([
                "protocolVersion": 1,
                "agentCapabilities": [
                    "loadSession": .bool(script.supportsLoad),
                    "sessionCapabilities": .object(sessionCapabilities),
                ],
                "agentInfo": ["name": "FakeACPAgent", "version": "1.0"],
                "authMethods": [],
            ])

        case ACP.Method.newSession:
            var result: JSONValue = ["sessionId": .string(sessionID)]
            if !script.configOptions.isEmpty,
               let options = try? JSONValue.encoding(script.configOptions) {
                result = ["sessionId": .string(sessionID), "configOptions": options]
            }
            return .success(result)

        case ACP.Method.resumeSession:
            if let error = script.sessionGoneError { return .failure(error) }
            return .success([:])

        case ACP.Method.loadSession:
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
            return await runTurn()

        case ACP.Method.close:
            return .success([:])

        default:
            return .failure(.methodNotFound(method))
        }
    }

    private func runTurn() async -> Result<JSONValue, JSONRPCError> {
        if let title = script.title {
            await send(update: ["sessionUpdate": "session_info_update", "title": .string(title)])
        }
        for update in script.updates { await send(update: update) }
        if let permission = script.permission {
            permissionOutcome = try? await connection.call(ACP.ClientMethod.requestPermission, permission)
        }
        return .success(["stopReason": .string(script.stopReason)])
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
