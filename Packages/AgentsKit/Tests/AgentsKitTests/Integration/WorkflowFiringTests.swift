import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// Workflows that actually fire, driven through the real daemon.
///
/// The clock is a parameter to `tickWorkflows`, not something to wait for, so a week
/// passes here in a millisecond. The runtime is the fake launcher, so an agent really
/// starts and really finishes without a CLI, a credential or a network.
@Suite("Firing a workflow", .timeLimit(.minutes(1)))
struct WorkflowFiringTests {
    // MARK: Scaffolding

    private func temporary() throws -> (StoreLocations, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsWorkflowTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (StoreLocations(root: root), root.resolvingSymlinksInPath())
    }

    private func project(_ root: URL, _ name: String = "api") throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return Project.standardize(url)
    }

    @discardableResult
    private func write(_ text: String, as workflowID: String, in project: URL) throws -> URL {
        let folder = WorkflowFile.folder(in: project)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = WorkflowFile.url(for: workflowID, in: project)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func core(_ locations: StoreLocations, seeded: [Agent] = [],
                      script: FakeACPAgent.Script = .init()) async throws -> DaemonCore {
        let store = try AgentStore(locations: locations)
        for agent in seeded { try await store.save(agent) }
        let core = DaemonCore(store: store, locations: locations,
                              discovery: .findsEverything, launcher: FakeLauncher(script: script))
        await core.loadFromDisk()
        return core
    }

    /// Every half hour, all day, in a new agent.
    private func everyHalfHour(_ prompt: String = "Say hello and stop.") -> String {
        """
        ---
        on:
          - schedule:
              at: [":00", ":30"]
        agent: new
        ---

        \(prompt)
        """
    }

    // MARK: Being seen at all

    @Test func aFileWrittenIntoAProjectIsListed() async throws {
        let (locations, root) = try temporary()
        let work = try project(root)
        try write(everyHalfHour(), as: "say-hello", in: work)

        let core = try await core(locations, seeded: [
            Agent(runtimeID: "claude", cwd: work, title: "seed", state: .finished,
                  endedReason: .endTurn)
        ])
        await core.rescanWorkflows(in: work)

        let listed = await core.allWorkflows(in: work)
        #expect(listed.count == 1)
        #expect(listed.first?.workflow.name == "Say hello")
        #expect(listed.first?.workflow.canFire == true)
        #expect(listed.first?.nextFireAt != nil)
    }

    @Test func anUnreadableFileIsListedWithItsProblemRatherThanLeftOut() async throws {
        // A gap where a row should be is exactly how this feature fails quietly.
        let (locations, root) = try temporary()
        let work = try project(root)
        try write("no front matter here", as: "broken", in: work)

        let core = try await core(locations)
        await core.rescanWorkflows(in: work)

        let listed = await core.allWorkflows(in: work)
        #expect(listed.count == 1)
        #expect(listed.first?.workflow.canFire == false)
        #expect(listed.first?.workflow.problem != nil)
    }

    // MARK: The clock

    @Test func aDueScheduleStartsAnAgent() async throws {
        let (locations, root) = try temporary()
        let work = try project(root)
        try write(everyHalfHour(), as: "say-hello", in: work)

        let core = try await core(locations)
        await core.rescanWorkflows(in: work)

        // Two ticks either side of a half-hour boundary. The first only establishes
        // where the window starts: a tick with nothing behind it fires nothing, because
        // everything before the daemon existed is somebody else's business.
        var when = DateComponents()
        when.year = 2026; when.month = 9; when.day = 21; when.hour = 9; when.minute = 29
        let justBefore = Calendar.current.date(from: when)!
        await core.tickWorkflows(now: justBefore)
        await core.tickWorkflows(now: justBefore.addingTimeInterval(90))

        let agents = await core.allAgents()
        #expect(agents.count == 1)
        #expect(agents.first?.startedByWorkflow == "say-hello")
        #expect(agents.first?.cwd == work)
    }

    @Test func aScheduleThatIsNotDueStartsNothing() async throws {
        let (locations, root) = try temporary()
        let work = try project(root)
        // Nine in the morning only, and the window below is nowhere near it.
        try write("""
            ---
            on:
              - schedule:
                  at: [":00"]
                  between: "09:00-09:00"
            ---

            Go.
            """, as: "morning-only", in: work)

        let core = try await core(locations)
        await core.rescanWorkflows(in: work)

        var when = DateComponents()
        when.year = 2026; when.month = 9; when.day = 21; when.hour = 14; when.minute = 0
        let afternoon = Calendar.current.date(from: when)!
        await core.tickWorkflows(now: afternoon)
        await core.tickWorkflows(now: afternoon.addingTimeInterval(60))

        #expect(await core.allAgents().isEmpty)
    }

    // MARK: Run now

    @Test func runNowStartsAnAgentWhateverTheSchedule() async throws {
        let (locations, root) = try temporary()
        let work = try project(root)
        try write(everyHalfHour(), as: "say-hello", in: work)

        let core = try await core(locations)
        await core.rescanWorkflows(in: work)
        let summary = try await core.runWorkflow(
            DaemonAPI.WorkflowRequest(folder: work, workflowID: "say-hello"))

        #expect(await core.allAgents().count == 1)
        if case .ran = summary.lastOutcome {} else {
            Issue.record("expected a run, got \(String(describing: summary.lastOutcome))")
        }
    }

    @Test func theAgentCarriesTheWorkflowsPromptAndName() async throws {
        let (locations, root) = try temporary()
        let work = try project(root)
        try write(everyHalfHour("Count to three."), as: "counter", in: work)

        let core = try await core(locations)
        await core.rescanWorkflows(in: work)
        try await core.runWorkflow(DaemonAPI.WorkflowRequest(folder: work, workflowID: "counter"))

        guard let agent = await core.allAgents().first else {
            Issue.record("expected an agent")
            return
        }
        #expect(agent.title == "Counter")
        let page = try await core.transcript(
            DaemonAPI.TranscriptRequest(agentID: agent.id, before: nil, limit: 50))
        let said = page.entries.contains { entry in
            if case .userMessage(let text, _, _) = entry.kind { return text.contains("Count to three.") }
            return false
        }
        #expect(said)
    }

    // MARK: Standing agents

    @Test func aStandingWorkflowResumesTheSameAgent() async throws {
        let (locations, root) = try temporary()
        let work = try project(root)
        try write("""
            ---
            on:
              - schedule:
                  at: [":00"]
            agent: standing
            ---

            Carry on.
            """, as: "standup", in: work)

        let core = try await core(locations)
        await core.rescanWorkflows(in: work)
        let request = DaemonAPI.WorkflowRequest(folder: work, workflowID: "standup")
        try await core.runWorkflow(request)
        let first = await core.allAgents().first?.id
        try await core.runWorkflow(request)

        let agents = await core.allAgents()
        #expect(agents.count == 1)
        #expect(agents.first?.id == first)
    }

    @Test func aStandingWorkflowWhoseAgentIsGoneStartsAndAdoptsAFreshOne() async throws {
        let (locations, root) = try temporary()
        let work = try project(root)
        try write("""
            ---
            on:
              - schedule:
                  at: [":00"]
            agent: standing
            ---

            Carry on.
            """, as: "standup", in: work)

        let core = try await core(locations)
        await core.rescanWorkflows(in: work)
        let request = DaemonAPI.WorkflowRequest(folder: work, workflowID: "standup")
        try await core.runWorkflow(request)

        guard let first = await core.allAgents().first?.id else {
            Issue.record("expected an agent")
            return
        }
        try await core.archive(first)
        try await core.runWorkflow(request)

        let agents = await core.allAgents()
        #expect(agents.count == 2)
        #expect(agents.contains { $0.id != first && $0.startedByWorkflow == "standup" })
    }

    // MARK: An ending the daemon discovered when it came back (020, US2)

    /// A workflow file that watches for an agent stopping.
    private func onStopped() -> String {
        """
        ---
        on:
          - agent-stopped
        ---

        An agent stopped. Go and look.
        """
    }

    /// An agent the last daemon was holding, as it would be found on disk.
    private func wasWorking(in work: URL, pickUps: Int) -> Agent {
        Agent(runtimeID: "claude", cwd: work, title: "cut off",
              state: .running, endedReason: nil, restartPickUps: pickUps)
    }

    /// There used to be a test here that a restart fires the stopped workflow for an
    /// agent left alone after a second cut-off. Alex removed the "left alone" rule on
    /// 2026-09-21 — every chat the daemon took is picked back up — so a restart never
    /// ends an agent for good any more, and the trigger it owed is owed by the run
    /// that carries on instead. The deferral itself is tested below by raising the
    /// event by hand.

    /// FR-016. An agent about to carry on has not finished stopping.
    ///
    /// Recovery is seconds away from bringing this one back — every one, now, however
    /// many times it has been through this. Saying "an agent stopped" about it would
    /// be false, and would race the pick-up.
    @Test func anAgentAboutToBePickedBackUpDoesNotFire() async throws {
        let (locations, root) = try temporary()
        let work = try project(root)
        try write(onStopped(), as: "on-stop", in: work)

        let core = try await core(locations, seeded: [wasWorking(in: work, pickUps: 0)])
        await core.holdWorkflowEventsUntilStarted()
        let recovered = await core.recover()
        await core.startWorkflows()

        // It was recorded as stopped all the same — the ending happened, it is simply
        // not one anything should be told about yet.
        let id = try #require(recovered.first)
        #expect(await core.agent(id)?.state == .stopped)
        #expect(await core.agent(id)?.endedReason == .daemonGone)
        #expect(await core.agent(id)?.mayBePickedUpAfterRestart == true)

        // Nothing to wait for, so give the drain every chance to have misfired.
        try await Task.sleep(for: .milliseconds(200))
        #expect(await core.allAgents().contains { $0.startedByWorkflow == "on-stop" } == false,
                "a workflow fired at an agent that is about to carry on")
    }

    /// The deferral itself, asserted directly rather than inferred from a fire.
    ///
    /// Worth its own test because the failure mode it guards is silence: if
    /// `workflowsRespond` dropped the event instead of holding it, every assertion
    /// above would still pass in a world where the queue did nothing, so long as
    /// nothing fired for other reasons.
    @Test func anEventRaisedBeforeWorkflowsStartedIsHeldAndNotDropped() async throws {
        let (locations, root) = try temporary()
        let work = try project(root)
        try write(onStopped(), as: "on-stop", in: work)

        let core = try await core(locations, seeded: [wasWorking(in: work, pickUps: 1)])
        await core.holdWorkflowEventsUntilStarted()
        let recovered = await core.recover()
        // Recovery itself raises nothing now — the agent is about to be picked back up
        // — so the ending is raised by hand, inside the closed window, exactly as
        // `move` would raise one that was final.
        let id = try #require(recovered.first)
        await core.workflowsRespond(to: .stopped, agentID: id)
        // Deliberately not started yet. The ending has happened and nothing has acted.
        #expect(await core.allAgents().contains { $0.startedByWorkflow == "on-stop" } == false)
        #expect(await core.deferredLifecycleEvents.count == 1,
                "the ending was dropped rather than held")
        #expect(await core.deferredLifecycleEvents.first?.event == .stopped)

        await core.startWorkflows()
        #expect(await core.deferredLifecycleEvents.isEmpty, "the queue was not drained")
        await eventually("the held event fired once the layer could act") {
            await core.allAgents().contains { $0.startedByWorkflow == "on-stop" }
        }
    }

    /// FR-013 and SC-004: an ending discovered on a restart is an ending like any
    /// other, so it writes one transcript line and moves the project's counts.
    ///
    /// Exactly one line, because until 020 this loop wrote it by hand — routing
    /// through `move` without deleting that write would have produced two.
    @Test func aRecoveryEndingIsRecordedExactlyOnce() async throws {
        let (locations, root) = try temporary()
        let work = try project(root)

        let core = try await core(locations, seeded: [wasWorking(in: work, pickUps: 1)])
        let recovered = await core.recover()
        let fallback = await core.allAgents().first?.id
        let id = try #require(recovered.first ?? fallback)

        let entries = try await core.store.transcript(for: id, limit: 200).entries
        let changes = entries.compactMap { entry -> AgentState? in
            if case .stateChanged(let state, _) = entry.kind { return state }
            return nil
        }
        #expect(changes == [.stopped], "one line, and only one")

        // And the note explaining it comes first, so the transcript reads in the order
        // it happened.
        let firstNote = entries.firstIndex { if case .runtimeNote = $0.kind { return true } else { return false } }
        let firstChange = entries.firstIndex { if case .stateChanged = $0.kind { return true } else { return false } }
        #expect(firstNote != nil && firstChange != nil && firstNote! < firstChange!)
    }

    // MARK: Reacting to agents

    @Test func anAgentFinishingFiresAWorkflowThatWatchesForIt() async throws {
        let (locations, root) = try temporary()
        let work = try project(root)
        try write("""
            ---
            on:
              - agent-finished
            ---

            Look at what just happened.
            """, as: "on-finish", in: work)

        let core = try await core(locations)
        await core.rescanWorkflows(in: work)

        // An agent nobody automated, finishing: the start of a chain, at depth zero.
        let started = try await core.start(DaemonAPI.StartRequest(
            runtimeID: "claude", cwd: work, prompt: "Do a thing"))
        await eventually("the first agent finished") { await core.agent(started)?.state == .finished }
        // Wait for the thing actually being asserted, not for a second agent to exist.
        // The agent is added to the list before `startedByWorkflow` is on it, so a wait
        // on the count could come back a moment before the field the test reads.
        await eventually("the workflow started an agent") {
            await core.allAgents().contains { $0.startedByWorkflow == "on-finish" }
        }

        let made = await core.allAgents().first { $0.startedByWorkflow == "on-finish" }
        #expect(made != nil)
    }

    /// US4. A workflow's row has to be able to say whether the run was any good, not
    /// only that it happened — four quiet nights and one that stopped half way look
    /// identical otherwise.
    ///
    /// Nothing is copied onto the workflow: `WorkflowOutcome.ran` carries the agent's
    /// id, and the row reads the report off that agent. So what this asserts is that
    /// the two are still joined, and that the project says somebody is wanted.
    @Test func aRunsOutcomeIsReadableFromTheWorkflowsRow() async throws {
        let (locations, root) = try temporary()
        let work = try project(root)
        try write(everyHalfHour("Check the build."), as: "nightly", in: work)

        let core = try await core(locations)
        await core.rescanWorkflows(in: work)
        let summary = try await core.runWorkflow(
            DaemonAPI.WorkflowRequest(folder: work, workflowID: "nightly"))

        guard case .ran(let agentID, _) = summary.lastOutcome else {
            Issue.record("expected a run, got \(String(describing: summary.lastOutcome))")
            return
        }
        // The agent the run started, saying it could not do the work.
        let token = await eventuallySome("the run's agent has a token") {
            await core.appTokens.first { $0.value == agentID }?.key
        } ?? ""
        _ = try await core.reportOutcome(.init(token: token, outcome: "stuck",
                                               message: "The build machine is unreachable."))

        // What the row reads: the agent the run names, and what it said.
        let agent = try #require(await core.agent(agentID))
        #expect(agent.report?.outcome == .stuck)
        #expect(agent.report?.message == "The build machine is unreachable.")
        #expect(agent.report?.outcome.needsAPerson == true)
        // And the project is marked, for the same reason any other agent would mark it.
        // Waited on rather than read at once: the counts follow the agent's group, and
        // an agent whose turn is still in flight is working rather than wanting anyone.
        await eventually("the project says somebody is wanted") {
            await core.allProjects()
                .first { Project.standardize($0.folder) == Project.standardize(work) }?
                .needsInput == true
        }
    }

    @Test func aTriggeringWorkflowSendsThePromptBackIntoTheSameAgent() async throws {
        let (locations, root) = try temporary()
        let work = try project(root)
        try write("""
            ---
            on:
              - agent-finished
            agent: triggering
            ---

            One more thing.
            """, as: "follow-up", in: work)

        let core = try await core(locations)
        await core.rescanWorkflows(in: work)
        let started = try await core.start(DaemonAPI.StartRequest(
            runtimeID: "claude", cwd: work, prompt: "Do a thing"))
        await eventually("the prompt came back to the same agent") {
            await core.agent(started)?.startedByWorkflow == "follow-up"
        }

        // No second agent: the prompt went back where it came from.
        #expect(await core.allAgents().count == 1)
    }

}

/// Which projects are being watched, and when that starts and stops.
///
/// Doing this only at daemon startup was wrong in exactly the case that matters most:
/// a project added during this session is where somebody trying the feature writes
/// their first workflow, and it would have stayed invisible until a restart.
@Suite("Taking a project's workflows on", .timeLimit(.minutes(1)))
struct WorkflowAdoptionTests {
    private func temporary() throws -> (StoreLocations, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsWorkflowAdopt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (StoreLocations(root: root), root.resolvingSymlinksInPath())
    }

    private func project(_ root: URL, _ name: String = "api") throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return Project.standardize(url)
    }

    private func write(_ workflowID: String, in project: URL) throws {
        let folder = WorkflowFile.folder(in: project)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("""
            ---
            on:
              - schedule:
                  at: [":00"]
            ---

            Go.
            """.utf8).write(to: WorkflowFile.url(for: workflowID, in: project))
    }

    private func core(_ locations: StoreLocations) async throws -> DaemonCore {
        let store = try AgentStore(locations: locations)
        let core = DaemonCore(store: store, locations: locations,
                              discovery: .findsEverything,
                              launcher: FakeLauncher(script: FakeACPAgent.Script()))
        await core.loadFromDisk()
        return core
    }

    @Test func aProjectAddedAfterTheDaemonStartedIsWatched() async throws {
        let (locations, root) = try temporary()
        let core = try await core(locations)
        // Started with no projects at all, which is the state a first run is in.
        await core.startWorkflows()

        let work = try project(root)
        try write("say-hello", in: work)
        _ = try await core.addProject(work)

        #expect(await core.allWorkflows(in: work).count == 1)
        #expect(await core.isWatchingWorkflows(in: work))
    }

    @Test func askingForAProjectsWorkflowsIsWhatStartsWatchingIt() async throws {
        // A folder becomes a project by something running in it, and nobody has to add
        // it by hand. Asking for its workflows — which is what a window opening a
        // project page does — is what picks them up and starts watching for more.
        let (locations, root) = try temporary()
        let core = try await core(locations)
        await core.startWorkflows()

        let work = try project(root)
        try write("say-hello", in: work)
        _ = try await core.start(DaemonAPI.StartRequest(
            runtimeID: "claude", cwd: work, prompt: "Do a thing"))

        #expect(await core.isWatchingWorkflows(in: work) == false)
        #expect(await core.allWorkflows(in: work).count == 1)
        #expect(await core.isWatchingWorkflows(in: work))
    }

    @Test func adoptingAProjectDoesNotSlowDownStartingAnAgent() async throws {
        // The guard that matters. Adoption reads a directory, reads a file and opens an
        // FSEvents stream; the first version did it on every agent state change, and
        // starting an agent got slow enough to miss deadlines. Nothing on the path of
        // an agent moving may touch the file system.
        let (locations, root) = try temporary()
        let work = try project(root)
        try write("say-hello", in: work)
        let core = try await core(locations)

        _ = try await core.start(DaemonAPI.StartRequest(
            runtimeID: "claude", cwd: work, prompt: "Do a thing"))

        #expect(await core.watchedWorkflowFolders().isEmpty)
    }

    @Test func archivingAProjectStopsItsWorkflows() async throws {
        let (locations, root) = try temporary()
        let work = try project(root)
        try write("say-hello", in: work)
        let core = try await core(locations)
        _ = try await core.addProject(work)
        #expect(await core.allWorkflows(in: work).count == 1)

        _ = try await core.archiveProject(work)

        #expect(await core.isWatchingWorkflows(in: work) == false)

        // And the point of it: nothing fires for a project somebody has put away.
        var when = DateComponents()
        when.year = 2026; when.month = 9; when.day = 21; when.hour = 8; when.minute = 59
        let justBefore = Calendar.current.date(from: when)!
        await core.tickWorkflows(now: justBefore)
        await core.tickWorkflows(now: justBefore.addingTimeInterval(120))
        #expect(await core.allAgents().isEmpty)
    }

    @Test func unarchivingReadsThemStraightBack() async throws {
        // Putting a project away is not editing it: the files were never touched.
        let (locations, root) = try temporary()
        let work = try project(root)
        try write("say-hello", in: work)
        let core = try await core(locations)
        _ = try await core.addProject(work)
        _ = try await core.archiveProject(work)
        _ = try await core.unarchiveProject(work)

        #expect(await core.isWatchingWorkflows(in: work))
        #expect(await core.allWorkflows(in: work).count == 1)
    }

    @Test func adoptingTwiceDoesNotMakeASecondWatcher() async throws {
        let (locations, root) = try temporary()
        let work = try project(root)
        try write("say-hello", in: work)
        let core = try await core(locations)

        _ = try await core.addProject(work)
        _ = try await core.addProject(work)
        _ = await core.allWorkflows(in: work)

        #expect(await core.watchedWorkflowFolders() == [work])
        #expect(await core.allWorkflows(in: work).count == 1)
    }

    @Test func aFolderThatIsNotThereIsNotWatched() async throws {
        let (locations, root) = try temporary()
        let core = try await core(locations)
        let missing = Project.standardize(root.appendingPathComponent("gone", isDirectory: true))
        await core.adoptWorkflows(in: missing)
        #expect(await core.isWatchingWorkflows(in: missing) == false)
    }
}

extension DaemonCore {
    /// What a test asks instead of reaching into the watcher dictionary.
    func isWatchingWorkflows(in folder: URL) -> Bool {
        workflowWatchers[Project.standardize(folder)] != nil
    }

    func watchedWorkflowFolders() -> [URL] {
        workflowWatchers.keys.sorted { $0.path < $1.path }
    }
}
