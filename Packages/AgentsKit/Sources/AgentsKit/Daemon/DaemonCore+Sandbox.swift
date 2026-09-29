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
