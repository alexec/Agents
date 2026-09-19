import Darwin
import Foundation

/// One shell, in one agent's folder, owned by the daemon.
///
/// It holds a pty and a byte buffer and nothing else. It does not parse what the shell
/// printed, does not know what is on screen, and has never heard of a window. That is
/// the point: emulation is the app's, and this outlives every window (plan decision 2).
public final class ShellSession: @unchecked Sendable {
    public let agentID: UUID
    public let folder: URL

    private let lock = NSLock()
    private var pty: PTY?
    private var buffer: Scrollback
    private var _state: ShellState = .live
    private var _lastInputAt: Date
    public let startedAt = Date()

    /// New bytes, as the shell produces them. The daemon forwards these to whichever
    /// windows are attached, and appends them to the buffer first so a window that
    /// attaches a moment later still sees them.
    private let onOutput: @Sendable (Data) -> Void
    private let onStateChange: @Sendable (ShellState) -> Void

    public init(agentID: UUID,
                folder: URL,
                shell: URL? = nil,
                rows: Int = 24,
                cols: Int = 80,
                cap: Int = Scrollback.defaultCap,
                onOutput: @escaping @Sendable (Data) -> Void,
                onStateChange: @escaping @Sendable (ShellState) -> Void) {
        self.agentID = agentID
        self.folder = folder
        self.buffer = Scrollback(cap: cap)
        self.onOutput = onOutput
        self.onStateChange = onStateChange
        self._lastInputAt = Date()

        // The user's own shell, not ours and not the agent's (FR-020, FR-025).
        let executable = shell ?? URL(filePath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")

        var environment = LoginShellPath.environment()
        environment["TERM"] = "xterm-256color"
        // So a program that asks can tell, and so anything that greps for it in a
        // parent's environment finds the truth rather than guessing.
        environment["TERM_PROGRAM"] = "Agents"

        do {
            pty = try PTY(executable: executable,
                          // A login shell, so the user's own configuration is there.
                          // This is their shell; it should look like it.
                          arguments: ["-l"],
                          cwd: folder,
                          environment: environment,
                          rows: rows,
                          cols: cols,
                          onOutput: { [weak self] data in
                              guard let self else { return }
                              self.lock.lock()
                              self.buffer.append(data)
                              self.lock.unlock()
                              self.onOutput(data)
                          },
                          onExit: { [weak self] status in
                              self?.moveTo(.exited(status: status))
                          })
        } catch PTY.Failure.folderGone(let path) {
            _state = .failed(reason: "The folder this agent works in is not there any more: \(path)")
        } catch PTY.Failure.shellMissing(let path) {
            _state = .failed(reason: "Your shell is not where the system says it is: \(path)")
        } catch PTY.Failure.couldNotStart(let reason) {
            _state = .failed(reason: "The shell would not start: \(reason)")
        } catch {
            _state = .failed(reason: "The shell would not start.")
        }
    }

    // MARK: What it is

    public var state: ShellState {
        lock.lock(); defer { lock.unlock() }
        return _state
    }

    public var lastInputAt: Date {
        lock.lock(); defer { lock.unlock() }
        return _lastInputAt
    }

    public var scrollback: Scrollback {
        lock.lock(); defer { lock.unlock() }
        return buffer
    }

    public var rows: Int { pty?.rows ?? 0 }
    public var cols: Int { pty?.cols ?? 0 }

    /// A job is running in front of the shell. The daemon counts this as work it is
    /// holding and will not shut down under it (FR-027).
    public var isBusy: Bool {
        guard state.isLive, let pty else { return false }
        return pty.hasForegroundJob
    }

    /// Idle: nothing running, and nothing typed for a while.
    ///
    /// A pure function of three inputs, written as one so it can be tested as one
    /// (FR-028). A busy shell is never idle however long ago the user last typed: they
    /// started a build and went to lunch, which is exactly the case FR-026 exists for.
    public static func isIdle(isBusy: Bool, lastInputAt: Date, now: Date, threshold: TimeInterval) -> Bool {
        if isBusy { return false }
        return now.timeIntervalSince(lastInputAt) >= threshold
    }

    /// How long a shell may sit doing nothing before the daemon lets it go.
    ///
    /// Two hours: long enough that lunch, a meeting, or an afternoon on another agent
    /// does not cost you a prompt you were using, and short enough that shells do not
    /// accumulate for every agent ever opened. A shell with a job running is never
    /// idle, so this never interrupts work; it only collects prompts nobody came back
    /// to.
    public static let idleThreshold: TimeInterval = 60 * 60 * 2

    public func isIdle(now: Date = Date(), threshold: TimeInterval = ShellSession.idleThreshold) -> Bool {
        Self.isIdle(isBusy: isBusy, lastInputAt: lastInputAt, now: now, threshold: threshold)
    }

    // MARK: Doing

    public func write(_ data: Data) {
        guard state.isLive else { return }
        lock.lock()
        _lastInputAt = Date()
        lock.unlock()
        pty?.write(data)
    }

    public func resize(rows: Int, cols: Int) {
        guard state.isLive else { return }
        pty?.resize(rows: rows, cols: cols)
    }

    public func signal(_ number: Int32) {
        guard state.isLive else { return }
        pty?.signal(number)
    }

    /// Let go of it, with a reason the pane can show. Used by the idle reaper and by the
    /// daemon on its way out.
    public func release(reason: String) {
        guard state.isLive else { return }
        pty?.terminate()
        pty?.killNow()
        pty?.stopReading()
        moveTo(.released(reason: reason))
    }

    /// End it now, for the daemon's own exit, so no pty is orphaned.
    public func killForShutdown() {
        pty?.killNow()
        pty?.stopReading()
    }

    private func moveTo(_ next: ShellState) {
        lock.lock()
        guard _state.isLive else { lock.unlock(); return }
        _state = next
        lock.unlock()
        onStateChange(next)
    }
}
