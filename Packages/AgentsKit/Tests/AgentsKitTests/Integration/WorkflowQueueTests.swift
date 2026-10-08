import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// Triggers that come while a run is going wait their turn (#422).
///
/// Found on the #383 walk: two `checks.failed` in one poll, and the second PR got no
/// agent because the first was still running. Each now waits, keeps its own event, and
/// runs on its own when the run before it ends; the event reads "queued" until then.
@Suite("Queueing a trigger behind a run", .timeLimit(.minutes(1)))
struct WorkflowQueueTests {
    private func temporary() throws -> (StoreLocations, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsWorkflowQueue-\(UUID().uuidString)", isDirectory: true)
        let work = root.appendingPathComponent("api", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        return (StoreLocations(root: root), Project.standardize(work))
    }

    private func write(in project: URL) throws {
        let folder = WorkflowFile.folder(in: project)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("---\non:\n  - mac.wake\nagent: new\n---\n\nGo.\n".utf8)
            .write(to: WorkflowFile.url(for: "fix", in: project))
    }

    private func core(_ locations: StoreLocations, turn: Duration) async throws -> DaemonCore {
        var script = FakeACPAgent.Script()
        script.turnDelay = turn
        let core = DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                              discovery: .findsEverything, launcher: FakeLauncher(script: script))
        await core.loadFromDisk()
        return core
    }

    private func summary(_ core: DaemonCore, _ folder: URL) async -> WorkflowSummary? {
        await core.allWorkflows(in: folder).first { $0.workflowID == "fix" }
    }

    /// A wake of its own: the same event again inside a minute folds into the last.
    private func wake(_ core: DaemonCore, _ n: Int) async -> Event {
        await core.raise(EventDraft(name: "mac.wake", at: Date(), scope: .mac, sentence: "This Mac woke up.",
                                    details: ["n": "\(n)"]))
    }

    private func consequences(_ core: DaemonCore, _ event: Event) async -> [Consequence] {
        await core.eventLog.event(at: event.position)?.consequences ?? []
    }

    private func firedAgent(_ consequences: [Consequence]) -> UUID? {
        for case .fired(_, _, let agentID?) in consequences { return agentID }
        return nil
    }

    private func eventually(_ what: String, _ check: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: max(.seconds(20), Eventually.timeout))
        while ContinuousClock.now < deadline {
            if try await check() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("never happened: \(what)")
    }

    @Test func eachTriggerDuringARunGetsARunOfItsOwnInTurn() async throws {
        let (locations, work) = try temporary()
        defer { try? FileManager.default.removeItem(at: locations.root) }
        try write(in: work)
        let core = try await core(locations, turn: .milliseconds(700))
        await core.rescanWorkflows(in: work)

        let first = await wake(core, 1)
        try await eventually("the first wake started a run") { await summary(core, work)?.isRunning == true }
        let second = await wake(core, 2)
        let third = await wake(core, 3)
        let queued = Consequence.refused(workflowID: "fix", folder: work, reason: .queued)
        try await eventually("both later wakes read queued") {
            let a = await consequences(core, second), b = await consequences(core, third)
            return a == [queued] && b == [queued]
        }
        let waiting = try #require(await summary(core, work))
        #expect(waiting.queued == 2)
        #expect(waiting.queuedSentence == "2 triggers queued — each runs in turn")
        #expect(await core.allAgents().count < 3, "one run at a time")
        // Queued is not news on the log; it is on the row and on each event.
        #expect(!(await core.eventLog.events.contains { $0.name == "workflow.refused" }))

        try await eventually("every wake ran") { await core.allAgents().count == 3 }
        try await eventually("the last run finished") {
            await summary(core, work).map { !$0.isRunning && $0.queued == 0 } == true
        }
        // Each event says "fired", in place of "queued", and names its own agent.
        var agents: [UUID] = []
        for event in [first, second, third] {
            let lines = await consequences(core, event)
            #expect(lines.count == 1, "one line per event, not queued and then fired: \(lines)")
            agents.append(try #require(firedAgent(lines)))
        }
        #expect(Set(agents).count == 3)
        // In the order they came.
        let started = await core.allAgents().sorted { $0.createdAt < $1.createdAt }.map(\.id)
        #expect(started == agents)
    }

    @Test func pastTheLimitATriggerIsRefusedAndSaysSo() async throws {
        let (locations, work) = try temporary()
        defer { try? FileManager.default.removeItem(at: locations.root) }
        try write(in: work)
        let core = try await core(locations, turn: .seconds(3_600))
        await core.rescanWorkflows(in: work)

        _ = await wake(core, 0)
        try await eventually("a run is going") { await summary(core, work)?.isRunning == true }
        for n in 1...Workflow.queueLimit { _ = await wake(core, n) }
        try await eventually("the queue is full") { await summary(core, work)?.queued == Workflow.queueLimit }
        let over = await wake(core, 99)
        let full = Consequence.refused(workflowID: "fix", folder: work,
                                       reason: .queueFull(limit: Workflow.queueLimit))
        try await eventually("the one past it says why") { await consequences(core, over) == [full] }
        #expect(await summary(core, work)?.queued == Workflow.queueLimit)
        try await eventually("and it is news") {
            await core.eventLog.events.contains { $0.name == "workflow.refused" && $0.details["reason"] == "queue_full" }
        }
    }

    @Test func turningItOffLetsTheQueueGoAndEachEventSays() async throws {
        let (locations, work) = try temporary()
        defer { try? FileManager.default.removeItem(at: locations.root) }
        try write(in: work)
        let core = try await core(locations, turn: .seconds(3_600))
        await core.rescanWorkflows(in: work)

        _ = await wake(core, 0)
        try await eventually("a run is going") { await summary(core, work)?.isRunning == true }
        let waiting = await wake(core, 1)
        try await eventually("queued") { await summary(core, work)?.queued == 1 }

        let off = try await core.setWorkflowEnabled(
            DaemonAPI.WorkflowEnableRequest(folder: work, workflowID: "fix", enabled: false))
        #expect(off.queued == 0)
        #expect(await consequences(core, waiting)
            == [.refused(workflowID: "fix", folder: work, reason: .disabled)])
    }

    @Test func theQueueSurvivesTheDaemonGoing() async throws {
        let (locations, work) = try temporary()
        defer { try? FileManager.default.removeItem(at: locations.root) }
        try write(in: work)
        do {
            let core = try await core(locations, turn: .seconds(3_600))
            await core.rescanWorkflows(in: work)
            _ = await wake(core, 0)
            try await eventually("a run is going") { await summary(core, work)?.isRunning == true }
            _ = await wake(core, 1)
            try await eventually("queued") { await summary(core, work)?.queued == 1 }
        }
        let again = try await core(locations, turn: .milliseconds(10))
        await again.rescanWorkflows(in: work)
        #expect(await summary(again, work)?.queued == 1)
    }
}
