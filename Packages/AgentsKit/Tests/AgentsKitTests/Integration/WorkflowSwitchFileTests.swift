import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// A workflow's switch and archive live in its own file (#125): `enabled: false` and
/// `archived: true`, written one key at a time, so they travel with the project. Who
/// turned it off, its approval and its history stay on the host.
@Suite("Workflow switches in the file", .timeLimit(.minutes(1)))
struct WorkflowSwitchFileTests {
    private func temporary() throws -> (StoreLocations, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsWorkflowSwitch-\(UUID().uuidString)", isDirectory: true)
        let work = root.appendingPathComponent("api", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        return (StoreLocations(root: root), Project.standardize(work))
    }

    private let text = "---\non:\n  - schedule:\n      at: [\":00\"]\nagent: new\n---\n\nGo.\n"

    @discardableResult
    private func write(_ text: String, as workflowID: String, in project: URL) throws -> URL {
        try FileManager.default.createDirectory(at: WorkflowFile.folder(in: project), withIntermediateDirectories: true)
        let url = WorkflowFile.url(for: workflowID, in: project)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func core(_ locations: StoreLocations, script: FakeACPAgent.Script = .init()) async throws -> DaemonCore {
        let core = DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                              discovery: .findsEverything, launcher: FakeLauncher(script: script))
        await core.loadFromDisk()
        return core
    }

    private func summary(_ core: DaemonCore, _ folder: URL, _ id: String) async -> WorkflowSummary? {
        await core.allWorkflows(in: folder).first { $0.workflowID == id }
    }

    private func read(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

    // MARK: The file

    @Test func theFileSaysArchivedAndEnabledAndAWrongValueIsAProblem() {
        let folder = URL(fileURLWithPath: "/tmp/x")
        let off = WorkflowFile.parse(text.replacingOccurrences(of: "agent: new", with: "agent: new\nenabled: false\narchived: true"),
                                     workflowID: "w", in: folder)
        #expect(off.isOff && off.isArchived && off.problem == nil)
        let plain = WorkflowFile.parse(text, workflowID: "w", in: folder)
        #expect(!plain.isOff && !plain.isArchived)
        let wrong = WorkflowFile.parse(text.replacingOccurrences(of: "agent: new", with: "archived: soon"),
                                       workflowID: "w", in: folder)
        #expect(wrong.problem == .unreadable("`archived:` must be true or false"))
    }

    @Test func thePagesSayTheSwitchIsALineInTheFile() {
        let summary = WorkflowSummary(workflow: Workflow(workflowID: "nightly", folder: URL(fileURLWithPath: "/tmp/x")))
        // The web page's test pins the same words.
        #expect(summary.switchesSentence
                == "Enabled and Archive are saved in .agents/workflows/nightly.md, a file in this project you may commit")
    }

    @Test func offAndOnAgainLeavesTheFileAsItWas() async throws {
        let (locations, work) = try temporary()
        let url = try write(text, as: "nightly", in: work)
        let core = try await core(locations)
        _ = try await core.addProject(work)
        await core.startWorkflows()

        let off = try await core.setWorkflowEnabled(.init(folder: work, workflowID: "nightly", enabled: false))
        #expect(try read(url).contains("\nenabled: false\n"))
        #expect(off.isEnabled == false && off.awaitingApproval == nil,
                "the person's switch does not make an approved file wait")

        let on = try await core.setWorkflowEnabled(.init(folder: work, workflowID: "nightly", enabled: true))
        #expect(try read(url) == text)
        #expect(on.isEnabled && on.awaitingApproval == nil)
    }

    @Test func archiveWritesTheFileAndBringBackTakesItOut() async throws {
        let (locations, work) = try temporary()
        let url = try write(text, as: "nightly", in: work)
        let core = try await core(locations)
        _ = try await core.addProject(work)
        await core.startWorkflows()

        let archived = try await core.archiveWorkflow(.init(folder: work, workflowID: "nightly", archived: true))
        #expect(archived.isArchived)
        #expect(try read(url).contains("\narchived: true\n"))
        #expect(archived.isEnabled, "archived is not the same as off")

        let back = try await core.archiveWorkflow(.init(folder: work, workflowID: "nightly", archived: false))
        #expect(!back.isArchived && back.awaitingApproval == nil)
        #expect(try read(url) == text)
    }

    @Test func aFileThatWasWaitingStillWaitsAfterTheSwitch() async throws {
        let (locations, work) = try temporary()
        let core = try await core(locations)
        await core.startWorkflows()
        try write(text, as: "fresh", in: work)
        await core.rescanWorkflows(in: work)
        #expect(await summary(core, work, "fresh")?.awaitingApproval != nil)

        _ = try await core.setWorkflowEnabled(.init(folder: work, workflowID: "fresh", enabled: false))
        #expect(await summary(core, work, "fresh")?.awaitingApproval != nil)
    }

    @Test func theStateIsTheFilesSoAnotherHostReadsItAsTheFileSays() async throws {
        let (locations, work) = try temporary()
        let url = try write(text, as: "nightly", in: work)
        let first = try await core(locations)
        await first.startWorkflows()
        _ = try await first.setWorkflowEnabled(.init(folder: work, workflowID: "nightly", enabled: false))
        _ = try await first.archiveWorkflow(.init(folder: work, workflowID: "nightly", archived: true))

        // A clone on another host: the same file, a root that has never seen it.
        let (elsewhere, clone) = try temporary()
        try write(try read(url), as: "nightly", in: clone)
        let second = try await core(elsewhere)
        await second.startWorkflows()
        let there = try #require(await summary(second, clone, "nightly"))
        #expect(there.isArchived)
        #expect(!there.isEnabled)
        #expect(there.offReason == .file, "who turned it off is this host's, not the file's")
    }

    @Test func anEditByHandMakesTheReasonTheFiles() async throws {
        let (locations, work) = try temporary()
        let url = try write(text, as: "nightly", in: work)
        let core = try await core(locations)
        await core.startWorkflows()
        _ = try await core.setWorkflowEnabled(.init(folder: work, workflowID: "nightly", enabled: false), byAgent: true)
        #expect(await summary(core, work, "nightly")?.offReason == .agent)

        try Data((try read(url) + "\nAnd more.\n").utf8).write(to: url)
        await core.rescanWorkflows(in: work)
        #expect(await summary(core, work, "nightly")?.offReason == .file)
    }

    @Test func aBrokenMetadataBlockIsRefusedAndNotWritten() async throws {
        let (locations, work) = try temporary()
        let url = try write("no front matter here\n", as: "broken", in: work)
        let core = try await core(locations)
        await core.rescanWorkflows(in: work)
        await #expect(throws: JSONRPCError.self) {
            _ = try await core.archiveWorkflow(.init(folder: work, workflowID: "broken", archived: true))
        }
        #expect(try read(url) == "no front matter here\n")
    }

    // MARK: Migration

    private func legacy(_ locations: StoreLocations, _ work: URL, _ id: String, _ fields: String,
                        approved: String? = nil, began: Bool = false) throws {
        try FileManager.default.createDirectory(at: locations.root, withIntermediateDirectories: true)
        let digest = approved.map { #","approvedDigest":"\#($0)""# } ?? ""
        let start = began ? #""approvalsBegan":"2026-09-24T09:00:00.000Z","# : ""
        try Data("""
            {\(start)"states":[{"folder":"\(work.absoluteString)","workflowID":"\(id)",\(fields)\(digest)}]}
            """.utf8).write(to: locations.workflows)
    }

    @Test func theOldStateIsWrittenIntoTheFileOnceAndForgotten() async throws {
        let (locations, work) = try temporary()
        let url = try write(text, as: "nightly", in: work)
        try legacy(locations, work, "nightly",
                   #""isArchived":true,"isDisabled":true,"enabledChosen":true,"disabledByAgent":true"#,
                   approved: ContentDigest.sha256(Data(text.utf8)), began: true)
        let core = try await core(locations)
        await core.startWorkflows()

        let written = try read(url)
        #expect(written.contains("\nenabled: false\n") && written.contains("\narchived: true\n"))
        let now = try #require(await summary(core, work, "nightly"))
        #expect(now.isArchived && !now.isEnabled)
        #expect(now.offReason == .agent, "who turned it off comes across")
        #expect(now.awaitingApproval == nil, "an approved file stays approved")
        let state = WorkflowStore(locations: locations).load().state(folder: work, workflowID: "nightly")
        #expect(state?.legacy == nil)

        // Once: a second start finds nothing to do, and a by-hand change stays.
        try Data(text.utf8).write(to: url)
        let again = try await self.core(locations)
        await again.startWorkflows()
        #expect(try read(url) == text)
    }

    @Test func aWorkflowTurnedOnOverItsFilesEnabledFalseIsWrittenOn() async throws {
        let (locations, work) = try temporary()
        let starting = text.replacingOccurrences(of: "agent: new", with: "agent: new\nenabled: false")
        let url = try write(starting, as: "review", in: work)
        try legacy(locations, work, "review", #""isDisabled":false,"enabledChosen":true"#)
        let core = try await core(locations)
        await core.startWorkflows()
        #expect(try read(url) == text)
        #expect(await summary(core, work, "review")?.isEnabled == true)
    }

    @Test func aProjectThatIsAwayKeepsItsOldStateForLater() async throws {
        let (locations, work) = try temporary()
        let away = work.deletingLastPathComponent().appendingPathComponent("away", isDirectory: true)
        try legacy(locations, Project.standardize(away), "nightly", #""isArchived":true"#)
        let core = try await core(locations)
        await core.startWorkflows()
        let state = WorkflowStore(locations: locations).load().states.first
        #expect(state?.legacy?.isArchived == true)
    }

    // MARK: Agents

    private func agent(_ core: DaemonCore, in project: URL) async throws -> (String, UUID) {
        let agentID = try await core.start(DaemonAPI.StartRequest(runtimeID: "claude", cwd: project, prompt: "Do a thing"))
        let token = UUID().uuidString
        await core.bindAppToken(token, to: agentID)
        return (token, agentID)
    }

    private func call(_ core: DaemonCore, _ token: String, _ agentID: UUID,
                      _ action: DaemonAPI.ManageWorkflowsRequest.Action,
                      id: String, content: String? = nil) async throws -> String {
        await core.bindAppToken(token, to: agentID)
        return try await core.manageWorkflows(.init(token: token, action: action, workflowID: id, content: content))
    }

    @Test func aNewOneAnAgentWritesHasEnabledFalseWrittenIn() async throws {
        let (locations, work) = try temporary()
        let core = try await core(locations, script: .init(gate: TurnGate()))
        let (token, agentID) = try await agent(core, in: work)
        let told = try await call(core, token, agentID, .write, id: "advisories", content: text)
        #expect(told.contains("enabled: false"))
        let written = try read(WorkflowFile.url(for: "advisories", in: work))
        #expect(written == text.replacingOccurrences(of: "agent: new", with: "agent: new\nenabled: false"))
        #expect(await summary(core, work, "advisories")?.offReason == .writtenByAgent)
        await #expect(throws: JSONRPCError.self) {
            _ = try await call(core, token, agentID, .enable, id: "advisories")
        }
    }

    @Test func anAgentRewritingOneKeepsItsSwitchAndArchive() async throws {
        let (locations, work) = try temporary()
        let url = try write(text, as: "nightly", in: work)
        let core = try await core(locations, script: .init(gate: TurnGate()))
        _ = try await core.addProject(work)
        await core.startWorkflows()
        _ = try await core.setWorkflowEnabled(.init(folder: work, workflowID: "nightly", enabled: false))
        _ = try await core.archiveWorkflow(.init(folder: work, workflowID: "nightly", archived: true))
        let (token, agentID) = try await agent(core, in: work)

        _ = try await call(core, token, agentID, .write, id: "nightly",
                           content: text.replacingOccurrences(of: "Go.", with: "Go faster."))
        let written = try read(url)
        #expect(written.contains("enabled: false") && written.contains("archived: true"))
        #expect(written.contains("Go faster."))
        let now = try #require(await summary(core, work, "nightly"))
        #expect(now.isArchived && !now.isEnabled)
        let back = try await core.archiveWorkflow(.init(folder: work, workflowID: "nightly", archived: false))
        #expect(back.awaitingApproval != nil, "an agent's change still waits for the person")
    }

    @Test func anAgentCanTurnOnOnlyWhatAnAgentTurnedOffEvenAfterItsFileChanged() async throws {
        let (locations, work) = try temporary()
        let url = try write(text, as: "nightly", in: work)
        let core = try await core(locations, script: .init(gate: TurnGate()))
        await core.startWorkflows()
        let (token, agentID) = try await agent(core, in: work)

        _ = try await call(core, token, agentID, .disable, id: "nightly")
        #expect(try read(url).contains("enabled: false"))
        _ = try await call(core, token, agentID, .enable, id: "nightly")
        #expect(try read(url) == text)

        // Checked in as `enabled: false` by somebody else: the agent may not turn it on.
        try Data(text.replacingOccurrences(of: "agent: new", with: "agent: new\nenabled: false").utf8).write(to: url)
        await core.rescanWorkflows(in: work)
        await #expect(throws: JSONRPCError.self) {
            _ = try await call(core, token, agentID, .enable, id: "nightly")
        }
    }
}
