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

    // MARK: The two tools (R7)

    /// A babysitting run that is still in its turn, and the token its helper holds.
    private func runInProgress() async throws -> (PullRequestSandbox, Agent, String)? {
        var script = FakeACPAgent.Script()
        script.turnDelay = .seconds(30)
        let box = try await PullRequestSandbox.make(workflows: ["babysit-pull-requests": Self.babysitter],
                                                    script: script)
        _ = await box.core.refreshPullRequestsNow(in: box.project)
        guard let agent = await eventuallySome("the babysitting agent", {
            await box.core.allAgents().first { $0.startedByWorkflow == "babysit-pull-requests" }
        }), let token = await eventuallySome("its token", {
            await box.core.appTokens.first { $0.value == agent.id }?.key
        }) else { return nil }
        return (box, agent, token)
    }

    @Test func pushGoesToThePullRequestsOwnBranch() async throws {
        guard let (box, _, token) = try await runInProgress() else { return }
        try "fixed\n".write(to: box.fixWorktree.appending(path: "fix.txt"), atomically: true, encoding: .utf8)
        try await PullRequestSandbox.git(["add", "."], in: box.fixWorktree)
        try await PullRequestSandbox.git(["commit", "-q", "-m", "Fix it"], in: box.fixWorktree)
        let head = try await PullRequestSandbox.git(["rev-parse", "HEAD"], in: box.fixWorktree)

        let said = try await box.core.pushPullRequest(DaemonAPI.PushPullRequestRequest(token: token))
        #expect(said == "Pushed \(head.prefix(7)) to fix-login-redirect (#412).")
        #expect(try await PullRequestSandbox.git(["rev-parse", "fix-login-redirect"], in: box.bare) == head)
        // Babysitting's own push is remembered, so it is never taken for the person's.
        #expect(await box.core.pullRequestStore.load().record(folder: box.project, number: 412)?.pushedOids == [head])
    }

    @Test func aPushTheRemoteHasMovedPastIsRefusedNotForced() async throws {
        guard let (box, _, token) = try await runInProgress() else { return }
        // Somebody else pushes to the branch first.
        let other = box.root.appending(path: "other", directoryHint: .isDirectory)
        try await PullRequestSandbox.git(["clone", "-q", "-b", "fix-login-redirect", box.bare.path, other.path], in: box.root)
        try await PullRequestSandbox.git(["-c", "user.email=o@example.com", "-c", "user.name=O",
                                          "commit", "-q", "--allow-empty", "-m", "theirs"], in: other)
        try await PullRequestSandbox.git(["push", "-q", "origin", "fix-login-redirect"], in: other)
        let theirs = try await PullRequestSandbox.git(["rev-parse", "HEAD"], in: other)

        try await PullRequestSandbox.git(["commit", "-q", "--allow-empty", "-m", "mine"], in: box.fixWorktree)
        let said = try await box.core.pushPullRequest(DaemonAPI.PushPullRequestRequest(token: token))
        #expect(said.hasPrefix("Git refused:"))
        #expect(try await PullRequestSandbox.git(["rev-parse", "fix-login-redirect"], in: box.bare) == theirs)
    }

    @Test func aReplyAnswersAReviewCommentInItsThread() async throws {
        guard let (box, _, token) = try await runInProgress() else { return }
        try #"{"id": 5550001, "html_url": "https://github.com/alexec/agents/pull/412#discussion_r5550001"}"#
            .write(to: box.gh.folder.appending(path: "reply.json"), atomically: true, encoding: .utf8)

        let said = try await box.core.replyOnPullRequest(
            DaemonAPI.ReplyOnPullRequestRequest(token: token, body: "Moved it into the router.", inReplyTo: 2210984))
        #expect(said == "Replied: https://github.com/alexec/agents/pull/412#discussion_r5550001")
        let call = try #require(box.gh.calledWith().last)
        #expect(call.hasPrefix("api --hostname github.com -X POST repos/alexec/agents/pulls/412/comments/2210984/replies"))
        #expect(call.contains("body=Moved it into the router."))
        #expect(await box.core.pullRequestStore.load().record(folder: box.project, number: 412)?.postedCommentIDs == [5550001])

        // Without a comment to answer, it goes on the pull request itself.
        _ = try await box.core.replyOnPullRequest(DaemonAPI.ReplyOnPullRequestRequest(token: token, body: "Done."))
        #expect(box.gh.calledWith().last?.contains("repos/alexec/agents/issues/412/comments") == true)
    }

    @Test func onlyThisPullRequestsCommentsCanBeAnswered() async throws {
        guard let (box, _, token) = try await runInProgress() else { return }
        let before = box.gh.calledWith().count
        let said = try await box.core.replyOnPullRequest(
            DaemonAPI.ReplyOnPullRequestRequest(token: token, body: "Hi", inReplyTo: 12345))
        #expect(said == "Comment 12345 is not on #412.")
        #expect(box.gh.calledWith().count == before)
    }

    @Test func anAgentNotStartedForAPullRequestCannotPushOrReply() async throws {
        let box = try await sandbox()
        let id = try await box.core.start(DaemonAPI.StartRequest(runtimeID: "claude", cwd: box.project, prompt: "hello"))
        guard let token = await eventuallySome("its token", { await box.core.appTokens.first { $0.value == id }?.key })
        else { return }
        for call in [{ try await box.core.pushPullRequest(DaemonAPI.PushPullRequestRequest(token: token)) },
                     { try await box.core.replyOnPullRequest(DaemonAPI.ReplyOnPullRequestRequest(token: token, body: "x")) }] {
            do {
                _ = try await call()
                Issue.record("expected a refusal")
            } catch let error as JSONRPCError {
                #expect(error.message == "Only a run started for a pull request can push or reply; ask the person to do it.")
            }
        }
    }

    @Test func theTwoToolsAreAnsweredWithoutAsking() {
        for name in ["mcp__agents__push_pull_request", "reply_on_pull_request"] {
            #expect(ToolCall(title: name, name: name).isAutoAllowable)
        }
        #expect(!ToolCall(title: "Bash", name: "Bash").isAutoAllowable)
    }
}
