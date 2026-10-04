import AgentsKitCore
import Foundation

/// Agents whose folder has gone (#119).
///
/// A worktree removed after a merge, a project folder moved or deleted, a disk ejected:
/// the session still lists and its prompt bar still takes words. So the record says so
/// (`Agent.missingFolder`), looked at on the heartbeat and before every send, and a send,
/// Send now or unpark is refused with `folderGone` and words naming the folder, before
/// anything is queued, so the words stay in the bar that sent them (#88).
///
/// The ways on: a successor in the project folder that reads this session (065's
/// continue successor), the worktree made again from its branch, or Archive.
extension DaemonCore {
    /// Refuse, with the words the apps show, if this agent's folder is not there. Also
    /// what keeps the record's mark true at the moment somebody acts on it.
    func requireFolder(_ agentID: UUID) async throws {
        guard let agent = agents[agentID] else { return }
        if Self.isDirectory(agent.cwd) {
            if agent.missingFolder != nil { await noteFolder(of: agentID) }
            return
        }
        await noteFolder(of: agentID)
        throw JSONRPCError(code: DaemonAPI.Failure.folderGone, message: agent.folderGoneMessage)
    }

    /// Look again at every agent's folder that is not archived, and say what changed. On
    /// the heartbeat, so a worktree removed by hand shows on its row within a tick. A stat
    /// each; git is asked only when a worktree's folder has newly gone.
    func noteMissingFolders() async {
        for agent in agents.live.values {
            let gone = !Self.isDirectory(agent.cwd)
            guard gone != (agent.missingFolder != nil) else { continue }
            await noteFolder(of: agent.id)
        }
    }

    /// Set or clear one agent's mark, asking git whether its worktree's branch is kept.
    func noteFolder(of agentID: UUID) async {
        guard let agent = agents[agentID] else { return }
        var missing: MissingFolder?
        if !Self.isDirectory(agent.cwd) {
            var kept = false
            if let worktree = agent.worktree, let branch = worktree.branch, Self.isDirectory(worktree.project) {
                kept = await GitWorktrees.branchExists(branch, in: worktree.project)
            }
            missing = MissingFolder(branchKept: kept)
        }
        // Read again after git: the agent may have changed while it answered.
        guard var now = agents[agentID], now.missingFolder != missing else { return }
        now.missingFolder = missing
        changed(now)
    }

    // MARK: Ways on

    /// Start a successor in the project folder that reads this session and carries on
    /// (065's continue successor). Same runtime, choices, sandbox and labels; the person's
    /// words, if they had any in the bar, after the note saying which session it continues.
    public func continueInProject(_ request: DaemonAPI.ContinueInProjectRequest) async throws -> UUID {
        guard let agent = agents[request.agentID] else {
            throw JSONRPCError(code: DaemonAPI.Failure.noSuchAgent, message: "That agent is not here.")
        }
        let project = agent.projectFolder
        guard Self.isDirectory(project) else {
            throw JSONRPCError(code: DaemonAPI.Failure.folderGone,
                               message: "The project folder isn't there either (\(MissingFolderWords.shortPath(project))).")
        }
        let prompt = MissingFolderWords.successorPrompt(
            title: agent.title, agentID: agent.id, folder: MissingFolderWords.shortPath(agent.cwd),
            project: MissingFolderWords.shortPath(project), then: request.text)
        let id = try await start(DaemonAPI.StartRequest(
            runtimeID: agent.runtimeID, cwd: project, prompt: prompt, attachments: request.attachments,
            startOptions: agent.startOptions, additionalDirectories: agent.additionalDirectories,
            mcpServers: agent.mcpServers, requestID: request.requestID, sandbox: agent.sandboxOverride,
            labels: agent.labels.filter { $0.owner == .person }.map(\.value)))
        // The same name, so the person finds the work where they left it.
        if let title = agent.title, var successor = agents[id], successor.title == nil || !successor.titledByAgent {
            successor.title = title
            changed(successor)
        }
        return id
    }

    /// Make the worktree again from its branch, where it was, and clear the mark. Only
    /// where the branch is still there: a branch deleted with the worktree has nothing to
    /// make it from, and the person continues in the project folder instead.
    public func recreateWorktree(_ agentID: UUID) async throws -> Agent {
        guard let agent = agents[agentID] else {
            throw JSONRPCError(code: DaemonAPI.Failure.noSuchAgent, message: "That agent is not here.")
        }
        if Self.isDirectory(agent.cwd) {
            await noteFolder(of: agentID)
            return agents[agentID] ?? agent
        }
        guard let worktree = agent.worktree, let branch = worktree.branch else {
            throw JSONRPCError(code: DaemonAPI.Failure.notAWorktree,
                               message: "This agent was not in a worktree, so there is nothing to make again.")
        }
        guard Self.isDirectory(worktree.project) else {
            throw JSONRPCError(code: DaemonAPI.Failure.folderGone,
                               message: "The project folder isn't there either (\(MissingFolderWords.shortPath(worktree.project))).")
        }
        guard await GitWorktrees.branchExists(branch, in: worktree.project) else {
            await noteFolder(of: agentID)
            throw JSONRPCError(code: DaemonAPI.Failure.folderGone,
                               message: "Its branch \(branch) is not there any more, so the worktree cannot be made again.")
        }
        do {
            // The removed one may still be listed, and git will not add a path it lists.
            try? await GitWorktrees.prune(in: worktree.project)
            try await GitWorktrees.add(existing: DaemonAPI.BranchSummary(name: branch), path: worktree.root,
                                       in: worktree.project)
        } catch {
            throw JSONRPCError(code: DaemonAPI.Failure.folderGone,
                               message: "The worktree could not be made again: \(reason(error))")
        }
        await noteFolder(of: agentID)
        return agents[agentID] ?? agent
    }
}
