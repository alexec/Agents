import Foundation
import AgentsKitCore

/// Worktrees: a second checkout of the project for an agent to work in (030).
///
/// The daemon makes them itself and starts the runtime inside, rather than asking a
/// runtime to make its own. Checked on 2026-09-24 over ACP: only Claude's option works;
/// Cursor's and Copilot's make one and then work in the project folder anyway, and
/// Grok's is ignored or refused. What all four do honour is the folder they are started
/// in, so that is the one thing asked of them (research R1).
///
/// Nothing about worktrees is stored beyond the agent's own record. The app's are
/// recognised in git by where they are and what their branch is called (R6).
extension DaemonCore {
    /// Where a start should put its agent: the folder to work in, and the worktree
    /// that folder is in. Makes the worktree when asked for a new one.
    func prepareWorktree(_ choice: WorktreeChoice, from project: URL,
                         prompt: String) async throws -> (cwd: URL, worktree: AgentWorktree) {
        let project = Project.standardize(project)
        guard let repository = await GitWorktrees.repository(of: project) else {
            throw JSONRPCError(code: DaemonAPI.Failure.worktreeFailed,
                               message: "\(project.lastPathComponent) is not in a git repository, so it has no worktrees.")
        }
        switch choice {
        case .new:
            return try await makeWorktree(in: repository, project: project, prompt: prompt)
        case .existing(let root):
            return try await existingWorktree(root, in: repository, project: project)
        case .branch(let name):
            return try await makeWorktree(onBranch: name, in: repository, project: project)
        }
    }

    /// A new worktree in the app's folder on a branch already there, named for it.
    /// Only a branch the chooser would offer: one checked out somewhere else is
    /// refused by git anyway, and saying so first says which.
    private func makeWorktree(onBranch wanted: String, in repository: GitWorktrees.Repository,
                              project: URL) async throws -> (cwd: URL, worktree: AgentWorktree) {
        let entries = (try? await GitWorktrees.list(in: project)) ?? []
        if let holder = entries.first(where: { $0.branch == wanted }) {
            throw JSONRPCError(code: DaemonAPI.Failure.worktreeFailed,
                               message: "\(wanted) is already checked out in \(holder.path.lastPathComponent). Choose that worktree instead.")
        }
        let branches = (try? await GitWorktrees.branches(in: project)) ?? []
        guard let branch = branches.first(where: { $0.name == wanted }) else {
            throw JSONRPCError(code: DaemonAPI.Failure.worktreeFailed,
                               message: "There is no branch called \(wanted) here.")
        }
        do {
            try GitWorktrees.ensureExcluded(commonDir: repository.commonDir)
        } catch let failure as GitWorktrees.Failure {
            throw JSONRPCError(code: DaemonAPI.Failure.worktreeFailed, message: failure.message)
        }

        let folder = repository.worktreesFolder
        var taken = reservedWorktreeNames(under: folder)
        taken.formUnion(existingNames(in: folder))
        let name = WorktreeName.next(after: WorktreeName.folder(forBranch: wanted), taken: taken)
        reserveWorktreeName(name, under: folder)
        defer { releaseWorktreeName(name, under: folder) }

        let root = folder.appending(path: name, directoryHint: .isDirectory)
        do {
            try await GitWorktrees.add(existing: branch, path: root, in: project)
        } catch let failure as GitWorktrees.Failure {
            throw JSONRPCError(code: DaemonAPI.Failure.worktreeFailed,
                               message: "Could not make a worktree on \(wanted): \(failure.message)")
        }
        let made = Project.standardize(root)
        let worktree = AgentWorktree(name: name, root: made, branch: wanted, project: project,
                                     base: nil, madeByApp: true)
        return (Self.workingFolder(in: made, prefix: repository.prefix), worktree)
    }

    private func makeWorktree(in repository: GitWorktrees.Repository, project: URL,
                              prompt: String) async throws -> (cwd: URL, worktree: AgentWorktree) {
        let folder = repository.worktreesFolder
        let wanted = WorktreeName.from(prompt: prompt, now: now())
        // Chosen and held before the first `await`: on an actor that is the whole of
        // the lock, so two starts from the same words cannot both pick the same name.
        var taken = reservedWorktreeNames(under: folder)
        taken.formUnion(existingNames(in: folder))
        var name = WorktreeName.next(after: wanted, taken: taken)
        reserveWorktreeName(name, under: folder)
        defer { releaseWorktreeName(name, under: folder) }

        guard await GitWorktrees.hasCommit(in: project) else {
            throw JSONRPCError(code: DaemonAPI.Failure.worktreeFailed,
                               message: "There is no commit here yet to base a worktree on. Commit something first.")
        }
        let base = await GitWorktrees.base(in: project)
        do {
            try GitWorktrees.ensureExcluded(commonDir: repository.commonDir)
        } catch let failure as GitWorktrees.Failure {
            throw JSONRPCError(code: DaemonAPI.Failure.worktreeFailed, message: failure.message)
        }

        // A branch of that name made some other way is only seen by git. Asked first,
        // and git refusing is still taken as a clash, because something else can make
        // one between the two.
        var attempts = 0
        while true {
            let branch = WorktreeName.branch(for: name)
            let root = folder.appending(path: name, directoryHint: .isDirectory)
            let branchTaken = await GitWorktrees.branchExists(branch, in: project)
            if !branchTaken {
                do {
                    try await GitWorktrees.add(branch: branch, path: root, in: project)
                    let made = Project.standardize(root)
                    let worktree = AgentWorktree(name: name, root: made, branch: branch,
                                                 project: project, base: base, madeByApp: true)
                    return (Self.workingFolder(in: made, prefix: repository.prefix), worktree)
                } catch let failure as GitWorktrees.Failure {
                    let clash = failure.message.contains("already exists")
                    guard clash, attempts < 20 else {
                        throw JSONRPCError(code: DaemonAPI.Failure.worktreeFailed,
                                           message: "Could not make a worktree: \(failure.message)")
                    }
                }
            }
            attempts += 1
            guard attempts < 20 else {
                throw JSONRPCError(code: DaemonAPI.Failure.worktreeFailed,
                                   message: "Could not find a free name for a worktree like \(wanted).")
            }
            releaseWorktreeName(name, under: folder)
            taken.insert(name)
            taken.formUnion(reservedWorktreeNames(under: folder))
            name = WorktreeName.next(after: wanted, taken: taken)
            reserveWorktreeName(name, under: folder)
        }
    }

    private func existingWorktree(_ root: URL, in repository: GitWorktrees.Repository,
                                  project: URL) async throws -> (cwd: URL, worktree: AgentWorktree) {
        let wanted = Self.canonical(root)
        let entries = (try? await GitWorktrees.list(in: project)) ?? []
        guard let entry = entries.first(where: { Self.canonicalPath($0.path) == wanted.path }) else {
            throw JSONRPCError(code: DaemonAPI.Failure.notAWorktree,
                               message: "\(wanted.path) is not a worktree of \(project.lastPathComponent)'s repository.")
        }
        guard !entry.isPrunable, Self.isDirectory(wanted) else {
            throw JSONRPCError(code: DaemonAPI.Failure.worktreeMissing,
                               message: "The worktree \(wanted.lastPathComponent) is not there any more.")
        }
        let worktree = AgentWorktree(name: wanted.lastPathComponent, root: wanted, branch: entry.branch,
                                     project: project, base: nil,
                                     madeByApp: Self.isMadeByApp(wanted, branch: entry.branch,
                                                                 in: repository))
        return (Self.workingFolder(in: wanted, prefix: repository.prefix), worktree)
    }

    // MARK: Listing

    /// A folder's repository and every worktree of it, for the chooser and the project
    /// page. A folder in no repository is an answer too, not an error: it is what hides
    /// the chooser.
    public func listWorktrees(for folder: URL) async -> DaemonAPI.WorktreesListResponse {
        let project = Project.standardize(folder)
        guard let repository = await GitWorktrees.repository(of: project) else { return .notARepository }
        let hasCommit = await GitWorktrees.hasCommit(in: project)
        let entries = (try? await GitWorktrees.list(in: project)) ?? []
        let here = Project.standardize(repository.toplevel)
        let working = agents.values.filter { $0.state != .archived }
        let summaries = entries.filter { !$0.isBare }.map { entry -> DaemonAPI.WorktreeSummary in
            let root = Self.canonical(entry.path)
            let inside = root.path + "/"
            let agentsHere = working.filter {
                let cwd = Self.canonicalPath($0.cwd)
                return cwd == root.path || cwd.hasPrefix(inside)
            }
            // Agents in a worktree inside this one are that worktree's, not the main
            // checkout's, even though their folders are under it on disk.
            let nested = entries.map { Self.canonicalPath($0.path) + "/" }.filter { $0 != inside && $0.hasPrefix(inside) }
            let own = agentsHere.filter { agent in
                let cwd = Self.canonicalPath(agent.cwd) + "/"
                return !nested.contains { cwd.hasPrefix($0) }
            }
            return DaemonAPI.WorktreeSummary(
                name: root.lastPathComponent, root: root, branch: entry.branch,
                isProjectFolder: root.path == here.path,
                exists: !entry.isPrunable && Self.isDirectory(root),
                madeByApp: Self.isMadeByApp(root, branch: entry.branch, in: repository),
                agents: own.sorted { $0.createdAt < $1.createdAt }.map(\.id))
        }
        // A branch checked out anywhere cannot be checked out again; its worktree is
        // already on the list.
        let checkedOut = Set(entries.compactMap(\.branch))
        let branches = hasCommit
            ? ((try? await GitWorktrees.branches(in: project)) ?? []).filter { !checkedOut.contains($0.name) }
            : []
        return DaemonAPI.WorktreesListResponse(
            isRepository: true, canMakeNew: hasCommit,
            whyNot: hasCommit ? nil : "There is no commit here yet to base a worktree on.",
            worktrees: summaries, branches: branches)
    }

    // MARK: Cleaning up (US3)

    /// What removing a worktree would lose. Nothing is changed.
    public func checkWorktreeRemoval(_ request: DaemonAPI.WorktreeRemovalRequest) async throws -> DaemonAPI.RemovalCheck {
        try await removalFacts(request).check
    }

    /// Remove a worktree the app made, and its branch when that loses nothing or the
    /// person said yes. Every check is made here, whatever the window already asked:
    /// the daemon does not take a client's word that nothing is in the way.
    public func removeWorktree(_ request: DaemonAPI.WorktreeRemovalRequest) async throws -> DaemonAPI.WorktreeRemoved {
        let facts = try await removalFacts(request)
        guard facts.madeByApp else {
            throw JSONRPCError(code: DaemonAPI.Failure.notAWorktree,
                               message: "\(facts.root.lastPathComponent) was not made by this app, so it is not this app's to remove.")
        }
        if !facts.check.blockedBy.isEmpty {
            let names = facts.check.blockedBy.compactMap { agents[$0]?.title ?? "an agent" }
            throw JSONRPCError(code: DaemonAPI.Failure.worktreeInUse,
                               message: "Still in use by \(names.joined(separator: ", ")). Archive them first.")
        }
        if facts.check.losesWork && !request.confirmed {
            throw JSONRPCError(code: DaemonAPI.Failure.worktreeFailed,
                               message: "Removing \(facts.root.lastPathComponent) would lose \(Self.whatIsLost(facts.check, base: facts.base)). Confirm to remove it anyway.")
        }
        do {
            if facts.exists {
                try await GitWorktrees.remove(facts.root, force: facts.check.uncommitted > 0, in: facts.project)
            } else {
                try await GitWorktrees.prune(in: facts.project)
            }
            var removedBranch = false
            if let branch = facts.branch, Self.isAppBranch(branch) {
                try await GitWorktrees.deleteBranch(branch, force: facts.check.unmerged, in: facts.project)
                removedBranch = true
            }
            projectChanged(forAgentIn: facts.project)
            return DaemonAPI.WorktreeRemoved(removedBranch: removedBranch)
        } catch let failure as GitWorktrees.Failure {
            throw JSONRPCError(code: DaemonAPI.Failure.worktreeFailed,
                               message: "Could not remove \(facts.root.lastPathComponent): \(failure.message)")
        }
    }

    /// Take away the worktree an agent was just archived out of, when that loses nothing:
    /// the app made it, no other agent that is not archived works in it, and everything
    /// in it is committed. Its branch goes too only when it is merged; otherwise the
    /// branch stays and holds the commits. Anything short of that leaves it all as it
    /// is, for the person to remove from the project page.
    func removeWorktreeIfDone(archiving agentID: UUID) async {
        guard let worktree = agents[agentID]?.worktree, worktree.madeByApp else { return }
        let request = DaemonAPI.WorktreeRemovalRequest(project: worktree.project, root: worktree.root,
                                                       confirmed: false)
        guard let facts = try? await removalFacts(request), facts.madeByApp, facts.exists,
              facts.check.blockedBy.isEmpty, facts.check.uncommitted == 0 else { return }
        do {
            try await GitWorktrees.remove(facts.root, force: false, in: facts.project)
            var branchNote = ""
            if let branch = facts.branch {
                if Self.isAppBranch(branch), !facts.check.unmerged {
                    try await GitWorktrees.deleteBranch(branch, force: false, in: facts.project)
                    branchNote = " and its branch, which was merged"
                } else {
                    branchNote = ". Its branch \(branch) is kept"
                }
            }
            await record(.runtimeNote("Removed the worktree \(worktree.name)\(branchNote), since everything in it was committed."),
                         for: agentID)
            projectChanged(forAgentIn: facts.project)
        } catch let failure as GitWorktrees.Failure {
            DaemonLog.shared.write("left the worktree \(facts.root.path) after archiving \(agentID): \(failure.message)")
        } catch {}
    }

    /// "3 uncommitted changes and commits not in main", as a removal confirmation says it.
    public static func whatIsLost(_ check: DaemonAPI.RemovalCheck, base: String? = nil) -> String {
        var parts: [String] = []
        if check.uncommitted == 1 { parts.append("1 uncommitted change") }
        if check.uncommitted > 1 { parts.append("\(check.uncommitted) uncommitted changes") }
        if check.unmerged { parts.append(base.map { "commits not in \($0)" } ?? "commits not merged anywhere else") }
        return parts.joined(separator: " and ")
    }

    private struct RemovalFacts {
        var project: URL
        var root: URL
        var branch: String?
        var exists: Bool
        var madeByApp: Bool
        var base: String?
        var check: DaemonAPI.RemovalCheck
    }

    private func removalFacts(_ request: DaemonAPI.WorktreeRemovalRequest) async throws -> RemovalFacts {
        let project = Project.standardize(request.project)
        guard let repository = await GitWorktrees.repository(of: project) else {
            throw JSONRPCError(code: DaemonAPI.Failure.notAWorktree,
                               message: "\(project.lastPathComponent) is not in a git repository.")
        }
        let root = Self.canonical(request.root)
        let entries = (try? await GitWorktrees.list(in: project)) ?? []
        guard let entry = entries.first(where: { Self.canonicalPath($0.path) == root.path }),
              root.path != Self.canonicalPath(repository.toplevel) else {
            throw JSONRPCError(code: DaemonAPI.Failure.notAWorktree,
                               message: "\(root.path) is not a worktree of \(project.lastPathComponent)'s repository.")
        }
        let inside = root.path + "/"
        let blockedBy = agents.values
            .filter { $0.state != .archived }
            .filter { let cwd = Self.canonicalPath($0.cwd); return cwd == root.path || cwd.hasPrefix(inside) }
            .sorted { $0.createdAt < $1.createdAt }
            .map(\.id)
        let exists = !entry.isPrunable && Self.isDirectory(root)
        let uncommitted = exists ? ((try? await GitWorktrees.statusCount(in: root)) ?? 0) : 0
        var unmerged = false
        var measuredAgainst: String?
        // Someone's own branch stays when its worktree goes, so nothing on it is lost.
        if let branch = entry.branch, Self.isAppBranch(branch) {
            // Measured against what it was made from, when an agent's record still
            // says; otherwise against what the project folder has checked out.
            let recorded = agents.values.first { $0.worktree.map { Self.canonicalPath($0.root) } == root.path }?.worktree?.base
            let base: String? = if let recorded { recorded } else { await GitWorktrees.base(in: project) }
            if let base {
                measuredAgainst = base
                unmerged = !(await GitWorktrees.isAncestor(branch, of: base, in: project))
            }
        }
        return RemovalFacts(project: project, root: root, branch: entry.branch, exists: exists,
                            madeByApp: Self.isMadeByApp(root, branch: entry.branch, in: repository),
                            base: measuredAgainst,
                            check: DaemonAPI.RemovalCheck(blockedBy: blockedBy, uncommitted: uncommitted,
                                                          unmerged: unmerged))
    }

    /// The same subfolder of the worktree the project folder is of its repository, so
    /// an agent in a worktree sees the same part of the code it would have. When that
    /// subfolder is not in the worktree's checkout, the top of the worktree.
    static func workingFolder(in root: URL, prefix: String) -> URL {
        guard !prefix.isEmpty else { return root }
        let inside = root.appending(path: prefix, directoryHint: .isDirectory)
        return isDirectory(inside) ? Project.standardize(inside) : root
    }

    /// One of the app's own: under its worktrees folder and on a branch (R6). The
    /// branch may be the app's or one it was made on; only the app's goes with it
    /// (`isAppBranch`). A detached one is not, since removing it could lose commits
    /// no branch holds.
    static func isMadeByApp(_ root: URL, branch: String?, in repository: GitWorktrees.Repository) -> Bool {
        let folder = canonicalPath(repository.worktreesFolder) + "/"
        return canonicalPath(root).hasPrefix(folder) && branch != nil
    }

    /// A branch the app made, and so the app's to delete.
    static func isAppBranch(_ branch: String) -> Bool {
        branch.hasPrefix(WorktreeName.branchPrefix)
    }

    /// What the agent's chat opens with, so where it is working is said before it does.
    static func worktreeNote(_ worktree: AgentWorktree) -> String {
        let on = worktree.branch.map { " on \($0)" } ?? ", detached"
        let from = worktree.madeByApp ? (worktree.base.map { ", from \($0)" } ?? "") : ""
        return "Working in worktree \(worktree.name)\(on)\(from)."
    }

    /// A folder's path as projects compare them, for a folder that may not be there.
    ///
    /// `Project.standardize` resolves symlinks, which for a folder that does not exist
    /// yet — the worktrees folder before the first one, a worktree someone deleted —
    /// cannot see through `/tmp` or `/var` to `/private`, and it remembers that answer.
    /// So the nearest folder that does exist is standardised, and the rest put back on.
    static func canonicalPath(_ url: URL) -> String {
        var existing = url.standardizedFileURL
        var rest: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.pathComponents.count > 1 {
            rest.insert(existing.lastPathComponent, at: 0)
            existing = existing.deletingLastPathComponent()
        }
        var path = Project.standardize(existing).path
        for component in rest { path = (path as NSString).appendingPathComponent(component) }
        return path
    }

    static func canonical(_ url: URL) -> URL {
        // The same form `Project.standardize` gives, no trailing slash, so the two compare equal.
        URL(filePath: canonicalPath(url), directoryHint: .notDirectory)
    }

    // MARK: Names held by starts in progress

    private func existingNames(in folder: URL) -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return Set(names)
    }

    private func reservedWorktreeNames(under folder: URL) -> Set<String> {
        let prefix = Self.canonicalPath(folder) + "/"
        return Set(reservedWorktreeNames.compactMap { key in
            key.hasPrefix(prefix) ? String(key.dropFirst(prefix.count)) : nil
        })
    }

    private func reserveWorktreeName(_ name: String, under folder: URL) {
        reservedWorktreeNames.insert(Self.canonicalPath(folder) + "/" + name)
    }

    private func releaseWorktreeName(_ name: String, under folder: URL) {
        reservedWorktreeNames.remove(Self.canonicalPath(folder) + "/" + name)
    }
}
