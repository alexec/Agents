import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// The daemon over its real socket, which is the part that has to survive a window.
@Suite("Daemon survival", .timeLimit(.minutes(1)))
struct DaemonSurvivalTests {
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

    @Test func twoWindowsSeeTheSameAgentsAndBothGetTold() async throws {
        let (locations, work) = try shortLocations()
        defer { try? FileManager.default.removeItem(at: locations.root) }
        let launcher = FakeLauncher()
        let daemon = try Daemon(locations: locations, discovery: .findsEverything, launcher: launcher)
        try await daemon.start()
        defer { Task { await daemon.shutDown() } }

        let first = try await client(to: locations)
        let second = try await client(to: locations)

        let heard = Task { () -> String? in
            for await notification in second.incomingNotifications()
            where notification.method == DaemonAPI.Notification.agentChanged {
                return notification.method
            }
            return nil
        }

        let started = try await first.call(DaemonAPI.Method.agentsStart,
                                           try JSONValue.encoding(DaemonAPI.StartRequest(
                                               runtimeID: "copilot", cwd: work, prompt: "hello")))
        #expect(started.stringValue != nil, "an agent id comes back")
        #expect(await heard.value == DaemonAPI.Notification.agentChanged,
                "the window that did nothing is told too")

        try await Task.sleep(for: .milliseconds(250))
        let listed = try await second.call(DaemonAPI.Method.agentsList, ["includeArchived": true])
        #expect(listed.arrayValue?.count == 1)

        await first.close()
        await second.close()
    }

    @Test func aSecondDaemonLosesTheLockAndTouchesNothing() async throws {
        let (locations, _) = try shortLocations()
        defer { try? FileManager.default.removeItem(at: locations.root) }
        let first = try Daemon(locations: locations, discovery: .findsEverything, launcher: FakeLauncher())
        try await first.start()
        defer { Task { await first.shutDown() } }

        #expect(throws: Daemon.StartError.self) {
            _ = try Daemon(locations: locations, discovery: .findsEverything, launcher: FakeLauncher())
        }
    }

    @Test func theWorkCarriesOnWhenEveryWindowGoes() async throws {
        let (locations, work) = try shortLocations()
        defer { try? FileManager.default.removeItem(at: locations.root) }
        var script = FakeACPAgent.Script()
        script.permission = ["toolCall": ["title": "A long job"],
                             "options": [["optionId": "allow", "name": "Allow", "kind": "allow_once"]]]
        let daemon = try Daemon(locations: locations, discovery: .findsEverything,
                                launcher: FakeLauncher(script: script))
        try await daemon.start()
        defer { Task { await daemon.shutDown() } }

        let window = try await client(to: locations)
        let started = try await window.call(DaemonAPI.Method.agentsStart,
                                            try JSONValue.encoding(DaemonAPI.StartRequest(
                                                runtimeID: "grok", cwd: work, prompt: "go")))
        let agentID = UUID(uuidString: started.stringValue ?? "")
        try await Task.sleep(for: .milliseconds(250))

        // The window goes, the way it goes when the app is force quit.
        await window.close()
        try await Task.sleep(for: .milliseconds(250))

        let core = daemon.daemonCore
        #expect(await core.isHoldingAgents, "the agent is still there with nobody watching")
        #expect(await core.shouldExit == false)
        #expect(await core.pendingPermissionRequests().count == 1,
                "and its question is still waiting to be asked of somebody")

        // A new window sees everything, including what happened while none was open.
        let reopened = try await client(to: locations)
        let waiting = try await reopened.call(DaemonAPI.Method.permissionsPending)
        #expect(waiting.arrayValue?.count == 1)
        let listed = try await reopened.call(DaemonAPI.Method.agentsList, ["includeArchived": true])
        #expect(listed.arrayValue?.first?["state"]?.stringValue == "waitingOnUser")
        #expect(agentID != nil)
        await reopened.close()
    }
}
