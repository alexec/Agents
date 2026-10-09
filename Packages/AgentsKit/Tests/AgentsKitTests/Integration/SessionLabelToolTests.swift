import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

@Suite("Agent label tools", .timeLimit(.minutes(1)))
struct SessionLabelToolTests {
    private actor Calls {
        var helper: AppService.AgentCall?
        func record(_ call: AppService.AgentCall) { helper = call }
    }

    @Test func startPayloadsReachTheirSink() async throws {
        let calls = Calls()
        let (mine, theirs) = PairedTransport.pair()
        let service = AppService(transport: theirs,
                                 agents: { call in
                                     await calls.record(call)
                                     return .shown("Started")
                                 })
        let client = JSONRPCConnection(transport: mine)
        await client.start()
        _ = try await client.call("tools/call", [
            "name": .string(AppService.startAgentToolName),
            "arguments": ["prompt": "Review", "labels": ["Ready"]],
        ])
        #expect(await calls.helper == .start(prompt: "Review", runtime: nil,
                                              model: nil, permissionMode: nil, labels: ["Ready"]))
        await service.close()
    }

    @Test func agentCannotRemoveOrClaimAPersonLabelInTwentyAttempts() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ToolLabels-\(UUID().uuidString)", isDirectory: true)
        let project = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let locations = StoreLocations(root: root)
        var script = FakeACPAgent.Script()
        script.turnDelay = .seconds(3)
        let core = DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                              discovery: .findsEverything, launcher: FakeLauncher(script: script))
        await core.loadFromDisk()
        let id = try await core.start(.init(runtimeID: "claude", cwd: project,
                                            prompt: "Review", labels: ["Priority"]))
        let token = UUID().uuidString
        await core.bindAppToken(token, to: id)
        for index in 0..<20 {
            let removing = index.isMultiple(of: 2)
            let request = DaemonAPI.FinishTurnRequest(
                token: token, outcome: "done", message: "Reviewed.", prompts: [],
                addLabels: removing ? ["Other"] : ["PRIORITY"],
                removeLabels: removing ? ["priority"] : [])
            do {
                _ = try await core.finishTurn(request)
                Issue.record("attempt \(index) changed the person's label")
            } catch let error as JSONRPCError {
                #expect(error.message.contains("belongs to the person"))
            }
            #expect(await core.agent(id)?.labels.map(\.value) == ["Priority"])
            #expect(await core.agent(id)?.report == nil)
        }
        let changed = try await core.setSessionLabels(.init(agentID: id, remove: ["priority"]))
        #expect(changed.labels.isEmpty)
    }

    @Test func helperStartsWithItsOwnLabelsAndFinishAddsOneAtomically() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("HelperLabels-\(UUID().uuidString)", isDirectory: true)
        let project = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let locations = StoreLocations(root: root)
        var script = FakeACPAgent.Script()
        script.turnDelay = .seconds(3)
        let core = DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                              discovery: .findsEverything, launcher: FakeLauncher(script: script))
        await core.loadFromDisk()
        let lead = try await core.start(.init(runtimeID: "claude", cwd: project, prompt: "Lead"))
        await core.bindAppToken("lead-token", to: lead)
        let helper = try await core.startHelper(.init(token: "lead-token", prompt: "Review",
                                                     labels: ["Review"]))
        #expect(await core.agent(helper.agentID)?.labels.map(\.value) == ["Review"])
        #expect(await core.agent(helper.agentID)?.labels.first?.owner == .agent)
        await core.bindAppToken("helper-token", to: helper.agentID)
        _ = try await core.finishTurn(.init(token: "helper-token", outcome: "done",
                                            message: "Reviewed.", prompts: [],
                                            addLabels: ["Done"], removeLabels: ["review"]))
        #expect(await core.agent(helper.agentID)?.labels.map(\.value) == ["Done"])
        #expect(await core.agent(helper.agentID)?.report?.message == "Reviewed.")
    }
}
