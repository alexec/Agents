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
        // The daemon is killed rather than stopped, which is the case that bites:
        // `release` unlocks before it closes, and an unlock is honoured no matter how
        // many processes hold the descriptor. A kill unlocks nothing, so the lock
        // lives exactly as long as the last process holding it — the shell.
        close(lock.descriptor)

        // Polled rather than asked once. `posix_spawn` returns as soon as the child
        // exists, and the flag is only honoured at the `exec` after that, so there is
        // a window in which even a correctly marked descriptor is still held by a
        // child that has not got there yet. A shell that really did inherit it holds
        // it for its whole `sleep`, so this still fails when the bug is back — it just
        // takes the timeout to say so.
        let next = await eventuallySome("the next daemon could take the lock: something else still holds it") {
            DaemonLock(at: url)
        }
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
        // `connect` returns as soon as the kernel has queued it; the server counts it
        // when its accept loop gets round to it, which is a hand-off away.
        await eventually("the server counted the connection") { server.connectionCount == 1 }
        #expect(server.connectionCount == 1)

        // A terminal is started while the window is connected, which is the ordinary
        // order of events and the one that does the damage.
        let child = spawnSleeper()
        defer { reap(child) }
        // As above: whatever the child inherited, it inherited at the spawn. This is
        // only here so the shell is properly up before the server goes.
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

    /// A window that has gone must take its descriptor with it.
    ///
    /// The other half of the descriptor story: not what a child walks off with, but
    /// what the daemon itself keeps. Every window, phone and helper connects and
    /// disconnects freely, and each one used to leave its accepted socket open in the
    /// daemon for good — 2,422 of them on one Sunday morning, at which point `accept`
    /// could take no more and the front door was shut with the daemon still standing
    /// behind it. Counted through `/dev/fd` rather than by asking the server, because
    /// the server thought it had let go: it had dropped the connection from its set,
    /// and the descriptor was the one thing it had not closed. Only the sockets bound
    /// to this test's own path are counted, so the tests running beside this one can
    /// open and close whatever they like without being mistaken for a leak.
    @Test func aWindowThatHasGoneLeavesNoDescriptorBehind() async throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let server = DaemonServer(url: url) { _, _ in .success([:]) }
        try server.start()
        defer { server.stop() }

        let rounds = 100
        let before = try socketsBound(to: url)
        for _ in 0..<rounds {
            let mine = try connect(to: url)
            await eventually("the server counted the connection") { server.connectionCount == 1 }
            close(mine)
            await eventually("the server let the connection go") { server.connectionCount == 0 }
        }
        let after = try socketsBound(to: url)
        // The listener itself is bound to the path and stays; a window that has gone
        // should add nothing. Well short of one per round, so a partial fix fails too.
        #expect(after - before < rounds / 2,
                "\(after - before) descriptors left behind by \(rounds) windows that had gone")
    }

    /// How many of this process's descriptors are Unix sockets bound to `url`'s path:
    /// the listener, plus every accepted connection the server still holds.
    private func socketsBound(to url: URL) throws -> Int {
        var count = 0
        for name in try FileManager.default.contentsOfDirectory(atPath: "/dev/fd") {
            guard let fd = Int32(name) else { continue }
            var address = sockaddr_un()
            var size = socklen_t(MemoryLayout<sockaddr_un>.size)
            let bound = withUnsafeMutablePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) }
            }
            guard bound == 0, address.sun_family == sa_family_t(AF_UNIX) else { continue }
            let path = withUnsafePointer(to: &address.sun_path) { pointer in
                String(cString: UnsafeRawPointer(pointer).assumingMemoryBound(to: CChar.self))
            }
            if path == url.path { count += 1 }
        }
        return count
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
