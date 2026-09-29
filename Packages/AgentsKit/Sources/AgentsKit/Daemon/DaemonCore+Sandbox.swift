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
