import Foundation

/// The shells the daemon is holding, as many per agent as the user opened (055).
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

    /// One shell: whose, and which of theirs. Zero is the one every agent has.
    public struct Key: Hashable, Sendable {
        public var agentID: UUID
        public var shell: Int

        public init(agentID: UUID, shell: Int = 0) {
            self.agentID = agentID
            self.shell = shell
        }
    }

    private let lock = NSLock()
    private var sessions: [Key: ShellSession] = [:]
    /// Where a shell's output goes. One broadcaster, not a sink per connection: the
    /// daemon already sends every notification to every window, and a second way to
    /// route one would be a second way to talk to the daemon. A window ignores agents
    /// it is not showing, and two windows on one agent both hear it, which is FR-023
    /// for free.
    private var broadcast: (@Sendable (Key, ShellEvent) -> Void)?

    /// Agents whose shell has gone since a window last looked, with the reason. Held so
    /// that the next attach can say what happened rather than silently handing over a
    /// new shell (FR-029).
    private var epitaphs: [Key: String] = [:]

    public enum ShellEvent: Sendable {
        case output(Data)
        case state(ShellState)
    }

    public init() {}

    // MARK: Where output goes

    public func setBroadcaster(_ broadcast: @escaping @Sendable (Key, ShellEvent) -> Void) {
        lock.lock(); defer { lock.unlock() }
        self.broadcast = broadcast
    }

    // MARK: Attaching

    /// Give this connection one of an agent's shells, starting it if there is none.
    public func attach(agentID: UUID,
                       shell: Int = 0,
                       folder: URL,
                       rows: Int,
                       cols: Int) throws -> Attachment {
        let key = Key(agentID: agentID, shell: shell)
        lock.lock()
        let existing = sessions[key]
        let epitaph = epitaphs.removeValue(forKey: key)
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

        let session = try start(key, folder: folder, rows: rows, cols: cols)
        // The previous shell died with the daemon or the machine. Say so on this first
        // attach rather than pretending this new one is the old one.
        if let epitaph {
            let note = "\r\n\u{1B}[2m\(epitaph)\u{1B}[0m\r\n"
            push(key, .output(Data(note.utf8)))
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
    public func detach(agentID: UUID, shell: Int = 0) {
        // Deliberately without consequence. See above.
    }

    /// The shells held for an agent, by number, in the order they were opened. When
    /// none is held yet, the first, which attaching will start: every agent has one.
    public func shells(for agentID: UUID) -> [Int] {
        lock.lock(); defer { lock.unlock() }
        let held = sessions.keys.filter { $0.agentID == agentID }.map(\.shell).sorted()
        return held.isEmpty ? [0] : held
    }

    /// The user closed this shell's tab: end it and forget it, output and all. Unlike
    /// detaching, this is the user saying they are finished with it (055).
    public func close(agentID: UUID, shell: Int) {
        let key = Key(agentID: agentID, shell: shell)
        lock.lock()
        let session = sessions.removeValue(forKey: key)
        epitaphs[key] = nil
        lock.unlock()
        session?.release(reason: "This shell was closed.")
    }

    private func start(_ key: Key, folder: URL, rows: Int, cols: Int) throws -> ShellSession {
        let session = ShellSession(
            agentID: key.agentID,
            folder: folder,
            rows: rows,
            cols: cols,
            onOutput: { [weak self] data in self?.push(key, .output(data)) },
            onStateChange: { [weak self] state in self?.push(key, .state(state)) })

        if case .failed(let reason) = session.state {
            throw Failure.willNotStart(reason)
        }
        lock.lock()
        sessions[key] = session
        lock.unlock()
        return session
    }

    /// Start a new shell in place of one that is over (FR-024).
    public func restart(agentID: UUID, shell: Int = 0, folder: URL, rows: Int, cols: Int) throws -> Attachment {
        let key = Key(agentID: agentID, shell: shell)
        lock.lock()
        let existing = sessions[key]
        lock.unlock()
        if let existing, existing.state.isLive { throw Failure.stillLive }

        lock.lock()
        sessions[key] = nil
        lock.unlock()

        let session = try start(key, folder: folder, rows: rows, cols: cols)
        push(key, .state(session.state))
        return Attachment(state: session.state,
                          scrollback: Data(),
                          dropped: 0,
                          startedAt: session.startedAt)
    }

    // MARK: Using one

    public func write(agentID: UUID, shell: Int = 0, data: Data) throws {
        guard let session = session(for: agentID, shell: shell), session.state.isLive else { throw Failure.notLive }
        session.write(data)
    }

    public func resize(agentID: UUID, shell: Int = 0, rows: Int, cols: Int) {
        session(for: agentID, shell: shell)?.resize(rows: rows, cols: cols)
    }

    public func signal(agentID: UUID, shell: Int = 0, number: Int32) throws {
        guard let session = session(for: agentID, shell: shell), session.state.isLive else { throw Failure.notLive }
        session.signal(number)
    }

    public func session(for agentID: UUID, shell: Int = 0) -> ShellSession? {
        lock.lock(); defer { lock.unlock() }
        return sessions[Key(agentID: agentID, shell: shell)]
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
                         threshold: TimeInterval = ShellSession.idleThreshold) -> [Key] {
        lock.lock()
        let all = sessions
        lock.unlock()

        var reaped: [Key] = []
        for (key, session) in all where session.state.isLive {
            guard session.isIdle(now: now, threshold: threshold) else { continue }
            session.release(reason: "This shell was let go after sitting idle. Start a new one when you need it.")
            reaped.append(key)
        }
        return reaped
    }

    /// The daemon is going. Kill every shell so no pty is orphaned, and leave a note
    /// for each so the next window is told rather than handed a new shell in silence.
    public func shutDown() {
        lock.lock()
        let all = sessions
        sessions = [:]
        for (key, session) in all where session.state.isLive {
            epitaphs[key] = "The shell that was running here went when the helper did."
        }
        lock.unlock()

        for session in all.values {
            session.killForShutdown()
        }
    }

    // MARK: Pushing

    private func push(_ key: Key, _ event: ShellEvent) {
        lock.lock()
        let sink = broadcast
        lock.unlock()
        sink?(key, event)
    }
}
