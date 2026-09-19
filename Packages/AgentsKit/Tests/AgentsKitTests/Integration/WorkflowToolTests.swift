import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// What an agent may do to its project's workflows, and what it is told when it may not.
///
/// The line this suite holds is between reading, which asks nobody, and writing, which
/// asks the person and does nothing if they decline. Every refusal is checked for its
/// words as well as its code: the agent reads these, and a refusal it cannot act on is
/// a refusal that gets retried.
@Suite("The workflow tool", .timeLimit(.minutes(1)))
struct WorkflowToolTests {
    private func temporary() throws -> (StoreLocations, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsWorkflowTool-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (StoreLocations(root: root), root.resolvingSymlinksInPath())
    }

    private func project(_ root: URL) throws -> URL {
        let url = root.appendingPathComponent("api", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return Project.standardize(url)
    }

    private let sample = """
        ---
        on:
          - schedule:
              at: [":00"]
              between: "09:00-09:00"
              days: [mon, tue, wed, thu, fri]
        agent: new
        ---

        Check the dependencies for security advisories.
        """

    /// A core with one agent in a project, and the token that speaks for it.
    private func core(_ locations: StoreLocations, in project: URL)
        async throws -> (DaemonCore, String, UUID) {
        let store = try AgentStore(locations: locations)
        let core = DaemonCore(store: store, locations: locations,
                              discovery: .findsEverything,
                              launcher: FakeLauncher(script: FakeACPAgent.Script()))
        await core.loadFromDisk()
        let agentID = try await core.start(DaemonAPI.StartRequest(
            runtimeID: "claude", cwd: project, prompt: "Do a thing"))
        let token = UUID().uuidString
        await core.bindAppToken(token, to: agentID)
        // A window is open, which is what makes there be anybody to ask.
        await core.setConnectionCount(1)
        return (core, token, agentID)
    }

    private func call(_ core: DaemonCore, _ token: String,
                      _ action: DaemonAPI.ManageWorkflowsRequest.Action,
                      id: String? = nil, content: String? = nil) async throws -> String {
        try await core.manageWorkflows(DaemonAPI.ManageWorkflowsRequest(
            token: token, action: action, workflowID: id, content: content))
    }

    /// Answer the confirmation as soon as one is raised, the way a person would.
    private func answering(_ core: DaemonCore, _ allow: Bool) -> Task<Void, Never> {
        Task {
            for _ in 0..<250 {
                if let pending = await core.pendingWorkflowConfirmations().first {
                    await core.answerWorkflowConfirmation(
                        DaemonAPI.WorkflowConfirmRequest(confirmationID: pending.id, allow: allow))
                    return
                }
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
    }

    // MARK: Reading asks nobody

    @Test func listingRaisesNoConfirmation() async throws {
        let (locations, root) = try temporary()
        let work = try project(root)
        let (core, token, _) = try await core(locations, in: work)

        let answer = try await call(core, token, .list)

        #expect(answer.contains("no workflows yet"))
        #expect(await core.pendingWorkflowConfirmations().isEmpty)
    }

    @Test func readingRaisesNoConfirmation() async throws {
        let (locations, root) = try temporary()
        let work = try project(root)
        try FileManager.default.createDirectory(at: WorkflowFile.folder(in: work),
                                                withIntermediateDirectories: true)
        try Data(sample.utf8).write(to: WorkflowFile.url(for: "advisories", in: work))
        let (core, token, _) = try await core(locations, in: work)

        let answer = try await call(core, token, .read, id: "advisories")

        #expect(answer == sample)
        #expect(await core.pendingWorkflowConfirmations().isEmpty)
    }

    @Test func listingSaysWhatEachOneIsAndWhatHappenedToIt() async throws {
        let (locations, root) = try temporary()
        let work = try project(root)
        try FileManager.default.createDirectory(at: WorkflowFile.folder(in: work),
                                                withIntermediateDirectories: true)
        try Data(sample.utf8).write(to: WorkflowFile.url(for: "advisories", in: work))
        let (core, token, _) = try await core(locations, in: work)
        _ = try await core.pauseWorkflow(DaemonAPI.WorkflowPauseRequest(
            folder: work, workflowID: "advisories", paused: true))

        let answer = try await call(core, token, .list)

        #expect(answer.contains("advisories"))
        #expect(answer.contains("Every weekday at 9am, in a new agent"))
        #expect(answer.contains("[paused]"))
    }

    // MARK: Writing asks

    @Test func aWriteApprovedIsLiveWithNoFurtherStep() async throws {
        let (locations, root) = try temporary()
        let work = try project(root)
        let (core, token, _) = try await core(locations, in: work)

        let answering = answering(core, true)
        let answer = try await call(core, token, .write, id: "advisories", content: sample)
        answering.cancel()

        #expect(answer.contains("Created advisories"))
        #expect(try Data(contentsOf: WorkflowFile.url(for: "advisories", in: work))
                == Data(sample.utf8))
        // Live: no enable step follows. The confirmation was the review.
        #expect(await core.allWorkflows(in: work).count == 1)
    }

    @Test func aWriteDeclinedWritesNothingAndSaysSo() async throws {
        let (locations, root) = try temporary()
        let work = try project(root)
        let (core, token, _) = try await core(locations, in: work)

        let answering = answering(core, false)
        await #expect(throws: JSONRPCError.self) {
            try await call(core, token, .write, id: "advisories", content: sample)
        }
        answering.cancel()

        #expect(FileManager.default.fileExists(
            atPath: WorkflowFile.url(for: "advisories", in: work).path) == false)
        #expect(await core.allWorkflows(in: work).isEmpty)
    }

    @Test func theConfirmationSaysWhatWillRunRatherThanShowingAFile() async throws {
        // FR-036: judgeable without opening anything. The same string the project page
        // row uses, so what was approved and what is seen later cannot drift.
        let (locations, root) = try temporary()
        let work = try project(root)
        let (core, token, agentID) = try await core(locations, in: work)

        let writing = Task { try? await call(core, token, .write, id: "advisories", content: sample) }
        var seen: DaemonAPI.WorkflowConfirmation?
        for _ in 0..<250 {
            if let pending = await core.pendingWorkflowConfirmations().first { seen = pending; break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        guard let confirmation = seen else {
            Issue.record("no confirmation was raised")
            writing.cancel()
            return
        }

        #expect(confirmation.summary == "Every weekday at 9am, in a new agent")
        #expect(confirmation.prompt == "Check the dependencies for security advisories.")
        #expect(confirmation.agentID == agentID)
        #expect(confirmation.action == .create)

        await core.answerWorkflowConfirmation(
            DaemonAPI.WorkflowConfirmRequest(confirmationID: confirmation.id, allow: false))
        _ = await writing.value
    }

    @Test func changingAnExistingOneSaysSoRatherThanSayingCreate() async throws {
        let (locations, root) = try temporary()
        let work = try project(root)
        try FileManager.default.createDirectory(at: WorkflowFile.folder(in: work),
                                                withIntermediateDirectories: true)
        try Data(sample.utf8).write(to: WorkflowFile.url(for: "advisories", in: work))
        let (core, token, _) = try await core(locations, in: work)

        let writing = Task { try? await call(core, token, .write, id: "advisories", content: sample) }
        var action: DaemonAPI.WorkflowConfirmation.Action?
        for _ in 0..<250 {
            if let pending = await core.pendingWorkflowConfirmations().first {
                action = pending.action
                await core.answerWorkflowConfirmation(
                    DaemonAPI.WorkflowConfirmRequest(confirmationID: pending.id, allow: true))
                break
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        _ = await writing.value
        #expect(action == .update)
    }

    @Test func removingAsksTheSameWayCreatingDoes() async throws {
        let (locations, root) = try temporary()
        let work = try project(root)
        try FileManager.default.createDirectory(at: WorkflowFile.folder(in: work),
                                                withIntermediateDirectories: true)
        try Data(sample.utf8).write(to: WorkflowFile.url(for: "advisories", in: work))
        let (core, token, _) = try await core(locations, in: work)
        _ = await core.allWorkflows(in: work)

        let answering = answering(core, true)
        let answer = try await call(core, token, .remove, id: "advisories")
        answering.cancel()

        #expect(answer.contains("is gone"))
        #expect(FileManager.default.fileExists(
            atPath: WorkflowFile.url(for: "advisories", in: work).path) == false)
    }

    // MARK: Refusals

    @Test func unparseableFrontMatterIsRefusedBeforeAnybodyIsAsked() async throws {
        // Raising a confirmation for a file that could never fire spends the one moment
        // of the reader's attention this feature gets.
        let (locations, root) = try temporary()
        let work = try project(root)
        let (core, token, _) = try await core(locations, in: work)

        await #expect(throws: JSONRPCError.self) {
            try await call(core, token, .write, id: "broken", content: "---\nagent: new\n---\n\nGo.")
        }
        #expect(await core.pendingWorkflowConfirmations().isEmpty)
        #expect(FileManager.default.fileExists(
            atPath: WorkflowFile.url(for: "broken", in: work).path) == false)
    }

    @Test func aPathOutOfTheWorkflowFolderIsRefused() async throws {
        let (locations, root) = try temporary()
        let work = try project(root)
        let (core, token, _) = try await core(locations, in: work)

        for escape in ["../../etc/passwd", "sub/dir", ".hidden", ".."] {
            await #expect(throws: JSONRPCError.self) {
                try await call(core, token, .write, id: escape, content: sample)
            }
        }
        #expect(await core.pendingWorkflowConfirmations().isEmpty)
    }

    @Test func aWriteWithNoWindowOpenIsToldRatherThanSwallowed() async throws {
        let (locations, root) = try temporary()
        let work = try project(root)
        let (core, token, _) = try await core(locations, in: work)
        await core.setConnectionCount(0)

        await #expect(throws: JSONRPCError.self) {
            try await call(core, token, .write, id: "advisories", content: sample)
        }
        #expect(FileManager.default.fileExists(
            atPath: WorkflowFile.url(for: "advisories", in: work).path) == false)
    }

    @Test func aTokenThatNoLongerSpeaksForAnAgentIsRefused() async throws {
        let (locations, root) = try temporary()
        let work = try project(root)
        let (core, _, _) = try await core(locations, in: work)

        await #expect(throws: JSONRPCError.self) {
            try await call(core, "not-a-token", .list)
        }
    }

    @Test func readingSomethingThatIsNotThereSaysSo() async throws {
        let (locations, root) = try temporary()
        let work = try project(root)
        let (core, token, _) = try await core(locations, in: work)

        await #expect(throws: JSONRPCError.self) {
            try await call(core, token, .read, id: "nothing-here")
        }
    }

    // MARK: The guard on narrowing auto-allow

    @Test func theAppAnswersForItsOwnToolsButNotForThisOne() async throws {
        // Suggestions and show-file are questions with no information in them, asked
        // once a turn. A file that starts agents on a timer is the opposite.
        let (locations, root) = try temporary()
        let work = try project(root)
        let (core, _, agentID) = try await core(locations, in: work)

        func request(named name: String) -> PermissionRequest {
            PermissionRequest(
                agentID: agentID,
                toolCall: ToolCall(title: name, name: name),
                options: [PermissionOption(optionID: "allow", name: "Allow", kind: .allowAlways)])
        }

        #expect(await core.autoAllowed(request(named: "mcp__agents__\(AppTool.suggestPrompts)")) != nil)
        #expect(await core.autoAllowed(request(named: "mcp__agents__\(AppTool.showFile)")) != nil)
        #expect(await core.autoAllowed(request(named: "mcp__agents__\(AppTool.manageWorkflows)")) == nil)
        #expect(await core.autoAllowed(request(named: "Write")) == nil)
    }
}
