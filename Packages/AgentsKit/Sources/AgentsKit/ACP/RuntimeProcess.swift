import CShims
import Foundation

/// A launched runtime, and the pipes to it.
///
/// Started with `posix_spawn` rather than `Process`, in a process group of its own
/// (#209). Claude runs through `npx`, whose node child is the runtime: signalling only
/// the process the daemon started left that child running, orphaned, holding the pipes.
/// Every signal here goes to the group, and when the process the daemon started exits,
/// whatever is left of its group is killed with it.
public final class RuntimeProcess: @unchecked Sendable {
    public let transport: FDTransport
    /// This side's descriptors, as numbered at launch: what `cleanUp` must give back.
    /// For a test to look for afterwards (#163).
    let heldDescriptors: [Int32]
    public let processIdentifier: Int32
    private let standardError: FileHandle
    /// Taken around every signal sent and around reaping, so a signal never reaches a
    /// group whose number has been given to somebody else since.
    private let lock = NSLock()
    private var exited = false

    public struct CouldNotStart: Error, CustomStringConvertible {
        public var executable: String
        public var reason: String
        public var description: String { "\(executable) could not start: \(reason)" }
    }

    public init(executable: URL,
                arguments: [String],
                cwd: URL,
                environment: [String: String],
                onStandardError: (@Sendable (String) -> Void)? = nil,
                onExit: @escaping @Sendable (Int32) -> Void) throws {
        // Three pipes: the child's stdin, stdout and stderr. This side's ends are kept out
        // of every other child; the child's ends are closed here once it has them.
        var pipes: [(read: Int32, write: Int32)] = []
        for _ in 0..<3 {
            var ends: [Int32] = [-1, -1]
            guard pipe(&ends) == 0 else {
                let reason = String(cString: strerror(errno))
                for (read, write) in pipes { POSIX.close(read); POSIX.close(write) }
                throw CouldNotStart(executable: executable.path, reason: reason)
            }
            for fd in ends { setCloseOnExec(fd) }
            pipes.append((ends[0], ends[1]))
        }
        let (stdin, stdout, stderr) = (pipes[0], pipes[1], pipes[2])

        var attributes: SpawnAttributes = Spawn.noAttributes
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Every signal at its default and none blocked, as `Process` did: the daemon
        // ignores SIGPIPE, and a runtime that inherited that would not die of one.
        var defaults = sigset_t()
        sigfillset(&defaults)
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        var unblocked = sigset_t()
        sigemptyset(&unblocked)
        posix_spawnattr_setsigmask(&attributes, &unblocked)
        // A group of its own, numbered as the child is, which every signal goes to.
        posix_spawnattr_setpgroup(&attributes, 0)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF
                                                     | POSIX_SPAWN_SETSIGMASK | Spawn.closeOnExecByDefault))

        var actions: SpawnActions = Spawn.noActions
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, stdin.read, 0)
        posix_spawn_file_actions_adddup2(&actions, stdout.write, 1)
        posix_spawn_file_actions_adddup2(&actions, stderr.write, 2)
        // Always a path to a folder: a folder sent as a bare path decodes to a URL with
        // no scheme, which `Process` raised an exception for, taking the daemon down.
        let folder = Self.folderURL(cwd).path(percentEncoded: false)
        _ = agents_spawn_chdir(&actions, folder)

        var argv: [UnsafeMutablePointer<CChar>?] = ([executable.path] + arguments).map { strdup($0) }
        argv.append(nil)
        defer { for pointer in argv where pointer != nil { free(pointer) } }
        var envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") }
        envp.append(nil)
        defer { for pointer in envp where pointer != nil { free(pointer) } }

        var pid: pid_t = 0
        let status = posix_spawn(&pid, executable.path, &actions, &attributes, &argv, &envp)
        // The child's ends are the child's now, or nobody's.
        for fd in [stdin.read, stdout.write, stderr.write] { POSIX.close(fd) }
        guard status == 0 else {
            for fd in [stdin.write, stdout.read, stderr.read] { POSIX.close(fd) }
            throw CouldNotStart(executable: executable.path, reason: String(cString: strerror(status)))
        }
        processIdentifier = pid
        // Written without blocking, so a runtime that stops reading its stdin cannot hold
        // a write, and with it `close`, for good (#209): `FDTransport.write` waits for room
        // a moment at a time and gives up once the transport is closed. The end is ours
        // alone; the child's is the read end.
        _ = fcntl(stdin.write, F_SETFL, fcntl(stdin.write, F_GETFL) | O_NONBLOCK)
        transport = FDTransport(readFD: stdout.read, writeFD: stdin.write,
                                maximumLine: FDTransport.runtimeLineLimit)
        heldDescriptors = [stdout.read, stdin.write, stderr.read]

        // Nobody reads a runtime's stderr but the log. Draining it matters anyway: a
        // full pipe stops the process writing, and a stopped process looks like a hung
        // agent.
        //
        // Empty is the end of the pipe, and it is reported again and again until the
        // handler goes: left in place, it is a core spinning for the daemon's life
        // (#163). So it takes itself away there, whether or not `cleanUp` ever runs.
        standardError = FileHandle(fileDescriptor: stderr.read, closeOnDealloc: false)
        standardError.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            onStandardError?(String(decoding: data, as: UTF8.self))
        }

        watchForExit(onExit)
    }

    /// Wait for the child on a thread of its own. Once it has exited, and before it is
    /// reaped — while its number, and so its group's, cannot be anybody else's — the rest
    /// of its group is killed: npx's node, or anything else it left behind.
    private func watchForExit(_ onExit: @escaping @Sendable (Int32) -> Void) {
        let pid = processIdentifier
        let thread = Thread { [self] in
            _ = agents_wait_for_exit(pid)
            var status: Int32 = 0
            lock.withLock {
                _ = killpg(pid, SIGKILL)
                while waitpid(pid, &status, 0) < 0, errno == EINTR {}
                exited = true
            }
            onExit(Self.exitCode(status))
        }
        thread.name = "AgentsKit.RuntimeProcess"
        thread.stackSize = 128 * 1024
        thread.start()
    }

    /// What `Process.terminationStatus` said: the exit code, or the signal that ended it.
    static func exitCode(_ status: Int32) -> Int32 {
        let signal = status & 0x7f
        return signal == 0 ? (status >> 8) & 0xff : signal
    }

    /// `url` as a file URL to a folder, whatever scheme it came with.
    static func folderURL(_ url: URL) -> URL {
        url.isFileURL ? url : URL(filePath: url.path(percentEncoded: false), directoryHint: .isDirectory)
    }

    public var isRunning: Bool { lock.withLock { !exited } }
    /// Whether stderr still has a handler on it. One left on a pipe at its end is a
    /// core spinning (#163).
    var watchesStandardError: Bool { standardError.readabilityHandler != nil }

    public func terminate() { sendToGroup(SIGTERM) }

    public func kill() { sendToGroup(SIGKILL) }

    /// To the whole group, while it is still the runtime's.
    private func sendToGroup(_ signal: Int32) {
        lock.withLock {
            guard !exited else { return }
            _ = killpg(processIdentifier, signal)
        }
    }

    private let cleanedUp = ManagedAtomicFlag()

    /// Let go of the pipes. Called once the process is gone, by whichever comes first:
    /// a stop (`ACPSession.end`) or the process dying by itself (`ACPSession.noteExit`).
    /// The second call does nothing.
    public func cleanUp() {
        guard cleanedUp.set() else { return }
        standardError.readabilityHandler = nil
        transport.close()
        try? standardError.close()
    }
}
