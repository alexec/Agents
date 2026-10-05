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
            return try await makeWorktree(in: repository, project: project,
                                          wanted: WorktreeName.from(prompt: prompt, now: now()))
        case .named(let name):
            return try await makeWorktree(in: repository, project: project,
                                          wanted: WorktreeName.from(prompt: name, keepingFiller: true, now: now()))
        case .existing(let root):
            return try await existingWorktree(root, in: repository, project: project)
        case .branch(let name):
            return try await makeWorktree(onBranch: name, in: repository, project: project)
        }
    }

    /// Take back the worktree a start made, when the start then failed (#212). Left, it
    /// was a folder and branch nobody held, and a retry picked a new name each time: on a
    /// full disk, the worst thing to keep doing. One chosen from what was there is left
    /// alone, and so is the branch of one made on a branch that was already there.
    func undoWorktree(_ placed: (cwd: URL, worktree: AgentWorktree)?, for choice: WorktreeChoice?) async {
        guard let worktree = placed?.worktree, let choice else { return }
        let madeBranch: Bool
        switch choice {
        case .existing: return
        case .branch: madeBranch = false
        case .new, .named: madeBranch = true
        }
        do {
            try await GitWorktrees.remove(worktree.root, force: true, in: worktree.project)
            if madeBranch, let branch = worktree.branch {
                try await GitWorktrees.deleteBranch(branch, force: true, in: worktree.project)
            }
        } catch {
            DaemonLog.shared.write("could not take back the worktree \(worktree.name) of a start that failed: \(error)")
        }
    }

    /// Where a move should put an agent (053): the folder to work in, and the worktree
    /// it is in, or none for the project folder. Makes the worktree for a new one.
    func prepareMoveTarget(_ target: MoveTarget, for agent: Agent) async throws -> (cwd: URL, worktree: AgentWorktree?) {
        let project = agent.projectFolder
        if target == .projectFolder { return (project, nil) }
        guard let repository = await GitWorktrees.repository(of: project) else {
            throw JSONRPCError(code: DaemonAPI.Failure.worktreeFailed,
                               message: "\(project.lastPathComponent) is not in a git repository, so it has no worktrees.")
        }
        switch target {
        case .projectFolder:
            return (project, nil)
        case .newWorktree(let name):
            let made = try await makeWorktree(in: repository, project: project,
                                              wanted: moveName(name, for: agent),
                                              from: agent.worktree.map { _ in agent.cwd })
            return (made.cwd, made.worktree)
        case .existing(let root):
            if Self.canonicalPath(root) == Self.canonicalPath(repository.toplevel) { return (project, nil) }
            let chosen = try await existingWorktree(root, in: repository, project: project)
            return (chosen.cwd, chosen.worktree)
        }
    }

    /// What a new worktree made by a move is called: the name the agent gave, cleaned the
    /// way a prompt is, or else its title, or else `agent-` and the time.
    func moveName(_ given: String?, for agent: Agent) -> String {
        if let given, !given.trimmingCharacters(in: .whitespaces).isEmpty {
            return WorktreeName.from(prompt: given, keepingFiller: true, now: now())
        }
        return WorktreeName.from(prompt: agent.title ?? "", now: now())
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
            throw Self.worktreeRefusal(failure.message, saying: failure.message)
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
            throw Self.worktreeRefusal(failure.message,
                                       saying: "Could not make a worktree on \(wanted): \(failure.message)")
        }
        let made = Project.standardize(root)
        let worktree = AgentWorktree(name: name, root: made, branch: wanted, project: project,
                                     base: nil, madeByApp: true)
        return (Self.workingFolder(in: made, prefix: repository.prefix), worktree)
    }

    /// A new worktree in the project's worktrees folder, on a new `agents/` branch.
    ///
    /// Made from what `from` has checked out: the project folder for a start, or the
    /// worktree an agent is moving out of (053), so its commits come along. Everything
    /// else — which repository, which folder, the exclude line, the names held — is the
    /// project's, since from inside a linked worktree git calls that worktree the top and
    /// the new one would be made inside it (053 research R4).
    private func makeWorktree(in repository: GitWorktrees.Repository, project: URL,
                              wanted: String, from: URL? = nil) async throws -> (cwd: URL, worktree: AgentWorktree) {
        let folder = repository.worktreesFolder
        let checkout = from ?? project
        // Chosen and held before the first `await`: on an actor that is the whole of
        // the lock, so two starts from the same words cannot both pick the same name.
        var taken = reservedWorktreeNames(under: folder)
        taken.formUnion(existingNames(in: folder))
        var name = WorktreeName.next(after: wanted, taken: taken)
        reserveWorktreeName(name, under: folder)
        defer { releaseWorktreeName(name, under: folder) }

        guard await GitWorktrees.hasCommit(in: checkout) else {
            throw JSONRPCError(code: DaemonAPI.Failure.worktreeFailed,
                               message: "There is no commit here yet to base a worktree on. Commit something first.")
        }
        let base = await GitWorktrees.base(in: checkout)
        do {
            try GitWorktrees.ensureExcluded(commonDir: repository.commonDir)
        } catch let failure as GitWorktrees.Failure {
            throw Self.worktreeRefusal(failure.message, saying: failure.message)
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
                    try await GitWorktrees.add(branch: branch, path: root, in: checkout)
                    let made = Project.standardize(root)
                    let worktree = AgentWorktree(name: name, root: made, branch: branch,
                                                 project: project, base: base, madeByApp: true)
                    return (Self.workingFolder(in: made, prefix: repository.prefix), worktree)
                } catch let failure as GitWorktrees.Failure {
                    let clash = failure.message.contains("already exists")
                    guard clash, attempts < 20 else {
                        throw Self.worktreeRefusal(failure.message,
                                                   saying: "Could not make a worktree: \(failure.message)")
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

    func existingWorktree(_ root: URL, in repository: GitWorktrees.Repository,
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
    ///
    /// `withStatus: false` is for a caller that needs only the names (a helper's
    /// `worktree`): no git call per worktree at all (#207).
    public func listWorktrees(for folder: URL, withStatus: Bool = true) async -> DaemonAPI.WorktreesListResponse {
        let project = Project.standardize(folder)
        guard let repository = await GitWorktrees.repository(of: project) else { return .notARepository }
        let entries = (try? await GitWorktrees.list(in: project)) ?? []
        let here = Project.standardize(repository.toplevel)
        // The checkout's own line of the list says what it is on, so neither needs a git
        // call of its own (#207). A repository with no commit lists a HEAD of zeros.
        let mine = entries.first { Self.canonicalPath($0.path) == Self.canonical(here).path }
        let hasCommit = if let head = mine?.head { head.contains { $0 != "0" } }
            else { await GitWorktrees.hasCommit(in: project) }
        let working = Array(agents.live.values)
        var summaries = entries.filter { !$0.isBare }.map { entry -> DaemonAPI.WorktreeSummary in
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
        if withStatus {
            let base: String? = if let mine, hasCommit { mine.branch ?? mine.head }
                else { await GitWorktrees.base(in: project) }
            let statuses = await Self.statuses(of: summaries, base: base, commonDir: repository.commonDir)
            for index in summaries.indices { summaries[index].status = statuses[summaries[index].root] }
        }
        // A branch checked out anywhere cannot be checked out again; its worktree is
        // already on the list.
        let checkedOut = Set(entries.compactMap(\.branch))
        let branches = hasCommit
            ? Array(((try? await GitWorktrees.branches(in: project)) ?? []).filter { !checkedOut.contains($0.name) }
                .prefix(Self.listedBranchLimit))
            : []
        return DaemonAPI.WorktreesListResponse(
            isRepository: true, canMakeNew: hasCommit,
            whyNot: hasCommit ? nil : "There is no commit here yet to base a worktree on.",
            worktrees: summaries, branches: branches)
    }

    /// The most branches a list offers to make a worktree on, most recent first (#207).
    static let listedBranchLimit = 200
    /// The most worktrees a list works out a status for (#207): the project folder and
    /// those with agents in them first. The rest are listed without one.
    static let statusedWorktreeLimit = 12

    /// Each worktree's git status, worked out side by side: a project with a dozen
    /// worktrees shouldn't wait on three dozen git calls one after another.
    ///
    /// Bounded (#207): at most `statusedWorktreeLimit` worktrees, and a status worked out
    /// before is given again while its worktree's HEAD, index and the refs it is counted
    /// against are as they were, for `WorktreeStatusCache.lifetime` at most. Every chat
    /// opened asks for this list.
    static func statuses(of worktrees: [DaemonAPI.WorktreeSummary], base: String?,
                         commonDir: URL? = nil) async -> [URL: DaemonAPI.WorktreeStatus] {
        let shown = worktrees.filter(\.exists).enumerated()
            .sorted { a, b in
                let rank = { (w: DaemonAPI.WorktreeSummary) in w.isProjectFolder ? 0 : w.agents.isEmpty ? 2 : 1 }
                return (rank(a.element), a.offset) < (rank(b.element), b.offset)
            }
            .prefix(statusedWorktreeLimit).map(\.element)
        var result: [URL: DaemonAPI.WorktreeStatus] = [:]
        var stale: [(DaemonAPI.WorktreeSummary, GitStamp?)] = []
        for worktree in shown {
            let stamp = WorktreeStatusCache.stamp(of: worktree.root, base: base, commonDir: commonDir)
            if let held = WorktreeStatusCache.shared.status(of: worktree.root, stamp: stamp, base: base) {
                result[worktree.root] = held
            } else {
                stale.append((worktree, stamp))
            }
        }
        guard !stale.isEmpty else { return result }
        return await withTaskGroup(of: (URL, DaemonAPI.WorktreeStatus?).self) { group in
            for (worktree, stamp) in stale {
                group.addTask {
                    let root = worktree.root
                    guard let uncommitted = try? await GitWorktrees.statusCount(in: root) else { return (root, nil) }
                    let tracking = await GitWorktrees.aheadBehind(in: root)
                    var unmerged: Int?
                    if !worktree.isProjectFolder, let branch = worktree.branch, let base, base != branch {
                        unmerged = await GitWorktrees.commitCount(from: base, to: branch, in: root)
                    }
                    let status = DaemonAPI.WorktreeStatus(uncommitted: uncommitted, ahead: tracking?.ahead,
                                                          behind: tracking?.behind, unmerged: unmerged)
                    WorktreeStatusCache.shared.keep(status, of: root, stamp: stamp, base: base)
                    return (root, status)
                }
            }
            for await (root, status) in group { result[root] = status }
            return result
        }
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
            await noteFolders(in: facts.root, of: facts.project)
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
            await noteFolders(in: facts.root, of: facts.project)
            projectChanged(forAgentIn: facts.project)
        } catch let failure as GitWorktrees.Failure {
            DaemonLog.shared.write("left the worktree \(facts.root.path) after archiving \(agentID): \(failure.message)")
        } catch {}
    }

    /// Mark the agents whose worktree was just removed, archived ones included: the
    /// heartbeat looks only at live agents' folders, and the rows read this mark rather
    /// than asking the host whether each worktree is there (#176).
    /// Only that project's agents are looked at.
    func noteFolders(in root: URL, of project: URL) async {
        let path = Self.canonicalPath(root)
        let members = agents.byFolder[Project.standardize(project)] ?? []
        let inIt = members.filter { id in
            guard let worktree = agents[id]?.worktree, worktree.root.lastPathComponent == root.lastPathComponent
            else { return false }
            return Self.canonicalPath(worktree.root) == path
        }
        for id in inIt { await noteFolder(of: id) }
    }

    /// Why an agent leaving a worktree with `remove` may not take it away, in words that
    /// say what would be lost, or nil when it may (#194). Like archiving, commits are not
    /// in the way: the branch stays and holds them, so a lane whose work waits for a merge
    /// still cleans up. What is in the way is what no branch would hold — a detached HEAD
    /// or a branch that is gone, whatever the agent says — and changes not committed,
    /// unless it says to discard them. `agentID` is the one leaving, so it does not count
    /// as working there.
    func whyNotRemoveLeft(_ facts: RemovalFacts, leaving agentID: UUID, discardChanges: Bool) async -> (code: Int, message: String)? {
        let name = facts.root.lastPathComponent
        guard let branch = facts.branch else {
            return (DaemonAPI.Failure.worktreeFailed,
                    "\(name) is on a detached HEAD, so removing it would leave any commits made there on no branch. Put them on a branch, or use keep.")
        }
        guard facts.madeByApp else {
            return (DaemonAPI.Failure.notAWorktree, "\(name) was not made by this app, so it is not this app's to remove. Use keep.")
        }
        let others = facts.check.blockedBy.filter { $0 != agentID }
        guard others.isEmpty else {
            let names = others.compactMap { agents[$0]?.title ?? "an agent" }
            return (DaemonAPI.Failure.worktreeInUse,
                    "\(name) is still in use by \(names.joined(separator: ", ")), so it cannot be removed. Use keep.")
        }
        guard await GitWorktrees.branchExists(branch, in: facts.project) else {
            return (DaemonAPI.Failure.worktreeFailed,
                    "\(name)'s branch \(branch) is not there any more, so removing it would leave its commits on no branch. Make the branch again, or use keep.")
        }
        if facts.check.uncommitted > 0, !discardChanges {
            let lines = (try? await GitWorktrees.status(in: facts.root)) ?? []
            return (DaemonAPI.Failure.worktreeFailed,
                    "Removing \(name) would lose \(Self.uncommittedWords(lines, count: facts.check.uncommitted)). Its commits are safe on \(branch). Commit the changes, use keep, or ask the person before calling again with discard_changes.")
        }
        return nil
    }

    /// Take away the worktree an agent has just left with `remove`, on the terms of
    /// `whyNotRemoveLeft`, checked again now that the turn is over. The branch goes too
    /// only when it is the app's and merged, as when archiving. What happened, as a
    /// sentence for the agent's chat.
    func removeLeftWorktree(_ worktree: AgentWorktree, leaving agentID: UUID, discardChanges: Bool) async throws -> String {
        let facts = try await removalFacts(DaemonAPI.WorktreeRemovalRequest(project: worktree.project,
                                                                            root: worktree.root))
        if let refusal = await whyNotRemoveLeft(facts, leaving: agentID, discardChanges: discardChanges) {
            throw JSONRPCError(code: refusal.code, message: refusal.message)
        }
        do {
            if facts.exists {
                try await GitWorktrees.remove(facts.root, force: facts.check.uncommitted > 0, in: facts.project)
            } else {
                try await GitWorktrees.prune(in: facts.project)
            }
            await noteFolders(in: facts.root, of: facts.project)
            projectChanged(forAgentIn: facts.project)
            guard let branch = facts.branch else { return "Removed the worktree \(worktree.name)." }
            if Self.isAppBranch(branch), !facts.check.unmerged {
                try await GitWorktrees.deleteBranch(branch, force: false, in: facts.project)
                return "Removed the worktree \(worktree.name) and its branch."
            }
            return "Removed the worktree \(worktree.name); its branch \(branch) is kept."
        } catch let failure as GitWorktrees.Failure {
            throw JSONRPCError(code: DaemonAPI.Failure.worktreeFailed,
                               message: "Could not remove \(worktree.name): \(failure.message)")
        }
    }

    /// "2 uncommitted changes: edited a.swift, untracked notes.txt", from `git status
    /// --porcelain` lines, naming the first few.
    static func uncommittedWords(_ lines: [String], count: Int) -> String {
        var words = count == 1 ? "1 uncommitted change" : "\(count) uncommitted changes"
        let shown = 5
        let named = lines.prefix(shown).compactMap { line -> String? in
            guard line.count > 3 else { return nil }
            let code = line.prefix(2)
            let path = String(line.dropFirst(3))
            let kind = switch code {
            case "??": "untracked"
            case _ where code.contains("D"): "deleted"
            case _ where code.contains("A"): "added"
            case _ where code.contains("R"): "renamed"
            default: "edited"
            }
            return "\(kind) \(path)"
        }
        if !named.isEmpty {
            words += ": " + named.joined(separator: ", ")
            if lines.count > shown { words += " and \(lines.count - shown) more" }
        }
        return words
    }

    /// Whether an archived agent's app-made worktree still holds work that only its
    /// conversation explains (051, FR-007): changes not committed, or commits not merged.
    /// A worktree another agent still works in is not this agent's to hold: that agent
    /// has its own record of it. One the person made is never the app's business.
    func worktreeHoldsWork(of agentID: UUID) async -> Bool {
        guard let worktree = agents[agentID]?.worktree, worktree.madeByApp else { return false }
        let request = DaemonAPI.WorktreeRemovalRequest(project: worktree.project, root: worktree.root,
                                                       confirmed: false)
        guard let facts = try? await removalFacts(request), facts.madeByApp, facts.exists,
              facts.check.blockedBy.isEmpty else { return false }
        return facts.check.losesWork
    }

    /// "3 uncommitted changes and commits not in main", as a removal confirmation says it.
    public static func whatIsLost(_ check: DaemonAPI.RemovalCheck, base: String? = nil) -> String {
        var parts: [String] = []
        if check.uncommitted == 1 { parts.append("1 uncommitted change") }
        if check.uncommitted > 1 { parts.append("\(check.uncommitted) uncommitted changes") }
        if check.unmerged { parts.append(base.map { "commits not in \($0)" } ?? "commits not merged anywhere else") }
        return parts.joined(separator: " and ")
    }

    struct RemovalFacts {
        var project: URL
        var root: URL
        var branch: String?
        var exists: Bool
        var madeByApp: Bool
        var base: String?
        var check: DaemonAPI.RemovalCheck
    }

    func removalFacts(_ request: DaemonAPI.WorktreeRemovalRequest) async throws -> RemovalFacts {
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
        // Live agents only (#218): an archived agent is in no folder.
        let blockedBy = agents.live.values
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
            // This project's agents, archived too: the one that made it may be put away.
            let recorded = agents.inProject(project)
                .first { $0.worktree.map { Self.canonicalPath($0.root) } == root.path }?.worktree?.base
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

/// Each worktree's last status and what it was worked out from (#207). Shared by every
/// list, whoever asks; a worktree that has gone is dropped when the cache is next full.
final class WorktreeStatusCache: @unchecked Sendable {
    static let shared = WorktreeStatusCache()
    /// Edits to tracked files and new untracked ones move no stamp, so a status is
    /// worked out again after this however still the stamp has been.
    static let lifetime: TimeInterval = 15
    static let capacity = 256

    private struct Held {
        var stamp: GitStamp
        var base: String?
        var status: DaemonAPI.WorktreeStatus
        var madeAt: Date
    }

    private let lock = NSLock()
    private var held: [String: Held] = [:]

    /// The worktree's own HEAD, index and log, and the refs its counts are made against:
    /// its base, its packed refs and the last fetch.
    static func stamp(of root: URL, base: String?, commonDir: URL?) -> GitStamp? {
        var also = ["packed-refs", "FETCH_HEAD"]
        if let base { also += ["refs/heads/\(base)", "logs/refs/heads/\(base)"] }
        return GitStamp.of(root, commonDir: commonDir, also: also)
    }

    func status(of root: URL, stamp: GitStamp?, base: String?, now: Date = Date()) -> DaemonAPI.WorktreeStatus? {
        guard let stamp else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard let found = held[root.path], found.stamp == stamp, found.base == base,
              now.timeIntervalSince(found.madeAt) < Self.lifetime else { return nil }
        return found.status
    }

    func keep(_ status: DaemonAPI.WorktreeStatus, of root: URL, stamp: GitStamp?, base: String?, now: Date = Date()) {
        guard let stamp else { return }
        lock.lock(); defer { lock.unlock() }
        if held.count >= Self.capacity {
            held = held.filter { now.timeIntervalSince($0.value.madeAt) < Self.lifetime }
            if held.count >= Self.capacity { held.removeAll() }
        }
        held[root.path] = Held(stamp: stamp, base: base, status: status, madeAt: now)
    }

    func forget(_ root: URL) {
        lock.lock(); defer { lock.unlock() }
        held[root.path] = nil
    }
}
