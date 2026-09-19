import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

@Suite("Plans", .timeLimit(.minutes(1)))
struct PlanTests {
    private func temporary() throws -> (StoreLocations, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsPlanTests-\(UUID().uuidString)", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        return (StoreLocations(root: root), work)
    }

    @Test func onePlanOnScreenThroughout() async throws {
        let (locations, work) = try temporary()
        var script = FakeACPAgent.Script()
        script.updates = [
            ["sessionUpdate": "plan_update", "plan": ["planId": "p1",
                                                      "entries": [["content": "Read it", "status": "pending"]]]],
            ["sessionUpdate": "plan_update", "plan": ["planId": "p1",
                                                      "entries": [["content": "Read it", "status": "completed"],
                                                                  ["content": "Write it", "status": "in_progress"]]]],
        ]
        let core = DaemonCore(store: try AgentStore(locations: locations),
                              locations: locations,
                              discovery: .findsEverything,
                              launcher: FakeLauncher(script: script))

        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "plan it"))
        try await Task.sleep(for: .milliseconds(300))

        let agent = await core.agent(id)
        #expect(agent?.plans.count == 1, "the same id replaces rather than adds")
        #expect(agent?.plans.first?.entries.count == 2)
        #expect(agent?.plans.first?.entries.first?.status == .completed)
    }

    @Test func aWithdrawnPlanIsMarkedAndKept() async throws {
        let (locations, work) = try temporary()
        var script = FakeACPAgent.Script()
        script.updates = [
            ["sessionUpdate": "plan_update", "plan": ["planId": "p1",
                                                      "entries": [["content": "Read it"]]]],
            ["sessionUpdate": "plan_removed", "planId": "p1"],
        ]
        let core = DaemonCore(store: try AgentStore(locations: locations),
                              locations: locations,
                              discovery: .findsEverything,
                              launcher: FakeLauncher(script: script))

        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "plan it"))
        try await Task.sleep(for: .milliseconds(300))

        let agent = await core.agent(id)
        #expect(agent?.plans.count == 1, "it happened, so it stays on the record")
        #expect(agent?.plans.first?.state == .withdrawn)
    }

    @Test func compactionIsOnTheRecord() async throws {
        let (locations, work) = try temporary()
        var script = FakeACPAgent.Script()
        script.updates = [
            ["sessionUpdate": "compaction_update", "compactionId": "c1", "status": "in_progress"],
            ["sessionUpdate": "compaction_update", "compactionId": "c1", "status": "completed",
             "summary": [["type": "text", "text": "We did three things."]]],
        ]
        let core = DaemonCore(store: try AgentStore(locations: locations),
                              locations: locations,
                              discovery: .findsEverything,
                              launcher: FakeLauncher(script: script))

        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "compact it"))
        try await Task.sleep(for: .milliseconds(300))

        let page = try await core.transcript(.init(agentID: id))
        let compactions = page.entries.compactMap { entry -> (String, [ContentBlock])? in
            if case .compaction(let status, let summary) = entry.kind { return (status, summary) }
            return nil
        }
        #expect(compactions.count == 2)
        #expect(compactions.last?.0 == "completed")
        #expect(compactions.last?.1.plainText == "We did three things.")
    }

    @Test func aPlanSurvivesBeingWrittenDown() throws {
        let plan = Plan(planID: "p1", entries: [PlanEntry(content: "one", priority: .high, status: .inProgress)])
        let data = try JSONEncoder().encode(plan)
        let back = try JSONDecoder().decode(Plan.self, from: data)
        #expect(back.entries == plan.entries)
        #expect(back.planID == "p1")
    }
}
