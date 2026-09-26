import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// Workflows on events, through the daemon (042 US3, FR-021, FR-023, FR-027, FR-030).
@Suite("Workflows on events", .timeLimit(.minutes(1)))
struct EventWorkflowTests {
    private func temporary() throws -> (StoreLocations, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsEventWorkflows-\(UUID().uuidString)", isDirectory: true)
        let work = root.appendingPathComponent("api", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        return (StoreLocations(root: root), Project.standardize(work))
    }

    private func write(_ on: String, mode: String = "new", as workflowID: String, in project: URL) throws {
        let folder = WorkflowFile.folder(in: project)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("---\non:\n\(on)\nagent: \(mode)\n---\n\nDo it.\n".utf8)
            .write(to: WorkflowFile.url(for: workflowID, in: project))
    }

    private func core(_ locations: StoreLocations) async throws -> DaemonCore {
        let core = DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                              discovery: .findsEverything, launcher: FakeLauncher())
        await core.loadFromDisk()
        return core
    }

    private func eventually(_ what: String, _ check: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while ContinuousClock.now < deadline {
            if try await check() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("never happened: \(what)")
    }

    private func started(_ core: DaemonCore, by workflowID: String) async -> [Agent] {
        await core.allAgents().filter { $0.startedByWorkflow == workflowID }
    }

    @Test func aWorkflowOnMacWakeFiresOnceAndTheEventSaysSo() async throws {
        let (locations, work) = try temporary()
        try write("  - mac.wake", as: "catch-up", in: work)
        let core = try await core(locations)
        await core.rescanWorkflows(in: work)

        let wake = await core.raise(EventDraft(name: "mac.wake", scope: .mac, sentence: "This Mac woke up."))
        try await eventually("the workflow started an agent") { await started(core, by: "catch-up").count == 1 }
        let agent = try #require(await started(core, by: "catch-up").first)
        try await eventually("the fire is on the event") {
            await core.eventLog.event(at: wake.position)?.consequences
                == [.fired(workflowID: "catch-up", folder: work, agentID: agent.id)]
        }
        let summary = await core.allWorkflows(in: work).first { $0.workflowID == "catch-up" }
        #expect(summary?.causingEvent == wake.position)
        #expect(summary?.causingEventName == "mac.wake")
        #expect(await core.eventLog.events.contains { $0.name == "workflow.ran" && $0.details["workflow"] == "catch-up" })
        try await Task.sleep(for: .milliseconds(100))
        #expect(await started(core, by: "catch-up").count == 1, "once")
    }

    @Test func aCustomEventResumesItsPublisherInTriggeringMode() async throws {
        let (locations, work) = try temporary()
        try write("  - custom.release_ready", mode: "triggering", as: "release", in: work)
        let core = try await core(locations)
        await core.rescanWorkflows(in: work)
        let publisher = try await core.start(DaemonAPI.StartRequest(runtimeID: "claude", cwd: work, prompt: "Build"))
        try await eventually("publisher settled") { await core.agent(publisher)?.state == .finished }

        let event = await core.raise(EventDraft(name: "custom.release_ready", scope: .project(folder: work),
                                                sentence: "published",
                                                publisher: EventPublisher(agentID: publisher, title: "Build")))
        try await eventually("fired in the publisher") {
            await core.eventLog.event(at: event.position)?.consequences
                == [.fired(workflowID: "release", folder: work, agentID: publisher)]
        }
    }

    @Test func triggeringOnAnEventWithNoAgentIsRefusedAndTheEventSaysWhy() async throws {
        let (locations, work) = try temporary()
        try write("  - mac.wake", mode: "triggering", as: "resume-someone", in: work)
        let core = try await core(locations)
        await core.rescanWorkflows(in: work)
        let wake = await core.raise(EventDraft(name: "mac.wake", scope: .mac, sentence: "This Mac woke up."))
        try await eventually("refused on the event") {
            await core.eventLog.event(at: wake.position)?.consequences
                == [.refused(workflowID: "resume-someone", folder: work, reason: .noTriggeringAgent)]
        }
        #expect(await core.eventLog.events.contains { $0.name == "workflow.refused" })
    }

    @Test func todaysAgentFinishedFiresOnceAndIsNowOnTheLog() async throws {
        let (locations, work) = try temporary()
        try write("  - agent-finished", as: "on-finish", in: work)
        let core = try await core(locations)
        await core.rescanWorkflows(in: work)
        let first = try await core.start(DaemonAPI.StartRequest(runtimeID: "claude", cwd: work, prompt: "Do a thing"))
        try await eventually("the workflow started an agent") { await started(core, by: "on-finish").count >= 1 }
        try await Task.sleep(for: .milliseconds(200))
        // One fire for the first agent's finish (its own agent's finish refuses: a run in flight).
        let finished = await core.eventLog.events.first {
            $0.name == "agent.finished" && $0.details["agent"] == first.uuidString
        }
        let fired = finished?.consequences.filter { if case .fired = $0 { return true } else { return false } }
        #expect(fired?.count == 1)
    }

    @Test func aWorkflowIsNeverFiredByNewsOfItself() async throws {
        let (locations, work) = try temporary()
        try write("  - workflow.*", as: "watcher", in: work)
        let core = try await core(locations)
        await core.rescanWorkflows(in: work)
        await core.raise(EventDraft(name: "workflow.refused", scope: .project(folder: work), sentence: "x",
                                    details: ["workflow": "watcher", "reason": "r"]))
        try await Task.sleep(for: .milliseconds(200))
        #expect(await started(core, by: "watcher").isEmpty)
    }
}
