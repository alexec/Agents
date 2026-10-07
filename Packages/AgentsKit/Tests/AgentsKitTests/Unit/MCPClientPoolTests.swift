import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// The app's connections for views are bounded (#191, T043): http only, four at most, one
/// start per server, ended when idle.
@Suite("MCP client pool", .timeLimit(.minutes(1)))
struct MCPClientPoolTests {
    private let cwd = FileManager.default.temporaryDirectory

    private func server(_ name: String) -> MCPServer {
        MCPServer(name: name, transport: .http(url: "https://\(name).example/mcp", headers: [:]))
    }

    private func key(_ name: String) -> MCPClientPool.Key { .init(scope: "personal", name: name, entry: name) }

    @Test func aStdioServerIsRefused() async {
        let pool = MCPClientPool(http: ViewsServerStandIn().send)
        let local = MCPServer(name: "local", transport: .stdio(command: "true", args: [], env: [:]))
        await #expect(throws: MCPClientPool.Refusal.localServer) {
            try await pool.with(key("local"), server: local, cwd: cwd) { _ in 1 }
        }
    }

    @Test func oneStartServesEveryAskerAndTheConnectionIsKept() async throws {
        let stand = ViewsServerStandIn()
        let pool = MCPClientPool(http: stand.send)
        try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<4 {
                group.addTask { try await pool.with(self.key("kite"), server: self.server("kite"), cwd: self.cwd) { try await $0.listTools().count } }
            }
            for try await count in group { #expect(count == 3) }
        }
        #expect(stand.connections == 1)
        #expect(await pool.count == 1)
        await pool.endAll()
    }

    @Test func atMostFourAndTheLeastRecentlyUsedGoesFirst() async throws {
        let stand = ViewsServerStandIn()
        let pool = MCPClientPool(http: stand.send)
        for name in ["a", "b", "c", "d"] {
            _ = try await pool.with(key(name), server: server(name), cwd: cwd) { _ in 0 }
        }
        // a is used again, so b is the oldest when e comes.
        _ = try await pool.with(key("a"), server: server("a"), cwd: cwd) { _ in 0 }
        _ = try await pool.with(key("e"), server: server("e"), cwd: cwd) { _ in 0 }
        #expect(await pool.count == MCPClientPool.limit)
        #expect(stand.connections == 5)
        _ = try await pool.with(key("a"), server: server("a"), cwd: cwd) { _ in 0 }
        #expect(stand.connections == 5, "a was kept")
        _ = try await pool.with(key("b"), server: server("b"), cwd: cwd) { _ in 0 }
        #expect(stand.connections == 6, "b had been ended")
        await pool.endAll()
    }

    @Test func anIdleClientIsEnded() async throws {
        let stand = ViewsServerStandIn()
        let pool = MCPClientPool(idle: .milliseconds(200), http: stand.send)
        _ = try await pool.with(key("kite"), server: server("kite"), cwd: cwd) { _ in 0 }
        #expect(await pool.count == 1)
        for _ in 0..<40 where await pool.count > 0 { try await Task.sleep(for: .milliseconds(50)) }
        #expect(await pool.count == 0)
        for _ in 0..<40 where !stand.seen.contains("DELETE") { try await Task.sleep(for: .milliseconds(50)) }
        #expect(stand.seen.contains("DELETE"), "the session was closed")
    }
}
