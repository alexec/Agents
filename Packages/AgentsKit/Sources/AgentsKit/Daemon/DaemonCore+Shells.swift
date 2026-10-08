import Foundation

/// Serving the user's shells.
///
/// These are the user's, not the agent's. Nothing typed here reaches the agent, and
/// nothing the agent runs appears here (FR-025). The daemon holds them for the same
/// reason it holds agents: so a build outlives the window that started it.
extension DaemonCore {
    /// Give a window the shell for an agent, starting one if there is none.
    func attachShell(_ request: DaemonAPI.ShellAttachRequest,
                     from surface: Surface? = nil, connection: UUID? = nil) throws -> DaemonAPI.ShellAttachResponse {
        watchShell(request.agentID, from: surface, connection: connection)
        noteMacScreen(ShellHost.Key(agentID: request.agentID, shell: request.shell), from: surface, connection: connection)
        guard let agent = agents[request.agentID] else {
            throw JSONRPCError(code: DaemonAPI.Failure.noSuchAgent, message: "There is no such agent.")
        }
        do {
            let attachment = try shells.attach(agentID: agent.id,
                                               shell: request.shell,
                                               folder: agent.cwd,
                                               rows: request.rows,
                                               cols: request.cols)
            return DaemonAPI.ShellAttachResponse(state: attachment.state,
                                                 scrollback: attachment.scrollback,
                                                 dropped: attachment.dropped,
                                                 startedAt: attachment.startedAt,
                                                 folder: attachment.folder)
        } catch ShellHost.Failure.willNotStart(let reason) {
            throw JSONRPCError(code: DaemonAPI.Failure.shellWillNotStart, message: reason)
        }
    }

    /// The window stopped looking. Nothing is killed (FR-026).
    func detachShell(_ request: DaemonAPI.ShellRequest, connection: UUID? = nil) {
        if let connection {
            let key = ShellHost.Key(agentID: request.agentID, shell: request.shell)
            shellMacScreens[key]?.remove(connection)
            if shellMacScreens[key]?.isEmpty == true { shellMacScreens[key] = nil }
            shellWatchers[request.agentID]?.remove(connection)
            if shellWatchers[request.agentID]?.isEmpty == true { shellWatchers[request.agentID] = nil }
        }
        shells.detach(agentID: request.agentID, shell: request.shell)
    }

    /// The shells a window should show tabs for (055).
    func listShells(_ agentID: UUID) -> DaemonAPI.ShellListResponse {
        DaemonAPI.ShellListResponse(shells: shells.shells(for: agentID))
    }

    /// The user closed a shell's tab. Unlike detaching, this ends it (055).
    func closeShell(_ request: DaemonAPI.ShellRequest) {
        shellMacScreens[ShellHost.Key(agentID: request.agentID, shell: request.shell)] = nil
        shells.close(agentID: request.agentID, shell: request.shell)
    }

    /// A new tab: the next number after every shell the agent has, started now, so the
    /// number is taken before anyone else can pick it (#401).
    func openShell(_ request: DaemonAPI.ShellAttachRequest) throws -> DaemonAPI.ShellOpenResponse {
        guard let agent = agents[request.agentID] else {
            throw JSONRPCError(code: DaemonAPI.Failure.noSuchAgent, message: "There is no such agent.")
        }
        let next = (shells.shells(for: agent.id).max() ?? 0) + 1
        do {
            _ = try shells.attach(agentID: agent.id, shell: next, folder: agent.cwd,
                                  rows: request.rows, cols: request.cols)
        } catch ShellHost.Failure.willNotStart(let reason) {
            throw JSONRPCError(code: DaemonAPI.Failure.shellWillNotStart, message: reason)
        }
        return DaemonAPI.ShellOpenResponse(shell: next)
    }

    /// A Mac window attached to this shell: while it is, the shell keeps the Mac's size
    /// (#401). A connection that says nothing of itself is a window, as it always was.
    private func noteMacScreen(_ key: ShellHost.Key, from surface: Surface?, connection: UUID?) {
        guard let connection else { return }
        if case .device = surface { return }
        shellMacScreens[key, default: []].insert(connection)
    }

    /// Whether this size should be taken: a phone's is not while a Mac window shows the
    /// shell, so the Mac's lines never wrap to the phone's width (Alex, #401).
    private func takesSize(for key: ShellHost.Key, from surface: Surface?) -> Bool {
        guard case .device = surface else { return true }
        return shellMacScreens[key]?.isEmpty ?? true
    }

    /// A device that opened this shell hears it from now on (034). A window hears every
    /// shell already, and is not written down.
    private func watchShell(_ agentID: UUID, from surface: Surface?, connection: UUID?) {
        guard case .device = surface, let connection else { return }
        shellWatchers[agentID, default: []].insert(connection)
    }

    /// A connection has gone: it hears no shells now.
    func forgetShellWatcher(_ connection: UUID) {
        for key in shellMacScreens.keys {
            shellMacScreens[key]?.remove(connection)
            if shellMacScreens[key]?.isEmpty == true { shellMacScreens[key] = nil }
        }
        for agentID in shellWatchers.keys {
            shellWatchers[agentID]?.remove(connection)
            if shellWatchers[agentID]?.isEmpty == true { shellWatchers[agentID] = nil }
        }
    }

    func writeToShell(_ request: DaemonAPI.ShellInputRequest, from surface: Surface? = nil) throws {
        // The shell takes the size of whoever typed last (034, US4 scenario 5), except
        // that a Mac window showing it wins over a phone (#401). The daemon is the one
        // place that knows who that was: two screens on one shell each send their own
        // size with their keystrokes.
        if let rows = request.rows, let cols = request.cols, rows > 0, cols > 0,
           takesSize(for: ShellHost.Key(agentID: request.agentID, shell: request.shell), from: surface),
           let session = shells.session(for: request.agentID, shell: request.shell),
           session.rows != rows || session.cols != cols {
            shells.resize(agentID: request.agentID, shell: request.shell, rows: rows, cols: cols)
        }
        do {
            try shells.write(agentID: request.agentID, shell: request.shell, data: request.bytes)
        } catch ShellHost.Failure.notLive {
            throw JSONRPCError(code: DaemonAPI.Failure.shellNotLive, message: "That shell is not running.")
        }
    }

    func resizeShell(_ request: DaemonAPI.ShellResizeRequest, from surface: Surface? = nil) {
        guard takesSize(for: ShellHost.Key(agentID: request.agentID, shell: request.shell), from: surface) else { return }
        shells.resize(agentID: request.agentID, shell: request.shell, rows: request.rows, cols: request.cols)
    }

    func signalShell(_ request: DaemonAPI.ShellSignalRequest) throws {
        do {
            try shells.signal(agentID: request.agentID, shell: request.shell, number: request.signal)
        } catch ShellHost.Failure.notLive {
            throw JSONRPCError(code: DaemonAPI.Failure.shellNotLive, message: "That shell is not running.")
        }
    }

    /// A new shell for an agent whose old one is over (FR-024).
    func restartShell(_ request: DaemonAPI.ShellAttachRequest,
                      from surface: Surface? = nil, connection: UUID? = nil) throws -> DaemonAPI.ShellAttachResponse {
        watchShell(request.agentID, from: surface, connection: connection)
        noteMacScreen(ShellHost.Key(agentID: request.agentID, shell: request.shell), from: surface, connection: connection)
        guard let agent = agents[request.agentID] else {
            throw JSONRPCError(code: DaemonAPI.Failure.noSuchAgent, message: "There is no such agent.")
        }
        do {
            let attachment = try shells.restart(agentID: agent.id,
                                                shell: request.shell,
                                                folder: agent.cwd,
                                                rows: request.rows,
                                                cols: request.cols)
            return DaemonAPI.ShellAttachResponse(state: attachment.state,
                                                 scrollback: attachment.scrollback,
                                                 dropped: attachment.dropped,
                                                 startedAt: attachment.startedAt,
                                                 folder: attachment.folder)
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
            of: (ShellHost.Key, ShellHost.ShellEvent).self, bufferingPolicy: .unbounded)
        shellEvents = continuation
        shellPump = Task { [weak self] in
            for await (key, event) in events {
                guard let self else { return }
                await self.forward(key, event)
            }
        }
        shells.setBroadcaster { [continuation] key, event in
            continuation.yield((key, event))
        }
    }

    private func forward(_ key: ShellHost.Key, _ event: ShellHost.ShellEvent) {
        let agentID = key.agentID
        let method: String
        let value: any Encodable & Sendable
        switch event {
        case .output(let data, let offset):
            method = DaemonAPI.Notification.shellOutput
            value = DaemonAPI.ShellOutputNotification(agentID: agentID, shell: key.shell, bytes: data, offset: offset)
        case .state(let state):
            method = DaemonAPI.Notification.shellStateChanged
            value = DaemonAPI.ShellStateNotification(agentID: agentID, shell: key.shell, state: state)
        }
        // Every window, and only the devices that opened this shell (034): a phone on
        // WiFi does not carry an unrelated agent's build output because a Mac window
        // has that shell open. Without the addressed door — a test's daemon — it goes
        // to everyone, as it always did.
        guard addressed.isSet else {
            broadcast(method, value)
            return
        }
        let watchers = shellWatchers[agentID] ?? []
        send(method, value, to: { context in
            guard case .device = context.surface else { return true }
            return watchers.contains(context.id)
        })
    }

    /// Let go of shells nobody has touched for a long time (FR-028). Called on the same
    /// tick that decides whether the daemon has anything left to do.
    func reapIdleShells() {
        for key in shells.reapIdle() {
            DaemonLog.shared.write("let go of idle shell \(key.shell) for \(key.agentID)")
        }
    }
}
