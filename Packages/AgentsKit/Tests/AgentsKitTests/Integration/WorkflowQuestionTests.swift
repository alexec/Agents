import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// A workflow waiting for an OK is asked as a changed guarded file is (#569): who changed
/// it, the lines against the approved copy kept in `workflows.json`, and Keep or Undo.
@Suite("Waiting workflows are asked as questions", .timeLimit(.minutes(1)))
struct WorkflowQuestionTests {
    private struct Setup {
        var core: DaemonCore
        var project: URL
        var lead: UUID
    }

    private static let approved = workflowText("Run the tests.")

    private static func workflowText(_ prompt: String) -> String {
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

    private func setUp() async throws -> Setup {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsWorkflowQuestion-\(UUID().uuidString)", isDirectory: true)
        let project = Project.standardize(root.appendingPathComponent("work", isDirectory: true))
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try write(Self.approved, as: "tests", in: project)
        let locations = StoreLocations(root: root.appendingPathComponent("root", isDirectory: true))
        try locations.createDirectories()
        let store = try AgentStore(locations: locations)
        let lead = Agent(runtimeID: "claude", cwd: project, title: "Lead", state: .finished, endedReason: .endTurn)
        try await store.save(lead)
        let core = DaemonCore(store: store, locations: locations, discovery: .findsEverything, launcher: FakeLauncher())
        await core.loadFromDisk()
        _ = try await core.addProject(project)
        await core.rescanWorkflows(in: project)
        await core.startWorkflows()
        return Setup(core: core, project: project, lead: lead.id)
    }

    private func write(_ text: String, as workflowID: String, in project: URL) throws {
        try FileManager.default.createDirectory(at: WorkflowFile.folder(in: project), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: WorkflowFile.url(for: workflowID, in: project))
    }

    private func text(_ workflowID: String, in project: URL) -> String? {
        try? String(contentsOf: WorkflowFile.url(for: workflowID, in: project), encoding: .utf8)
    }

    private func waiting(_ s: Setup, _ id: String) async throws -> WorkflowSummary {
        try #require(await s.core.allWorkflows(in: s.project).first { $0.workflowID == id })
    }

    @Test func theApprovedCopyIsKeptBesideItsDigest() async throws {
        let s = try await setUp()
        let state = await s.core.workflowStore.load().state(folder: s.project, workflowID: "tests")
        #expect(state?.approvedContent == Data(Self.approved.utf8))
    }

    @Test func aChangeDuringATurnIsAskedInThatAgentsSession() async throws {
        let s = try await setUp()
        await s.core.startTurnForTesting(s.lead)
        try write(Self.workflowText("Run the tests, then push."), as: "tests", in: s.project)
        await s.core.rescanWorkflows(in: s.project)

        let change = try #require(await s.core.projectSummary(for: s.project)?.guardedChanges?.first)
        #expect(change.path == ".agents/workflows/tests.md")
        #expect(change.isWorkflow)
        #expect(change.changedBy == ["Lead"])
        #expect(change.askedIn == s.lead)
        #expect(change.headline == "Lead changed .agents/workflows/tests.md")
        let need = try #require(await s.core.needs().first { $0.kind == .guardedChange })
        #expect(need.id == .guardedChange(s.project, ".agents/workflows/tests.md"))
        #expect(need.agentID == s.lead)

        let reading = try await s.core.readGuardedChange(.init(folder: s.project, path: change.path))
        #expect(reading.lines.contains(GuardedDiffLine(kind: .removed, text: "Run the tests.")))
        #expect(reading.lines.contains(GuardedDiffLine(kind: .added, text: "Run the tests, then push.")))

        await #expect(throws: JSONRPCError.self, "only the change the person was shown") {
            _ = try await s.core.undoGuardedChange(.init(folder: s.project, path: change.path, digest: "other"))
        }
        let summary = try await s.core.undoGuardedChange(.init(folder: s.project, path: change.path, digest: reading.digest))
        #expect(summary.guardedChanges == nil)
        #expect(text("tests", in: s.project) == Self.approved, "the approved copy is back")
        #expect(try await waiting(s, "tests").awaitingApproval == nil)
        #expect(await !s.core.needs().contains { $0.kind == .guardedChange }, "answered, it is asked no more")
    }

    @Test func aChangeFirstSeenAtTheEndOfATurnIsThatTurns() async throws {
        let s = try await setUp()
        await s.core.startTurnForTesting(s.lead)
        try write(Self.workflowText("Push."), as: "tests", in: s.project)
        await s.core.endTurnForTesting(s.lead)

        let change = try #require(await s.core.projectSummary(for: s.project)?.guardedChanges?.first)
        #expect(change.changedBy == ["Lead"])
    }

    @Test func keepApprovesAndKeepsTheNewCopy() async throws {
        let s = try await setUp()
        let changed = Self.workflowText("Run the tests, then push.")
        try write(changed, as: "tests", in: s.project)
        await s.core.rescanWorkflows(in: s.project)

        let change = try #require(await s.core.projectSummary(for: s.project)?.guardedChanges?.first)
        #expect(change.changedBy.isEmpty)
        #expect(change.headline == "Something outside the app changed .agents/workflows/tests.md")
        let kept = try await s.core.keepGuardedChange(.init(folder: s.project, path: change.path, digest: change.digest))
        #expect(kept.guardedChanges == nil)
        #expect(try await waiting(s, "tests").awaitingApproval == nil)

        // Changed again, Undo goes back to what was kept.
        try write(Self.workflowText("Delete everything."), as: "tests", in: s.project)
        await s.core.rescanWorkflows(in: s.project)
        let again = try #require(await s.core.projectSummary(for: s.project)?.guardedChanges?.first)
        _ = try await s.core.undoGuardedChange(.init(folder: s.project, path: again.path, digest: again.digest))
        #expect(text("tests", in: s.project) == changed)
    }

    @Test func undoRemovesAWorkflowNeverApproved() async throws {
        let s = try await setUp()
        try write(Self.workflowText("Push to production."), as: "deploy", in: s.project)
        await s.core.rescanWorkflows(in: s.project)

        let change = try #require(await s.core.projectSummary(for: s.project)?.guardedChanges?.first)
        #expect(change.path == ".agents/workflows/deploy.md")
        let reading = try await s.core.readGuardedChange(.init(folder: s.project, path: change.path))
        #expect(reading.approved == nil)
        _ = try await s.core.undoGuardedChange(.init(folder: s.project, path: change.path, digest: reading.digest))
        #expect(text("deploy", in: s.project) == nil)
        #expect(await s.core.allWorkflows(in: s.project).map(\.workflowID) == ["tests"])
    }

    @Test func aWorkflowApprovedBeforeCopiesWereKeptGetsOneWhenSeenApproved() async throws {
        let s = try await setUp()
        var records = await s.core.workflowStore.load()
        records.update(folder: s.project, workflowID: "tests") { $0.approvedContent = nil }
        try await s.core.workflowStore.save(records)

        await s.core.rescanWorkflows(in: s.project)
        let state = await s.core.workflowStore.load().state(folder: s.project, workflowID: "tests")
        #expect(state?.approvedContent == Data(Self.approved.utf8))
    }

    @Test func undoWithNoCopyKeptIsRefusedAndLeavesTheFile() async throws {
        let s = try await setUp()
        let changed = Self.workflowText("Push.")
        try write(changed, as: "tests", in: s.project)
        var records = await s.core.workflowStore.load()
        records.update(folder: s.project, workflowID: "tests") { $0.approvedContent = nil }
        try await s.core.workflowStore.save(records)
        await s.core.rescanWorkflows(in: s.project)

        let change = try #require(await s.core.projectSummary(for: s.project)?.guardedChanges?.first)
        await #expect(throws: JSONRPCError.self) {
            _ = try await s.core.undoGuardedChange(.init(folder: s.project, path: change.path, digest: change.digest))
        }
        #expect(text("tests", in: s.project) == changed)
    }
}
