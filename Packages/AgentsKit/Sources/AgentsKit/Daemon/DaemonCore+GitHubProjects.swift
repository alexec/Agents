import Foundation
import AgentsKitCore

extension DaemonCore {
    private static let githubProjectRefreshFloor: TimeInterval = 30

    /// Return what the daemon last read without making the window wait on GitHub.
    public func githubProjectBoard(for folder: URL) async -> GitHubProjectBoard? {
        let folder = Project.standardize(folder)
        if let board = githubProjectBoards[folder] { return board }
        guard let repository = await gitHubRepository(of: folder) else { return nil }
        return GitHubProjectBoard(folder: folder, repository: repository)
    }

    /// Read the first project linked to this repository, preserving a stale copy on errors.
    @discardableResult
    public func refreshGitHubProjectBoard(in folder: URL, force: Bool = false) async -> GitHubProjectBoard? {
        let folder = Project.standardize(folder)
        guard !githubProjectRefreshes.contains(folder) else { return await githubProjectBoard(for: folder) }
        var records = githubProjectStore.load()
        if !force, let last = records.lastAttemptAt[folder.path],
           now().timeIntervalSince(last) < Self.githubProjectRefreshFloor {
            return await githubProjectBoard(for: folder)
        }
        githubProjectRefreshes.insert(folder)
        defer { githubProjectRefreshes.remove(folder) }
        records.lastAttemptAt[folder.path] = now()

        guard let repository = await gitHubRepository(of: folder) else {
            records.setBoard(nil, folder: folder)
            records.lastAttemptAt.removeValue(forKey: folder.path)
            githubProjectStore.save(records)
            githubProjectBoards[folder] = nil
            return nil
        }

        let previous = githubProjectBoards[folder]
        do {
            let fetched = try await GitHubProjectQuery.fetch(repository: repository, folder: folder,
                                                             using: gitHubCLI, now: now())
            var board = fetched ?? GitHubProjectBoard(
                folder: folder, repository: repository,
                problem: GitHubProjectProblem(message: "No GitHub Project is linked to this repository."))
            board.issues = applyingAssignments(records: records, to: board)
            records.setBoard(board, folder: folder)
            githubProjectStore.save(records)
            githubProjectBoards[folder] = board
            tellMac(board)
            return board
        } catch {
            let problem = githubProjectProblem(from: error, host: repository.host, scope: "read:project")
            var board = previous.flatMap { $0.repository == repository ? $0 : nil }
                ?? GitHubProjectBoard(folder: folder, repository: repository)
            board.problem = problem
            board.issues = applyingAssignments(records: records, to: board)
            records.setBoard(board, folder: folder)
            githubProjectStore.save(records)
            githubProjectBoards[folder] = board
            tellMac(board)
            return board
        }
    }

    /// Start a fresh agent, save its durable issue link, then synchronize the Project status.
    public func assignGitHubIssue(_ request: GitHubIssueAssignmentRequest) async throws -> GitHubIssueAssignmentResult {
        let folder = Project.standardize(request.folder)
        if let existing = githubProjectStore.load().assignment(requestID: request.requestID) {
            if existing.assignment.statusSync == .pending || existing.assignment.statusSync == .failed {
                return try await syncGitHubIssueStatus(.init(folder: folder,
                                                             projectID: existing.assignment.projectID,
                                                             itemID: existing.assignment.itemID))
            }
            return result(for: existing.assignment)
        }

        var cachedBoard = githubProjectBoards[folder]
        if cachedBoard == nil { cachedBoard = await refreshGitHubProjectBoard(in: folder) }
        guard let board = cachedBoard,
              let projectID = board.projectID,
              let fieldID = board.statusFieldID,
              let inProgressOptionID = board.inProgressOptionID,
              let issue = board.issues.first(where: {
                  $0.itemID == request.itemID && $0.nodeID == request.issueNodeID
              }),
              issue.number == request.issueNumber,
              issue.status == .ready else {
            throw JSONRPCError(code: DaemonAPI.Failure.issueAssignmentRefused,
                               message: "This issue is no longer Ready on the selected GitHub Project. Refresh the board and try again.")
        }
        var records = githubProjectStore.load()
        if records.assignment(folder: folder, projectID: projectID, itemID: issue.itemID) != nil {
            throw JSONRPCError(code: DaemonAPI.Failure.issueAssignmentRefused,
                               message: "This issue already has an agent assignment. Refresh the board to see its worktree.")
        }

        let name = WorktreeName.issue(number: issue.number, title: issue.title, now: now())
        let agentID = try await start(DaemonAPI.StartRequest(
            runtimeID: request.runtimeID, cwd: folder, prompt: request.prompt,
            worktree: .named(name), requestID: request.requestID))
        guard let agent = agents[agentID], let worktree = agent.worktree else {
            throw JSONRPCError(code: DaemonAPI.Failure.issueAssignmentRefused,
                               message: "The agent started without an issue worktree, so the issue was not linked.")
        }

        let timestamp = now()
        var assignment = GitHubIssueAssignment(
            projectID: projectID, itemID: issue.itemID, issueNodeID: issue.nodeID,
            issueNumber: issue.number, agentID: agentID, worktree: worktree,
            statusSync: .pending, requestID: request.requestID,
            createdAt: timestamp, updatedAt: timestamp)
        let entry = GitHubProjectAssignmentEntry(folder: folder,
                                                 repository: board.repository,
                                                 assignment: assignment)
        records.setAssignment(entry)
        var assignedBoard = board
        assignedBoard.issues = applyingAssignments(records: records, to: board)
        records.setBoard(assignedBoard, folder: folder)
        githubProjectStore.save(records)
        if let updated = records.board(folder: folder) { githubProjectBoards[folder] = updated; tellMac(updated) }

        // We have the IDs from the current board; no extra GitHub read is needed here.
        do {
            try await GitHubProjectQuery.updateStatus(projectID: projectID, itemID: issue.itemID,
                                                      fieldID: fieldID, optionID: inProgressOptionID,
                                                      host: board.repository.host, using: gitHubCLI)
            assignment.statusSync = .synced
            assignment.statusSyncProblem = nil
        } catch {
            assignment.statusSync = .failed
            assignment.statusSyncProblem = githubProjectProblem(from: error,
                                                                host: board.repository.host,
                                                                scope: "project")
        }
        assignment.updatedAt = now()
        records = githubProjectStore.load()
        records.updateAssignment(folder: folder, projectID: projectID, itemID: issue.itemID) {
            $0.assignment = assignment
        }
        if var latest = records.board(folder: folder) {
            latest.issues = applyingAssignments(records: records, to: latest)
            latest.problem = nil
            records.setBoard(latest, folder: folder)
        }
        githubProjectStore.save(records)
        if let latest = records.board(folder: folder) { githubProjectBoards[folder] = latest; tellMac(latest) }
        return GitHubIssueAssignmentResult(agentID: agentID, worktree: worktree,
                                           statusSync: assignment.statusSync,
                                           statusSyncProblem: assignment.statusSyncProblem)
    }

    /// Retry the GitHub status write only; the agent and worktree are never started twice.
    public func syncGitHubIssueStatus(_ request: GitHubProjectStatusSyncRequest) async throws -> GitHubIssueAssignmentResult {
        let folder = Project.standardize(request.folder)
        var records = githubProjectStore.load()
        guard var entry = records.assignment(folder: folder, projectID: request.projectID,
                                             itemID: request.itemID) else {
            throw JSONRPCError(code: DaemonAPI.Failure.issueAssignmentRefused,
                               message: "There is no agent assignment for this issue to synchronize.")
        }
        var cachedBoard = githubProjectBoards[folder]
        if cachedBoard == nil { cachedBoard = await refreshGitHubProjectBoard(in: folder) }
        guard let board = cachedBoard,
              board.projectID == request.projectID,
              let fieldID = board.statusFieldID,
              let optionID = board.inProgressOptionID else {
            throw JSONRPCError(code: DaemonAPI.Failure.issueAssignmentRefused,
                               message: "This GitHub Project no longer has an In Progress status option.")
        }
        do {
            try await GitHubProjectQuery.updateStatus(projectID: request.projectID,
                                                      itemID: request.itemID,
                                                      fieldID: fieldID, optionID: optionID,
                                                      host: entry.repository.host, using: gitHubCLI)
            entry.assignment.statusSync = .synced
            entry.assignment.statusSyncProblem = nil
        } catch {
            entry.assignment.statusSync = .failed
            entry.assignment.statusSyncProblem = githubProjectProblem(from: error,
                                                                       host: entry.repository.host,
                                                                       scope: "project")
        }
        entry.assignment.updatedAt = now()
        records.setAssignment(entry)
        if var latest = records.board(folder: folder) {
            latest.issues = applyingAssignments(records: records, to: latest)
            records.setBoard(latest, folder: folder)
        }
        githubProjectStore.save(records)
        if let latest = records.board(folder: folder) { githubProjectBoards[folder] = latest; tellMac(latest) }
        return result(for: entry.assignment)
    }

    private func applyingAssignments(records: GitHubProjectRecords,
                                      to board: GitHubProjectBoard) -> [GitHubProjectIssue] {
        board.issues.map { issue in
            guard let entry = records.assignment(folder: board.folder,
                                                 projectID: board.projectID ?? "",
                                                 itemID: issue.itemID),
                  entry.assignment.issueNodeID == issue.nodeID else { return issue }
            var assigned = issue
            // Local assignment is the source of truth for this app's work even while
            // GitHub's status mutation is waiting to be retried.
            assigned.status = .inProgress
            assigned.assignment = entry.assignment
            assigned.statusSync = entry.assignment.statusSync
            assigned.statusSyncProblem = entry.assignment.statusSyncProblem
            return assigned
        }
    }

    private func result(for assignment: GitHubIssueAssignment) -> GitHubIssueAssignmentResult {
        GitHubIssueAssignmentResult(agentID: assignment.agentID, worktree: assignment.worktree,
                                   statusSync: assignment.statusSync,
                                   statusSyncProblem: assignment.statusSyncProblem)
    }

    private func githubProjectProblem(from error: Error, host: String, scope: String) -> GitHubProjectProblem {
        guard let failure = error as? GitHubCLI.Failure else {
            return GitHubProjectProblem(message: "GitHub Project could not be updated: \(error.localizedDescription)",
                                        isUnreachable: true)
        }
        switch failure.problem {
        case .noCLI:
            return GitHubProjectProblem(message: "The GitHub CLI is not installed.", fix: "brew install gh")
        case .notSignedIn(let failedHost):
            return GitHubProjectProblem(message: "The GitHub CLI is not signed in to \(failedHost).",
                                        fix: "gh auth login --hostname \(failedHost)")
        case .cannotSee(let failedHost, _, _):
            let fix = "gh auth refresh --hostname \(failedHost) --scopes \(scope)"
            return GitHubProjectProblem(message: "GitHub denied access to this Project or its repository.",
                                        fix: fix)
        case .unreachable(let reason):
            return GitHubProjectProblem(message: "GitHub could not be reached: \(reason)",
                                        isUnreachable: true)
        }
    }

    private func tellMac(_ board: GitHubProjectBoard) {
        send(DaemonAPI.Notification.projectIssuesChanged, board, to: { $0.surface == .mac })
    }
}
