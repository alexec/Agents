import Darwin
import Foundation

/// A program running on a pseudo-terminal.
///
/// Not `Process`, which gives pipes. A pipe is not a terminal: `isatty` is false, so
/// programs switch to their batch behaviour, and there is no process group for `^C` to
/// reach. What `Process` cannot do is ask for a session of its own, which is what makes
/// the child's tty its controlling terminal, so this goes to `posix_spawn` directly.
///
/// The recipe was proved on this Mac before it was written: `openpty`, then
/// `posix_spawn` with `POSIX_SPAWN_SETSID`, then the child opens the slave device as
/// its first tty, which BSD makes the controlling terminal. See research section 2.
public final class PTY: @unchecked Sendable {
    public enum Failure: Error, Equatable {
        case couldNotOpen
        case couldNotStart(String)
        case folderGone(String)
        case shellMissing(String)
    }

    /// The master side. Read what the program wrote; write what the user typed.
    private var master: Int32 = -1
    public private(set) var pid: pid_t = -1
    private let lock = NSLock()
    private var reader: DispatchSourceRead?
    private let queue = DispatchQueue(label: "com.alexecollins.agents.pty")

    public private(set) var rows: Int
    public private(set) var cols: Int

    /// Called with whatever the program wrote, as it writes it, on a background queue.
    private let onOutput: @Sendable (Data) -> Void
    /// Called once, when the program is gone.
    private let onExit: @Sendable (Int32) -> Void

    public init(executable: URL,
                arguments: [String] = [],
                cwd: URL,
                environment: [String: String],
                rows: Int = 24,
                cols: Int = 80,
                onOutput: @escaping @Sendable (Data) -> Void,
                onExit: @escaping @Sendable (Int32) -> Void) throws {
        self.rows = rows
        self.cols = cols
        self.onOutput = onOutput
        self.onExit = onExit

        // A shell started in a folder that is not there fails in a way worth naming,
        // rather than as a generic spawn error.
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw Failure.folderGone(cwd.path)
        }
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw Failure.shellMissing(executable.path)
        }

        var slave: Int32 = -1
        var size = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&master, &slave, nil, nil, &size) == 0 else { throw Failure.couldNotOpen }
        guard let slaveName = ptsname(master).map({ String(cString: $0) }) else {
            Darwin.close(master); Darwin.close(slave)
            throw Failure.couldNotOpen
        }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)

        // Every signal back to its default in the child.
        //
        // Signal dispositions are inherited, and a host process that ignores SIGTERM,
        // SIGINT or SIGPIPE hands that ignoring to the shell and to everything the
        // user runs in it. That was found here rather than reasoned about: a test that
        // had a shell signal itself watched it carry on and exit cleanly, because the
        // test host ignored SIGTERM. A terminal whose ^C does nothing in some hosts
        // and works in others is not a terminal.
        var defaults = sigset_t()
        sigfillset(&defaults)
        posix_spawnattr_setsigdefault(&attributes, &defaults)

        // And nothing blocked. The mask is inherited separately from the dispositions,
        // and resetting only the dispositions is not enough: a blocked signal stays
        // pending and never runs. This was found by watching a shell told to terminate
        // itself exit cleanly instead, inside a host that blocks SIGTERM. Both halves
        // are needed, and neither is obvious until a terminal misbehaves in one
        // application and not another.
        var unblocked = sigset_t()
        sigemptyset(&unblocked)
        posix_spawnattr_setsigmask(&attributes, &unblocked)

        // SETSID is the piece `Process` does not expose. Without a session of its own
        // the child has no controlling terminal, and ^C has no process group to reach.
        posix_spawnattr_setflags(&attributes,
                                 Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        // Opened by the child, after setsid, so BSD makes it the controlling terminal.
        posix_spawn_file_actions_addopen(&actions, 0, slaveName, O_RDWR, 0)
        posix_spawn_file_actions_adddup2(&actions, 0, 1)
        posix_spawn_file_actions_adddup2(&actions, 0, 2)

        defer {
            posix_spawnattr_destroy(&attributes)
            posix_spawn_file_actions_destroy(&actions)
        }

        let argv = [executable.path] + arguments
        var cArgs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
        cArgs.append(nil)
        var cEnv: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") }
        cEnv.append(nil)
        defer {
            for pointer in cArgs where pointer != nil { free(pointer) }
            for pointer in cEnv where pointer != nil { free(pointer) }
        }

        var spawned: pid_t = 0
        let previous = FileManager.default.currentDirectoryPath
        // posix_spawn has no working-directory action on this platform, so the folder
        // is set around the call. The lock keeps two starts from interleaving.
        PTY.spawnLock.lock()
        FileManager.default.changeCurrentDirectoryPath(cwd.path)
        let result = posix_spawn(&spawned, executable.path, &actions, &attributes, &cArgs, &cEnv)
        FileManager.default.changeCurrentDirectoryPath(previous)
        PTY.spawnLock.unlock()

        // The parent has no use for the slave: holding it open would keep the master
        // from ever reporting end of file when the child goes.
        Darwin.close(slave)

        guard result == 0 else {
            Darwin.close(master)
            master = -1
            throw Failure.couldNotStart(String(cString: strerror(result)))
        }
        pid = spawned
        startReading()
    }

    private static let spawnLock = NSLock()

    private func startReading() {
        let source = DispatchSource.makeReadSource(fileDescriptor: master, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            let count = read(self.master, &buffer, buffer.count)
            if count > 0 {
                self.onOutput(Data(buffer[0..<count]))
            } else {
                // End of file on the master means the child let go of the tty.
                self.finish()
            }
        }
        source.setCancelHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            if self.master >= 0 { Darwin.close(self.master); self.master = -1 }
            self.lock.unlock()
        }
        reader = source
        source.resume()
    }

    private var hasFinished = false

    private func finish() {
        lock.lock()
        guard !hasFinished else { lock.unlock(); return }
        hasFinished = true
        lock.unlock()

        reader?.cancel()
        reader = nil

        // End of file on the master does not mean the child has been reaped, so wait
        // for it properly. Blocking is safe here: the tty is closed, so it is going.
        //
        // The status is only meaningful when waitpid actually returned our child. An
        // earlier version read `status` regardless, and a child killed by a signal
        // reported as a clean exit, because the untouched variable was still zero.
        var status: Int32 = 0
        var reaped = waitpid(pid, &status, 0)
        while reaped == -1 && errno == EINTR {
            reaped = waitpid(pid, &status, 0)
        }
        onExit(reaped == pid ? exitCode(from: status) : Self.unknownExitCode)
    }

    /// Reported when the child is gone but its status could not be collected, which
    /// happens if something else reaped it first. Better than claiming a clean exit.
    public static let unknownExitCode: Int32 = -1

    private func exitCode(from status: Int32) -> Int32 {
        // A signalled child reports as the shell does: 128 plus the signal.
        if status & 0x7F == 0 { return (status >> 8) & 0xFF }
        return 128 + (status & 0x7F)
    }

    // MARK: Talking to it

    public func write(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard master >= 0 else { return }
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var written = 0
            while written < raw.count {
                let n = Darwin.write(master, base.advanced(by: written), raw.count - written)
                if n <= 0 { break }
                written += n
            }
        }
    }

    public func resize(rows: Int, cols: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard master >= 0, rows > 0, cols > 0 else { return }
        self.rows = rows
        self.cols = cols
        var size = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(master, TIOCSWINSZ, &size)
        // The kernel sends SIGWINCH to the foreground process group by itself.
    }

    /// Send a signal to the program's process group, so it reaches the foreground job
    /// rather than only the shell.
    public func signal(_ number: Int32) {
        guard pid > 0 else { return }
        let group = tcgetpgrp(master)
        if group > 0 {
            killpg(group, number)
        } else {
            kill(pid, number)
        }
    }

    public var isRunning: Bool {
        guard pid > 0, !hasFinished else { return false }
        return kill(pid, 0) == 0
    }

    /// Whether the shell has a job running in front of it.
    ///
    /// The foreground process group differs from the shell's own when the shell is
    /// waiting on a child. That is the whole of "busy": a build is running, so the
    /// daemon is holding work and must not shut down under it (FR-027).
    public var hasForegroundJob: Bool {
        lock.lock()
        defer { lock.unlock() }
        guard master >= 0, pid > 0 else { return false }
        let group = tcgetpgrp(master)
        return group > 0 && group != pid
    }

    public func terminate() {
        guard isRunning else { return }
        signal(SIGHUP)
    }

    /// Not named `kill`: that shadows the C function this file needs.
    public func killNow() {
        guard pid > 0 else { return }
        killpg(pid, SIGKILL)
        Darwin.kill(pid, SIGKILL)
    }

    /// Let go of the master descriptor. The program is not signalled: detaching a
    /// window must never end a build (FR-026).
    public func stopReading() {
        reader?.cancel()
        reader = nil
    }
}
