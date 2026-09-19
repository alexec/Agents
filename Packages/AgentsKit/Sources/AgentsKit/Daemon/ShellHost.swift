import Foundation

/// The shells the daemon is holding, one per agent.
///
/// The daemon owns these for the same reason it owns agents: a build that dies when a
/// window closes is a build you cannot start before lunch. Attaching starts one;
/// detaching never stops one (FR-023, FR-026).
public final class ShellHost: @unchecked Sendable {
    /// What a window gets when it attaches.
    public struct Attachment: Sendable {
        public var state: ShellState
        /// Raw bytes for the client to replay into its own emulator. The daemon parses
        /// nothing (plan decision 2).
        public var scrollback: Data
        /// Bytes dropped off the front of the buffer over this shell's life. Non-zero
        /// means the replay is the end of the session rather than the whole of it.
        public var dropped: Int
        public var startedAt: Date

        public init(state: ShellState, scrollback: Data, dropped: Int, startedAt: Date) {
            self.state = state
            self.scrollback = scrollback
            self.dropped = dropped
            self.startedAt = startedAt
        }
    }

    public enum Failure: Error, Equatable {
        case willNotStart(String)
        case notLive
        case stillLive
    }

    private let lock = NSLock()
    private var sessions: [UUID: ShellSession] = [:]
    /// Where a shell's output goes. One broadcaster, not a sink per connection: the
    /// daemon already sends every notification to every window, and a second way to
    /// route one would be a second way to talk to the daemon. A window ignores agents
    /// it is not showing, and two windows on one agent both hear it, which is FR-023
    /// for free.
    private var broadcast: (@Sendable (UUID, ShellEvent) -> Void)?

    /// Agents whose shell has gone since a window last looked, with the reason. Held so
    /// that the next attach can say what happened rather than silently handing over a
    /// new shell (FR-029).
    private var epitaphs: [UUID: String] = [:]

    public enum ShellEvent: Sendable {
        case output(Data)
        case state(ShellState)
    }

    public init() {}

    // MARK: Where output goes

    public func setBroadcaster(_ broadcast: @escaping @Sendable (UUID, ShellEvent) -> Void) {
        lock.lock(); defer { lock.unlock() }
        self.broadcast = broadcast
    }

    // MARK: Attaching

    /// Give this connection the shell for an agent, starting one if there is none.
    public func attach(agentID: UUID,
                       folder: URL,
                       rows: Int,
                       cols: Int) throws -> Attachment {
        lock.lock()
        let existing = sessions[agentID]
        let epitaph = epitaphs.removeValue(forKey: agentID)
        lock.unlock()

        if let existing, existing.state.isLive {
            existing.resize(rows: rows, cols: cols)
            let buffer = existing.scrollback
            return Attachment(state: existing.state,
                              scrollback: buffer.tail,
                              dropped: buffer.dropped,
                              startedAt: existing.startedAt)
        }

        // A shell that is over but whose output is still worth reading stays until the
        // user asks for a new one. Its scrollback is kept readable (FR-029).
        if let existing, !existing.state.isLive {
            let buffer = existing.scrollback
            return Attachment(state: existing.state,
                              scrollback: buffer.tail,
                              dropped: buffer.dropped,
                              startedAt: existing.startedAt)
        }

        let session = try start(agentID: agentID, folder: folder, rows: rows, cols: cols)
        // The previous shell died with the daemon or the machine. Say so on this first
        // attach rather than pretending this new one is the old one.
        if let epitaph {
            let note = "\r\n\u{1B}[2m\(epitaph)\u{1B}[0m\r\n"
            push(agentID, .output(Data(note.utf8)))
        }
        let buffer = session.scrollback
        return Attachment(state: session.state,
                          scrollback: buffer.tail,
                          dropped: buffer.dropped,
                          startedAt: session.startedAt)
    }

    /// The window has stopped looking. Kills nothing and stops nothing: a shell
    /// belongs to the agent, not to whoever is watching it (FR-026). It exists as a
    /// named call because a window closing is a real event, and because the pane's own
    /// bookkeeping deserves a counterpart on this side.
    public func detach(agentID: UUID) {
        // Deliberately without consequence. See above.
    }

    private func start(agentID: UUID, folder: URL, rows: Int, cols: Int) throws -> ShellSession {
        let session = ShellSession(
            agentID: agentID,
            folder: folder,
            rows: rows,
            cols: cols,
            onOutput: { [weak self] data in self?.push(agentID, .output(data)) },
            onStateChange: { [weak self] state in self?.push(agentID, .state(state)) })

        if case .failed(let reason) = session.state {
            throw Failure.willNotStart(reason)
        }
        lock.lock()
        sessions[agentID] = session
        lock.unlock()
        return session
    }

    /// Start a new shell for an agent whose old one is over (FR-024).
    public func restart(agentID: UUID, folder: URL, rows: Int, cols: Int) throws -> Attachment {
        lock.lock()
        let existing = sessions[agentID]
        lock.unlock()
        if let existing, existing.state.isLive { throw Failure.stillLive }

        lock.lock()
        sessions[agentID] = nil
        lock.unlock()

        let session = try start(agentID: agentID, folder: folder, rows: rows, cols: cols)
        push(agentID, .state(session.state))
        return Attachment(state: session.state,
                          scrollback: Data(),
                          dropped: 0,
                          startedAt: session.startedAt)
    }

    // MARK: Using one

    public func write(agentID: UUID, data: Data) throws {
        guard let session = session(for: agentID), session.state.isLive else { throw Failure.notLive }
        session.write(data)
    }

    public func resize(agentID: UUID, rows: Int, cols: Int) {
        session(for: agentID)?.resize(rows: rows, cols: cols)
    }

    public func signal(agentID: UUID, number: Int32) throws {
        guard let session = session(for: agentID), session.state.isLive else { throw Failure.notLive }
        session.signal(number)
    }

    public func session(for agentID: UUID) -> ShellSession? {
        lock.lock(); defer { lock.unlock() }
        return sessions[agentID]
    }

    // MARK: Lifetime

    /// Shells with something running in them. The daemon counts these as work it is
    /// holding and will not exit under them (FR-027).
    public var busyCount: Int {
        lock.lock()
        let all = Array(sessions.values)
        lock.unlock()
        return all.count(where: \.isBusy)
    }

    /// Let go of shells that have been sitting idle (FR-028).
    ///
    /// A shell with a job running is never idle, whatever the clock says.
    @discardableResult
    public func reapIdle(now: Date = Date(),
                         threshold: TimeInterval = ShellSession.idleThreshold) -> [UUID] {
        lock.lock()
        let all = sessions
        lock.unlock()

        var reaped: [UUID] = []
        for (agentID, session) in all where session.state.isLive {
            guard session.isIdle(now: now, threshold: threshold) else { continue }
            session.release(reason: "This shell was let go after sitting idle. Start a new one when you need it.")
            reaped.append(agentID)
        }
        return reaped
    }

    /// The daemon is going. Kill every shell so no pty is orphaned, and leave a note
    /// for each so the next window is told rather than handed a new shell in silence.
    public func shutDown() {
        lock.lock()
        let all = sessions
        sessions = [:]
        for (agentID, session) in all where session.state.isLive {
            epitaphs[agentID] = "The shell that was running here went when the helper did."
        }
        lock.unlock()

        for session in all.values {
            session.killForShutdown()
        }
    }

    // MARK: Pushing

    private func push(_ agentID: UUID, _ event: ShellEvent) {
        lock.lock()
        let sink = broadcast
        lock.unlock()
        sink?(agentID, event)
    }
}
