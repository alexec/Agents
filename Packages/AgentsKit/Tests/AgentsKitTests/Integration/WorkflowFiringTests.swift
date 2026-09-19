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
            if case .userMessage(let text, _) = entry.kind { return text.contains("Count to three.") }
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
