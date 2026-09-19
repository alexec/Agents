import Foundation

/// Serving the user's shells.
///
/// These are the user's, not the agent's. Nothing typed here reaches the agent, and
/// nothing the agent runs appears here (FR-025). The daemon holds them for the same
/// reason it holds agents: so a build outlives the window that started it.
extension DaemonCore {
    /// Give a window the shell for an agent, starting one if there is none.
    func attachShell(_ request: DaemonAPI.ShellAttachRequest) throws -> DaemonAPI.ShellAttachResponse {
        guard let agent = agents[request.agentID] else {
            throw JSONRPCError(code: DaemonAPI.Failure.noSuchAgent, message: "There is no such agent.")
        }
        do {
            let attachment = try shells.attach(agentID: agent.id,
                                               folder: agent.cwd,
                                               rows: request.rows,
                                               cols: request.cols)
            return DaemonAPI.ShellAttachResponse(state: attachment.state,
                                                 scrollback: attachment.scrollback,
                                                 dropped: attachment.dropped,
                                                 startedAt: attachment.startedAt)
        } catch ShellHost.Failure.willNotStart(let reason) {
            throw JSONRPCError(code: DaemonAPI.Failure.shellWillNotStart, message: reason)
        }
    }

    /// The window stopped looking. Nothing is killed (FR-026).
    func detachShell(_ agentID: UUID) {
        shells.detach(agentID: agentID)
    }

    func writeToShell(_ request: DaemonAPI.ShellInputRequest) throws {
        do {
            try shells.write(agentID: request.agentID, data: request.bytes)
        } catch ShellHost.Failure.notLive {
            throw JSONRPCError(code: DaemonAPI.Failure.shellNotLive, message: "That shell is not running.")
        }
    }

    func resizeShell(_ request: DaemonAPI.ShellResizeRequest) {
        shells.resize(agentID: request.agentID, rows: request.rows, cols: request.cols)
    }

    func signalShell(_ request: DaemonAPI.ShellSignalRequest) throws {
        do {
            try shells.signal(agentID: request.agentID, number: request.signal)
        } catch ShellHost.Failure.notLive {
            throw JSONRPCError(code: DaemonAPI.Failure.shellNotLive, message: "That shell is not running.")
        }
    }

    /// A new shell for an agent whose old one is over (FR-024).
    func restartShell(_ request: DaemonAPI.ShellAttachRequest) throws -> DaemonAPI.ShellAttachResponse {
        guard let agent = agents[request.agentID] else {
            throw JSONRPCError(code: DaemonAPI.Failure.noSuchAgent, message: "There is no such agent.")
        }
        do {
            let attachment = try shells.restart(agentID: agent.id,
                                                folder: agent.cwd,
                                                rows: request.rows,
                                                cols: request.cols)
            return DaemonAPI.ShellAttachResponse(state: attachment.state,
                                                 scrollback: attachment.scrollback,
                                                 dropped: attachment.dropped,
                                                 startedAt: attachment.startedAt)
        } catch ShellHost.Failure.stillLive {
            throw JSONRPCError(code: DaemonAPI.Failure.shellNotLive,
                               message: "That shell is still running.")
        } catch ShellHost.Failure.willNotStart(let reason) {
            throw JSONRPCError(code: DaemonAPI.Failure.shellWillNotStart, message: reason)
        }
    }

    /// Point the shell host's output at every window, the way every other notification
    /// goes out.
    ///
    /// Through one stream drained by one task, not a task per chunk. A shell hands
    /// over its output on its own queue, in order, and the only way to keep that order
    /// across the hop onto this actor is to make the hop once and queue behind it.
    /// Tasks started per chunk arrive in whatever order the runtime chooses.
    func connectShells() {
        let (events, continuation) = AsyncStream.makeStream(
            of: (UUID, ShellHost.ShellEvent).self, bufferingPolicy: .unbounded)
        shellEvents = continuation
        shellPump = Task { [weak self] in
            for await (agentID, event) in events {
                guard let self else { return }
                await self.forward(agentID, event)
            }
        }
        shells.setBroadcaster { [continuation] agentID, event in
            continuation.yield((agentID, event))
        }
    }

    private func forward(_ agentID: UUID, _ event: ShellHost.ShellEvent) {
        switch event {
        case .output(let data):
            broadcast(DaemonAPI.Notification.shellOutput,
                      DaemonAPI.ShellOutputNotification(agentID: agentID, bytes: data))
        case .state(let state):
            broadcast(DaemonAPI.Notification.shellStateChanged,
                      DaemonAPI.ShellStateNotification(agentID: agentID, state: state))
        }
    }

    /// Let go of shells nobody has touched for a long time (FR-028). Called on the same
    /// tick that decides whether the daemon has anything left to do.
    func reapIdleShells() {
        for agentID in shells.reapIdle() {
            DaemonLog.shared.write("let go of an idle shell for \(agentID)")
        }
    }
}
