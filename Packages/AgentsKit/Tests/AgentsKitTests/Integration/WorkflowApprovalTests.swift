import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// Nothing runs from a workflow file the person has not looked at (security review).
///
/// What this holds: an agent that may only edit files cannot give itself a standing
/// agent that asks about nothing. A new or changed file waits; only the person's
/// Approve, of the file they were shown, lets it run; and the upgrade stops nothing,
/// because what was there when approval began is approved as it stood.
@Suite("Approving workflow files", .timeLimit(.minutes(1)))
struct WorkflowApprovalTests {
    private func temporary() throws -> (StoreLocations, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsApproval-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (StoreLocations(root: root), root.resolvingSymlinksInPath())
    }

    private func project(_ root: URL) throws -> URL {
        let url = root.appendingPathComponent("api", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return Project.standardize(url)
    }

    /// No mode unless one is named: the fake runtime offers none, and a mode it does not
    /// offer would be refused for that rather than for anything this suite is about.
    private func write(_ prompt: String, mode: String? = nil, as workflowID: String, in project: URL) throws {
        try FileManager.default.createDirectory(at: WorkflowFile.folder(in: project), withIntermediateDirectories: true)
        try Data("""
            ---
            on:
              - schedule:
                  at: [":00"]
            agent: new\(mode.map { "\npermission-mode: \($0)" } ?? "")
            ---

            \(prompt)
            """.utf8).write(to: WorkflowFile.url(for: workflowID, in: project))
    }

    private func core(_ locations: StoreLocations) async throws -> DaemonCore {
        let core = DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                              discovery: .findsEverything, launcher: FakeLauncher())
        await core.loadFromDisk()
        return core
    }

    private func summary(_ core: DaemonCore, _ id: String, in work: URL) async throws -> WorkflowSummary {
        await core.rescanWorkflows(in: work)
        return try #require(await core.allWorkflows(in: work).first { $0.workflowID == id })
    }

    /// A project whose one workflow was there when approval began.
    private func started() async throws -> (DaemonCore, URL, StoreLocations) {
        let (locations, root) = try temporary()
        let work = try project(root)
        try write("Run the tests.", as: "tests", in: work)
        let core = try await core(locations)
        await core.rescanWorkflows(in: work)
        await core.startWorkflows()
        return (core, work, locations)
    }

    // MARK: The digest

    @Test func theDigestIsSHA256() {
        #expect(ContentDigest.sha256(Data()) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(ContentDigest.sha256(Data("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(ContentDigest.sha256(Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8))
                == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
    }

    // MARK: Waiting

    @Test func whatWasThereWhenApprovalBeganRunsAsBefore() async throws {
        let (core, work, _) = try await started()

        #expect(try await summary(core, "tests", in: work).awaitingApproval == nil)
        _ = try await core.runWorkflow(.init(folder: work, workflowID: "tests"))
        #expect(await core.allAgents().count == 1)
    }

    @Test func aNewFileWaitsAndStartsNothing() async throws {
        let (core, work, _) = try await started()
        try write("Push to production.", mode: "bypassPermissions", as: "deploy", in: work)

        let waiting = try await summary(core, "deploy", in: work)
        #expect(waiting.awaitingApproval?.isNew == true)
        #expect(waiting.needsAPerson)

        let ran = try await core.runWorkflow(.init(folder: work, workflowID: "deploy"))
        #expect(await core.allAgents().isEmpty, "nothing started")
        if case .refused(.awaitingApproval, _, _) = ran.lastOutcome {} else {
            Issue.record("expected a refusal for waiting, got \(String(describing: ran.lastOutcome))")
        }
    }

    @Test func aChangeToAnApprovedFileWaitsAgain() async throws {
        let (core, work, _) = try await started()
        try write("Run the tests, then push.", as: "tests", in: work)

        let waiting = try await summary(core, "tests", in: work)
        #expect(waiting.awaitingApproval?.isNew == false)
        _ = try await core.runWorkflow(.init(folder: work, workflowID: "tests"))
        #expect(await core.allAgents().isEmpty)
    }

    @Test func anArchivedFileIsNotAlsoWaiting() async throws {
        let (core, work, _) = try await started()
        try write("Push to production.", as: "deploy", in: work)
        _ = try await summary(core, "deploy", in: work)
        _ = try await core.archiveWorkflow(.init(folder: work, workflowID: "deploy", archived: true))

        #expect(try await summary(core, "deploy", in: work).awaitingApproval == nil)
    }

    // MARK: Approving

    @Test func approvingWhatWasShownLetsItRun() async throws {
        let (core, work, _) = try await started()
        try write("Push to production.", as: "deploy", in: work)
        let digest = try #require(try await summary(core, "deploy", in: work).awaitingApproval?.digest)

        let approved = try await core.approveWorkflow(.init(folder: work, workflowID: "deploy", digest: digest))
        #expect(approved.awaitingApproval == nil)
        #expect(!approved.needsAPerson)
        _ = try await core.runWorkflow(.init(folder: work, workflowID: "deploy"))
        #expect(await core.allAgents().count == 1)
    }

    /// The file changed between the person looking and clicking: the click approves
    /// nothing, because what they read is not what would run.
    @Test func aFileThatChangedAfterItWasShownIsNotApproved() async throws {
        let (core, work, _) = try await started()
        try write("Summarise the logs.", as: "deploy", in: work)
        let shown = try #require(try await summary(core, "deploy", in: work).awaitingApproval?.digest)
        try write("Push to production.", mode: "bypassPermissions", as: "deploy", in: work)

        await #expect(throws: JSONRPCError.self) {
            _ = try await core.approveWorkflow(.init(folder: work, workflowID: "deploy", digest: shown))
        }
        #expect(try await summary(core, "deploy", in: work).awaitingApproval != nil)
    }

    /// Approving is a window's to do: an agent's helper cannot reach it.
    @Test func onlyAWindowMayApprove() {
        #expect(ConnectionRole.control.allows(DaemonAPI.Method.workflowsApprove))
        #expect(!ConnectionRole.agent.allows(DaemonAPI.Method.workflowsApprove))
        #expect(!ConnectionRole.stranger.allows(DaemonAPI.Method.workflowsApprove))
    }

    // MARK: Saving from the app

    @Test func aSaveFromTheAppKeepsAnApprovedFileApproved() async throws {
        let (core, work, _) = try await started()

        let saved = try await core.setWorkflowSettings(
            .init(folder: work, workflowID: "tests", settings: WorkflowSettings(model: "sonnet")))

        #expect(saved.awaitingApproval == nil)
        #expect(saved.workflow.settings.model == "sonnet")
    }

    /// Changing one setting on a file an agent wrote must not approve the rest of it.
    @Test func aSaveFromTheAppDoesNotApproveAFileThatWasWaiting() async throws {
        let (core, work, _) = try await started()
        try write("Push to production.", mode: "bypassPermissions", as: "deploy", in: work)
        _ = try await summary(core, "deploy", in: work)

        let saved = try await core.setWorkflowSettings(
            .init(folder: work, workflowID: "deploy", settings: WorkflowSettings(permissionMode: "plan")))

        #expect(saved.awaitingApproval != nil)
    }

    // MARK: Restarts

    /// Approval begins once. A file written between two starts is not swept in by the
    /// second, which is what would let a restart launder an agent's file.
    @Test func aRestartDoesNotApproveWhatArrivedInBetween() async throws {
        let (first, work, locations) = try await started()
        _ = first
        try write("Push to production.", mode: "bypassPermissions", as: "deploy", in: work)

        let second = try await core(locations)
        await second.rescanWorkflows(in: work)
        await second.startWorkflows()

        #expect(try await summary(second, "deploy", in: work).awaitingApproval?.isNew == true)
        #expect(try await summary(second, "tests", in: work).awaitingApproval == nil)
    }
}
