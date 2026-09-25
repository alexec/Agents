import Foundation
import AgentsKitCore

/// One pull request a workflow is about to fire on, with what changed on it.
struct PullRequestFire: Sendable {
    var folder: URL
    var repository: GitHubRepository
    var pull: PullRequest
    var changes: [PullRequestChanges.Change]

    var ref: PullRequestRef {
        PullRequestRef(number: pull.number, headBranch: pull.headBranch,
                       worktree: pull.worktree?.root ?? folder,
                       changeKey: changes.map(\.key).joined(separator: "|"))
    }
}

/// The person's own pull requests on a GitHub project (038).
///
/// Read with their `gh`, one request per project, at most every five minutes on the
/// workflow ticker and on demand (R1–R3). Matched to worktrees through git itself, so a
/// worktree the person made by hand counts too (R4). Nothing is sent to the phone: the
/// section is the Mac's (FR-010).
extension DaemonCore {
    /// How often a project is refreshed by itself (FR-008).
    static let pullRequestCadence: TimeInterval = 5 * 60
    /// The floor under a refresh somebody asked for (FR-008).
    static let pullRequestFloor: TimeInterval = 60

    public func setGitHubCLI(_ cli: GitHubCLI) {
        gitHubCLI = cli
    }

    /// Let the ticker refresh pull requests by itself. The daemon does, once its
    /// workflows have started.
    public func watchPullRequests() {
        watchesPullRequests = true
    }

    // MARK: Asked for by a window

    /// The section as last known, without running `gh`. A GitHub project not yet
    /// fetched gets an empty list, so its section can show while the first refresh
    /// runs; a project that is not on GitHub gets nil (SC-006).
    public func pullRequestList(for folder: URL) async -> PullRequestList? {
        let folder = Project.standardize(folder)
        if let cached = pullRequestLists[folder] { return withBabysitter(cached) }
        guard let repository = await gitHubRepository(of: folder) else { return nil }
        return withBabysitter(PullRequestList(folder: folder, repository: repository))
    }

    /// Refresh now, unless the last attempt was under a minute ago (FR-008).
    public func refreshPullRequests(in folder: URL) async -> PullRequestList? {
        let folder = Project.standardize(folder)
        let last = pullRequestStore.load().lastAttemptAt[folder.path]
        if let last, now().timeIntervalSince(last) < Self.pullRequestFloor {
            return await pullRequestList(for: folder)
        }
        return await refreshPullRequestsNow(in: folder)
    }

    // MARK: On the clock

    /// Start a sweep of every project that is due, unless one is already going. Called
    /// on every tick; costs nothing when nothing is due (R3).
    func sweepPullRequestsIfDue(now: Date) {
        guard watchesPullRequests, pullRequestSweep == nil else { return }
        let attempts = pullRequestStore.load().lastAttemptAt
        let due = allProjects(includeArchived: false).map(\.folder).filter { folder in
            guard Self.isDirectory(folder) else { return false }
            if let soon = pullRequestsDueAt[folder], soon <= now { return true }
            guard let last = attempts[folder.path] else { return true }
            return now.timeIntervalSince(last) >= Self.pullRequestCadence
        }
        guard !due.isEmpty else { return }
        pullRequestSweep = Task { [weak self] in
            for folder in due {
                guard !Task.isCancelled else { break }
                _ = await self?.refreshPullRequestsNow(in: folder)
            }
            await self?.endPullRequestSweep()
        }
    }

    private func endPullRequestSweep() {
        pullRequestSweep = nil
    }

    // MARK: The refresh

    /// Read `origin` again, ask GitHub, match worktrees, remember, and tell the Mac.
    @discardableResult
    func refreshPullRequestsNow(in folder: URL) async -> PullRequestList? {
        let folder = Project.standardize(folder)
        guard !pullRequestRefreshes.contains(folder) else { return await pullRequestList(for: folder) }
        pullRequestRefreshes.insert(folder)
        defer { pullRequestRefreshes.remove(folder) }

        var records = pullRequestStore.load()
        records.lastAttemptAt[folder.path] = now()

        // Read every time, so a remote changed to somewhere else takes effect within a
        // refresh (spec edge case). Not on GitHub: no section, and nothing kept.
        guard let repository = await gitHubRepository(of: folder) else {
            records.setList(nil, for: folder)
            records.keepOnly([], in: folder)
            pullRequestStore.save(records)
            pullRequestLists[folder] = nil
            return nil
        }

        let previous = pullRequestLists[folder]
        var list: PullRequestList
        do {
            let body = try await gitHubCLI.graphql(GitHubQuery.text, variables: GitHubQuery.variables(for: repository),
                                                   host: repository.host)
            let result = try GitHubQuery.decode(body)
            let matched = await matchWorktrees(result.pullRequests, in: folder)
            list = PullRequestList(folder: folder, repository: repository, viewer: result.viewer,
                                   pullRequests: matched, fetchedAt: now())
            records.keepOnly(Set(matched.map(\.number)), in: folder)
            // Before any trigger is looked at: somebody else having acted starts the
            // count again (R8).
            for pull in matched {
                records.update(folder: folder, number: pull.number) { $0.notice(pull) }
            }
        } catch let failure as GitHubCLI.Failure {
            var problem = failure.problem
            if case .cannotSee(let host, _, let login) = problem {
                problem = .cannotSee(host: host, repository: repository.fullName, login: login)
            }
            if problem.isUnreachable, let previous, previous.repository == repository {
                // The last good rows stay, marked with when they are from (FR-009).
                list = previous
                list.problem = problem
            } else {
                list = PullRequestList(folder: folder, repository: repository, problem: problem)
            }
        } catch {
            // GitHub answered with something that is not what was asked for. Treated
            // as not reaching it: keep what was there.
            list = previous ?? PullRequestList(folder: folder, repository: repository)
            list.problem = .unreachable("GitHub's answer could not be read")
        }

        list = withBabysitter(withBabysitting(list, records: records))
        records.setList(list, for: folder)
        pullRequestStore.save(records)
        pullRequestLists[folder] = list
        pullRequestsDueAt[folder] = nil
        if list != previous { tellMac(list) }
        // Only on a list that is true now: nothing fires on stale state (spec edge case).
        if list.problem == nil {
            // What changed, on the log first (042), so each of 038's fires can say
            // which event it came from.
            let causes = await raisePullRequestEvents(in: list)
            await firePullRequestTriggers(in: list, causes: causes)
        }
        return pullRequestLists[folder] ?? list
    }

    // MARK: Stopping (US3)

    /// Resume: start the count again on a stopped pull request (FR-024), and look at it
    /// again at once rather than in five minutes.
    public func resumePullRequest(_ number: Int, in folder: URL) async throws -> PullRequestList {
        let folder = Project.standardize(folder)
        guard let list = pullRequestLists[folder], list.pullRequests.contains(where: { $0.number == number }) else {
            throw JSONRPCError(code: DaemonAPI.Failure.noSuchPullRequest,
                               message: "#\(number) is not one of your open pull requests here.")
        }
        var records = pullRequestStore.load()
        records.update(folder: folder, number: number) { $0.resume() }
        pullRequestStore.save(records)
        republishPullRequests(in: folder, records: records)
        if let latest = pullRequestLists[folder] { await firePullRequestTriggers(in: latest) }
        return pullRequestLists[folder] ?? list
    }

    // MARK: Firing (US2)

    /// Every workflow here with a pull-request trigger, against every pull request, for
    /// the changes it has not fired on yet (R6). One fire for each workflow and pull
    /// request, carrying every change at once, so a review and a failing check that
    /// arrive together are one run rather than two in a row.
    func firePullRequestTriggers(in list: PullRequestList, causes: [String: EventPosition] = [:]) async {
        let records = workflowStore.load()
        let candidates = (workflows[list.folder] ?? [:]).values
            .filter { $0.respondsToPullRequests
                && records.state(folder: list.folder, workflowID: $0.workflowID)?.isArchived != true }
            .sorted { $0.workflowID < $1.workflowID }
        for workflow in candidates {
            for pull in list.pullRequests {
                // A run in flight on it: left alone, and looked at again once the run
                // ends, when its key is still unfired (FR-014).
                guard workflowRuns[runKey(for: workflow, pullRequest: pull.number)] == nil else { continue }
                let record = pullRequestStore.load().record(folder: list.folder, number: pull.number)
                let changes = PullRequestChanges.unfired(workflow.triggers, on: pull, record: record,
                                                         workflowID: workflow.workflowID)
                guard let first = changes.first else { continue }
                let cause = Self.eventName(for: first.trigger).flatMap { causes["\(pull.number) \($0)"] }
                await fire(workflow, on: first.trigger,
                           pullRequest: PullRequestFire(folder: list.folder, repository: list.repository,
                                                        pull: pull, changes: changes),
                           causingEvent: cause)
            }
        }
    }

    /// R9's checks, in order, before 008's own.
    func pullRequestRefusal(for workflow: Workflow, _ fire: PullRequestFire) async -> WorkflowRefusal? {
        let number = fire.pull.number
        guard let worktree = fire.pull.worktree else { return .noWorktree(pr: number) }
        let record = pullRequestStore.load().record(folder: fire.folder, number: number)
        if let record, record.isStopped {
            return .babysittingStopped(pr: number, runs: record.consecutiveRuns)
        }
        if let dirty = try? await GitWorktrees.workInProgressCount(in: worktree.root), dirty > 0 {
            return .worktreeDirty(pr: number)
        }
        if agents(in: worktree, folder: fire.folder).contains(where: { $0.state.holdsRuntime }) {
            return .worktreeBusy(pr: number)
        }
        return nil
    }

    /// The agents working in a pull request's worktree. For the project folder, the ones
    /// in it and not in one of its worktrees.
    func agents(in worktree: PullRequestWorktree, folder: URL) -> [Agent] {
        let checkout = Self.canonicalPath(worktree.checkout)
        return agents.values.filter { agent in
            guard agent.state != .archived else { return false }
            if worktree.isProjectFolder {
                return agent.worktree == nil && agent.projectFolder == Project.standardize(folder)
            }
            if let own = agent.worktree { return Self.canonicalPath(own.root) == checkout }
            return Self.canonicalPath(agent.cwd).hasPrefix(checkout)
        }
    }

    /// Write down a refusal against the pull request as well as the workflow, so its row
    /// can say it (FR-019). Repeats collapse, as on the workflow's row.
    func notePullRequestOutcome(_ outcome: WorkflowOutcome, workflow: Workflow, _ fire: PullRequestFire) {
        var records = pullRequestStore.load()
        records.update(folder: fire.folder, number: fire.pull.number) { record in
            record.lastOutcome = outcome.following(record.lastOutcome)
            record.lastOutcomeWorkflowID = workflow.workflowID
            if case .refused(.babysittingStopped, let at, _) = outcome, record.stoppedAt == nil {
                record.stoppedAt = at
            }
        }
        pullRequestStore.save(records)
        republishPullRequests(in: fire.folder, records: records)
    }

    /// A run started: every change it carries is fired, the watermark moves past the
    /// comments it was given, and it counts towards the three in a row (R6, R8).
    func notePullRequestRan(agentID: UUID, at now: Date, workflow: Workflow, _ fire: PullRequestFire) {
        var records = pullRequestStore.load()
        records.update(folder: fire.folder, number: fire.pull.number) { record in
            for change in fire.changes {
                record.firedKeys[PullRequestChanges.slot(workflowID: workflow.workflowID, trigger: change.trigger)] = change.key
            }
            if let newest = fire.changes.flatMap(\.comments).map(\.id).max() {
                record.commentWatermark[workflow.workflowID] = max(newest, record.commentWatermark[workflow.workflowID] ?? 0)
            }
            record.consecutiveRuns += 1
            record.lastRunStartedAt = now
            record.lastOutcome = .ran(agentID: agentID, at: now)
            record.lastOutcomeWorkflowID = workflow.workflowID
        }
        pullRequestStore.save(records)
        republishPullRequests(in: fire.folder, records: records)
    }

    /// A pull request's run ended: say so on its row, and look again within a minute or
    /// so, at the first tick past the floor (FR-014, R3).
    func pullRequestRunEnded(in folder: URL) {
        let folder = Project.standardize(folder)
        let last = pullRequestStore.load().lastAttemptAt[folder.path] ?? .distantPast
        pullRequestsDueAt[folder] = max(now(), last.addingTimeInterval(Self.pullRequestFloor))
        republishPullRequests(in: folder, records: pullRequestStore.load())
    }

    /// The cached list with babysitting filled in again, kept and sent.
    private func republishPullRequests(in folder: URL, records: PullRequestRecords) {
        let folder = Project.standardize(folder)
        guard let cached = pullRequestLists[folder] else { return }
        let list = withBabysitter(withBabysitting(cached, records: records))
        guard list != cached else { return }
        pullRequestLists[folder] = list
        var records = records
        records.setList(list, for: folder)
        pullRequestStore.save(records)
        tellMac(list)
    }

    // MARK: The prompt (R10)

    /// What a pull-request run adds to the workflow's own words: which pull request,
    /// where, and what changed. Reviewers' words are quoted and introduced as theirs,
    /// never run into the instructions.
    func pullRequestPromptBlock(for workflow: Workflow, _ fire: PullRequestFire) async -> String {
        let pull = fire.pull
        var lines: [String] = []
        var context = "(You were started by the workflow \"\(workflow.name)\" for pull request #\(pull.number), "
            + "\"\(pull.title)\", \(pull.url.absoluteString). Branch \(pull.headBranch) into \(pull.baseBranch), checked out here."
        if let worktree = pull.worktree, let counts = await GitWorktrees.aheadBehind(in: worktree.root), counts.behind > 0 {
            context += counts.ahead > 0
                ? " Your branch and GitHub's have both moved on (\(counts.ahead) and \(counts.behind) commits): bring GitHub's in, don't discard them."
                : " GitHub has \(counts.behind) commit\(counts.behind == 1 ? "" : "s") you don't: bring \(counts.behind == 1 ? "it" : "them") in first."
        }
        lines.append(context + ")")
        lines.append("")
        lines.append("What changed:")
        for change in fire.changes {
            for check in change.checks {
                lines.append("- Check \"\(check.name)\" failed" + (check.logURL.map { ": \($0.absoluteString)" } ?? "."))
            }
            for item in change.comments {
                var who = item.author
                if let path = item.path { who += " on \(path)" + (item.line.map { ":\($0)" } ?? "") }
                if item.requestsChanges { who += ", requesting changes" }
                lines.append("- \(who) (comment \(item.id)) wrote:")
                let body = item.body.count > 2_000 ? String(item.body.prefix(2_000)) + " …" : item.body
                lines.append(contentsOf: body.split(separator: "\n", omittingEmptySubsequences: false).map { "  > \($0)" })
            }
            if let base = change.conflictsWith {
                lines.append("- It now conflicts with \(base).")
            }
        }
        lines.append("")
        lines.append("Push with push_pull_request, and reply with reply_on_pull_request. Never force-push, "
                     + "and never use git push or gh yourself.")
        return "\n\n" + lines.joined(separator: "\n")
    }

    /// The Mac's windows only (FR-010).
    func tellMac(_ list: PullRequestList) {
        send(DaemonAPI.Notification.pullRequestsChanged, list, to: { $0.surface == .mac })
    }

    // MARK: Which repository, which worktree

    /// The project's `origin`, if it is on GitHub (FR-001).
    func gitHubRepository(of folder: URL) async -> GitHubRepository? {
        guard let url = await GitWorktrees.remoteURL("origin", in: folder),
              let remote = GitRemote(url) else { return nil }
        return GitHubRepository(remote: remote)
    }

    /// Each pull request with the worktree its branch is checked out in, the project
    /// folder included (R4). A fork's branch must also really be that pull request: a
    /// local `fix-typo` must not claim somebody's fork's `fix-typo`.
    func matchWorktrees(_ pulls: [PullRequest], in folder: URL) async -> [PullRequest] {
        guard let repository = await GitWorktrees.repository(of: folder),
              let entries = try? await GitWorktrees.list(in: folder) else { return pulls }
        let top = Self.canonicalPath(repository.toplevel)
        var matched: [PullRequest] = []
        for var pull in pulls {
            pull.worktree = nil
            for entry in entries where entry.branch == pull.headBranch && !entry.isPrunable && !entry.isBare {
                if pull.isFromFork, !(await isThatPullRequest(pull, branch: entry.branch!, in: folder)) { continue }
                let isProjectFolder = Self.canonicalPath(entry.path) == top
                let root = isProjectFolder
                    ? Project.standardize(folder)
                    : Self.workingFolder(in: Project.standardize(entry.path), prefix: repository.prefix)
                pull.worktree = PullRequestWorktree(root: root, checkout: Project.standardize(entry.path),
                                                    name: isProjectFolder ? "project folder" : entry.path.lastPathComponent,
                                                    isProjectFolder: isProjectFolder)
                break
            }
            matched.append(pull)
        }
        return matched
    }

    private func isThatPullRequest(_ pull: PullRequest, branch: String, in folder: URL) async -> Bool {
        if let head = pull.headRepositoryURL, let upstream = await GitWorktrees.upstreamURL(of: branch, in: folder),
           let theirs = GitRemote(head.absoluteString), let ours = GitRemote(upstream),
           theirs.identity == ours.identity {
            return true
        }
        return await GitWorktrees.isAncestor(pull.headOid, of: branch, in: folder)
    }

    /// Fill in what the rows say about babysitting, from the records (FR-019).
    func withBabysitting(_ list: PullRequestList, records: PullRequestRecords) -> PullRequestList {
        var list = list
        list.pullRequests = list.pullRequests.map { pull in
            var pull = pull
            let record = records.record(folder: list.folder, number: pull.number)
            let running = workflowRuns.values.contains {
                $0.folder == list.folder && $0.pullRequest?.number == pull.number
            }
            pull.babysitting = BabysittingStatus(lastRun: record?.lastOutcome,
                                                 lastRunWorkflowID: record?.lastOutcomeWorkflowID,
                                                 consecutiveRuns: record?.consecutiveRuns ?? 0,
                                                 isStopped: record?.isStopped ?? false,
                                                 isRunning: running)
            return pull
        }
        return list
    }

    /// Whether the project already has a babysitter, archived or not (US4-2).
    func withBabysitter(_ list: PullRequestList) -> PullRequestList {
        var list = list
        list.babysitterWorkflowID = (workflows[list.folder] ?? [:]).values
            .filter { $0.triggers.contains(where: \.isPullRequest) }
            .map(\.workflowID).sorted().first
        return list
    }

    // MARK: Checking one out (FR-007)

    /// Check a pull request's branch out into a new worktree, on its existing branch
    /// rather than a new `agents/` one (R5).
    public func checkOutPullRequest(_ number: Int, in folder: URL) async throws -> PullRequestList {
        let folder = Project.standardize(folder)
        guard let list = await pullRequestList(for: folder),
              let pull = list.pullRequests.first(where: { $0.number == number }) else {
            throw JSONRPCError(code: DaemonAPI.Failure.noSuchPullRequest,
                               message: "#\(number) is not one of your open pull requests here.")
        }
        if pull.worktree != nil { return list }
        guard let repository = await GitWorktrees.repository(of: folder) else {
            throw JSONRPCError(code: DaemonAPI.Failure.worktreeFailed,
                               message: "\(folder.lastPathComponent) is not in a git repository.")
        }
        let name = WorktreeName.from(branch: pull.headBranch)
        let path = repository.worktreesFolder.appending(path: name, directoryHint: .isDirectory)
        guard !FileManager.default.fileExists(atPath: path.path) else {
            throw JSONRPCError(code: DaemonAPI.Failure.worktreeExists,
                               message: "There is already a folder at \(WorktreeName.folder)/\(name).")
        }
        let entries = (try? await GitWorktrees.list(in: folder)) ?? []
        if let elsewhere = entries.first(where: { $0.branch == pull.headBranch }) {
            throw JSONRPCError(code: DaemonAPI.Failure.branchCheckedOut,
                               message: "\(pull.headBranch) is checked out in \(elsewhere.path.path(percentEncoded: false)).")
        }
        do {
            try GitWorktrees.ensureExcluded(commonDir: repository.commonDir)
        } catch let failure as GitWorktrees.Failure {
            throw JSONRPCError(code: DaemonAPI.Failure.worktreeFailed, message: failure.message)
        }

        let branch = pull.headBranch
        let hasBranch = await GitWorktrees.branchExists(branch, in: folder)
        do {
            if pull.isFromFork {
                guard let head = pull.headRepositoryURL else {
                    throw GitWorktrees.Failure(message: "The fork #\(number) came from is gone.")
                }
                if !hasBranch {
                    try await GitWorktrees.fetch(remote: head.absoluteString, refspec: "\(branch):\(branch)", in: folder)
                }
            } else {
                try await GitWorktrees.fetch(remote: "origin", refspec: branch, in: folder)
            }
        } catch let failure as GitWorktrees.Failure {
            throw JSONRPCError(code: DaemonAPI.Failure.fetchFailed,
                               message: "Couldn't fetch \(branch): \(failure.message)")
        }
        do {
            if hasBranch || pull.isFromFork {
                try await GitWorktrees.add(existingBranch: branch, path: path, in: folder)
            } else {
                try await GitWorktrees.add(trackingBranch: branch, upstream: "origin/\(branch)", path: path, in: folder)
            }
        } catch let failure as GitWorktrees.Failure {
            throw JSONRPCError(code: DaemonAPI.Failure.worktreeFailed,
                               message: "Couldn't check out \(branch): \(failure.message)")
        }

        var updated = list
        updated.pullRequests = await matchWorktrees(list.pullRequests, in: folder)
        var records = pullRequestStore.load()
        records.setList(updated, for: folder)
        pullRequestStore.save(records)
        pullRequestLists[folder] = updated
        tellMac(updated)
        return updated
    }
}
