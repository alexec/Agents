import Foundation
import AgentsKitCore

/// Where events come from besides agents, workflows and pull requests (042 R9–R11).
extension DaemonCore {
    // MARK: branch.moved (R9)

    /// Watch a project's `.git` for branch tips moving. Called wherever a project's
    /// workflows are adopted, which is everywhere a project becomes live.
    func watchBranches(in folder: URL) {
        let folder = Project.standardize(folder)
        guard branchWatchers[folder] == nil, Self.isDirectory(folder.appending(path: ".git")) else { return }
        branchWatchers[folder] = FolderWatch(root: folder) { [weak self] changed in
            guard changed.contains(where: Self.isBranchPath) else { return }
            Task { await self?.scheduleBranchCheck(in: folder) }
        }
        // Seed what the tips are now, so the first move after this is a move.
        scheduleBranchCheck(in: folder, after: .zero)
    }

    func stopWatchingAllBranches() {
        for (_, watch) in branchWatchers { watch.stop() }
        branchWatchers.removeAll()
    }

    /// Whether a changed path is a branch tip or what a worktree has checked out.
    static func isBranchPath(_ url: URL) -> Bool {
        let path = url.path
        return path.contains("/.git/refs/heads") || path.hasSuffix("/.git/packed-refs")
            || path.hasSuffix("/.git/HEAD") || (path.contains("/.git/worktrees/") && path.hasSuffix("/HEAD"))
    }

    /// Wait for git to finish writing — a rebase writes many refs — then look once.
    func scheduleBranchCheck(in folder: URL, after delay: Duration = .seconds(1)) {
        branchChecks[folder]?.cancel()
        branchChecks[folder] = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.checkBranches(in: folder)
        }
    }

    /// The branches worth saying moved: the project's default branch, and each branch
    /// an agent's worktree in it is on.
    func watchedBranches(in folder: URL) async -> Set<String> {
        var branches = Set(agents.values.compactMap { agent -> String? in
            guard agent.state != .archived, agent.projectFolder == folder else { return nil }
            return agent.worktree?.branch
        })
        branches.insert(await defaultBranch(of: folder))
        return branches
    }

    /// `origin/HEAD`'s branch when there is one, otherwise `main`, otherwise `master`.
    private func defaultBranch(of folder: URL) async -> String {
        if let git = try? GitProcess(["symbolic-ref", "--short", "refs/remotes/origin/HEAD"], in: folder),
           let outcome = try? await git.run(), outcome.succeeded {
            let name = outcome.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if let slash = name.firstIndex(of: "/") { return String(name[name.index(after: slash)...]) }
        }
        let tips = await branchTips(in: folder)
        return tips["main"] != nil || tips["master"] == nil ? "main" : "master"
    }

    /// Every local branch and the commit it points at.
    func branchTips(in folder: URL) async -> [String: String] {
        guard let git = try? GitProcess(["for-each-ref", "--format=%(refname:short) %(objectname)", "refs/heads"],
                                        in: folder),
              let outcome = try? await git.run(), outcome.succeeded else { return [:] }
        var tips: [String: String] = [:]
        for line in outcome.output.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1)
            if parts.count == 2 { tips[String(parts[0])] = String(parts[1]) }
        }
        return tips
    }

    /// Compare the watched branches' tips with those last seen, and raise one
    /// `branch.moved` for each that changed. The first look at a project only seeds
    /// them; a tip that moved while the daemon was down is raised when noticed.
    func checkBranches(in folder: URL) async {
        loadEventsIfNeeded()
        let tips = await branchTips(in: folder)
        let watched = await watchedBranches(in: folder)
        let key = folder.path
        let before = eventState.branchTips[key]
        var now: [String: String] = [:]
        for branch in watched { if let tip = tips[branch] { now[branch] = tip } }
        eventState.branchTips[key] = now
        eventStore.saveState(eventState)
        guard let before else { return }
        for (branch, tip) in now.sorted(by: { $0.key < $1.key }) {
            guard let old = before[branch], old != tip else { continue }
            raise(EventDraft(name: "branch.moved", at: self.now(), scope: .project(folder: folder),
                             sentence: "\(branch) moved to \(tip.prefix(7)).",
                             details: ["branch": branch, "from": String(old.prefix(12)), "to": String(tip.prefix(12))]))
        }
    }
}
