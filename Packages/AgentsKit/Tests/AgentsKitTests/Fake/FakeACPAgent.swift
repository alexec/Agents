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
        /// `models` and `modes` in a session answer, the older way Gemini CLI sends them
        /// instead of `configOptions` (046).
        var olderStyle: [String: JSONValue] = [:]
        /// Refuse `session/load` with `-32000` until `authenticate` has been called, as
        /// Gemini CLI 0.61.0 does (046).
        var loadNeedsAuthenticate = false
        var updates: [JSONValue] = []
        var stopReason = "end_turn"
        /// How long a turn takes. Zero for almost every test; a real duration for the
        /// ones about what happens while the agent is still working.
        var turnDelay: Duration = .zero
        /// Hold every turn until the test opens this. What a test about "while it is
        /// still working" should use rather than `turnDelay`: the turn cannot end
        /// early on a slow machine, and the test does not wait on a clock.
        var gate: TurnGate?
        /// End a turn held at `gate` with `cancelled` when `session/cancel` comes, as the
        /// real adapters do. Off, a held turn hears nothing and keeps going: an adapter
        /// stuck in a tool of its own (#139: Codex in its `wait`).
        var endsOnCancel = false
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
        /// What `session/set_config_option` fails with, by option id (049: OpenCode refusing
        /// a model of a provider nobody signed in to).
        var setOptionErrors: [String: JSONRPCError] = [:]
        /// What `session/set_config_option` puts in place of the value it was sent, by option
        /// id, while answering with success: Claude's adapter turning Auto into Accept edits
        /// on a model without it (#143).
        var setOptionInstead: [String: JSONValue] = [:]
        /// What the runtime calls the session, sent as a `session_info_update`.
        var title: String?
        /// `_meta` on the `session/prompt` result: where Claude's and Codex's adapters put
        /// a typed failure when the client asked for them (052, research R1).
        var promptResultMeta: JSONValue?
        /// Sent as a `usage_update` carrying this `_meta` before the turn ends: Claude's
        /// `_claude/rateLimit` (052, R2).
        var usageMeta: JSONValue?
        /// Sent during the turn as a `session_info_update` with no title and this `_meta`:
        /// a failure not tied to the turn's own answer (052).
        var sessionInfoMeta: JSONValue?
        /// Fail this many prompts, with `promptError` or `promptResultMeta`, and then take
        /// turns normally. Zero means every prompt fails the way the script says.
        var failTimes = 0
        /// The answer to Grok's `_x.ai/billing`. Nil answers method-not-found, as every
        /// other runtime does.
        var billing: JSONValue?
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
        /// The same shape as `clientRequests`, but fired together rather than one after
        /// another — what a runtime does when it asks about several edits at once.
        var concurrentClientRequests: [(method: String, params: JSONValue)] = []
        /// Notifications under a method of the runtime's own invention, sent during the
        /// turn. A real one is `_auth/status_update`. Nothing is expected back, which is
        /// exactly why they used to vanish without trace. (Cursor's `cursor/*` methods
        /// look like these and are requests: put those in `clientRequests`.)
        var extensionNotifications: [(method: String, params: JSONValue)] = []
        /// How long the handshake takes. Zero for almost every test; a real duration
        /// for the ones about what the daemon is doing while a runtime is still
        /// starting — which is the only window in which "one at a time" means
        /// anything, and the only one in which a crash mid-pick-up is reproducible.
        var handshakeDelay: Duration = .zero
        /// How long `session/new`, and `session/resume` or `session/load`, take (#166).
        var newSessionDelay: Duration = .zero
        var loadDelay: Duration = .zero
        /// A pause after the turn's updates and before its answer: with a tool call left
        /// open in `updates`, a turn quiet with work in hand (#166).
        var delayAfterUpdates: Duration = .zero
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
        /// Advertise `_meta.steering.supported`, and answer `_session/steering` with
        /// this outcome. Nil advertises nothing, and the method is not found.
        var steering: String?

        // MARK: Background work (057)

        /// Updates about background work, sent during the turn after `updates`, each under
        /// the session named (nil: the agent's own). Sent only if the client advertised
        /// what the real adapters wait for: `asyncTasks` for `async_task_*`, and
        /// `nativeSubagentSessions` for `subagent_*` and anything under a subagent's id.
        var air: [(session: String?, update: JSONValue)] = []
        /// What a runtime says instead when the client did not opt in: the prose.
        var withoutAir: [JSONValue] = []
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
    /// Every prompt's content, in the order they came, so a test can see what was sent
    /// and how many times (052: a failed prompt is sent to the next runtime once).
    private(set) var prompts: [JSONValue] = []
    private var promptsFailed = 0
    private(set) var deletedSessions: [String] = []
    private(set) var disabledProviders: [String] = []
    /// Every `_session/steering` request, as it arrived.
    private(set) var steers: [JSONValue] = []
    /// What `session/new` was asked for, so a test can see what we attached to a
    /// session rather than only what we recorded against the agent.
    private(set) var newSessionParams: JSONValue?
    private(set) var continuedSessionParams: JSONValue?
    /// What the client said it could do at the handshake.
    private(set) var clientCapabilities: JSONValue?
    /// Tasks announced and not yet ended, which is what Stop can reach.
    private var runningTasks: [String: String] = [:]
    private(set) var stopRequests: [JSONValue] = []
    /// How many `session/cancel` notifications came while a turn was held.
    private(set) var cancels = 0
    /// The held turn's wait, resumed by the gate (false) or by a cancel (true).
    private var heldTurn: (turn: Int, wait: CheckedContinuation<Bool, Never>)?
    private var heldTurns = 0

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
        let incoming = connection.incomingNotifications()
        Task { [weak self] in
            for await note in incoming where note.method == ACP.Method.cancel {
                await self?.heardCancel()
            }
        }
    }

    private func heardCancel() {
        // Only a cancel of a turn under way: the one letting a session go is not counted.
        guard let held = heldTurn else { return }
        cancels += 1
        guard script.endsOnCancel else { return }
        releaseHeldTurn(held.turn, cancelled: true)
    }

    /// Only the turn named: a gate opened after a cancel ended its turn must not end
    /// the next one.
    private func releaseHeldTurn(_ turn: Int, cancelled: Bool) {
        guard let held = heldTurn, held.turn == turn else { return }
        heldTurn = nil
        held.wait.resume(returning: cancelled)
    }

    /// Wait at the gate, or, for a script that ends on cancel, until a cancel comes.
    /// True when it was the cancel.
    private func hold(at gate: TurnGate) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            heldTurns += 1
            let turn = heldTurns
            heldTurn = (turn, continuation)
            Task { await gate.pass(); self.releaseHeldTurn(turn, cancelled: false) }
        }
    }

    func handle(method: String, params: JSONValue?) async -> Result<JSONValue, JSONRPCError> {
        received.append(method)
        switch method {
        case ACP.Method.initialize:
            clientCapabilities = params?["clientCapabilities"]
            if script.handshakeDelay > .zero { try? await Task.sleep(for: script.handshakeDelay) }
            var sessionCapabilities = script.sessionCapabilities
            if script.supportsResume { sessionCapabilities["resume"] = [:] }
            var capabilities = script.agentCapabilities
            capabilities["loadSession"] = .bool(script.supportsLoad)
            // What every runtime the app starts says, unless a test says otherwise.
            if capabilities["mcpCapabilities"] == nil { capabilities["mcpCapabilities"] = ["http": true, "sse": true] }
            capabilities["sessionCapabilities"] = .object(sessionCapabilities)
            var result: [String: JSONValue] = [
                "protocolVersion": .int(script.protocolVersion),
                "agentCapabilities": .object(capabilities),
                "agentInfo": ["name": "FakeACPAgent", "version": "1.0"],
                "authMethods": .array(script.authMethods),
            ]
            if script.steering != nil { result["_meta"] = ["steering": ["supported": true]] }
            return .success(.object(result))

        case ACP.Method.steering where script.steering != nil:
            steers.append(params ?? .null)
            return .success(["outcome": .string(script.steering ?? "")])

        case ACP.Method.grokBilling where script.billing != nil:
            return .success(script.billing ?? .null)

        case ACP.Method.newSession:
            newSessionParams = params
            if script.newSessionDelay > .zero { try? await Task.sleep(for: script.newSessionDelay) }
            if let error = script.newSessionError { return .failure(error) }
            var result: [String: JSONValue] = ["sessionId": .string(sessionID)]
            if let raw = script.rawConfigOptions {
                result["configOptions"] = raw
            } else if !script.configOptions.isEmpty,
                      let options = try? JSONValue.encoding(script.configOptions) {
                result["configOptions"] = options
            }
            result.merge(script.olderStyle) { current, _ in current }
            return .success(.object(result))

        case "session/set_model", "session/set_mode":
            let key = method == "session/set_model" ? "modelId" : "modeId"
            setOptions.append((method == "session/set_model" ? "model" : "mode", params?[key] ?? .null))
            return .success([:])

        case ACP.Method.list:
            return .success(["sessions": .array(script.sessions)])

        case ACP.Method.disableProvider:
            if let id = params?["providerId"]?.stringValue { disabledProviders.append(id) }
            return .success([:])

        case ACP.Method.deleteSession:
            if let id = params?["sessionId"]?.stringValue { deletedSessions.append(id) }
            return .success([:])

        case ACP.Method.forkSession:
            return .success(["sessionId": .string("forked-" + sessionID)])

        case ACP.Method.resumeSession:
            continuedSessionParams = params
            if script.loadDelay > .zero { try? await Task.sleep(for: script.loadDelay) }
            if let error = script.sessionGoneError { return .failure(error) }
            return .success([:])

        case ACP.Method.loadSession:
            continuedSessionParams = params
            if script.loadDelay > .zero { try? await Task.sleep(for: script.loadDelay) }
            if script.loadNeedsAuthenticate, !received.contains(ACP.Method.authenticate) {
                return .failure(JSONRPCError(code: -32000, message: "Authentication required"))
            }
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
            if let error = script.setOptionErrors[id] { return .failure(error) }
            setOptions.append((id, params?["value"] ?? .null))
            // The answer carries the options as they now are, as the protocol says.
            if let index = script.configOptions.firstIndex(where: { $0.id == id }) {
                script.configOptions[index].currentValue = script.setOptionInstead[id] ?? params?["value"]
            }
            let options = (try? JSONValue.encoding(script.configOptions)) ?? .array([])
            return .success(["configOptions": options])

        case ACP.Method.prompt:
            promptContent = params?["prompt"]
            prompts.append(params?["prompt"] ?? .null)
            // Failing a set number of times, then working: the retry and the "succeeds on
            // the next runtime" cases (052). Without a count, the script fails every time.
            let failing = script.failTimes == 0 || promptsFailed < script.failTimes
            if failing, script.promptError != nil || script.promptResultMeta != nil { promptsFailed += 1 }
            if failing, let error = script.promptError { return .failure(error) }
            return await runTurn(failing: failing)

        case ACP.Method.authenticate, ACP.Method.logout:
            return .success([:])

        case ACP.Method.close:
            for update in script.updatesOnClose { await send(update: update) }
            return .success([:])

        case ACP.Method.stopAsyncTask where advertised("asyncTasks"):
            stopRequests.append(params ?? .null)
            guard let id = params?["asyncTaskId"]?.stringValue,
                  let name = runningTasks.removeValue(forKey: id) else {
                return .success(["stopped": false])
            }
            // As Claude's adapter 0.81.2 does it, captured: the ending twice, then the
            // notice, then the answer.
            let ending: JSONValue = ["sessionUpdate": "async_task_state_update",
                                     "asyncTaskId": .string(id), "state": "stopped"]
            await send(update: ending)
            await send(update: ending)
            await send(update: ["sessionUpdate": "notice", "severity": "info",
                                "title": "Task stopped by user", "description": .string("\(name).")])
            return .success(["stopped": true])

        default:
            return .failure(.methodNotFound(method))
        }
    }

    private func runTurn(failing: Bool = true) async -> Result<JSONValue, JSONRPCError> {
        if script.turnDelay > .zero { try? await Task.sleep(for: script.turnDelay) }
        if let title = script.title {
            await send(update: ["sessionUpdate": "session_info_update", "title": .string(title)])
        }
        turnsTaken += 1
        if !script.updatesOnFirstTurnOnly || turnsTaken == 1 {
            for update in script.updates { await send(update: update) }
        }
        if script.delayAfterUpdates > .zero { try? await Task.sleep(for: script.delayAfterUpdates) }
        let airOn = advertised("asyncTasks"), subagentsOn = advertised("nativeSubagentSessions")
        for (session, update) in script.air {
            let kind = update["sessionUpdate"]?.stringValue ?? ""
            let needs = kind.hasPrefix("async_task_") && session == nil ? airOn : subagentsOn
            guard needs else { continue }
            if kind == "async_task_spawned", let id = update["asyncTaskId"]?.stringValue {
                runningTasks[id] = update["name"]?.stringValue ?? id
            }
            if kind == "async_task_state_update", let id = update["asyncTaskId"]?.stringValue,
               update["state"]?.stringValue != "running" {
                runningTasks[id] = nil
            }
            await send(update: update, as: session)
        }
        if !airOn { for update in script.withoutAir { await send(update: update) } }
        for notification in script.extensionNotifications {
            try? connection.notify(notification.method, notification.params)
        }
        for request in script.clientRequests {
            await askClient(request.method, request.params)
        }
        if !script.concurrentClientRequests.isEmpty {
            let answers = await withTaskGroup(
                of: (String, Result<JSONValue, JSONRPCError>).self,
                returning: [(String, Result<JSONValue, JSONRPCError>)].self
            ) { group in
                for request in script.concurrentClientRequests {
                    group.addTask { await self.askClientResult(request.method, request.params) }
                }
                var collected: [(String, Result<JSONValue, JSONRPCError>)] = []
                for await answer in group { collected.append(answer) }
                return collected
            }
            clientAnswers.append(contentsOf: answers)
        }
        if let permission = script.permission {
            permissionOutcome = try? await connection.call(ACP.ClientMethod.requestPermission, permission)
        }
        // Held after everything the turn does and before it ends: a test sees the turn
        // at work, and it ends when the test says.
        if let meta = script.usageMeta {
            await send(update: ["sessionUpdate": "usage_update", "used": 1000, "size": 200000, "_meta": meta])
        }
        if failing, let meta = script.sessionInfoMeta {
            await send(update: ["sessionUpdate": "session_info_update", "_meta": meta])
        }
        var stopReason = script.stopReason
        if let gate = script.gate, await hold(at: gate) { stopReason = "cancelled" }
        var result: [String: JSONValue] = ["stopReason": .string(stopReason)]
        if let usage = script.usage { result["usage"] = usage }
        if failing, let meta = script.promptResultMeta { result["_meta"] = meta }
        return .success(.object(result))
    }

    private func send(update: JSONValue, as session: String? = nil) async {
        try? connection.notify(ACP.ClientMethod.sessionUpdate,
                                     ["sessionId": .string(session ?? sessionID), "update": update])
    }

    private func askClient(_ method: String, _ params: JSONValue) async {
        let answer = await askClientResult(method, params)
        clientAnswers.append(answer)
    }

    private func askClientResult(_ method: String, _ params: JSONValue) async
        -> (String, Result<JSONValue, JSONRPCError>) {
        var params = params
        if case .object(var object) = params, object["sessionId"] == nil {
            object["sessionId"] = .string(sessionID)
            params = .object(object)
        }
        do {
            return (method, .success(try await connection.call(method, params)))
        } catch let error as JSONRPCError {
            return (method, .failure(error))
        } catch {
            return (method, .failure(.internalError("\(error)")))
        }
    }

    /// Whether the client listed this JetBrains "AIR" capability, read the way both
    /// adapters read it: version at least 1 and the name in the list.
    private func advertised(_ capability: String) -> Bool {
        let air = clientCapabilities?["_meta"]?["jetbrains"]?["air"]
        guard (air?["version"]?.intValue ?? 0) >= 1 else { return false }
        return (air?["capabilities"]?.arrayValue ?? []).contains(.string(capability))
    }

    /// Send an update under a subagent's session, outside a turn.
    func emit(_ update: JSONValue, as session: String) async {
        await send(update: update, as: session)
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

    /// Every answer to one method, in order, for a test that sends it more than once.
    func answers(to method: String) -> [Result<JSONValue, JSONRPCError>] {
        clientAnswers.filter { $0.method == method }.map(\.result)
    }

    /// Make a request of the client outside a turn and say what came back, the way a
    /// runtime calling a method of its own invention does.
    func emitRequest(_ method: String, _ params: JSONValue = [:]) async -> Result<JSONValue, JSONRPCError> {
        do {
            return .success(try await connection.call(method, params))
        } catch let error as JSONRPCError {
            return .failure(error)
        } catch {
            return .failure(.internalError("\(error)"))
        }
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
