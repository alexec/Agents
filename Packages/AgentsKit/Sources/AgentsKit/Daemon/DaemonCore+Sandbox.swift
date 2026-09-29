import Foundation
import AgentsKitCore

extension DaemonCore {
    /// Saves every runtime's default (064). A choice the catalog does not offer for that
    /// runtime is dropped rather than kept, so nothing asks for a route that is not there.
    public func setSandboxSettings(_ settings: SandboxSettings) throws -> SandboxSettings {
        var kept = SandboxSettings()
        for (runtimeID, choice) in settings.defaults where SandboxCatalog.choices(for: runtimeID).contains(choice) {
            kept = kept.setting(choice, for: runtimeID)
        }
        try sandboxStore.save(kept)
        sandboxSettings = kept
        broadcast(DaemonAPI.Notification.sandboxChanged, kept)
        return kept
    }
}

extension DaemonCore {
    /// Codex's mode that has no sandbox (R2): Off is this, and this is Off.
    static let codexFullAccess = "agent-full-access"
    /// The mode On returns Codex to from Full access (FR-005b).
    static let codexAskForApproval = "read-only"

    /// One agent's own choice (FR-003b); nil clears it. It applies from the agent's next
    /// turn, because every turn starts its runtime afresh (FR-012). For Codex the mode moves
    /// with it, so the two never disagree (FR-005a, FR-005b).
    public func setSandbox(_ request: DaemonAPI.SetSandboxRequest) async throws -> Agent {
        guard var agent = agents[request.agentID] else {
            throw JSONRPCError(code: DaemonAPI.Failure.noSuchAgent, message: "That agent is not here.")
        }
        if let choice = request.choice, !SandboxCatalog.choices(for: agent.runtimeID).contains(choice) {
            throw JSONRPCError(code: JSONRPCError.invalidParams,
                               message: SandboxCatalog.entry(for: agent.runtimeID)?.why
                                   ?? "The app cannot change this runtime’s sandbox.")
        }
        agent.sandboxOverride = request.choice
        changed(agent)
        if agent.runtimeID == RuntimeCatalog.codex.id, let mode = codexMode(for: request.choice, agent: agent) {
            _ = try await setOption(DaemonAPI.SetOptionRequest(agentID: agent.id, optionID: "mode", value: .string(mode)),
                                    fromSandbox: true)
        }
        return agents[request.agentID] ?? agent
    }

    /// The Codex mode a sandbox choice asks for, or nil to leave the mode as it is.
    func codexMode(for choice: SandboxChoice?, agent: Agent) -> String? {
        let current = agent.startOptions.values["mode"]?.stringValue
        switch choice ?? sandboxSettings.choice(for: agent.runtimeID) {
        case .off: return current == Self.codexFullAccess ? nil : Self.codexFullAccess
        case .on: return current == Self.codexFullAccess ? Self.codexAskForApproval : nil
        case .runtime: return nil
        }
    }

    /// A Codex mode chosen by hand is a sandbox choice for that agent too (FR-005c): Full
    /// access is Off, anything else On. The runtime default is untouched.
    func followCodexMode(_ value: JSONValue, agentID: UUID) {
        guard var agent = agents[agentID], agent.runtimeID == RuntimeCatalog.codex.id,
              let mode = value.stringValue else { return }
        let choice: SandboxChoice = mode == Self.codexFullAccess ? .off : .on
        guard agent.sandboxOverride != choice else { return }
        agent.sandboxOverride = choice
        changed(agent)
    }
}

/// The sandbox choice the runtime about to be started resolved to (064), set around
/// `SessionLauncher.launch` as `LentEnvironment` is, and read by `ProcessSessionLauncher`
/// for the routes that are arguments or environment.
public enum LaunchSandbox {
    @TaskLocal public static var value: SandboxChoice = .runtime

    /// What the choice adds to a runtime's launch: arguments before its own, and
    /// environment over everything else. Nothing for `runtime` (FR-003c, SC-006).
    public static func additions(runtimeID: String, choice: SandboxChoice) -> (arguments: [String], environment: [String: String]) {
        guard choice != .runtime, let route = SandboxCatalog.entry(for: runtimeID)?.route else { return ([], [:]) }
        switch route {
        case .arguments(let on, let off):
            return (choice == .on ? on : off, [:])
        case .environment(let on, let off):
            return ([], choice == .on ? (on ?? [:]) : off)
        case .claudeMeta, .codexMode, .fixed:
            return ([], [:])
        }
    }

    /// Claude's `_meta` for the choice: `claudeCode.options.sandbox.enabled`, which the
    /// adapter gives Claude Code as flag settings (research R7).
    public static func meta(runtimeID: String, choice: SandboxChoice) -> JSONValue? {
        guard choice != .runtime, SandboxCatalog.entry(for: runtimeID)?.route == .claudeMeta else { return nil }
        return ["claudeCode": ["options": ["sandbox": ["enabled": .bool(choice == .on)]]]]
    }
}

extension DaemonCore {
    /// The choice an agent's next start or turn uses, and why it is not what was asked
    /// (FR-003a, FR-011): its own override, else its runtime's default, else as configured.
    /// A choice the catalog does not offer is as configured (FR-002). A helper started by
    /// an agent whose sandbox is on cannot be looser than it (R10).
    func resolveSandbox(runtimeID: String, override: SandboxChoice?, starter: UUID?) -> (choice: SandboxChoice, reason: String?) {
        var choice = override ?? sandboxSettings.choice(for: runtimeID)
        if !SandboxCatalog.choices(for: runtimeID).contains(choice) { choice = .runtime }
        if choice == .off, let starter, agents[starter]?.effectiveSandbox?.state == .on {
            return (.runtime, "Limited by the agent that started it")
        }
        return (choice, nil)
    }

    func resolveSandbox(for agent: Agent) -> (choice: SandboxChoice, reason: String?) {
        resolveSandbox(runtimeID: agent.runtimeID, override: agent.sandboxOverride, starter: agent.startedByAgent)
    }

    /// Codex starts in the mode its sandbox choice needs (FR-005c): Full access for Off,
    /// Ask for approval when On would otherwise leave it in Full access.
    func codexStartOptions(_ options: StartOptions, runtimeID: String, choice: SandboxChoice) -> StartOptions {
        guard runtimeID == RuntimeCatalog.codex.id else { return options }
        var options = options
        let mode = options.values["mode"]?.stringValue
        switch choice {
        case .off: options.values["mode"] = .string(Self.codexFullAccess)
        case .on where mode == Self.codexFullAccess: options.values["mode"] = .string(Self.codexAskForApproval)
        default: break
        }
        return options
    }

    /// What the agent's latest start runs under (FR-010), written after each handshake.
    func noteEffectiveSandbox(agentID: UUID, choice: SandboxChoice, reason: String?) {
        guard var agent = agents[agentID] else { return }
        let effective = EffectiveSandbox(
            state: SandboxCatalog.state(runtimeID: agent.runtimeID, choice: choice,
                                        codexMode: agent.startOptions.values["mode"]?.stringValue),
            requested: agent.sandboxOverride ?? sandboxSettings.choice(for: agent.runtimeID),
            reason: reason)
        guard agent.effectiveSandbox != effective else { return }
        agent.effectiveSandbox = effective
        changed(agent)
    }
}

extension DaemonCore {
    /// A new prompt answers a waiting card by moving past it (064).
    func clearWaitingSandbox(agentID: UUID) {
        guard var agent = agents[agentID], agent.pendingSandboxFailure != nil else { return }
        agent.pendingSandboxFailure = nil
        changed(agent)
    }

    /// The setup failure a turn showed, if any (FR-006a): in a finished command's output,
    /// or, for a runtime that says it only there, in its reply (Codex). A command whose
    /// sandbox failed did not run, so it is not counted as work done.
    func sandboxFailure(in evidence: TurnEvidence, runtimeID: String) -> (detail: String, completedToolCalls: Int)? {
        guard let entry = SandboxCatalog.entry(for: runtimeID), !entry.failurePatterns.isEmpty else { return nil }
        var detail: String?
        var completed = 0
        for output in evidence.outputs {
            if let match = SandboxFailureDetector.match(runtimeID: runtimeID, text: output.text) {
                detail = detail ?? match
            } else if output.didWork {
                completed += 1
            }
        }
        if detail == nil, entry.readsReply {
            detail = SandboxFailureDetector.match(runtimeID: runtimeID, text: evidence.reply)
        }
        return detail.map { ($0, completed) }
    }

    /// Why a runtime would not start, when the reason is its sandbox: its error or the last
    /// of its stderr (R11). Nil for anything else, which is then handled as before.
    func sandboxStartFailure(runtimeID: String, error: any Error, session: ACPSession?) async -> String? {
        guard !(SandboxCatalog.entry(for: runtimeID)?.failurePatterns ?? []).isEmpty else { return nil }
        let words = (error as? JSONRPCError).map { "\($0.message)\n\($0.data.map { "\($0)" } ?? "")" }
            ?? "\(error)"
        if let detail = SandboxFailureDetector.match(runtimeID: runtimeID, text: words) { return detail }
        guard let session else { return nil }
        return SandboxFailureDetector.match(runtimeID: runtimeID, text: await session.standardErrorTail())
    }

    /// Whether a runtime that never answered is Gemini with its sandbox on (R6): the one
    /// known cause of that hang, and Off is harmless if it was something else.
    func isSandboxHang(_ error: any Error) -> Bool { error is SandboxHang }

    /// The handshake, given a deadline where a sandbox that is on would hang it (R6): Gemini
    /// unless it is Off. Every other runtime waits as long as it takes, as before.
    func initializeWatchingForHang(_ session: ACPSession, runtimeID: String,
                                   choice: SandboxChoice) async throws -> ACP.InitializeResult {
        guard SandboxCatalog.entry(for: runtimeID)?.hangsWhenOn == true, choice != .off else {
            return try await session.initialize()
        }
        let deadline = sandboxHangDeadline
        // A race that returns at the deadline without waiting for the handshake: a hung
        // one answers nothing, ever, until its process is ended, which the caller does.
        return try await withCheckedThrowingContinuation { continuation in
            let once = ResumeOnce(continuation)
            Task {
                do { once.resume(with: .success(try await session.initialize())) } catch { once.resume(with: .failure(error)) }
            }
            Task {
                try? await Task.sleep(for: deadline)
                once.resume(with: .failure(SandboxHang()))
            }
        }
    }

    /// The card, in the conversation, waiting on the agent for an answer (FR-007).
    /// **Continue without sandbox** is offered only where Off is a route.
    func recordSandboxFailure(agentID: UUID, detail: String, hang: Bool = false, completedToolCalls: Int = 0) async {
        guard var agent = agents[agentID] else { return }
        let record = SandboxFailureRecord(runtimeID: agent.runtimeID, detail: detail, hang: hang,
                                          recoveryOffered: SandboxCatalog.canTurnOff(agent.runtimeID),
                                          completedToolCalls: completedToolCalls)
        agent.pendingSandboxFailure = record
        changed(agent)
        await self.record(.sandboxFailure(record), for: agentID)
        DaemonLog.shared.write("agent \(agentID): \(agent.runtimeID)'s sandbox could not start: \(detail)")
    }

    /// The card's answer (FR-007a): only while it waits, and only this agent changes.
    public func answerSandbox(_ request: DaemonAPI.AnswerSandboxRequest) async throws -> Agent {
        guard var agent = agents[request.agentID] else {
            throw JSONRPCError(code: DaemonAPI.Failure.noSuchAgent, message: "That agent is not here.")
        }
        guard let pending = agent.pendingSandboxFailure else {
            throw JSONRPCError(code: DaemonAPI.Failure.notAllowed, message: "That has been answered already.")
        }
        guard !request.carryOn || pending.recoveryOffered else {
            throw JSONRPCError(code: DaemonAPI.Failure.notAllowed, message: SandboxWords.noRecovery)
        }
        agent.pendingSandboxFailure = nil
        changed(agent)
        let name = RuntimeCatalog.runtime(id: agent.runtimeID)?.name ?? agent.runtimeID
        guard request.carryOn else {
            await record(.runtimeNote(SandboxWords.keptStoppedNote(name)), for: agent.id)
            return agents[agent.id] ?? agent
        }
        _ = try await setSandbox(.init(agentID: agent.id, choice: .off))
        await record(.runtimeNote(SandboxWords.continuedNote(name)), for: agent.id)
        if agents[agent.id]?.queuedPrompts.isEmpty == false {
            // A pick-up that failed left the prompt on the queue: it goes now.
            try await sendNextQueued(to: agent.id)
        } else if pending.completedToolCalls > 0 {
            try await enqueue(DaemonAPI.PromptRequest(agentID: agent.id, text: Self.carryOnWithoutSandbox,
                                                      from: .app), first: true)
        } else if let prompt = lastPrompts[agent.id] {
            // Sent again as it went, and not written down twice (R12, like Pool's retry).
            let session = try await liveSession(for: agents[agent.id] ?? agent)
            await beginTurn(agentID: agent.id, text: prompt.text, blocks: prompt.blocks, from: prompt.from,
                            session: session, preface: prompt.preface, recorded: false)
        } else if let text = await lastPersonsPrompt(agentID: agent.id) {
            try await enqueue(DaemonAPI.PromptRequest(agentID: agent.id, text: text, from: .app), first: true)
        }
        return agents[agent.id] ?? agent
    }

    /// What recovery sends when commands already ran in the failed turn (R12): the prompt
    /// again could repeat them.
    static let carryOnWithoutSandbox = "The command sandbox is now off. Carry on with the task."

    /// The person's last words, from the record, for a daemon that has restarted since.
    func lastPersonsPrompt(agentID: UUID) async -> String? {
        guard let page = try? await store.transcript(for: agentID, limit: 400) else { return nil }
        for entry in page.entries.reversed() {
            if case .userMessage(let text, _, .person) = entry.kind { return text }
        }
        return nil
    }
}

/// A runtime that never answered its handshake where a sandbox that is on hangs it (R6).
struct SandboxHang: Error {}

extension DaemonCore {
    /// For tests: how long a hang is waited on.
    func setSandboxHangDeadline(_ deadline: Duration) { sandboxHangDeadline = deadline }
}

/// A continuation resumed by whichever of two tasks finishes first, and only once.
final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, any Error>?

    init(_ continuation: CheckedContinuation<T, any Error>) { self.continuation = continuation }

    func resume(with result: Result<T, any Error>) {
        lock.lock()
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume(with: result)
    }
}
