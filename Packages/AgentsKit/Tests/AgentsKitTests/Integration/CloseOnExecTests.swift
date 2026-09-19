import Foundation
import Testing
@testable import AgentsKit

/// What the daemon must not hand to the shells it starts.
///
/// Written from a real morning: a daemon was killed, its two login shells outlived it
/// still holding the lock it had opened, and every daemon started afterwards took the
/// "another one is already running" path and exited without a word. The window sat
/// there with nothing to talk to.
///
/// The tests that matter here are the ones that watch the consequence rather than the
/// flag, because the flag is invisible until something is spawned.
@Suite("What the daemon keeps to itself", .timeLimit(.minutes(1)))
struct CloseOnExecTests {
    private func temporaryFile() -> URL {
        URL(fileURLWithPath: "/tmp/agt-cloexec-\(UUID().uuidString.prefix(8))")
    }

    /// A child that sits there doing nothing, the way a login shell does.
    private func spawnSleeper() -> pid_t {
        var pid: pid_t = 0
        let arguments = ["/bin/sh", "-c", "sleep 30"]
        var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) }
        argv.append(nil)
        defer { for pointer in argv where pointer != nil { free(pointer) } }
        var environment: [UnsafeMutablePointer<CChar>?] = [nil]
        #expect(posix_spawn(&pid, "/bin/sh", nil, nil, &argv, &environment) == 0)
        return pid
    }

    private func reap(_ pid: pid_t) {
        kill(pid, SIGKILL)
        var status: Int32 = 0
        waitpid(pid, &status, 0)
    }

    /// The bug itself: take the lock, start a shell, let the daemon die, and see
    /// whether the next daemon can start. With the descriptor inheritable, the shell
    /// is still holding the lock and it cannot.
    @Test func aShellTheDaemonStartedCannotKeepItsLock() async throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }

        let lock = try #require(DaemonLock(at: url))
        let child = spawnSleeper()
        defer { reap(child) }
        try await Task.sleep(for: .milliseconds(100))

        // The daemon is killed rather than stopped, which is the case that bites:
        // `release` unlocks before it closes, and an unlock is honoured no matter how
        // many processes hold the descriptor. A kill unlocks nothing, so the lock
        // lives exactly as long as the last process holding it — the shell.
        close(lock.descriptor)

        let next = DaemonLock(at: url)
        #expect(next != nil, "the next daemon could not take the lock: something else still holds it")
        next?.release()
    }

    /// The other half of the same story. A window's connection held open by a shell
    /// that will never read it leaves the daemon counting a window that has gone, and
    /// a daemon that thinks somebody is watching does not shut down.
    @Test func aShellDoesNotHoldAWindowsConnectionOpen() async throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }

        let server = DaemonServer(url: url) { _, _ in .success([:]) }
        try server.start()

        let mine = try connect(to: url)
        defer { close(mine) }
        try await Task.sleep(for: .milliseconds(200))
        #expect(server.connectionCount == 1)

        // A terminal is started while the window is connected, which is the ordinary
        // order of events and the one that does the damage.
        let child = spawnSleeper()
        defer { reap(child) }
        try await Task.sleep(for: .milliseconds(100))

        server.stop()

        // Reading a socket whose every writer has closed gives end of file. If the
        // shell inherited it there is still a writer, and this waits out its timeout
        // and comes back empty-handed instead.
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(mine, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var byte: UInt8 = 0
        let read = Darwin.read(mine, &byte, 1)
        #expect(read == 0, "the connection was still open: a shell inherited it")
    }

    /// The listening socket has no consequence that can be watched from outside — it
    /// is unlinked on the way out — so this one does look at the flag.
    @Test func theListeningSocketIsNotInherited() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let server = DaemonServer(url: url) { _, _ in .success([:]) }
        try server.start()
        defer { server.stop() }
        #expect(isCloseOnExec(server.listenFD))
    }

    private func connect(to url: URL) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            url.path.withCString { source in
                strncpy(UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: CChar.self), source, 103)
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let joined = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, size) }
        }
        #expect(joined == 0, "could not reach the socket")
        return fd
    }
}
