import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// What each kind of connection may ask the daemon for.
///
/// The case this is for: an agent's own shell reaching the socket and answering its
/// own permission prompt, or starting an agent that never asks. The shell is a
/// stranger and learns only that the daemon is there; the helper its runtime started
/// reaches the agent tools and nothing a window does.
@Suite("What each connection may ask for", .timeLimit(.minutes(1)))
struct ConnectionRoleTests {
    private func path() -> String { "/tmp/ag-role-\(UUID().uuidString.prefix(8)).sock" }

    private func connect(_ path: String) -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            path.withCString { strncpy(UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: CChar.self), $0, 103) }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, size) }
        }
        precondition(result == 0, "could not connect: \(errno)")
        var wait = timeval(tv_sec: 0, tv_usec: 200_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
        return fd
    }

    /// One request, and the one line that answers it.
    private func ask(_ fd: Int32, _ method: String) async -> [String: Any]? {
        let line = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"\(method)\",\"params\":{}}\n"
        _ = line.withCString { Darwin.write(fd, $0, strlen($0)) }
        // Five seconds, or `Eventually`'s longer wait on CI: a busy runner can take that
        // long to answer, and no answer reads as "not refused".
        let wait = max(5, Double(Eventually.timeout.components.seconds))
        return await readLine(fd, deadline: Date().addingTimeInterval(wait))
    }

    /// Read off the pool: this blocks until the line or the deadline, and the daemon
    /// being asked needs the pool to answer.
    private func readLine(_ fd: Int32, deadline: Date) async -> [String: Any]? {
        guard let line = await offThePool({ Self.rawLine(fd, deadline: deadline) }) else { return nil }
        return try? JSONSerialization.jsonObject(with: line) as? [String: Any]
    }

    private static func rawLine(_ fd: Int32, deadline: Date) -> Data? {
        var received = Data()
        var byte: UInt8 = 0
        while Date() < deadline {
            let n = Darwin.read(fd, &byte, 1)
            if n == 1 {
                if byte == UInt8(ascii: "\n") { return received }
                received.append(byte)
            } else if n == 0 {
                return nil
            }
        }
        return nil
    }

    private func errorCode(_ reply: [String: Any]?) -> Int? {
        (reply?["error"] as? [String: Any])?["code"] as? Int
    }

    /// A server whose every caller is `role`, and which says which methods reached it.
    private final class Heard: @unchecked Sendable {
        private let lock = NSLock()
        private var methods: [String] = []
        func add(_ method: String) { lock.withLock { methods.append(method) } }
        var all: [String] { lock.withLock { methods } }
    }

    private func server(_ role: ConnectionRole, at path: String, heard: Heard) throws -> DaemonServer {
        let server = DaemonServer(url: URL(fileURLWithPath: path),
                                  roles: RolePolicy(summary: "test") { _ in role }) { _, method, _ in
            heard.add(method)
            return .success([:])
        }
        try server.start()
        return server
    }

    @Test func aStrangerLearnsOnlyThatTheDaemonIsThere() async throws {
        let path = path()
        let heard = Heard()
        let server = try server(.stranger, at: path, heard: heard)
        defer { server.stop() }
        let fd = connect(path)
        defer { close(fd) }

        #expect(errorCode(await ask(fd, DaemonAPI.Method.ping)) == nil)
        for method in [DaemonAPI.Method.permissionsAnswer, DaemonAPI.Method.agentsStart,
                       DaemonAPI.Method.agentsList, DaemonAPI.Method.shellInput,
                       DaemonAPI.Method.agentsFinishTurn, DaemonAPI.Method.daemonQuit] {
            #expect(errorCode(await ask(fd, method)) == DaemonAPI.Failure.notPermitted, "\(method)")
        }
        #expect(heard.all == [DaemonAPI.Method.ping], "nothing refused reached the daemon")
    }

    @Test func aHelperReachesTheAgentToolsAndNothingAWindowDoes() async throws {
        let path = path()
        let heard = Heard()
        let server = try server(.agent, at: path, heard: heard)
        defer { server.stop() }
        let fd = connect(path)
        defer { close(fd) }

        for method in [DaemonAPI.Method.agentsFinishTurn, DaemonAPI.Method.agentsStartHelper,
                       DaemonAPI.Method.leasesLease, DaemonAPI.Method.eventsWait] {
            #expect(errorCode(await ask(fd, method)) == nil, "\(method)")
        }
        for method in [DaemonAPI.Method.permissionsAnswer, DaemonAPI.Method.agentsStart,
                       DaemonAPI.Method.agentsSetOption, DaemonAPI.Method.workflowsRun,
                       DaemonAPI.Method.shellInput, DaemonAPI.Method.credentialsLend] {
            #expect(errorCode(await ask(fd, method)) == DaemonAPI.Failure.notPermitted, "\(method)")
        }
    }

    /// Transcripts and terminal output go by as notifications; only a window hears them.
    @Test func onlyAWindowHearsWhatTheDaemonSays() async throws {
        let windowPath = path(), strangerPath = path()
        let heard = Heard()
        let window = try server(.control, at: windowPath, heard: heard)
        let stranger = try server(.stranger, at: strangerPath, heard: heard)
        defer { window.stop(); stranger.stop() }
        let windowFD = connect(windowPath), strangerFD = connect(strangerPath)
        defer { close(windowFD); close(strangerFD) }
        await eventually("both are connected") { window.connectionCount == 1 && stranger.connectionCount == 1 }

        window.broadcast("agent/entry", ["secret": "for the window"])
        stranger.broadcast("agent/entry", ["secret": "for the window"])

        #expect(await readLine(windowFD, deadline: Date().addingTimeInterval(5))?["method"] as? String == "agent/entry")
        #expect(await readLine(strangerFD, deadline: Date().addingTimeInterval(1)) == nil)
    }

    // MARK: Signatures

    /// This test binary is not the app, the bridge or the helper, so under the real
    /// requirements it is what an agent's shell is.
    @Test func anUnsignedCallerIsAStrangerByItsSignature() throws {
        var pair: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        defer { close(pair[0]); close(pair[1]) }

        #expect(CallerSignature.code(of: pair[0]) != nil, "the kernel names the caller")
        #expect(RolePolicy.signatures(team: "6T4RVD5724").role(pair[0]) == .stranger)
    }

    @Test func theRequirementsCompile() {
        #expect(CallerSignature.requirement(team: "6T4RVD5724", identifiers: RolePolicy.controlIdentifiers) != nil)
        #expect(CallerSignature.requirement(team: "6T4RVD5724", identifiers: [RolePolicy.helperIdentifier]) != nil)
    }

    /// Nothing to tell programs apart by: open, and said so.
    @Test func aDaemonNotSignedByATeamIsOpenAndSaysSo() throws {
        let locations = StoreLocations(root: URL(fileURLWithPath: "/tmp/ag-role-root"))
        let policy = RolePolicy.forDaemon(at: locations, environment: ["AGENTS_ENFORCE_ROLES": "1"])
        #expect(CallerSignature.ownTeam == nil)
        #expect(policy.summary.hasPrefix("not signed by a team"))
    }

    @Test func aHelperMayCallEveryToolItRelaysAndOnlyThose() {
        #expect(ConnectionRole.agentMethods.count == 19)
        #expect(ConnectionRole.stranger.allows(DaemonAPI.Method.daemonStatus))
        #expect(!ConnectionRole.agent.allows(DaemonAPI.Method.filesBrowse))
        #expect(ConnectionRole.control.allows("anything/atAll"))
        #expect(!ConnectionRole.agent.hearsNotifications && !ConnectionRole.stranger.hearsNotifications)
    }
}
