import AgentsKit
import Foundation
import Observation

/// The window's end of an agent's shell.
///
/// One per agent per window. It talks to the daemon, which owns the shell; this holds
/// nothing but a way to reach it and the state it was last told about. Closing the
/// window takes this with it and leaves the shell running (FR-026).
@MainActor
@Observable
final class ShellClient {
    let agentID: UUID
    private(set) var state: ShellState = .live
    private(set) var isAttached = false
    private(set) var problem: String?
    /// Bytes the daemon says were dropped off the front of the buffer. Non-zero means
    /// the replay is the end of the session rather than the whole of it.
    private(set) var dropped = 0

    /// Where incoming bytes go: the emulator, set by the pane once its view exists.
    @ObservationIgnored var onOutput: ((Data) -> Void)?

    private let model: AppModel

    init(agentID: UUID, model: AppModel) {
        self.agentID = agentID
        self.model = model
    }

    func attach(rows: Int, cols: Int) async {
        guard !isAttached else { return }
        do {
            let response = try await model.attachShell(agentID: agentID, rows: rows, cols: cols)
            state = response.state
            dropped = response.dropped
            isAttached = true
            problem = nil
            // Replay what the shell printed before this window was looking. Feeding
            // the bytes gives the same screen as having watched all along, which is
            // the property the whole design rests on.
            if !response.scrollback.isEmpty { onOutput?(response.scrollback) }
        } catch {
            problem = model.describeForShell(error)
            isAttached = false
        }
    }

    func detach() async {
        guard isAttached else { return }
        isAttached = false
        await model.detachShell(agentID: agentID)
    }

    func send(_ data: Data) async {
        guard state.isLive else { return }
        await model.sendToShell(agentID: agentID, bytes: data)
    }

    func resize(rows: Int, cols: Int) async {
        guard state.isLive, rows > 0, cols > 0 else { return }
        await model.resizeShell(agentID: agentID, rows: rows, cols: cols)
    }

    /// A new shell, once this one is over (FR-024).
    func restart(rows: Int, cols: Int) async {
        do {
            let response = try await model.restartShell(agentID: agentID, rows: rows, cols: cols)
            state = response.state
            dropped = 0
            isAttached = true
            problem = nil
        } catch {
            problem = model.describeForShell(error)
        }
    }

    // MARK: Told by the daemon

    func received(_ data: Data) {
        onOutput?(data)
    }

    func received(_ state: ShellState) {
        self.state = state
    }
}
