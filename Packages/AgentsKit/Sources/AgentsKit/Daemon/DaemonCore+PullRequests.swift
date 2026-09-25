import Foundation
import AgentsKitCore

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
        if list != previous { tellMac(list) }
        return list
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
                pull.worktree = PullRequestWorktree(root: root,
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
                                                 isStopped: record?.stoppedAt != nil,
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
