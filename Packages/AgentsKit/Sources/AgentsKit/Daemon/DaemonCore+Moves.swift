import Foundation
import AgentsKitCore

/// Moving an agent into a worktree, or back to its project folder, during its life (053).
///
/// There is no restart here, because there does not need to be one. The runtime is let go
/// at the end of every turn, and the next turn launches a fresh one in `agent.cwd` and asks
/// it to continue its session there. So a move is only this: between those two moments,
/// make or check the place with 030's code and write the agent's folder. Whatever starts
/// the next turn — the app's own prompt after the agent's move, a queued prompt, the
/// person — starts it in the new folder (research R1).
///
/// A move asked for mid-turn waits on the record, as `pendingMove`, for the turn to end:
/// changing where a runtime works while it is working is the one thing no runtime offers.
extension DaemonCore {
    // MARK: Asking

    /// An agent moving itself, through `enter_worktree` or `exit_worktree`.
    public func moveSelf(_ request: DaemonAPI.MoveSelfRequest) async throws -> DaemonAPI.MoveAnswer {
        guard let agentID = appTokens[request.token], agents[agentID] != nil else {
            throw JSONRPCError(code: DaemonAPI.Failure.noSuchAgent,
                               message: "That conversation is not open any more, so nothing was moved.")
        }
        return try await askMove(agentID, PendingMove(target: request.target, removeLeft: request.removeLeft,
                                                      discardChanges: request.discardChanges,
                                                      askedBy: .agent, askedAt: now()))
    }

    /// The person moving an agent from its page, or taking back a move still waiting.
    public func move(_ request: DaemonAPI.MoveRequest) async throws -> DaemonAPI.MoveAnswer {
        guard var agent = agents[request.agentID] else {
            throw JSONRPCError(code: DaemonAPI.Failure.noSuchAgent, message: "That agent is not here.")
        }
        guard let target = request.target else {
            guard agent.pendingMove != nil else {
                return DaemonAPI.MoveAnswer(when: .nothing, message: "No move was waiting.", agent: agent)
            }
            agent.pendingMove = nil
            changed(agent)
            await record(.runtimeNote("Move cancelled."), for: agent.id)
            return DaemonAPI.MoveAnswer(when: .nothing, message: "Move cancelled.", agent: agents[agent.id])
        }
        return try await askMove(agent.id, PendingMove(target: target, removeLeft: request.removeLeft,
                                                       discardChanges: request.discardChanges,
                                                       askedBy: .person, askedAt: now()))
    }

    /// Check a move now, in words, and keep it for when the turn ends — or make it now,
    /// when no turn is running. Anything refused here is refused before it is stored, so
    /// the agent hears why while it can still do something about it.
    func askMove(_ agentID: UUID, _ move: PendingMove) async throws -> DaemonAPI.MoveAnswer {
        guard var agent = agents[agentID] else {
            throw JSONRPCError(code: DaemonAPI.Failure.noSuchAgent, message: "That agent is not here.")
        }
        guard agent.state != .archived else {
            throw JSONRPCError(code: DaemonAPI.Failure.noSuchAgent,
                               message: "\(agent.title ?? "That agent") is archived, so it cannot be moved.")
        }
        let project = agent.projectFolder
        guard let repository = await GitWorktrees.repository(of: project) else {
            throw JSONRPCError(code: DaemonAPI.Failure.worktreeFailed,
                               message: "Moving needs a git repository, and \(project.lastPathComponent) is not in one.")
        }

        var target = move.target
        if case .existing(let root) = target,
           Self.canonicalPath(root) == Self.canonicalPath(repository.toplevel) {
            target = .projectFolder
        }
        let here = agent.worktree.map { Self.canonicalPath($0.root) }
        switch target {
        case .projectFolder:
            guard agent.worktree != nil else {
                return DaemonAPI.MoveAnswer(when: .nothing,
                                            message: "You are not in a worktree; nothing to do.", agent: agent)
            }
        case .existing(let root):
            if here == Self.canonicalPath(root) {
                return DaemonAPI.MoveAnswer(when: .nothing,
                                            message: "Already working in \(root.lastPathComponent); nothing to do.",
                                            agent: agent)
            }
            let entries = (try? await GitWorktrees.list(in: project)) ?? []
            guard let entry = entries.first(where: { Self.canonicalPath($0.path) == Self.canonicalPath(root) }) else {
                throw JSONRPCError(code: DaemonAPI.Failure.notAWorktree,
                                   message: "\(root.path) is not a worktree of \(project.lastPathComponent)'s repository.")
            }
            guard !entry.isPrunable, Self.isDirectory(root) else {
                throw JSONRPCError(code: DaemonAPI.Failure.worktreeMissing,
                                   message: "The worktree \(root.lastPathComponent) is not there any more.")
            }
        case .newWorktree:
            guard await GitWorktrees.hasCommit(in: agent.cwd) else {
                throw JSONRPCError(code: DaemonAPI.Failure.worktreeFailed,
                                   message: "There is no commit here yet to base a worktree on. Commit something first.")
            }
        }

        if move.removeLeft {
            guard target == .projectFolder, let leaving = agent.worktree else {
                throw JSONRPCError(code: JSONRPCError.invalidParams,
                                   message: "Only a move back to the project folder can remove the worktree left.")
            }
            let facts = try await removalFacts(DaemonAPI.WorktreeRemovalRequest(project: leaving.project,
                                                                                root: leaving.root))
            guard facts.madeByApp else {
                throw JSONRPCError(code: DaemonAPI.Failure.notAWorktree,
                                   message: "\(leaving.name) was not made by this app, so it is not this app's to remove. Use keep.")
            }
            let others = facts.check.blockedBy.filter { $0 != agentID }
            guard others.isEmpty else {
                let names = others.compactMap { agents[$0]?.title ?? "an agent" }
                throw JSONRPCError(code: DaemonAPI.Failure.worktreeInUse,
                                   message: "\(leaving.name) is still in use by \(names.joined(separator: ", ")), so it cannot be removed. Use keep.")
            }
            if facts.check.losesWork && !move.discardChanges {
                throw JSONRPCError(code: DaemonAPI.Failure.worktreeFailed,
                                   message: "Removing \(leaving.name) would lose \(Self.whatIsLost(facts.check, base: facts.base)). Commit it, use keep, or ask the person before calling again with discard_changes.")
            }
        }

        var stored = move
        stored.target = target
        agent.pendingMove = stored
        changed(agent)

        let running = turnIsRunning(agentID)
        if !running {
            _ = await applyPendingMove(agentID)
            let moved = agents[agentID]
            return DaemonAPI.MoveAnswer(when: .now, message: movedMessage(moved), agent: moved)
        }
        let whereTo = await destinationWords(target, for: agent)
        let removing = move.removeLeft ? ", and remove \(agent.worktree?.name ?? "the worktree") after" : ""
        let by = move.askedBy == .person ? " (asked by you)" : ""
        await record(.runtimeNote("Will move to \(whereTo)\(removing) when this turn ends\(by)."), for: agentID)

        let uncommitted = (try? await GitWorktrees.statusCount(in: agent.cwd)) ?? 0
        let staying = uncommitted == 0
            ? "Nothing uncommitted comes with you."
            : "Nothing uncommitted comes with you (\(uncommitted) \(uncommitted == 1 ? "file here is" : "files here are") uncommitted)."
        let message = move.askedBy == .agent
            ? "Moving to \(whereTo)\(removing) when this turn ends. \(staying) End your turn to move; you will be started again there to carry on."
            : "Moving to \(whereTo)\(removing) when this turn ends."
        return DaemonAPI.MoveAnswer(when: .afterTurn, message: message, agent: agents[agentID])
    }

    /// A turn in flight, or one being sent: a move waits for either to be over.
    func turnIsRunning(_ agentID: UUID) -> Bool {
        turnTasks[agentID] != nil || sending.contains(agentID) || agents[agentID]?.state.hasTurnInFlight == true
    }

    // MARK: Moving

    /// Make the move that is waiting, if one is. Who asked, when it was made; nil when
    /// nothing moved. Never throws: a move that cannot be made leaves the agent where it
    /// was, and says why in its chat.
    @discardableResult
    func applyPendingMove(_ agentID: UUID) async -> MoveAsker? {
        guard var agent = agents[agentID], let move = agent.pendingMove else { return nil }
        agent.pendingMove = nil
        changed(agent)
        guard agent.state != .archived else { return nil }
        // Nothing should be running between turns, and a runtime left open would carry on
        // in the old folder.
        await releaseRuntime(for: agentID)

        let old = agent.cwd
        let leaving = agent.worktree
        let leftBehind = (try? await GitWorktrees.statusCount(in: old)) ?? 0
        let place: (cwd: URL, worktree: AgentWorktree?)
        do {
            place = try await prepareMoveTarget(move.target, for: agent)
        } catch {
            await record(.runtimeNote("Could not move: \(reason(error)) Still in \(Self.placeName(old, leaving))."),
                         for: agentID)
            return nil
        }
        guard var moved = agents[agentID] else { return nil }
        moved.cwd = place.cwd
        moved.worktree = place.worktree
        changed(moved)
        projectChanged(forAgentIn: moved.projectFolder)

        var note = "Moved from \(Self.placeName(old, leaving)) to "
        if let worktree = place.worktree {
            note += "worktree \(worktree.name)"
            note += worktree.branch.map { " on \($0)" } ?? ", detached"
            if worktree.madeByApp, let base = worktree.base, leaving?.branch != worktree.branch { note += ", from \(base)" }
            note += "."
        } else {
            note += "the project folder."
        }
        if leftBehind > 0 {
            note += " \(leftBehind) uncommitted \(leftBehind == 1 ? "change stayed" : "changes stayed") in \(Self.placeName(old, leaving))."
        }
        if move.removeLeft, let leaving {
            do {
                let removed = try await removeWorktree(DaemonAPI.WorktreeRemovalRequest(
                    project: leaving.project, root: leaving.root, confirmed: move.discardChanges))
                note += removed.removedBranch
                    ? " Removed the worktree \(leaving.name) and its branch."
                    : " Removed the worktree \(leaving.name)" + (leaving.branch.map { "; its branch \($0) is kept." } ?? ".")
            } catch {
                note += " Kept the worktree \(leaving.name): \(reason(error))"
            }
        }
        await record(.runtimeNote(note), for: agentID)
        moveNotes[agentID] = Self.movePreface(moved, from: old, leftBehind: leftBehind)
        return move.askedBy
    }

    /// After the agent's own move, the turn that lets it carry on. Only when nothing the
    /// person queued is waiting: their words go first, and the move's preface rides on them.
    func continueAfterMove(_ agentID: UUID) async {
        guard var agent = agents[agentID], agent.state != .archived, agent.queuedPrompts.isEmpty,
              !turnIsRunning(agentID) else { return }
        agent.queuedPrompts.append(QueuedPrompt(text: Self.carryOn, from: .app))
        changed(agent)
        do {
            try await sendNextQueued(to: agentID)
        } catch {
            await record(.runtimeNote("Could not start again after the move: \(reason(error))"), for: agentID)
        }
    }

    // MARK: Words

    /// What the app says to an agent it has just moved, as the prompt that starts it again.
    static let carryOn = "Carry on with what you were doing."

    /// What the agent is told at the start of its next turn, whoever sends it.
    static func movePreface(_ agent: Agent, from old: URL, leftBehind: Int) -> String {
        var text: String
        if let worktree = agent.worktree {
            text = "You have moved: you now work in \(agent.cwd.path), the worktree \(worktree.name)"
            text += worktree.branch.map { " on the branch \($0)." } ?? ", detached."
        } else {
            text = "You have moved back to the project folder, \(agent.cwd.path)."
        }
        if leftBehind > 0 {
            text += " What was uncommitted in \(old.path) stayed there."
        }
        return text
    }

    /// How a place reads in a sentence: the worktree's name, or "the project folder".
    static func placeName(_ folder: URL, _ worktree: AgentWorktree?) -> String {
        worktree.map { "worktree \($0.name)" } ?? "the project folder"
    }

    private func destinationWords(_ target: MoveTarget, for agent: Agent) async -> String {
        switch target {
        case .projectFolder: "the project folder"
        case .existing(let root): "the worktree \(root.lastPathComponent)"
        case .newWorktree(let name): "a new worktree like \(moveName(name, for: agent))"
        }
    }

    private func movedMessage(_ agent: Agent?) -> String {
        guard let agent else { return "Moved." }
        if let worktree = agent.worktree {
            return "Moved. Now working in the worktree \(worktree.name)\(worktree.branch.map { " on \($0)" } ?? ""), at \(agent.cwd.path)."
        }
        return "Moved. Now working in the project folder, \(agent.cwd.path)."
    }
}
