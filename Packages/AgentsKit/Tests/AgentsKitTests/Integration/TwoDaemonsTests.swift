import Foundation
import Testing
@testable import AgentsKit

/// Two daemons at once, one per root.
///
/// The ordinary case is one daemon and one set of agents. This is the other one: a
/// build from a branch run beside the ordinary app, each with its own agents, neither
/// able to disturb the other. Everything that makes it work is `StoreLocations` —
/// there is no second lock, no port, no registry — so what these check is that the
/// separation really is complete rather than nearly complete.
@Suite("Two daemons at once", .timeLimit(.minutes(1)))
struct TwoDaemonsTests {
    /// Socket paths live in a 104-byte struct, so they are kept short on purpose.
    private func shortLocations() throws -> (StoreLocations, URL) {
        let id = UUID().uuidString.prefix(8)
        let root = URL(fileURLWithPath: "/tmp/agt-\(id)", isDirectory: true)
        let work = root.appendingPathComponent("w", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        return (StoreLocations(root: root), work)
    }

    private func client(to locations: StoreLocations) async throws -> JSONRPCConnection {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            locations.socket.path.withCString { source in
                strncpy(UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: CChar.self), source, 103)
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, size) }
        }
        #expect(result == 0, "could not reach the daemon socket")
        let connection = JSONRPCConnection(transport: FDTransport(socket: fd))
        await connection.start()
        return connection
    }

    /// The whole feature in one test: both start, both answer, and an agent belongs to
    /// the daemon it was started in and to no other.
    @Test func eachRootIsItsOwnDaemonWithItsOwnAgents() async throws {
        let (here, hereWork) = try shortLocations()
        let (there, thereWork) = try shortLocations()
        defer {
            try? FileManager.default.removeItem(at: here.root)
            try? FileManager.default.removeItem(at: there.root)
        }

        // Neither refuses the other: the lock each takes is inside its own root.
        let first = try Daemon(locations: here, discovery: .findsEverything, launcher: FakeLauncher())
        let second = try Daemon(locations: there, discovery: .findsEverything, launcher: FakeLauncher())
        try await first.start()
        try await second.start()
        defer {
            Task { await first.shutDown() }
            Task { await second.shutDown() }
        }

        let toFirst = try await client(to: here)
        let toSecond = try await client(to: there)

        _ = try await toFirst.call(DaemonAPI.Method.agentsStart,
                                   try JSONValue.encoding(DaemonAPI.StartRequest(
                                       runtimeID: "copilot", cwd: hereWork, prompt: "mine")))
        await eventually("the first daemon has its agent") {
            (try? await toFirst.call(DaemonAPI.Method.agentsList,
                                     ["includeArchived": true]).arrayValue?.count) == 1
        }

        #expect(try await toFirst.call(DaemonAPI.Method.agentsList,
                                       ["includeArchived": true]).arrayValue?.count == 1)
        // Not "empty because it has not caught up": there is nothing to catch up to.
        #expect(try await toSecond.call(DaemonAPI.Method.agentsList,
                                        ["includeArchived": true]).arrayValue?.count == 0)

        // And the other way round, so neither is merely the quiet one.
        _ = try await toSecond.call(DaemonAPI.Method.agentsStart,
                                    try JSONValue.encoding(DaemonAPI.StartRequest(
                                        runtimeID: "copilot", cwd: thereWork, prompt: "theirs")))
        await eventually("the second daemon has its own") {
            (try? await toSecond.call(DaemonAPI.Method.agentsList,
                                      ["includeArchived": true]).arrayValue?.count) == 1
        }
        #expect(try await toFirst.call(DaemonAPI.Method.agentsList,
                                       ["includeArchived": true]).arrayValue?.count == 1)
        #expect(try await toSecond.call(DaemonAPI.Method.agentsList,
                                        ["includeArchived": true]).arrayValue?.count == 1)

        await toFirst.close()
        await toSecond.close()
    }

    /// Nothing is written outside the root it belongs to, which is what makes running
    /// a branch build beside the ordinary one safe rather than merely possible.
    @Test func neitherWritesIntoTheOthersFolder() async throws {
        let (here, work) = try shortLocations()
        let (there, _) = try shortLocations()
        defer {
            try? FileManager.default.removeItem(at: here.root)
            try? FileManager.default.removeItem(at: there.root)
        }

        let first = try Daemon(locations: here, discovery: .findsEverything, launcher: FakeLauncher())
        let second = try Daemon(locations: there, discovery: .findsEverything, launcher: FakeLauncher())
        try await first.start()
        try await second.start()
        defer {
            Task { await first.shutDown() }
            Task { await second.shutDown() }
        }

        let toFirst = try await client(to: here)
        _ = try await toFirst.call(DaemonAPI.Method.agentsStart,
                                   try JSONValue.encoding(DaemonAPI.StartRequest(
                                       runtimeID: "copilot", cwd: work, prompt: "mine")))
        await eventually("the agent was written to the first root") {
            ((try? FileManager.default.contentsOfDirectory(atPath: here.agents.path)) ?? []).count == 1
        }

        let manager = FileManager.default
        let mine = (try? manager.contentsOfDirectory(atPath: here.agents.path)) ?? []
        let theirs = (try? manager.contentsOfDirectory(atPath: there.agents.path)) ?? []
        #expect(mine.count == 1)
        #expect(theirs.isEmpty)

        await toFirst.close()
    }

    /// The window tells its own daemon where to live. A daemon that read the ambient
    /// environment instead would be the ordinary one wearing a branch's name.
    @Test func theHelperIsToldTheRootRatherThanLeftToGuess() async throws {
        let (locations, work) = try shortLocations()
        defer { try? FileManager.default.removeItem(at: locations.root) }
        let launcher = FakeLauncher()
        let core = DaemonCore(store: try AgentStore(locations: locations),
                              locations: locations,
                              discovery: .findsEverything,
                              launcher: launcher)

        _ = try await core.start(.init(runtimeID: "copilot", cwd: work, prompt: "go"))

        let server = (await launcher.lastAgent?.newSessionParams?["mcpServers"]?.arrayValue ?? []).first
        // ACP sends an environment as a list of name/value pairs, not as an object.
        let named = (server?["env"]?.arrayValue ?? [])
            .first { $0["name"]?.stringValue == StoreLocations.rootVariable }
        #expect(named?["value"]?.stringValue == locations.root.path)
    }
}
