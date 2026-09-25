import Foundation
import Observation

/// A window's or a phone's end of an agent's shell.
///
/// One per agent per client. It talks to the daemon, which owns the shell; this holds
/// nothing but a way to reach it and the state it was last told about. Closing the
/// window, or putting the phone away, takes this with it and leaves the shell running
/// (FR-026).
///
/// In Core since 034, so the phone attaches to the same shell the Mac's pane shows
/// rather than having one of its own: one shell per agent, owned by the Mac, and every
/// screen looking at it is a view of it.
@MainActor
@Observable
public final class ShellClient {
    public let agentID: UUID
    public private(set) var state: ShellState = .live
    public private(set) var isAttached = false
    public private(set) var problem: String?
    /// Bytes the daemon says were dropped off the front of the buffer. Non-zero means
    /// the replay is the end of the session rather than the whole of it.
    public private(set) var dropped = 0

    /// Where incoming bytes go: the emulator, set by the pane once its view exists.
    @ObservationIgnored public var onOutput: ((Data) -> Void)?

    private let client: DaemonClient
    private let describe: @MainActor (any Error) -> String
    /// This screen's size, as last laid out. Sent with every keystroke, so the shell
    /// takes the size of whichever screen typed last (034, US4 scenario 5).
    @ObservationIgnored private var rows = 0
    @ObservationIgnored private var cols = 0

    public init(agentID: UUID, client: DaemonClient,
                describe: @escaping @MainActor (any Error) -> String) {
        self.agentID = agentID
        self.client = client
        self.describe = describe
    }

    public func attach(rows: Int, cols: Int) async {
        guard !isAttached else { return }
        remember(rows: rows, cols: cols)
        do {
            let response = try await client.call(
                DaemonAPI.Method.shellAttach,
                DaemonAPI.ShellAttachRequest(agentID: agentID, rows: rows, cols: cols),
                returning: DaemonAPI.ShellAttachResponse.self)
            state = response.state
            dropped = response.dropped
            isAttached = true
            problem = nil
            // Replay what the shell printed before this screen was looking. Feeding
            // the bytes gives the same screen as having watched all along, which is
            // the property the whole design rests on.
            if !response.scrollback.isEmpty { onOutput?(response.scrollback) }
        } catch {
            problem = describe(error)
            isAttached = false
        }
    }

    /// Detaching never stops anything. A build carries on (FR-026).
    public func detach() async {
        guard isAttached else { return }
        isAttached = false
        try? await client.call(DaemonAPI.Method.shellDetach, DaemonAPI.AgentRequest(agentID: agentID))
    }

    /// The connection went: whatever the daemon knew of this screen went with it. The
    /// next attach replays what was missed.
    public func lostConnection() {
        isAttached = false
    }

    public func send(_ data: Data) async {
        guard state.isLive else { return }
        try? await client.call(DaemonAPI.Method.shellInput,
                               DaemonAPI.ShellInputRequest(agentID: agentID, bytes: data,
                                                           rows: rows > 0 ? rows : nil,
                                                           cols: cols > 0 ? cols : nil))
    }

    public func resize(rows: Int, cols: Int) async {
        guard state.isLive, rows > 0, cols > 0 else { return }
        remember(rows: rows, cols: cols)
        try? await client.call(DaemonAPI.Method.shellResize,
                               DaemonAPI.ShellResizeRequest(agentID: agentID, rows: rows, cols: cols))
    }

    /// A new shell, once this one is over (FR-024).
    public func restart(rows: Int, cols: Int) async {
        remember(rows: rows, cols: cols)
        do {
            let response = try await client.call(
                DaemonAPI.Method.shellRestart,
                DaemonAPI.ShellAttachRequest(agentID: agentID, rows: rows, cols: cols),
                returning: DaemonAPI.ShellAttachResponse.self)
            state = response.state
            dropped = 0
            isAttached = true
            problem = nil
        } catch {
            problem = describe(error)
        }
    }

    // MARK: Told by the daemon

    public func received(_ data: Data) {
        onOutput?(data)
    }

    public func received(_ state: ShellState) {
        self.state = state
    }

    private func remember(rows: Int, cols: Int) {
        guard rows > 0, cols > 0 else { return }
        self.rows = rows
        self.cols = cols
    }
}
