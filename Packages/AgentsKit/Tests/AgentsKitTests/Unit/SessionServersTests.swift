import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// What a session is made with (054, research R10): the app's own, then the agent's
/// chosen servers, then the person's, then plugin servers; the first of a name wins; a
/// transport the runtime does not advertise is left out.
@Suite("Session servers")
struct SessionServersTests {
    private let app = MCPServer(name: "agents", transport: .stdio(command: "agentsd", args: ["mcp", "t"], env: [:]))

    private func stdio(_ name: String, _ tag: String = "") -> MCPServer {
        MCPServer(name: name, transport: .stdio(command: "run-\(name)\(tag)", args: [], env: [:]))
    }

    private func http(_ name: String) -> MCPServer {
        MCPServer(name: name, transport: .http(url: "https://\(name).example", headers: [:]))
    }

    private func sse(_ name: String) -> MCPServer {
        MCPServer(name: name, transport: .sse(url: "https://\(name).example", headers: [:]))
    }

    @Test func theOrderIsAppThenChosenThenPersonalThenPlugins() {
        let plan = SessionServers.plan(app: app, chosen: [stdio("chosen")], personal: .success([stdio("mine")]),
                                       pluginServers: [stdio("plugged")], http: true, sse: true)
        #expect(plan.servers.map(\.name) == ["agents", "chosen", "mine", "plugged"])
        #expect(plan.dropped.isEmpty)
    }

    // FR-020
    @Test func theFirstOfANameIsKept() {
        let plan = SessionServers.plan(app: app, chosen: [stdio("github", "-chosen")],
                                       personal: .success([stdio("github", "-mine"), stdio("agents")]),
                                       http: true, sse: true)
        #expect(plan.servers == [app, stdio("github", "-chosen")])
        #expect(plan.dropped.map(\.name) == ["github", "agents"])
        #expect(plan.dropped.allSatisfy { $0.reason == .nameTaken })
    }

    // FR-019: Codex says `sse: false`.
    @Test func aTransportTheRuntimeDoesNotAdvertiseIsLeftOut() {
        let codex = SessionServers.plan(app: app, chosen: [], personal: .success([sse("old"), http("docs")]),
                                        http: true, sse: false)
        #expect(codex.servers.map(\.name) == ["agents", "docs"])
        #expect(codex.dropped.map(\.name) == ["old"])
        #expect(codex.dropped.first?.reason == .transportNotAdvertised("sse"))

        let none = SessionServers.plan(app: app, chosen: [http("chosen")], personal: .success([sse("old")]),
                                       http: false, sse: false)
        #expect(none.servers == [app])
        #expect(none.dropped.map(\.reason) == [.transportNotAdvertised("http"), .transportNotAdvertised("sse")])
    }

    // A server left out for its transport does not take the name from a later one.
    @Test func aServerLeftOutForItsTransportLeavesItsNameFree() {
        let plan = SessionServers.plan(app: app, chosen: [sse("docs")], personal: .success([stdio("docs")]),
                                       http: true, sse: false)
        #expect(plan.servers.map(\.name) == ["agents", "docs"])
    }

    // Story 6 scenario 4
    @Test func aProblemFileDropsOnlyThePersonsServers() {
        let plan = SessionServers.plan(app: app, chosen: [stdio("chosen")],
                                       personal: .failure(.init(message: "not JSON", line: 2)),
                                       pluginServers: [stdio("plugged")], http: true, sse: true)
        #expect(plan.servers.map(\.name) == ["agents", "chosen", "plugged"])
        #expect(plan.dropped.map(\.reason) == [.mcpFileProblem])
    }
}
