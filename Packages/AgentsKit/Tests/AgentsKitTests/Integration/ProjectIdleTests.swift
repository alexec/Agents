import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// `project.idle` (#360): once, when the last agent in a project stops working, and
/// never for the clean-up it starts.
@Suite("Project idle", .timeLimit(.minutes(1)))
struct ProjectIdleTests {
    private let settle: Duration = .milliseconds(150)

    private func temporary() throws -> (StoreLocations, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsProjectIdle-\(UUID().uuidString)", isDirectory: true)
        let work = root.appendingPathComponent("api", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        return (StoreLocations(root: root), Project.standardize(work))
    }

    private func core(_ locations: StoreLocations, launcher: FakeLauncher = FakeLauncher()) async throws -> DaemonCore {
        let core = DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                              discovery: .findsEverything, launcher: launcher)
        await core.loadFromDisk()
        await core.useProjectIdleSettle(settle)
        return core
    }

    private func eventually(_ what: String, _ check: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: max(.seconds(20), Eventually.timeout))
        while ContinuousClock.now < deadline {
            if try await check() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("never happened: \(what)")
    }

    private func idles(_ core: DaemonCore) async -> [Event] {
        await core.eventLog.events.filter { $0.name == "project.idle" }
    }

    @Test func raisedOnceWhenTheLastAgentStopsAndNotBefore() async throws {
        let (locations, work) = try temporary()
        let gate = TurnGate()
        let core = try await core(locations, launcher: FakeLauncher(then: [.init(gate: gate)]))
        let held = try await core.start(DaemonAPI.StartRequest(runtimeID: "claude", cwd: work, prompt: "Long"))
        try await eventually("the held turn is under way") { gate.turnsArrived == 1 }
        let quick = try await core.start(DaemonAPI.StartRequest(runtimeID: "claude", cwd: work, prompt: "Short"))
        try await eventually("the quick one finished") { await core.agent(quick)?.state == .finished }
        try await Task.sleep(for: settle * 3)
        #expect(await idles(core).isEmpty, "one agent is still working")

        gate.open()
        try await eventually("the project went idle") { await idles(core).count == 1 }
        let idle = try #require(await idles(core).first)
        #expect(idle.scope == .project(folder: work))
        #expect(idle.details["agents"] == "2")
        #expect(idle.details["finished"] == "2")
        #expect(Set(idle.details["ids"]?.split(separator: ",").map(String.init) ?? [])
                == [held.uuidString, quick.uuidString])
        #expect(idle.sentence.hasPrefix("Every agent here has stopped: 2 worked"))

        try await Task.sleep(for: settle * 3)
        #expect(await idles(core).count == 1, "once a busy period, not again while quiet")
    }

    @Test func theCleanUpItStartsDoesNotRaiseItAgain() async throws {
        let (locations, work) = try temporary()
        let folder = WorkflowFile.folder(in: work)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("---\non:\n  - project.idle\nagent: new\n---\n\nTidy up.\n".utf8)
            .write(to: WorkflowFile.url(for: "tidy", in: work))
        let core = try await core(locations)
        await core.rescanWorkflows(in: work)

        _ = try await core.start(DaemonAPI.StartRequest(runtimeID: "claude", cwd: work, prompt: "Work"))
        try await eventually("the clean-up ran and finished") {
            await core.allAgents().contains { $0.startedByWorkflow == "tidy" && $0.state == .finished }
        }
        try await Task.sleep(for: settle * 4)
        #expect(await idles(core).count == 1)
        #expect(await core.allAgents().filter { $0.startedByWorkflow == "tidy" }.count == 1)
    }

    @Test func aWorkflowParsesItAndAWholeSubjectReadsIt() {
        let workflow = WorkflowFile.parse("---\non:\n  - project.idle\n  - project.*\n---\n\nGo.\n",
                                          workflowID: "w", in: URL(fileURLWithPath: "/tmp/p"))
        #expect(workflow.problem == nil)
        #expect(workflow.triggers.first?.listensIn == .project)
        #expect(workflow.triggers.first?.resumedAgent == "These events are about no agent, so this never runs it")
        #expect(workflow.triggers.first?.summary == "When every agent in this project has stopped working")
    }
}
