import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// What an agent may do to its project's workflows, and what it is told when it may not.
///
/// Nothing here asks first: an agent told to set up a workflow writes one, and the
/// person's say is the project page afterwards, where it can be archived.
/// What this suite holds is everything that still refuses — a path out of the folder,
/// front matter nobody could act on, a token that has stopped meaning an agent — and
/// the words each refusal uses, because the agent reads them and a refusal it cannot
/// act on is a refusal that gets retried.
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
        return (core, token, agentID)
    }

    /// One tool call. `keepingAlive` binds the token again first, which a test making
    /// several calls needs: the fake agent's turn ends when it likes, and a session
    /// ending drops its token. What these tests are about is the tool, not how long a
    /// token lives.
    private func call(_ core: DaemonCore, _ token: String,
                      _ action: DaemonAPI.ManageWorkflowsRequest.Action,
                      id: String? = nil, content: String? = nil,
                      keepingAlive agentID: UUID? = nil) async throws -> String {
        if let agentID { await core.bindAppToken(token, to: agentID) }
        return try await core.manageWorkflows(DaemonAPI.ManageWorkflowsRequest(
            token: token, action: action, workflowID: id, content: content))
    }

    // MARK: Reading

    @Test func listingAProjectWithNoneSaysWhereTheyWouldGo() async throws {
        let (locations, root) = try temporary()
        let work = try project(root)
        let (core, token, _) = try await core(locations, in: work)

        let answer = try await call(core, token, .list)

        #expect(answer.contains("no workflows yet"))
        #expect(answer.contains(WorkflowFile.folderName))
    }

    @Test func readingGivesBackTheFileItself() async throws {
        let (locations, root) = try temporary()
        let work = try project(root)
        try FileManager.default.createDirectory(at: WorkflowFile.folder(in: work),
                                                withIntermediateDirectories: true)
        try Data(sample.utf8).write(to: WorkflowFile.url(for: "advisories", in: work))
        let (core, token, _) = try await core(locations, in: work)

        let answer = try await call(core, token, .read, id: "advisories")

        #expect(answer == sample)
    }

    /// What Claude advertised the last time it was used here: a mode, an effort and a
    /// fast mode. Remembered by hand, because what these tests are about is what the
    /// tool says with it, not how it came to be remembered.
    private func rememberClaude(_ core: DaemonCore, in project: URL) async {
        let options = [
            ConfigOption(id: "mode", name: "Mode", category: "mode", type: "select",
                         options: [ConfigChoice(value: .string("default"), name: "Default"),
                                   ConfigChoice(value: .string("plan"), name: "Plan")]),
            ConfigOption(id: "effort", name: "Effort", category: "thought_level", type: "select",
                         options: [ConfigChoice(value: .string("low"), name: "Low"),
                                   ConfigChoice(value: .string("high"), name: "High")]),
            ConfigOption(id: "fast", name: "Fast mode", category: "model_config", kind: .boolean),
        ]
        await core.remember(OptionCache.Entry(options: options, commands: []),
                            for: OptionCache.key(runtimeID: "claude", cwd: project, mcpServers: []))
    }

    @Test func readingSaysWhatTheRuntimeOffersUnderTheFile() async throws {
        let (locations, root) = try temporary()
        let work = try project(root)
        try FileManager.default.createDirectory(at: WorkflowFile.folder(in: work),
                                                withIntermediateDirectories: true)
        try Data(sample.utf8).write(to: WorkflowFile.url(for: "advisories", in: work))
        let (core, token, _) = try await core(locations, in: work)
        await rememberClaude(core, in: work)

        let answer = try await call(core, token, .read, id: "advisories")

        // The file first and whole, so an agent writing it back has it as it was.
        #expect(answer.hasPrefix(sample + "\n\n(End of the file. Not part of it:)"))
        #expect(answer.contains("- `permission-mode:` default, plan"))
        #expect(answer.contains("- `effort:` low, high"))
        #expect(answer.contains("  - `fast:` true, false (Fast mode)"))
    }

    @Test func writingAnEffortAndFastModeIsTakenAndAnUnofferedOneIsSaidAtOnce() async throws {
        let (locations, root) = try temporary()
        let work = try project(root)
        let (core, token, agentID) = try await core(locations, in: work)
        await rememberClaude(core, in: work)
        // Its turn over and its runtime let go first, so the session ending cannot
        // drop the token between one write and the next.
        await eventually("its runtime was handed back") { await core.live[agentID] == nil }

        let settled = sample.replacingOccurrences(
            of: "agent: new\n", with: "agent: new\neffort: high\noptions:\n  fast: true\n")
        let answer = try await call(core, token, .write, id: "advisories", content: settled,
                                    keepingAlive: agentID)
        #expect(answer.contains("at high effort, with fast."))
        #expect(!answer.contains("will not run"))

        let unoffered = sample.replacingOccurrences(of: "agent: new\n", with: "agent: new\neffort: max\n")
        let warned = try await call(core, token, .write, id: "advisories", content: unoffered,
                                    keepingAlive: agentID)
        // Written anyway — the memory may be stale — but the agent is told now.
        #expect(warned.hasPrefix("Changed advisories."))
        #expect(warned.contains("\"max\" is not an effort Claude offers here — it offers low, high"))
    }

    @Test func listingSaysWhatEachOneIsAndWhatHappenedToIt() async throws {
        let (locations, root) = try temporary()
        let work = try project(root)
        try FileManager.default.createDirectory(at: WorkflowFile.folder(in: work),
                                                withIntermediateDirectories: true)
        try Data(sample.utf8).write(to: WorkflowFile.url(for: "advisories", in: work))
        let (core, token, _) = try await core(locations, in: work)

        let answer = try await call(core, token, .list)

        #expect(answer.contains("advisories"))
        #expect(answer.contains("Every weekday at 9am, in a new agent"))
    }

    @Test func listingSaysWhichOnesThePersonHasPutAway() async throws {
        // The agent has to be able to tell a workflow that is running from one somebody
        // archived, or it will keep offering to fix a thing that is not broken.
        let (locations, root) = try temporary()
        let work = try project(root)
        try FileManager.default.createDirectory(at: WorkflowFile.folder(in: work),
                                                withIntermediateDirectories: true)
        try Data(sample.utf8).write(to: WorkflowFile.url(for: "advisories", in: work))
        let (core, token, _) = try await core(locations, in: work)
        _ = try await core.archiveWorkflow(DaemonAPI.WorkflowArchiveRequest(
            folder: work, workflowID: "advisories", archived: true))

        let answer = try await call(core, token, .list)

        #expect(answer.contains("[archived]"))
    }

    // MARK: Writing, which asks nobody either

    @Test func aWriteIsLiveWithNoFurtherStep() async throws {
        let (locations, root) = try temporary()
        let work = try project(root)
        let (core, token, _) = try await core(locations, in: work)

        let answer = try await call(core, token, .write, id: "advisories", content: sample)

        #expect(answer.contains("Created advisories"))
        #expect(try Data(contentsOf: WorkflowFile.url(for: "advisories", in: work))
                == Data(sample.utf8))
        // Live: nothing follows. No confirmation, and no enable step either.
        #expect(await core.allWorkflows(in: work).count == 1)
    }

    @Test func whatTheAgentIsToldNamesTheTriggerAndWhereToLook() async throws {
        // FR-036 moved rather than went: the sentence that used to be on a confirmation
        // is what the agent is handed, in the same words the project-page row uses, so
        // what it reports back and what the person later sees cannot drift.
        let (locations, root) = try temporary()
        let work = try project(root)
        let (core, token, _) = try await core(locations, in: work)

        let answer = try await call(core, token, .write, id: "advisories", content: sample)

        #expect(answer.contains("Every weekday at 9am, in a new agent"))
        #expect(answer.contains("project page"))
        #expect(answer.contains("archive"))
    }

    @Test func aWriteNamingAModeIsToldBackInWords() async throws {
        // FR-029, FR-030: what the agent is handed after a write is the row's own
        // sentence, and the settings clause is part of it — "in plan mode", not a
        // quoted line of YAML the agent would have to parse back out of a reply.
        let (locations, root) = try temporary()
        let work = try project(root)
        let (core, token, _) = try await core(locations, in: work)
        let withMode = sample.replacingOccurrences(of: "agent: new\n", with: "agent: new\npermission-mode: plan\n")

        let answer = try await call(core, token, .write, id: "advisories", content: withMode)

        #expect(answer.contains("in plan mode"))
        #expect(!answer.contains("permission-mode:"))
    }

    @Test func aWriteWithNoWindowOpenStillHappens() async throws {
        // The case asking first could not serve. An agent working at three in the
        // morning for somebody who closed the window has nobody to ask, and the old
        // answer — refuse — made the feature turn itself off exactly when it was most
        // useful.
        let (locations, root) = try temporary()
        let work = try project(root)
        let (core, token, _) = try await core(locations, in: work)
        await core.setConnectionCount(0)

        let answer = try await call(core, token, .write, id: "advisories", content: sample)

        #expect(answer.contains("Created advisories"))
        #expect(await core.allWorkflows(in: work).count == 1)
    }

    @Test func anArchivedOneWrittenToAgainStaysArchivedAndTheAgentIsTold() async throws {
        // The person's one veto is not undone by the agent it was aimed at.
        let (locations, root) = try temporary()
        let work = try project(root)
        let (core, token, agentID) = try await core(locations, in: work)
        _ = try await call(core, token, .write, id: "advisories", content: sample)
        _ = try await core.archiveWorkflow(DaemonAPI.WorkflowArchiveRequest(
            folder: work, workflowID: "advisories", archived: true))

        let answer = try await call(core, token, .write, id: "advisories", content: sample,
                                    keepingAlive: agentID)

        #expect(answer.contains("archived"))
        #expect(await core.allWorkflows(in: work).first?.isArchived == true)
    }

    @Test func aFourthWorkflowIsRefusedWithTheThreeItAlreadyHas() async throws {
        // The ceiling an agent meets. Told rather than written-and-inert: an agent that
        // hears this now can offer to change one of the three instead.
        let (locations, root) = try temporary()
        let work = try project(root)
        let (core, token, agentID) = try await core(locations, in: work)
        for name in ["one", "two", "three"] {
            _ = try await call(core, token, .write, id: name, content: sample, keepingAlive: agentID)
        }

        await #expect(throws: JSONRPCError.self) {
            try await call(core, token, .write, id: "four", content: sample, keepingAlive: agentID)
        }

        #expect(FileManager.default.fileExists(
            atPath: WorkflowFile.url(for: "four", in: work).path) == false)
        #expect(await core.allWorkflows(in: work).count == 3)
    }

    @Test func changingOneOfTheThreeIsFineAtTheLimit() async throws {
        let (locations, root) = try temporary()
        let work = try project(root)
        let (core, token, agentID) = try await core(locations, in: work)
        for name in ["one", "two", "three"] {
            _ = try await call(core, token, .write, id: name, content: sample, keepingAlive: agentID)
        }

        let answer = try await call(core, token, .write, id: "two", content: sample,
                                    keepingAlive: agentID)

        #expect(answer.contains("Changed two"))
    }

    @Test func archivingOneLetsAnAgentWriteAnother() async throws {
        let (locations, root) = try temporary()
        let work = try project(root)
        let (core, token, agentID) = try await core(locations, in: work)
        for name in ["one", "two", "three"] {
            _ = try await call(core, token, .write, id: name, content: sample, keepingAlive: agentID)
        }
        _ = try await core.archiveWorkflow(DaemonAPI.WorkflowArchiveRequest(
            folder: work, workflowID: "two", archived: true))

        let answer = try await call(core, token, .write, id: "four", content: sample,
                                    keepingAlive: agentID)

        #expect(answer.contains("Created four"))
    }

    @Test func aWorkflowTooManyAcrossEveryProjectIsRefusedTheSameWay() async throws {
        // The ceiling an agent meets in a project of its own that is nowhere near full.
        // The remedy is somewhere else, so the refusal has to say so.
        let (locations, root) = try temporary()
        let work = try project(root)
        let (core, token, agentID) = try await core(locations, in: work)
        // Ten elsewhere, three at a time, which is all any project may run.
        for index in 0..<4 {
            let other = root.appendingPathComponent("full\(index)", isDirectory: true)
            try FileManager.default.createDirectory(
                at: WorkflowFile.folder(in: other), withIntermediateDirectories: true)
            for name in ["a", "b", "c"] {
                try Data(sample.utf8).write(to: WorkflowFile.url(for: name, in: other))
            }
            await core.rescanWorkflows(in: Project.standardize(other))
        }

        await #expect(throws: JSONRPCError.self) {
            try await call(core, token, .write, id: "mine", content: sample, keepingAlive: agentID)
        }

        #expect(FileManager.default.fileExists(
            atPath: WorkflowFile.url(for: "mine", in: work).path) == false)
    }

    @Test func changingAnExistingOneSaysSoRatherThanSayingCreate() async throws {
        let (locations, root) = try temporary()
        let work = try project(root)
        try FileManager.default.createDirectory(at: WorkflowFile.folder(in: work),
                                                withIntermediateDirectories: true)
        try Data(sample.utf8).write(to: WorkflowFile.url(for: "advisories", in: work))
        let (core, token, _) = try await core(locations, in: work)

        let answer = try await call(core, token, .write, id: "advisories", content: sample)

        #expect(answer.contains("Changed advisories"))
    }

    @Test func removingTakesTheFileWithIt() async throws {
        let (locations, root) = try temporary()
        let work = try project(root)
        try FileManager.default.createDirectory(at: WorkflowFile.folder(in: work),
                                                withIntermediateDirectories: true)
        try Data(sample.utf8).write(to: WorkflowFile.url(for: "advisories", in: work))
        let (core, token, _) = try await core(locations, in: work)
        _ = await core.allWorkflows(in: work)

        let answer = try await call(core, token, .remove, id: "advisories")

        #expect(answer.contains("is gone"))
        #expect(FileManager.default.fileExists(
            atPath: WorkflowFile.url(for: "advisories", in: work).path) == false)
    }

    // MARK: Refusals

    @Test func unparseableFrontMatterIsRefusedRatherThanWritten() async throws {
        // Said while the agent is still there to fix it, and it keeps a row nobody can
        // act on off the project page.
        let (locations, root) = try temporary()
        let work = try project(root)
        let (core, token, _) = try await core(locations, in: work)

        await #expect(throws: JSONRPCError.self) {
            try await call(core, token, .write, id: "broken", content: "---\nagent: new\n---\n\nGo.")
        }
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
        #expect(await core.allWorkflows(in: work).isEmpty)
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

    // MARK: Auto-allow

    @Test func theAppAnswersForItsOwnToolsAndNothingElse() async throws {
        // All three of ours, none of the agent's. A runtime that asks before every call
        // must not be able to stall the app's own plumbing on a question nobody is
        // there to answer — and for the workflow tool the answer is the project page,
        // after the fact, where there is something to look at.
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
        #expect(await core.autoAllowed(request(named: "mcp__agents__\(AppTool.manageWorkflows)")) != nil)
        #expect(await core.autoAllowed(request(named: "Write")) == nil)
    }

    /// The tool's description is what the agent tells the person, so it must say what
    /// happens: the app answers for the tool without asking anyone, a write is live at
    /// once, and the person's controls afterwards are the ones the page has.
    @Test func theDescriptionSaysWritingAsksNobody() async throws {
        let description = AppService.workflowTool["description"]?.stringValue ?? ""
        #expect(!description.contains("removing one asks"))
        #expect(!description.contains("if they decline"))
        #expect(description.contains("Nothing here asks the person,"))

        let (locations, root) = try temporary()
        let work = try project(root)
        let (core, token, agentID) = try await core(locations, in: work)
        let asked = PermissionRequest(
            agentID: agentID,
            toolCall: ToolCall(title: AppTool.manageWorkflows, name: "mcp__agents__\(AppTool.manageWorkflows)"),
            options: [PermissionOption(optionID: "allow", name: "Allow", kind: .allowAlways)])
        #expect(await core.autoAllowed(asked) != nil)

        let answer = try await call(core, token, .write, id: "advisories", content: sample, keepingAlive: agentID)
        #expect(FileManager.default.fileExists(atPath: WorkflowFile.url(for: "advisories", in: work).path))
        #expect(answer.contains("It is live now"))
        #expect(!answer.contains("pause"))
        #expect(description.contains("does not run until they approve it"))
    }

    /// Once approval has begun, what an agent writes waits for the person, and the
    /// agent is told so in words it can pass on rather than believing it will run.
    @Test func aWorkflowAnAgentWritesWaitsForTheirOKAndTheAgentIsTold() async throws {
        let (locations, root) = try temporary()
        let work = try project(root)
        let (core, token, agentID) = try await core(locations, in: work)
        await core.startWorkflows()

        let answer = try await call(core, token, .write, id: "advisories", content: sample, keepingAlive: agentID)

        #expect(answer.contains("It will not run until they approve it on the project page"))
        let summary = try #require(await core.allWorkflows(in: work).first)
        #expect(summary.awaitingApproval?.isNew == true)
        #expect(summary.needsAPerson)
    }
}
