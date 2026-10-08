#if canImport(Darwin)
import Darwin
#elseif canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#endif
import CShims
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

    /// The child's side, held for as long as the child is alive.
    ///
    /// The parent has no use for it and the obvious thing is to close it the moment
    /// the child has been handed its own. That silently loses output. macOS throws
    /// away whatever is still sitting in a tty's queue at the **last** close of the
    /// slave, so a program that prints and exits before the reader has been scheduled
    /// — which is what a machine under load does — has everything it said discarded
    /// by the kernel, and the master reports end of file with nothing in front of it.
    /// Measured here: `echo one; echo two; echo three` delivered 0 of its 17 bytes,
    /// every time, whenever the first read landed after the child let go of the tty.
    ///
    /// Holding it means the child's close is never the last one, so nothing is
    /// discarded. Better than that, the kernel parks the child inside `exit` until
    /// the queue has been drained, so its last words cannot be outrun however busy
    /// the machine is.
    ///
    /// End of file still arrives on time, and for a better reason than before. The
    /// child is the leader of its own session and the tty is its controlling
    /// terminal, so BSD revokes the tty when it goes — which takes this descriptor
    /// with it and wakes the master, after the child has been drained rather than
    /// before. `finish` is reached exactly as it always was.
    private var slave: Int32 = -1

    public private(set) var pid: pid_t = -1
    private let lock = NSLock()
    private var reader: DispatchSourceRead?
    private let queue = DispatchQueue(label: "com.alexecollins.agents.pty")
    /// Watches the child so the tty is let go even in the case where the revoke above
    /// does not come. It does not wait for the child: `finish` is the one place the
    /// child is ever reaped, and two reapers race each other to ECHILD.
    private var exitWatcher: (any DispatchSourceProtocol)?

    public private(set) var rows: Int
    public private(set) var cols: Int

    /// Called with whatever the program wrote, as it writes it, on a background queue.
    private let onOutput: @Sendable (Data) -> Void
    /// Called once, when the program is gone.
    private let onExit: @Sendable (Int32) -> Void

    /// What has been read and not yet handed on. See `gathered`.
    ///
    /// Touched only on `queue`, which is serial, so it needs no lock and the bytes
    /// cannot get out of order.
    private var pending = Data()
    private var flushIsScheduled = false
    private var lastFlushAt: UInt64 = 0

    /// What was typed and not yet taken by the tty, and the watch that says when it
    /// has room again. Touched only on `writeQueue`, so a paste larger than the tty's
    /// input queue goes in whole and in order, and a slow program never stalls the
    /// caller (#401). A queue of its own, so typing is not held behind output being
    /// handed on.
    private let writeQueue = DispatchQueue(label: "com.alexecollins.agents.pty.write")
    private var outbox = Data()
    private var writer: DispatchSourceWrite?

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

        var size = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&master, &slave, nil, nil, &size) == 0 else { throw Failure.couldNotOpen }
        // Neither of these is ours to lend. `openpty` hands back plain descriptors,
        // and this process spawns other things — the agent runtimes among them — that
        // would otherwise walk off with somebody's terminal. The shell started below
        // is given its tty by name, so marking these costs it nothing.
        _ = fcntl(master, F_SETFD, FD_CLOEXEC)
        // Never block on it: a write to a tty whose input queue is full would hold the
        // caller, which is the daemon's actor, until the program read (#401).
        _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK)
        _ = fcntl(slave, F_SETFD, FD_CLOEXEC)
        guard let slaveName = ptsname(master).map({ String(cString: $0) }) else {
            POSIX.close(master); master = -1
            POSIX.close(slave); slave = -1
            throw Failure.couldNotOpen
        }

        var attributes: SpawnAttributes = Spawn.noAttributes
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
        // CLOEXEC_DEFAULT closes everything else the daemon has open: its lock, its
        // socket, the other shells' masters. A shell in a session of its own outlives
        // the daemon, and whatever it inherited it goes on holding — which is how a
        // dead daemon's lock ends up refusing to let the next one start.
        posix_spawnattr_setflags(&attributes,
                                 Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_SETSIGDEF
                                       | POSIX_SPAWN_SETSIGMASK | Spawn.closeOnExecByDefault))

        var actions: SpawnActions = Spawn.noActions
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
        _ = FileManager.default.changeCurrentDirectoryPath(cwd.path)
        let result = posix_spawn(&spawned, executable.path, &actions, &attributes, &cArgs, &cEnv)
        _ = FileManager.default.changeCurrentDirectoryPath(previous)
        PTY.spawnLock.unlock()

        guard result == 0 else {
            POSIX.close(master); master = -1
            POSIX.close(slave); slave = -1
            throw Failure.couldNotStart(String(cString: strerror(result)))
        }
        pid = spawned
        // The slave stays open here. See the note on the property: letting go of it
        // now is what makes the child's exit the tty's last close, and the kernel
        // discards anything still queued at a last close.
        startReading()
        watchForExit()
    }

    deinit {
        // A pty dropped while its child is still going would otherwise leave the
        // child parked in `exit` for ever, waiting for a reader that has gone.
        exitWatcher?.cancel()
        writer?.cancel()
        reader?.cancel()
        if slave >= 0 { POSIX.close(slave) }
        if master >= 0 { POSIX.close(master) }
    }

    private static let spawnLock = NSLock()

    /// Only ever called on `writeQueue`.
    private func closeMaster() {
        lock.lock()
        if master >= 0 { POSIX.close(master); master = -1 }
        lock.unlock()
        outbox = Data()
    }

    private func startReading() {
        let source = DispatchSource.makeReadSource(fileDescriptor: master, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            let count = read(self.master, &buffer, buffer.count)
            if count > 0 {
                self.pending.append(contentsOf: buffer[0..<count])
                self.gathered()
            } else if count < 0, errno == EAGAIN || errno == EINTR {
                // Woken with nothing to read after all. Not the end of anything.
                return
            } else {
                // End of file on the master means the child let go of the tty.
                self.finish()
            }
        }
        source.setCancelHandler { [weak self] in
            guard let self else { return }
            // A descriptor is closed only once no source watches it, so the write
            // watch, if there is one, goes first.
            self.writeQueue.async {
                guard let writer = self.writer else { return self.closeMaster() }
                self.writer = nil
                writer.setCancelHandler { self.closeMaster() }
                writer.cancel()
            }
        }
        reader = source
        source.resume()
    }

    /// Watch the child, so the tty is never held on behalf of somebody who has gone.
    ///
    /// Belt and braces rather than the main path: when the child goes, BSD revokes
    /// the controlling terminal and the master reports end of file by itself. This
    /// covers the child that somehow leaves without that happening, where the slave
    /// this side holds would otherwise keep the master silent for ever.
    ///
    /// It deliberately does not wait for the child. `finish` is the only place the
    /// child is ever reaped: a second waiter races the first and one of the two comes
    /// away with ECHILD and no status, which is how a shell that exited 3 was
    /// reported as having exited for no reason anyone could name.
    ///
    /// Nor does it let go the moment the process source fires. A child that is
    /// already on its way out when the source is registered — which is what a loaded
    /// machine makes of a short program — is refused by the kernel, and Dispatch
    /// reports that as an exit straight away. The child is then still parked in
    /// `exit` waiting for its last words to be read, with its own descriptors not yet
    /// closed, and letting go of this side there makes the child's close the last
    /// one: the kernel discards everything still queued, and the master reports end
    /// of file with nothing in front of it. So the slave is held until the child can
    /// be reaped, which is after the drain and the revoke.
    private func watchForExit() {
        #if canImport(Darwin)
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.exitWatcher?.cancel()
            self.releaseSlaveOnceReapable()
        }
        exitWatcher = source
        source.resume()
        #else
        // Linux has no process source, so this is the watch from the start; on Linux
        // it is the main path rather than the spare, because the master only reports
        // end of file once the slave this side holds is let go (037).
        releaseSlaveOnceReapable()
        #endif
    }

    /// Ask, without reaping, five times a second, and let go of the slave once the
    /// child is waiting to be reaped.
    private func releaseSlaveOnceReapable() {
        let pid = self.pid
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(200))
        timer.setEventHandler { [weak self] in
            guard let self, agents_has_exited(pid) == 1 else { return }
            self.exitWatcher?.cancel()
            self.exitWatcher = nil
            self.releaseSlave()
        }
        exitWatcher = timer
        timer.resume()
    }

    private func releaseSlave() {
        lock.lock()
        if slave >= 0 { POSIX.close(slave); slave = -1 }
        lock.unlock()
    }

    /// How long reads are gathered for before they are handed on, and how much may
    /// pile up before the wait is cut short.
    ///
    /// Eight milliseconds is half a frame: too short to see, long enough that a shell
    /// printing as fast as the kernel will let it hands over about a hundred times a
    /// second instead of thirty thousand.
    private static let flushInterval: UInt64 = 8_000_000
    private static let flushThreshold = 128 * 1024

    /// Something was read. Decide whether to pass it on now or let a little more
    /// arrive first.
    ///
    /// A pty master does not hand back what you ask for. Measured on this Mac: a
    /// shell printing 4.9MB came back in 38,057 reads averaging 128 bytes, because
    /// the tty's output queue in the kernel is small and the writer refills it as
    /// fast as it is drained. Passing each of those on by itself made 38,057
    /// notifications, and every one of them was encoded to JSON three times, written
    /// to a socket, decoded twice on the app's main actor and fed to the emulator.
    /// The bytes were never the cost. The count was.
    ///
    /// So the first read after a quiet moment goes straight out — that is an echoed
    /// keystroke, and it must not wait — and after that at most one handover every
    /// `flushInterval`. Chunking is not information: feeding an emulator the same
    /// bytes in different sized pieces gives the same screen, which is the property
    /// the daemon's scrollback already rests on (plan decision 2).
    private func gathered() {
        guard !flushIsScheduled else { return }
        let due = lastFlushAt &+ Self.flushInterval
        if pending.count >= Self.flushThreshold || DispatchTime.now().uptimeNanoseconds >= due {
            flushPending()
            return
        }
        flushIsScheduled = true
        queue.asyncAfter(deadline: DispatchTime(uptimeNanoseconds: due)) { [weak self] in
            guard let self else { return }
            self.flushIsScheduled = false
            self.flushPending()
        }
    }

    /// Hand over everything gathered so far. Only ever called on `queue`.
    private func flushPending() {
        lastFlushAt = DispatchTime.now().uptimeNanoseconds
        guard !pending.isEmpty else { return }
        let gathered = pending
        pending = Data()
        onOutput(gathered)
    }

    private var hasFinished = false

    private func finish() {
        lock.lock()
        guard !hasFinished else { lock.unlock(); return }
        hasFinished = true
        lock.unlock()

        // Whatever was still being gathered goes before the news that the program is
        // over, or the last line a command printed would arrive after its own exit —
        // or, for anyone who stops listening on exit, not at all.
        flushPending()

        reader?.cancel()
        reader = nil

        exitWatcher?.cancel()
        exitWatcher = nil
        // Nothing is reading any more, so the tty must not be held: a child part-way
        // through its own exit waits for its last words to be taken, and with nobody
        // to take them it would wait for ever.
        releaseSlave()

        // End of file on the master does not mean the child has been reaped, so wait
        // for it properly. Blocking is safe here: the tty is gone, so it is going.
        //
        // The status is only meaningful when waitpid actually returned our child. An
        // earlier version read `status` regardless, and a child killed by a signal
        // reported as a clean exit, because the untouched variable was still zero.
        var status: Int32 = 0
        var reaped = waitpid(pid, &status, 0)
        while reaped == -1 && errno == EINTR {
            reaped = waitpid(pid, &status, 0)
        }
        let code = reaped == pid ? exitCode(from: status) : Self.unknownExitCode
        onExit(code)
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

    /// Typed bytes, queued for the program and written as the tty takes them. Returns
    /// at once: the write itself happens on the write queue.
    public func write(_ data: Data) {
        guard !data.isEmpty else { return }
        writeQueue.async { [weak self] in
            guard let self else { return }
            self.outbox.append(data)
            self.drainOutbox()
        }
    }

    /// As much of the outbox as the tty will take now. What it will not take waits for
    /// it to have room: a short write or EAGAIN is the tty being full, not the end, and
    /// giving up there lost the rest of a paste. Only ever called on `writeQueue`.
    private func drainOutbox() {
        guard writer == nil else { return }
        lock.lock()
        let fd = master
        lock.unlock()
        guard fd >= 0 else { outbox = Data(); return }
        while !outbox.isEmpty {
            let n = outbox.withUnsafeBytes { raw in POSIX.write(fd, raw.baseAddress!, raw.count) }
            if n > 0 {
                outbox.removeFirst(n)
            } else if n < 0, errno == EINTR {
                continue
            } else if n < 0, errno == EAGAIN {
                let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: writeQueue)
                source.setEventHandler { [weak self] in
                    guard let self, let writer = self.writer else { return }
                    self.writer = nil
                    writer.cancel()
                    self.drainOutbox()
                }
                writer = source
                source.resume()
                return
            } else {
                // The tty has gone with the program. Nothing typed can reach it now.
                outbox = Data()
                return
            }
        }
    }

    public func resize(rows: Int, cols: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard master >= 0, rows > 0, cols > 0 else { return }
        self.rows = rows
        self.cols = cols
        _ = agents_set_winsize(master, UInt16(rows), UInt16(cols))
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
        POSIX.kill(pid, SIGKILL)
    }

    /// Let go of the master descriptor. The program is not signalled: detaching a
    /// window must never end a build (FR-026).
    public func stopReading() {
        // Anything gathered but not yet handed on is still worth having: a shell being
        // let go should not take its last few lines with it.
        queue.async { [weak self] in self?.flushPending() }
        reader?.cancel()
        reader = nil
        // And let the tty go with it. Nobody is draining the master any more, and a
        // child on its way out waits to be drained before it can finish going.
        releaseSlave()
    }
}
