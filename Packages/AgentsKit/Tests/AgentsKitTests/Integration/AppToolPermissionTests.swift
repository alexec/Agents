import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// The app answers for every tool of its own MCP server when a runtime asks (049, T035a).
/// Antigravity asks before every MCP call, titled `<server>_<tool>`; Copilot asks before
/// every call of any kind. Without this, each lease, wait or event stops on a card.
@Suite("The app answers for its own tools", .timeLimit(.minutes(1)))
struct AppToolPermissionTests {
    @Test func everyToolOfTheAppsServerIsRecognisedWithItsServerInFront() {
        for tool in AppTool.all {
            #expect(AppTool.isServedByTheApp("mcp__agents__\(tool)"), "Claude's spelling of \(tool)")
            #expect(AppTool.isServedByTheApp("agents_\(tool)"), "Antigravity's spelling of \(tool)")
            #expect(ToolCall(title: "agents_\(tool)").isAutoAllowable, "\(tool)")
        }
    }

    /// A bare name says nothing about whose it is: Antigravity has a `list_resources` of
    /// its own. Nor does another server's tool of the same name.
    @Test func aBareNameOrAnotherServersToolIsStillThePersonsToAnswer() {
        #expect(!AppTool.isServedByTheApp(AppTool.listResources))
        #expect(!AppTool.isServedByTheApp("github_\(AppTool.listResources)"))
        #expect(!AppTool.isServedByTheApp("mcp__github__\(AppTool.startAgent)"))
        #expect(!AppTool.isServedByTheApp("agents_rm_rf"))
        #expect(!ToolCall(title: AppTool.leaseResource).isAutoAllowable)
        #expect(!ToolCall(title: "run_command", name: "run_command").isAutoAllowable)
    }

    @Test func theDaemonsServerIsTheOneThePrefixNames() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AppToolPermission-\(UUID().uuidString)", isDirectory: true)
        let locations = StoreLocations(root: root)
        let core = DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                              discovery: .findsEverything, launcher: FakeLauncher())
        #expect(try await core.appServer(token: "t").name == AppTool.serverName)
    }

    /// Through the daemon, as Antigravity asks it (R6b): a lease mid-turn is answered by the
    /// app, and the agent never waits on the person.
    @Test func antigravityAskingAboutALeaseIsAnsweredWithoutAsking() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AppToolPermission-\(UUID().uuidString)", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let locations = StoreLocations(root: root)
        let current = locations.tools.appendingPathComponent("antigravity/current", isDirectory: true)
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        try Data().write(to: current.appendingPathComponent("ok"))
        var discovery = RuntimeDiscovery.findsEverything
        discovery.macToolsHome = locations.tools.path

        var script = FakeACPAgent.Script()
        script.permission = [
            "toolCall": ["toolCallId": "c1", "title": "agents_lease_resource", "kind": "other", "status": "pending"],
            "options": [["optionId": "allow_always", "name": "Allow Always (risky)", "kind": "allow_always"],
                        ["optionId": "allow_once", "name": "Allow Once", "kind": "allow_once"],
                        ["optionId": "reject_once", "name": "Deny", "kind": "reject_once"]],
        ]
        let launcher = FakeLauncher(script: script)
        let core = DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                              discovery: discovery, launcher: launcher)
        let id = try await core.start(.init(runtimeID: "antigravity", cwd: work, prompt: "take the lease"))
        await eventually("the turn ended") { await core.agent(id)?.endedReason != nil }
        let outcome = await launcher.lastAgent?.permissionOutcome
        #expect(outcome?["outcome"]?["outcome"]?.stringValue == "selected")
        #expect(outcome?["outcome"]?["optionId"]?.stringValue?.hasPrefix("allow") == true)
        let page = try await core.transcript(.init(agentID: id))
        #expect(!page.entries.contains { if case .permissionAsked = $0.kind { return true } else { return false } },
                "the person was never asked")
    }
}
