import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// A workflow's run putting its own session away when it is done (#433), as the
/// workflow's `when-done:` allows — driven through the real daemon.
///
/// The promise: only a run of a workflow that says so is archived, only when its turn
/// ended done or with nothing to do, and a session a person started stays park-only.
@Suite("A workflow's run archived when done", .timeLimit(.minutes(1)))
struct WorkflowWhenDoneTests {
    private static func file(whenDone: String?, agent: String = "new") -> String {
        """
        ---
        on:
          - schedule:
              at: [":00"]
        agent: \(agent)
        \(whenDone.map { "when-done: \($0)" } ?? "")
        ---

        Check the build.
        """
    }

    private struct Setup {
        var core: DaemonCore
        var launcher: FakeLauncher
        var project: URL
    }

    private func setUp(whenDone: String?) async throws -> Setup {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("WorkflowWhenDone-\(UUID().uuidString)", isDirectory: true)
        let project = Project.standardize(root.appendingPathComponent("work", isDirectory: true))
        try FileManager.default.createDirectory(at: WorkflowFile.folder(in: project), withIntermediateDirectories: true)
        try Data(Self.file(whenDone: whenDone).utf8).write(to: WorkflowFile.url(for: "check", in: project))
        var script = FakeACPAgent.Script()
        script.turnDelay = .milliseconds(400)
        let launcher = FakeLauncher(script: script)
        let locations = StoreLocations(root: root)
        let core = DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                              discovery: .findsEverything, launcher: launcher)
        await core.loadFromDisk()
        await core.rescanWorkflows(in: project)
        return Setup(core: core, launcher: launcher, project: project)
    }

    /// Start the run, and the id of the agent doing it.
    private func run(_ setup: Setup) async throws -> UUID {
        _ = try await setup.core.runWorkflow(.init(folder: setup.project, workflowID: "check"))
        return try #require(await eventuallySome("the run started its agent") {
            await setup.core.allAgents().first?.id
        })
    }

    private func token(_ launcher: FakeLauncher) async -> String {
        await eventuallySome("the runtime was handed its token") {
            let minted = MintedMCPToken.from(sessionParams: await launcher.lastAgent?.newSessionParams)
            return minted.isEmpty ? nil : minted
        } ?? ""
    }

    @discardableResult
    private func finish(_ setup: Setup, _ outcome: String, afterwards: String? = nil) async throws -> String {
        try await setup.core.finishTurn(.init(token: await token(setup.launcher), outcome: outcome,
                                              message: "Checked the build.", prompts: [],
                                              afterwards: afterwards))
    }

    /// Wait until the turn is over, nothing is queued, and the runtime has been let go.
    private func settle(_ core: DaemonCore, _ id: UUID) async throws {
        let deadline = ContinuousClock.now.advanced(by: Eventually.timeout)
        while ContinuousClock.now < deadline {
            if let agent = await core.agent(id), !agent.state.hasTurnInFlight,
               agent.queuedPrompts.isEmpty, await core.live[id] == nil {
                // An archive lands a moment after the runtime is let go.
                try await Task.sleep(for: .milliseconds(100))
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// The agent once it is archived, waited for: the archive lands after the runtime goes.
    private func archived(_ core: DaemonCore, _ id: UUID) async -> Agent? {
        await eventuallySome("the run was archived") {
            guard let agent = await core.agent(id), agent.state == .archived else { return nil }
            return agent
        }
    }

    // MARK: The file

    @Test func theKeyIsRead() {
        let folder = URL(filePath: "/tmp/work")
        for (text, expected) in [(nil, nil), ("park", WorkflowWhenDone.park),
                                 ("archive-allowed", .archiveAllowed), ("archive", .archive)] as [(String?, WorkflowWhenDone?)] {
            let workflow = WorkflowFile.parse(Self.file(whenDone: text), workflowID: "check", in: folder)
            #expect(workflow.problem == nil)
            #expect(workflow.whenDone == expected)
            #expect(workflow.unknownFields.isEmpty)
        }
    }

    @Test func aValueThatIsNoneOfTheThreeIsAFileToFix() {
        let workflow = WorkflowFile.parse(Self.file(whenDone: "delete"), workflowID: "check",
                                          in: URL(filePath: "/tmp/work"))
        #expect(workflow.problem == .unreadable(WorkflowWhenDone.unknown))
    }

    @Test func theRunIsToldWhatItMayDo() {
        let folder = URL(filePath: "/tmp/work")
        func note(_ text: String?, agent: String = "new") -> String {
            DaemonCore.whenDoneNote(WorkflowFile.parse(Self.file(whenDone: text, agent: agent),
                                                       workflowID: "check", in: folder))
        }
        #expect(note(nil).isEmpty)
        #expect(note("park").isEmpty)
        #expect(note("archive-allowed").contains("archive_agent with no id"))
        #expect(note("archive").contains("archives its run"))
        #expect(note("archive", agent: "triggering").isEmpty, "a borrowed agent is somebody else's")
    }

    @Test func thePageWritesTheLineAndParkTakesItOut() async throws {
        let setup = try await setUp(whenDone: nil)
        let url = WorkflowFile.url(for: "check", in: setup.project)
        let settings = WorkflowSettings()
        var summary = try await setup.core.setWorkflowSettings(
            .init(folder: setup.project, workflowID: "check", settings: settings, whenDone: "archive-allowed"))
        #expect(summary.workflow.whenDone == .archiveAllowed)
        #expect(try String(contentsOf: url, encoding: .utf8).contains("when-done: archive-allowed"))

        summary = try await setup.core.setWorkflowSettings(
            .init(folder: setup.project, workflowID: "check", settings: settings, whenDone: "park"))
        #expect(summary.workflow.whenDone == nil)
        #expect(try !String(contentsOf: url, encoding: .utf8).contains("when-done"))

        await #expect(throws: JSONRPCError.self) {
            _ = try await setup.core.setWorkflowSettings(
                .init(folder: setup.project, workflowID: "check", settings: settings, whenDone: "delete"))
        }
    }

    // MARK: archive

    @Test func archiveArchivesARunThatFinishesDone() async throws {
        let setup = try await setUp(whenDone: "archive")
        let id = try await run(setup)
        let reply = try await finish(setup, "done")
        #expect(reply.contains("will be archived"))
        let agent = try #require(await archived(setup.core, id))
        #expect(agent.archivedReason == .byAgent)
    }

    @Test func archiveWinsOverAnAskToPark() async throws {
        let setup = try await setUp(whenDone: "archive")
        let id = try await run(setup)
        try await finish(setup, "nothing_to_do", afterwards: "park")
        #expect(await archived(setup.core, id) != nil)
    }

    @Test(arguments: ["stuck", "partly_done", "needs_answer"])
    func archiveKeepsARunThatNeedsSomebody(_ outcome: String) async throws {
        let setup = try await setUp(whenDone: "archive")
        let id = try await run(setup)
        try await finish(setup, outcome)
        try await settle(setup.core, id)
        let agent = try #require(await setup.core.agent(id))
        #expect(agent.state == .finished)
    }

    // MARK: archive-allowed

    @Test func archiveAllowedArchivesOnlyOnTheAsk() async throws {
        let setup = try await setUp(whenDone: "archive-allowed")
        let id = try await run(setup)
        let reply = try await finish(setup, "done", afterwards: "archive")
        #expect(reply.contains("will be archived"))
        #expect(await archived(setup.core, id) != nil)
    }

    @Test func archiveAllowedKeepsARunThatDoesNotAsk() async throws {
        let setup = try await setUp(whenDone: "archive-allowed")
        let id = try await run(setup)
        try await finish(setup, "done")
        try await settle(setup.core, id)
        #expect(await setup.core.agent(id)?.state == .finished)
    }

    @Test func archiveAllowedStillRefusesAnArchiveWithPartlyDone() async throws {
        let setup = try await setUp(whenDone: "archive-allowed")
        let id = try await run(setup)
        let error = await #expect(throws: JSONRPCError.self) {
            try await finish(setup, "partly_done", afterwards: "archive")
        }
        #expect(error?.message == AfterTurn.archive.refusal)
        try await settle(setup.core, id)
    }

    // MARK: park

    @Test func parkRefusesAnAskToArchive() async throws {
        let setup = try await setUp(whenDone: nil)
        let id = try await run(setup)
        let error = await #expect(throws: JSONRPCError.self) {
            try await finish(setup, "done", afterwards: "archive")
        }
        #expect(error?.message == AfterTurn.archiveNotAllowed)
        #expect(await setup.core.agent(id)?.report == nil, "refused whole")
        try await finish(setup, "done")
        try await settle(setup.core, id)
        #expect(await setup.core.agent(id)?.state == .finished)
    }

    /// A person's session is park-only, whatever a workflow in its project says.
    @Test func aPersonsSessionCannotArchiveItself() async throws {
        let setup = try await setUp(whenDone: "archive")
        let id = try await setup.core.start(.init(runtimeID: "cursor", cwd: setup.project, prompt: "go"))
        let error = await #expect(throws: JSONRPCError.self) {
            try await finish(setup, "done", afterwards: "archive")
        }
        #expect(error?.message == AfterTurn.archiveNotAllowed)
        try await finish(setup, "done")
        try await settle(setup.core, id)
        #expect(await setup.core.agent(id)?.state == .finished)
    }
}
