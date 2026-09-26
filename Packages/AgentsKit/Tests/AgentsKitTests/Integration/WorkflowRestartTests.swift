import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// 025 US3: a restart does not break a chain of workflows.
///
/// A run in flight was the only part of the workflow bookkeeping held in memory alone.
/// When the daemon went while one was running, its agent was picked back up and finished
/// — and then nothing set to run on that workflow's completion ever heard, because the
/// run it would have been told about no longer existed. The depth that stops a chain
/// looping went with it.
///
/// Every test here is a second `DaemonCore` on the same root, started the way
/// `Daemon.start()` starts one. A test with one daemon in it proves nothing about this.
@Suite("Workflows across a restart", .timeLimit(.minutes(1)))
struct WorkflowRestartTests {
    // MARK: Scaffolding

    private func temporary() throws -> (StoreLocations, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsWorkflowRestart-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (StoreLocations(root: root), root.resolvingSymlinksInPath())
    }

    private func project(_ root: URL, _ name: String = "api") throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return Project.standardize(url)
    }

    private func write(_ text: String, as workflowID: String, in project: URL) throws {
        let folder = WorkflowFile.folder(in: project)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: WorkflowFile.url(for: workflowID, in: project))
    }

    /// Something that runs when asked, in a new agent.
    private func byHand(_ prompt: String = "Do the thing.") -> String {
        """
        ---
        on:
          - schedule:
              at: [":00"]
        agent: new
        ---

        \(prompt)
        """
    }

    /// Something that runs when another workflow completes — or any, with no id.
    private func after(_ workflowID: String?) -> String {
        let trigger = workflowID.map { "  - workflow-completed:\n      id: \($0)" }
            ?? "  - workflow-completed"
        return """
            ---
            on:
            \(trigger)
            agent: new
            ---

            The one before me finished. Carry on.
            """
    }

    /// A runtime whose turns take an hour: an agent that is still working when the test
    /// is over, which is what an agent cut off by a restart was.
    private var endless: FakeACPAgent.Script {
        var script = FakeACPAgent.Script()
        script.turnDelay = .seconds(3_600)
        return script
    }

    private func core(_ locations: StoreLocations, seeded: [Agent] = [],
                      script: FakeACPAgent.Script = .init()) async throws -> DaemonCore {
        let store = try AgentStore(locations: locations)
        for agent in seeded { try await store.save(agent) }
        return DaemonCore(store: store, locations: locations,
                          discovery: .findsEverything, launcher: FakeLauncher(script: script))
    }

    /// The order `Daemon.start()` does it in, which is the order this feature depends on:
    /// events held, recovery, workflows, and only then the agents picked back up.
    @discardableResult
    private func startLikeTheDaemon(_ core: DaemonCore) async -> [UUID] {
        await core.holdWorkflowEventsUntilStarted()
        let recovered = await core.recover()
        await core.startWorkflows()
        await core.pickUpAfterRestart(recovered)
        return recovered
    }

    /// An agent the last daemon was holding, started by a workflow run.
    private func cutOff(in work: URL, by workflowID: String, run: UUID) -> Agent {
        Agent(runtimeID: "claude", cwd: work, title: "cut off", state: .running,
              endedReason: nil, startedByWorkflow: workflowID, startedByRun: run)
    }

    /// A run on disk, as the last daemon would have left it.
    private func leaveOnDisk(_ runs: [WorkflowRun], at locations: StoreLocations) {
        let store = WorkflowStore(locations: locations)
        var records = store.load()
        records.runs = runs
        store.save(records)
    }

    private func runsOnDisk(_ locations: StoreLocations) -> [WorkflowRun] {
        WorkflowStore(locations: locations).load().runs
    }

    private func summary(_ core: DaemonCore, _ workflowID: String, in work: URL) async -> WorkflowSummary? {
        await core.allWorkflows(in: work).first { $0.workflowID == workflowID }
    }

    // MARK: US3

    /// Scenario 1, end to end: the run is written when it is claimed, survives the
    /// daemon, and its completion fires what was waiting on it.
    @Test func aChainIsNotBrokenByARestart() async throws {
        let (locations, root) = try temporary()
        defer { try? FileManager.default.removeItem(at: locations.root) }
        let work = try project(root)
        try write(byHand(), as: "first", in: work)
        try write(after("first"), as: "second", in: work)

        // The first daemon fires the first workflow, whose agent is still working when
        // the daemon goes.
        let first = try await core(locations, script: endless)
        _ = await first.recover()
        await first.rescanWorkflows(in: work)
        _ = try await first.runWorkflow(DaemonAPI.WorkflowRequest(folder: work, workflowID: "first"))
        await eventually("the run is on disk, with its agent") {
            runsOnDisk(locations).first { $0.workflowID == "first" }?.agentID != nil
        }
        // And the agent's own record names the run back. It is written by a queued task
        // a moment after the run, so a restart here, before it lands, is the crash window
        // `aRunWhoseAgentDoesNotNameItBackIsStillFound` is about — not this test's.
        await eventually("the agent's record names the run back") {
            guard let run = runsOnDisk(locations).first(where: { $0.workflowID == "first" }),
                  let agentID = run.agentID,
                  let (agent, _) = try? await AgentStore(locations: locations).load(agentID)
            else { return false }
            return agent.startedByRun == run.id
        }

        // The next daemon picks the agent up, it finishes, and the chain carries on.
        let second = try await core(locations)
        await startLikeTheDaemon(second)
        let chained = await eventually("the workflow waiting on the first one ran") {
            await second.allAgents().contains { $0.startedByWorkflow == "second" }
        }
        if !chained {
            // Say what was seen, because "never became true" is not a place to start.
            let carried = await second.allAgents().first { $0.startedByWorkflow == "first" }
            let lines = (try? await second.store.transcript(for: carried?.id ?? UUID(), limit: 8).entries) ?? []
            let inMemory: [String] = await second.workflowRuns.values.map(\.workflowID)
            let onDisk: [String] = runsOnDisk(locations).map(\.workflowID)
            let outcome = await summary(second, "second", in: work)?.lastOutcome
            let state = String(describing: carried?.state)
            let ending = String(describing: carried?.endedReason)
            let tail: [String] = lines.map { String(String(describing: $0.kind).prefix(100)) }
            let seen: String = "first's agent: \(state) \(ending); last lines: \(tail); "
                + "runs in memory: \(inMemory); on disk: \(onDisk); second: \(String(describing: outcome))"
            Issue.record(Comment(rawValue: seen))
        }
        await eventually("and the first run is over, on disk as well as in memory") {
            !runsOnDisk(locations).contains { $0.workflowID == "first" }
        }
    }

    /// The window between the two writes. The run is on disk the moment its agent is
    /// known; the agent's record, which names the run back, lands a moment later. A
    /// daemon killed in between leaves an agent that does not know it is doing a
    /// workflow's work — and its run must still be found, or it is never released and
    /// nothing waiting on it hears.
    @Test func aRunWhoseAgentDoesNotNameItBackIsStillFound() async throws {
        let (locations, root) = try temporary()
        defer { try? FileManager.default.removeItem(at: locations.root) }
        let work = try project(root)
        try write(byHand(), as: "first", in: work)
        try write(after("first"), as: "second", in: work)
        // As `start` first writes it: working, and nothing yet about any workflow.
        let agent = Agent(runtimeID: "claude", cwd: work, title: "cut off", state: .running,
                          endedReason: nil)
        leaveOnDisk([WorkflowRun(workflowID: "first", folder: work,
                                 trigger: .schedule(WorkflowSchedule()),
                                 agentID: agent.id, startedAt: Date())], at: locations)

        let core = try await core(locations, seeded: [agent])
        await startLikeTheDaemon(core)

        #expect(await summary(core, "first", in: work)?.isRunning == true,
                "a run whose agent is carrying on is kept, however it is linked")
        await eventually("its agent finished, and what waited on it ran") {
            await core.allAgents().contains { $0.startedByWorkflow == "second" }
        }
        await eventually("and the run was let go") { runsOnDisk(locations).isEmpty }
    }

    /// Scenario 2: the ceiling counts from the restored run, not from zero. A run three
    /// deep whose agent finishes after a restart makes a fourth link — which is refused.
    /// Were the depth lost, the fourth would run, and a loop would have one more lap in
    /// it every time the daemon restarted.
    @Test func theDepthCeilingCountsFromTheRestoredRun() async throws {
        let (locations, root) = try temporary()
        defer { try? FileManager.default.removeItem(at: locations.root) }
        let work = try project(root)
        try write(byHand(), as: "deep", in: work)
        try write(after("deep"), as: "next", in: work)
        let runID = UUID()
        let agent = cutOff(in: work, by: "deep", run: runID)
        leaveOnDisk([WorkflowRun(id: runID, workflowID: "deep", folder: work,
                                 trigger: .workflowCompleted(id: "earlier"),
                                 depth: Workflow.chainDepthLimit, agentID: agent.id,
                                 startedAt: Date())], at: locations)

        let core = try await core(locations, seeded: [agent])
        await startLikeTheDaemon(core)

        let refused = await eventuallySome("the next link was refused for depth") { () -> WorkflowRefusal? in
            guard case .refused(let refusal, _, _) = await summary(core, "next", in: work)?.lastOutcome
            else { return nil }
            return refusal
        }
        #expect(refused == .chainTooDeep(depth: Workflow.chainDepthLimit))
        #expect(await core.allAgents().contains { $0.startedByWorkflow == "next" } == false)
    }

    /// The other half of the ceiling: one link short of it, the chain still runs.
    @Test func aChainShortOfTheCeilingCarriesOnFromTheRestoredDepth() async throws {
        let (locations, root) = try temporary()
        defer { try? FileManager.default.removeItem(at: locations.root) }
        let work = try project(root)
        try write(byHand(), as: "deep", in: work)
        try write(after("deep"), as: "next", in: work)
        let runID = UUID()
        let agent = cutOff(in: work, by: "deep", run: runID)
        leaveOnDisk([WorkflowRun(id: runID, workflowID: "deep", folder: work,
                                 trigger: .workflowCompleted(id: "earlier"),
                                 depth: Workflow.chainDepthLimit - 1, agentID: agent.id,
                                 startedAt: Date())], at: locations)

        let core = try await core(locations, seeded: [agent])
        await startLikeTheDaemon(core)

        await eventually("the next link ran") {
            await core.allAgents().contains { $0.startedByWorkflow == "next" }
        }
    }

    /// Scenarios 3 and 5: a restored run is a run. The project page says it is running,
    /// and a second fire of the same workflow is refused as one already in flight.
    @Test func aRestoredRunStillHoldsItsWorkflow() async throws {
        let (locations, root) = try temporary()
        defer { try? FileManager.default.removeItem(at: locations.root) }
        let work = try project(root)
        try write(byHand(), as: "deep", in: work)
        let runID = UUID()
        let agent = cutOff(in: work, by: "deep", run: runID)
        leaveOnDisk([WorkflowRun(id: runID, workflowID: "deep", folder: work,
                                 trigger: .workflowCompleted(id: "earlier"),
                                 agentID: agent.id, startedAt: Date())], at: locations)

        // Picked back up into a turn that does not end, so the run stays in flight.
        let core = try await core(locations, seeded: [agent], script: endless)
        await startLikeTheDaemon(core)

        #expect(await summary(core, "deep", in: work)?.isRunning == true)
        _ = try await core.runWorkflow(DaemonAPI.WorkflowRequest(folder: work, workflowID: "deep"))
        guard case .refused(let refusal, _, _) = await summary(core, "deep", in: work)?.lastOutcome else {
            Issue.record("a second fire was not refused")
            return
        }
        #expect(refusal == .runInFlight)
        #expect(await core.allAgents().filter { $0.startedByWorkflow == "deep" }.count == 1,
                "no second agent was started beside the one carrying on")
    }

    /// Scenario 4 and FR-012: a run that cannot complete is let go, and nothing waiting
    /// on its completion is fired — it did not complete, and firing on it would be the
    /// app inventing a completion nobody saw.
    @Test func aRunThatCannotCompleteIsReleasedWithoutFiring() async throws {
        let (locations, root) = try temporary()
        defer { try? FileManager.default.removeItem(at: locations.root) }
        let work = try project(root)
        for id in ["archived", "missing", "deleted", "stale", "finished"] {
            try write(byHand(), as: id, in: work)
        }
        try write(after(nil), as: "watcher", in: work)

        let archived = Agent(runtimeID: "claude", cwd: work, title: "put away", state: .archived,
                             endedReason: .endTurn, archivedReason: .byUser,
                             startedByWorkflow: "archived", startedByRun: UUID())
        let deleted = cutOff(in: work, by: "deleted", run: UUID())
        let stale = cutOff(in: work, by: "stale", run: UUID())
        // Finished, but the daemon went before the run was let go: the narrow window
        // between a record written and the run released. It will never finish again.
        let finished = Agent(runtimeID: "claude", cwd: work, title: "done", state: .finished,
                             endedReason: .endTurn, startedByWorkflow: "finished", startedByRun: UUID())
        let week = WorkflowRecords.runHorizon
        func run(_ agent: Agent?, _ workflowID: String, startedAt: Date = Date()) -> WorkflowRun {
            WorkflowRun(id: agent?.startedByRun ?? UUID(), workflowID: workflowID, folder: work,
                        trigger: .schedule(WorkflowSchedule()), agentID: agent?.id ?? UUID(),
                        startedAt: startedAt)
        }
        leaveOnDisk([run(archived, "archived"),
                     run(nil, "missing"),
                     run(deleted, "deleted"),
                     run(stale, "stale", startedAt: Date().addingTimeInterval(-week - 60)),
                     run(finished, "finished")], at: locations)
        try FileManager.default.removeItem(at: WorkflowFile.url(for: "deleted", in: work))

        let core = try await core(locations, seeded: [archived, deleted, stale, finished])
        await startLikeTheDaemon(core)

        #expect(runsOnDisk(locations).isEmpty, "left: \(runsOnDisk(locations).map(\.workflowID))")
        for id in ["archived", "missing", "stale", "finished"] {
            #expect(await summary(core, id, in: work)?.isRunning == false, "\(id) still held")
        }
        // The two cut-off agents are picked back up and finish. Their runs are gone, so
        // their finishing completes nothing.
        await eventually("the picked-up agents finished") {
            let one = await core.agent(deleted.id)?.state
            let other = await core.agent(stale.id)?.state
            return one == .finished && other == .finished
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(await core.allAgents().contains { $0.startedByWorkflow == "watcher" } == false,
                "a completion was invented for a run that was let go")
    }
}
