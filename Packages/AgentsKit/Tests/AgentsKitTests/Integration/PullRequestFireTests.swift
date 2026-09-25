import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// A workflow with pull-request triggers firing, end to end (038 US2).
///
/// `PullRequestSandbox`: real git, a fake `gh` answering `pulls-mixed`, a fake runtime.
/// #412 is failing, asking for changes, and checked out in a worktree; #405 is in the
/// project folder and happy; the other three are not checked out anywhere.
@Suite("Babysitting fires", .timeLimit(.minutes(1)))
struct PullRequestFireTests {
    private static let babysitter = """
        ---
        name: Babysit my pull requests
        on:
          - pull-request-checks-failed
          - pull-request-review-comments
          - pull-request-conflicts
        agent: new
        ---
        Read what changed and fix it.
        """

    private func sandbox() async throws -> PullRequestSandbox {
        try await PullRequestSandbox.make(workflows: ["babysit-pull-requests": Self.babysitter])
    }

    private func pull(_ number: Int, in sandbox: PullRequestSandbox) async -> PullRequest? {
        await sandbox.core.pullRequestList(for: sandbox.project)?.pullRequests.first { $0.number == number }
    }

    @Test func aFailingCheckAndAReviewStartOneAgentInTheWorktree() async throws {
        let box = try await sandbox()
        _ = await box.core.refreshPullRequestsNow(in: box.project)

        guard let agent = await eventuallySome("the babysitting agent", {
            await box.core.allAgents().first { $0.startedByWorkflow == "babysit-pull-requests" }
        }) else { return }
        #expect(Project.standardize(agent.cwd) == box.fixWorktree)
        #expect(agent.projectFolder == box.project)
        #expect(agent.title == "Babysit my pull requests · #412")
        // Only #412 has somewhere to work; the rest are refused, not run.
        #expect(await box.core.allAgents().count == 1)

        let prompt = try #require(try await box.prompts(to: agent.id).first)
        #expect(prompt.hasPrefix("Read what changed and fix it."))
        #expect(prompt.contains("pull request #412, \"Fix login redirect\", https://github.com/alexec/agents/pull/412"))
        #expect(prompt.contains("Branch fix-login-redirect into main"))
        #expect(prompt.contains("- Check \"build\" failed: https://github.com/alexec/agents/actions/runs/1/job/9001"))
        // Only what came after the viewer's own last word, and quoted as theirs.
        #expect(prompt.contains("- maintainer (comment 4763207602) wrote:\n  > Can this land today?"))
        #expect(!prompt.contains("This should live in the router"))
        #expect(!prompt.contains("Please add my feature"))
        #expect(prompt.contains("Never force-push, and never use git push or gh yourself."))

        let row = try #require(await pull(412, in: box))
        #expect(row.babysitting.lastRun.map { if case .ran = $0 { true } else { false } } == true)
        #expect(row.babysitting.consecutiveRuns == 1)
    }

    @Test func aPullRequestWithNowhereToWorkIsRefusedOnItsRow() async throws {
        let box = try await sandbox()
        _ = await box.core.refreshPullRequestsNow(in: box.project)
        let row = try #require(await pull(377, in: box))
        guard case .refused(let refusal, _, _) = row.babysitting.lastRun else {
            Issue.record("expected #377 refused, got \(String(describing: row.babysitting.lastRun))")
            return
        }
        #expect(refusal == .noWorktree(pr: 377))
        #expect(refusal.rowMessage == "not checked out here")
        // #405 is happy: nothing to fire on, and nothing on its row.
        #expect(try #require(await pull(405, in: box)).babysitting.lastRun == nil)
    }

    @Test func uncommittedChangesInTheWorktreeRefuse() async throws {
        let box = try await sandbox()
        try "half done\n".write(to: box.fixWorktree.appending(path: "scratch.txt"), atomically: true, encoding: .utf8)
        _ = await box.core.refreshPullRequestsNow(in: box.project)

        #expect(await box.core.allAgents().isEmpty)
        let row = try #require(await pull(412, in: box))
        guard case .refused(let refusal, _, _) = row.babysitting.lastRun else {
            Issue.record("expected a refusal")
            return
        }
        #expect(refusal == .worktreeDirty(pr: 412))
        #expect(refusal.rowMessage == "its worktree has uncommitted changes")
    }

    @Test func theSameStateDoesNotFireTwice() async throws {
        let box = try await sandbox()
        _ = await box.core.refreshPullRequestsNow(in: box.project)
        await eventually("the first run to end") {
            let workflows = await box.core.allWorkflows(in: box.project)
            let agents = await box.core.allAgents()
            return !agents.isEmpty && workflows.allSatisfy { !$0.isRunning }
        }
        _ = await box.core.refreshPullRequestsNow(in: box.project)
        try? await Task.sleep(for: .milliseconds(300))
        #expect(await box.core.allAgents().count == 1)
    }

    @Test func runNowOnAPullRequestOnlyWorkflowIsRefused() async throws {
        let box = try await sandbox()
        let summary = try await box.core.runWorkflow(
            DaemonAPI.WorkflowRequest(folder: box.project, workflowID: "babysit-pull-requests"))
        guard case .refused(let refusal, _, _) = summary.lastOutcome else {
            Issue.record("expected a refusal")
            return
        }
        #expect(refusal == .noPullRequest)
        #expect(await box.core.allAgents().isEmpty)
    }

    @Test func nothingFiresWhenGitHubCannotBeReached() async throws {
        let box = try await sandbox()
        try box.gh.set(.offline)
        _ = await box.core.refreshPullRequestsNow(in: box.project)
        #expect(await box.core.allAgents().isEmpty)
    }

    @Test func anArchivedBabysitterFiresNothing() async throws {
        let box = try await sandbox()
        _ = try await box.core.archiveWorkflow(DaemonAPI.WorkflowArchiveRequest(
            folder: box.project, workflowID: "babysit-pull-requests", archived: true))
        _ = await box.core.refreshPullRequestsNow(in: box.project)
        #expect(await box.core.allAgents().isEmpty)
    }
}
