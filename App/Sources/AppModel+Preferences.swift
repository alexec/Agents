import AgentsKitCore
import AppKit
import Foundation
import os

/// The mode you keep choosing, language servers and simulators.
extension AppModel {
    // MARK: The mode you keep choosing

    /// What was last chosen for this runtime, on this Mac or a phone. The daemon keeps
    /// it now — it writes on a start and on a conversation's mode changing — and this
    /// reads the copy `modes/changed` keeps current (029).
    func rememberedMode(for runtimeID: String) -> JSONValue? {
        work.rememberedMode(for: runtimeID)
    }

    /// The daemon's memory. A daemon too old to know the method leaves the form opening
    /// on the runtime's own current mode, which is what it did before anything was
    /// remembered.
    func refreshModes() async {
        let modes = try? await macClient.call(DaemonAPI.Method.modesRemembered, Optional<Int>.none,
                                           returning: DaemonAPI.RememberedModes.self)
        if let modes { work.replaceRememberedModes(modes) }
    }

    // MARK: Language servers

    /// A source file's problems, from its language server on the agent's host (#844). A
    /// failure is thrown, for the editor to say (#1687).
    func diagnose(path: String, text: String, of agentID: UUID) async throws -> DaemonAPI.FileDiagnostics {
        try await client(forAgent: agentID).call(
            DaemonAPI.Method.filesDiagnostics,
            DaemonAPI.FileDiagnosticsRequest(agentID: agentID, path: path, text: text),
            returning: DaemonAPI.FileDiagnostics.self)
    }

    /// What the file's language server would write at a line and column (#844), or why
    /// there is nothing: the host's reason, or the failure (#1688).
    func complete(path: String, text: String, line: Int, column: Int, of agentID: UUID) async -> DaemonAPI.FileCompletions {
        do {
            return try await client(forAgent: agentID).call(
                DaemonAPI.Method.filesComplete,
                DaemonAPI.FileCompletionRequest(agentID: agentID, path: path, text: text, line: line, column: column),
                returning: DaemonAPI.FileCompletions.self)
        } catch {
            return DaemonAPI.FileCompletions(items: [], reason: DaemonAPI.FileCompletions.failure(error))
        }
    }

    // MARK: Simulators

    /// The Simulator pane's calls (#842), to the session's host.
    func simulatorCalls(for agentID: UUID) -> SimulatorCalls {
        SimulatorCalls(
            list: { try await self.client(forAgent: agentID).call(
                DaemonAPI.Method.simulatorsList, Optional<String>.none, returning: DaemonAPI.SimulatorList.self) },
            boot: { udid in _ = try await self.client(forAgent: agentID).call(
                DaemonAPI.Method.simulatorsBoot, DaemonAPI.SimulatorRequest(udid: udid)) },
            shutdown: { udid in _ = try await self.client(forAgent: agentID).call(
                DaemonAPI.Method.simulatorsShutdown, DaemonAPI.SimulatorRequest(udid: udid)) },
            screen: { udid, maxHeight in try await self.client(forAgent: agentID).call(
                DaemonAPI.Method.simulatorsScreen, DaemonAPI.SimulatorScreenRequest(udid: udid, maxHeight: maxHeight),
                returning: DaemonAPI.SimulatorScreen.self) },
            tap: { udid, x, y in _ = try await self.client(forAgent: agentID).call(
                DaemonAPI.Method.simulatorsTap, DaemonAPI.SimulatorTapRequest(udid: udid, x: x, y: y)) },
            home: { udid in _ = try await self.client(forAgent: agentID).call(
                DaemonAPI.Method.simulatorsHome, DaemonAPI.SimulatorRequest(udid: udid)) })
    }
}
