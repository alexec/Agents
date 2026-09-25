import Foundation
import AgentsKitCore

/// The two things a babysitting agent may do on GitHub (038 R7, FR-020 to FR-022).
///
/// Neither takes a pull request, a branch or a repository. The daemon takes all three
/// from the run the caller was started for, and that is what makes it impossible for a
/// babysitting agent to force-push, push anywhere else, merge, close or approve: there
/// is no tool that could. Because the daemon does the pushing and commenting, it also
/// knows which commits and comments were babysitting's (R8).
extension DaemonCore {
    static let onlyPullRequestRuns = "Only a run started for a pull request can push or reply; ask the person to do it."

    /// Who is asking, and the pull request their run is for. Refused, in words the
    /// agent reads, for anybody else.
    private func pullRequestCaller(_ token: String) throws -> (run: WorkflowRun, ref: PullRequestRef,
                                                             list: PullRequestList, pull: PullRequest,
                                                             agent: Agent) {
        guard let agentID = appTokens[token], let agent = agents[agentID] else {
            throw JSONRPCError(code: DaemonAPI.Failure.noSuchAgent,
                               message: "This agent is not one the app knows, so nothing was done.")
        }
        guard let (_, run) = runInFlight(for: agentID), let ref = run.pullRequest,
              let list = pullRequestLists[Project.standardize(run.folder)],
              let pull = list.pullRequests.first(where: { $0.number == ref.number }) else {
            throw JSONRPCError(code: DaemonAPI.Failure.notYours, message: Self.onlyPullRequestRuns)
        }
        guard Self.canonicalPath(agent.cwd).hasPrefix(Self.canonicalPath(ref.worktree)) else {
            throw JSONRPCError(code: DaemonAPI.Failure.notYours,
                               message: "This agent is not in #\(ref.number)'s worktree.")
        }
        return (run, ref, list, pull, agent)
    }

    /// `push_pull_request`: the worktree's commits to the pull request's own branch.
    ///
    /// Never `--force`, `--force-with-lease` or a `+` refspec, so git refuses a push the
    /// remote has moved past, and its own words go back to the agent. A pull request
    /// from this repository goes through `origin`, with the person's own remote and
    /// credentials; one from a fork goes to the fork's URL.
    public func pushPullRequest(_ request: DaemonAPI.PushPullRequestRequest) async throws -> String {
        let (_, ref, list, pull, _) = try pullRequestCaller(request.token)
        let destination: String
        if !pull.isFromFork {
            destination = "origin"
        } else if let head = pull.headRepositoryURL {
            destination = head.absoluteString
        } else {
            return "Git refused: the fork #\(ref.number) came from is not there any more."
        }
        let outcome: GitProcess.Outcome
        do {
            outcome = try await GitProcess(["push", destination, "HEAD:refs/heads/\(pull.headBranch)"],
                                           in: ref.worktree).run()
        } catch {
            return "Git refused: git is not installed on this Mac."
        }
        guard outcome.succeeded else {
            let said = outcome.errors.trimmingCharacters(in: .whitespacesAndNewlines)
            return "Git refused: \(said.isEmpty ? "the push failed" : said)"
        }
        let head = (try? await GitWorktrees.git(["rev-parse", "HEAD"], in: ref.worktree)) ?? ""
        var records = pullRequestStore.load()
        records.update(folder: list.folder, number: ref.number) { $0.notePushed(head) }
        pullRequestStore.save(records)
        return "Pushed \(head.prefix(7)) to \(pull.headBranch) (#\(ref.number))."
    }

    /// `reply_on_pull_request`: answer a review comment in its thread, or comment on
    /// the pull request. As the person, through their `gh` (FR-021).
    public func replyOnPullRequest(_ request: DaemonAPI.ReplyOnPullRequestRequest) async throws -> String {
        let (_, ref, list, pull, _) = try pullRequestCaller(request.token)
        let repo = list.repository
        let path: String
        if let id = request.inReplyTo {
            // Only a comment on *this* pull request, as last fetched. A review comment
            // is answered in its thread; anything else on it is answered on the pull
            // request, since only review comments have threads.
            guard let item = pull.countableComments.first(where: { $0.id == id }) else {
                return "Comment \(id) is not on #\(ref.number)."
            }
            path = item.kind == .threadComment
                ? "repos/\(repo.owner)/\(repo.name)/pulls/\(ref.number)/comments/\(id)/replies"
                : "repos/\(repo.owner)/\(repo.name)/issues/\(ref.number)/comments"
        } else {
            path = "repos/\(repo.owner)/\(repo.name)/issues/\(ref.number)/comments"
        }
        let body: Data
        do {
            body = try await gitHubCLI.api(method: "POST", path: path, fields: ["body": request.body],
                                           host: repo.host)
        } catch let failure as GitHubCLI.Failure {
            return "GitHub refused: " + (failure.problem.message ?? "it could not be reached.")
        }
        let posted = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        if let id = posted?["id"] as? Int {
            var records = pullRequestStore.load()
            records.update(folder: list.folder, number: ref.number) { $0.notePosted(id) }
            pullRequestStore.save(records)
        }
        let url = posted?["html_url"] as? String ?? pull.url.absoluteString
        return "Replied: \(url)"
    }
}
