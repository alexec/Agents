import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// Every way a fire can produce no agent, and the mark it leaves when it does.
///
/// This suite is entirely about things not happening, which is why every case asserts
/// on the recorded outcome and never on the absence of an agent. An assertion that only
/// counts agents passes just as happily when the trigger never matched, and that is the
/// bug this whole user story exists to make impossible.
@Suite("Refusing to fire a workflow", .timeLimit(.minutes(1)))
struct WorkflowRefusalTests {
    private func temporary() throws -> (StoreLocations, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsWorkflowRefusal-\(UUID().uuidString)", isDirectory: true)
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

    private func core(_ locations: StoreLocations,
                      script: FakeACPAgent.Script = .init()) async throws -> DaemonCore {
        let store = try AgentStore(locations: locations)
        let core = DaemonCore(store: store, locations: locations,
                              discovery: .findsEverything, launcher: FakeLauncher(script: script))
        await core.loadFromDisk()
        return core
    }

    private let onSchedule = """
        ---
        on:
          - schedule:
              at: [":00", ":30"]
        ---

        Go.
        """

    private func outcome(_ core: DaemonCore, _ folder: URL, _ id: String) async -> WorkflowOutcome? {
        await core.allWorkflows(in: folder).first { $0.workflowID == id }?.lastOutcome
    }

    private func refusal(_ core: DaemonCore, _ folder: URL, _ id: String) async -> WorkflowRefusal? {
        if case .refused(let refusal, _, _) = await outcome(core, folder, id) { return refusal }
        return nil
    }

    // MARK: A run still going

    @Test func aSecondFireIsSkippedRatherThanQueued() async throws {
        // Run now twice, with a turn slow enough that the first is still going.
        let (locations, root) = try temporary()
        let work = try project(root)
        try write(onSchedule, as: "slow", in: work)

        var script = FakeACPAgent.Script()
        script.turnDelay = .milliseconds(800)
        let core = try await core(locations, script: script)
        await core.rescanWorkflows(in: work)

        let request = DaemonAPI.WorkflowRequest(folder: work, workflowID: "slow")
        try await core.runWorkflow(request)
        try await core.runWorkflow(request)

        #expect(await refusal(core, work, "slow") == .runInFlight)
        // And the thing the refusal is protecting: one agent, not two.
        #expect(await core.allAgents().count == 1)
    }

    // MARK: Paused

    @Test func aPausedWorkflowRefusesEvenRunNow() async throws {
        let (locations, root) = try temporary()
        let work = try project(root)
        try write(onSchedule, as: "held", in: work)

        let core = try await core(locations)
        await core.rescanWorkflows(in: work)
        _ = try await core.pauseWorkflow(
            DaemonAPI.WorkflowPauseRequest(folder: work, workflowID: "held", paused: true))
        try await core.runWorkflow(DaemonAPI.WorkflowRequest(folder: work, workflowID: "held"))

        #expect(await refusal(core, work, "held") == .paused)
        #expect(await core.allAgents().isEmpty)
    }

    @Test func pausingAProjectHoldsAllOfIts() async throws {
        let (locations, root) = try temporary()
        let work = try project(root)
        try write(onSchedule, as: "one", in: work)
        try write(onSchedule, as: "two", in: work)

        let core = try await core(locations)
        await core.rescanWorkflows(in: work)
        _ = await core.pauseProjectWorkflows(
            DaemonAPI.WorkflowPauseProjectRequest(folder: work, paused: true))
        try await core.runWorkflow(DaemonAPI.WorkflowRequest(folder: work, workflowID: "one"))
        try await core.runWorkflow(DaemonAPI.WorkflowRequest(folder: work, workflowID: "two"))

        #expect(await refusal(core, work, "one") == .paused)
        #expect(await refusal(core, work, "two") == .paused)
    }

    @Test func pausingNeverTouchesTheFile() async throws {
        // FR-024 is a contract, not an implementation note: this is what stops a pause
        // from becoming a commit.
        let (locations, root) = try temporary()
        let work = try project(root)
        let url = try write(onSchedule, as: "held", in: work)
        let before = try Data(contentsOf: url)

        let core = try await core(locations)
        await core.rescanWorkflows(in: work)
        _ = try await core.pauseWorkflow(
            DaemonAPI.WorkflowPauseRequest(folder: work, workflowID: "held", paused: true))

        #expect(try Data(contentsOf: url) == before)
    }

    // MARK: Files that cannot run

    @Test func anUnreadableFileRefusesAndSaysWhy() async throws {
        let (locations, root) = try temporary()
        let work = try project(root)
        try write("---\nagent: new\n---\n\nGo.", as: "broken", in: work)

        let core = try await core(locations)
        await core.rescanWorkflows(in: work)
        try await core.runWorkflow(DaemonAPI.WorkflowRequest(folder: work, workflowID: "broken"))

        #expect(await refusal(core, work, "broken")
                == .unreadable("The metadata does not say what makes this run"))
    }

    @Test func aTriggerFromTheFutureRefusesRatherThanErroring() async throws {
        let (locations, root) = try temporary()
        let work = try project(root)
        try write("---\non: deploys-finished\n---\n\nGo.", as: "future", in: work)

        let core = try await core(locations)
        await core.rescanWorkflows(in: work)
        try await core.runWorkflow(DaemonAPI.WorkflowRequest(folder: work, workflowID: "future"))

        #expect(await refusal(core, work, "future")
                == .triggerNotSupported(name: "deploys-finished"))
        // Still listed, and Run now was still offered: that is what makes a file from a
        // later version something you can try rather than only read.
        #expect(await core.allWorkflows(in: work).count == 1)
    }

    // MARK: Triggering mode with nothing to resume

    @Test func triggeringModeRunByHandHasNoAgentToResume() async throws {
        let (locations, root) = try temporary()
        let work = try project(root)
        try write("---\non: agent-finished\nagent: triggering\n---\n\nGo.", as: "follow", in: work)

        let core = try await core(locations)
        await core.rescanWorkflows(in: work)
        try await core.runWorkflow(DaemonAPI.WorkflowRequest(folder: work, workflowID: "follow"))

        #expect(await refusal(core, work, "follow") == .noTriggeringAgent)
        #expect(await core.allAgents().isEmpty)
    }

    @Test func triggeringModeWithAnArchivedAgentIsRefusedRatherThanSubstituted() async throws {
        // Substituting would send words meant for one conversation into another.
        let (locations, root) = try temporary()
        let work = try project(root)
        try write("---\non: agent-stopped\nagent: triggering\n---\n\nGo.", as: "follow", in: work)

        let core = try await core(locations)
        await core.rescanWorkflows(in: work)

        let gone = UUID()
        #expect(await core.fireForTesting(workflowID: "follow", in: work,
                                          triggeringAgentID: gone) == .agentUnavailable)
        #expect(await core.allAgents().isEmpty)
    }

    // MARK: The folder

    @Test func aProjectFolderThatHasGoneRefuses() async throws {
        let (locations, root) = try temporary()
        let work = try project(root)
        try write(onSchedule, as: "orphan", in: work)

        let core = try await core(locations)
        await core.rescanWorkflows(in: work)
        try FileManager.default.removeItem(at: work)
        try await core.runWorkflow(DaemonAPI.WorkflowRequest(folder: work, workflowID: "orphan"))

        #expect(await refusal(core, work, "orphan") == .folderGone)
    }

    // MARK: Loops

    @Test func aWorkflowThatFiresOnItsOwnOutputComesToRestOnItsOwn() async throws {
        // The trap every first workflow falls into: an agent started by a workflow
        // finishing is exactly what `agent-finished` watches for. Nobody intervenes
        // here — the depth limit is what stops it, and it must say so.
        let (locations, root) = try temporary()
        let work = try project(root)
        try write("---\non: agent-finished\n---\n\nGo again.", as: "loop", in: work)

        let core = try await core(locations)
        await core.rescanWorkflows(in: work)
        _ = try await core.start(DaemonAPI.StartRequest(
            runtimeID: "claude", cwd: work, prompt: "Start it off"))

        await eventually("the loop was refused") { await refusal(core, work, "loop") != nil }

        guard case .chainTooDeep = await refusal(core, work, "loop") else {
            Issue.record("expected chainTooDeep, got \(String(describing: await refusal(core, work, "loop")))")
            return
        }
        // Four runs, one per allowed depth, plus the agent that started it all. The
        // count is the assertion that matters: a refusal at the end proves nothing if
        // a hundred agents ran to reach it.
        let made = await core.allAgents().filter { $0.startedByWorkflow == "loop" }
        #expect(made.count == Workflow.chainDepthLimit + 1)
    }

    // MARK: Missed while nothing was listening

    @Test func aFireMissedWhileTheAppWasClosedIsSaidRatherThanReplayed() async throws {
        // Opening the app after a weekend must not start a queue of agents nobody asked
        // for, and must not look the same as a workflow that is simply not triggering.
        let (locations, root) = try temporary()
        let work = try project(root)
        try write(onSchedule, as: "nightly", in: work)

        let core = try await core(locations)
        await core.rescanWorkflows(in: work)

        var when = DateComponents()
        when.year = 2026; when.month = 9; when.day = 18; when.hour = 9; when.minute = 0
        let friday = Calendar.current.date(from: when)!
        await core.tickWorkflows(now: friday)
        // Three days later: the gap is the app having been closed.
        await core.tickWorkflows(now: friday.addingTimeInterval(3 * 24 * 3600))

        #expect(await refusal(core, work, "nightly") == .missedWhileClosed)
        #expect(await core.allAgents().isEmpty)
    }

    @Test func repeatedMissesCollapseIntoOneLine() async throws {
        let (locations, root) = try temporary()
        let work = try project(root)
        try write(onSchedule, as: "nightly", in: work)

        let core = try await core(locations)
        await core.rescanWorkflows(in: work)

        var when = DateComponents()
        when.year = 2026; when.month = 9; when.day = 18; when.hour = 9; when.minute = 0
        var moment = Calendar.current.date(from: when)!
        await core.tickWorkflows(now: moment)
        for _ in 0..<3 {
            moment = moment.addingTimeInterval(3 * 24 * 3600)
            await core.tickWorkflows(now: moment)
        }

        guard case .refused(_, _, let repeats) = await outcome(core, work, "nightly") else {
            Issue.record("expected a refusal")
            return
        }
        #expect(repeats == 3)
    }

    // MARK: The criterion this whole story exists for

    @Test func noFireIsEverSilent() async throws {
        // SC-003. Every one of these either produces an agent reachable from the row or
        // a stated reason on it. Nothing leaves no trace.
        let (locations, root) = try temporary()
        let work = try project(root)
        try write(onSchedule, as: "fine", in: work)
        try write("---\nagent: new\n---\n\nGo.", as: "broken", in: work)
        try write("---\non: deploys-finished\n---\n\nGo.", as: "future", in: work)
        try write("---\non: agent-finished\nagent: triggering\n---\n\nGo.", as: "follow", in: work)

        let core = try await core(locations)
        await core.rescanWorkflows(in: work)
        _ = try await core.pauseWorkflow(
            DaemonAPI.WorkflowPauseRequest(folder: work, workflowID: "fine", paused: true))

        for id in ["fine", "broken", "future", "follow"] {
            try await core.runWorkflow(DaemonAPI.WorkflowRequest(folder: work, workflowID: id))
        }

        let summaries = await core.allWorkflows(in: work)
        #expect(summaries.count == 4)
        for summary in summaries {
            #expect(summary.lastOutcome != nil, "\(summary.workflowID) left no trace")
        }
    }

}

extension DaemonCore {
    /// Fire a workflow with a triggering agent named directly, for the cases a test
    /// cannot reach through the front door — an agent that is already gone.
    func fireForTesting(workflowID: String, in folder: URL,
                        triggeringAgentID: UUID?) async -> WorkflowRefusal? {
        guard let workflow = workflow(workflowID, in: folder) else { return nil }
        return await fire(workflow, on: .agentStopped, triggeringAgentID: triggeringAgentID)
    }
}
