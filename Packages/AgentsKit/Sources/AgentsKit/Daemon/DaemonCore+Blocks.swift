import Foundation

/// An agent that ended its turn blocked, and the app carrying it on when the block
/// clears (039).
///
/// The deciding is all here and all on the actor. What makes one resume per block true
/// is the shape of `queueResume`: it checks and writes with no `await` between, and the
/// write that marks the block cleared is the same write that queues the prompt. Two
/// agents finishing together arrive here one after the other, and the second finds the
/// block already cleared; a daemon killed after the write finds the prompt still queued
/// and sends it, and one killed before finds the block still open and clears it then.
extension DaemonCore {
    // MARK: Reporting

    /// The block a `blocked` report carries, checked whole before anything is written.
    ///
    /// Every refusal is a sentence the agent reads and can act on — an unknown name
    /// lists the names it could have meant, and an agent that has already ended says how,
    /// so the one waiting can use what it said instead of waiting on nothing (SC-004).
    func checkedBlock(for caller: Agent, waitingOn written: [String],
                      checkAgainInMinutes minutes: Int?, at: Date) throws -> Block {
        if let minutes, !Block.checkAgainMinutes.contains(minutes) {
            throw refusal("check_again_in_minutes has to be from \(Block.checkAgainMinutes.lowerBound) "
                          + "to \(Block.checkAgainMinutes.upperBound).")
        }
        var waits: [Wait] = []
        for name in written.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where !name.isEmpty {
            let target = try waitTarget(named: name, for: caller)
            guard !waits.contains(where: { $0.agentID == target.id }) else { continue }
            waits.append(Wait(agentID: target.id, nameAtReport: target.title ?? "Untitled"))
        }
        if let path = circle(from: caller.id, through: waits.map(\.agentID)) {
            let names = path.map { "\u{201C}\(agents[$0]?.title ?? "Untitled")\u{201D}" }
            throw refusal("waiting on \(names[0]) would close a circle: "
                          + names.joined(separator: " waits on ") + " waits on you.")
        }
        return Block(waits: waits,
                     checkAgainAt: minutes.map { at.addingTimeInterval(TimeInterval($0) * 60) })
    }

    /// One name an agent wrote, as an agent it may wait on.
    private func waitTarget(named name: String, for caller: Agent) throws -> Agent {
        let project = caller.projectFolder
        let here = agents.values.filter { $0.projectFolder == project && $0.state != .archived }
        let target: Agent
        if let id = UUID(uuidString: name), let found = agents[id] {
            guard found.projectFolder == project else {
                throw refusal("\(name) is in another project. You can only wait on agents in this one.")
            }
            target = found
        } else {
            let wanted = name.lowercased()
            let matches = here.filter {
                ($0.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == wanted
            }
            switch matches.count {
            case 1:
                target = matches[0]
            case 0:
                let known = here.filter { $0.id != caller.id }.sorted { $0.createdAt < $1.createdAt }
                throw refusal("no agent in this project is called \u{201C}\(name)\u{201D}. "
                              + (known.isEmpty ? "There are no other agents here."
                                               : "The agents here are: " + Self.listing(known) + "."))
            default:
                throw refusal("\u{201C}\(name)\u{201D} could be any of "
                              + Self.listing(matches.sorted { $0.createdAt < $1.createdAt })
                              + ". Use the id.")
            }
        }
        guard target.id != caller.id else { throw refusal("you can't wait on yourself.") }
        if let how = hasEnded(target) {
            throw refusal("\u{201C}\(target.title ?? "Untitled")\u{201D} has already ended (\(how)). "
                          + "Use what it said rather than waiting on it.")
        }
        return target
    }

    /// How an agent ended, if it has — or nil when there is still something to wait
    /// for (research R3). An agent sitting in its own block has not finished; nor has
    /// one with prompts queued, or one the daemon is bringing back.
    func hasEnded(_ agent: Agent) -> String? {
        if resuming.contains(agent.id) || interrupted[agent.id] != nil { return nil }
        switch agent.state {
        case .starting, .running, .waitingOnUser:
            return nil
        case .archived:
            return "archived"
        case .stopped:
            return agent.endedReason?.summary?.lowercased() ?? "stopped"
        case .finished:
            if agent.report?.isOpenBlock == true || !agent.queuedPrompts.isEmpty
                || turnTasks[agent.id] != nil || sending.contains(agent.id) { return nil }
            guard let report = agent.report else { return "finished without saying how it went" }
            return "\(report.outcome.heading.lowercased()) — \(report.message)"
        }
    }

    /// The agents from the first one named round to the caller, if waiting on them
    /// would close a circle (research R4). The caller's own block is left out: the one
    /// being reported replaces it.
    func circle(from caller: UUID, through targets: [UUID]) -> [UUID]? {
        func openWaits(_ id: UUID) -> [UUID] {
            guard id != caller, let report = agents[id]?.report, report.isOpenBlock,
                  let block = report.block else { return [] }
            return block.waits.filter { $0.ending == nil }.map(\.agentID)
        }
        for start in targets {
            var seen: Set<UUID> = []
            var stack: [[UUID]] = [[start]]
            while let path = stack.popLast() {
                let last = path[path.count - 1]
                for next in openWaits(last) {
                    if next == caller { return path }
                    if seen.insert(next).inserted { stack.append(path + [next]) }
                }
            }
        }
        return nil
    }

    /// What an agent waited on is called now: its title, or the one it had when the
    /// block was made.
    func waitName(_ wait: Wait) -> String {
        let title = agents[wait.agentID]?.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.flatMap { $0.isEmpty ? nil : $0 } ?? wait.nameAtReport
    }

    /// What an agent is told when its blocked report is taken.
    static func blockedNote(_ block: Block?, names: (Wait) -> String) -> String {
        let block = block ?? Block()
        let named = block.waits.map { "\u{201C}\(names($0))\u{201D}" }
        var note = "Recorded. The person will see this conversation under \"Blocked\"."
        switch named.count {
        case 0: break
        case 1: note += " You will be resumed when \(named[0]) has finished"
        default:
            note += " You will be resumed when \(named.dropLast().joined(separator: ", ")) and \(named.last!) "
                + "have all finished"
        }
        if let at = block.checkAgainAt {
            let minutes = Int((at.timeIntervalSinceNow / 60).rounded())
            note += named.isEmpty ? " You will be resumed in \(max(minutes, 1)) minutes."
                                  : ", or in \(max(minutes, 1)) minutes, whichever comes first."
        } else if !named.isEmpty {
            note += "."
        }
        if named.isEmpty && block.checkAgainAt == nil {
            note += " Nothing will resume you until the person carries you on."
        }
        return note
    }

    private func refusal(_ why: String) -> JSONRPCError {
        JSONRPCError(code: JSONRPCError.invalidParams, message: "Nothing was recorded: " + why)
    }

    private static func listing(_ agents: [Agent]) -> String {
        agents.map { "\($0.id.uuidString): \u{201C}\($0.title ?? "Untitled")\u{201D}" }
            .joined(separator: ", ")
    }

    // MARK: Clearing

    /// How an agent's ending closes the waits on it, if it does (research R5): the same
    /// endings the agent-finished workflow fires on. A finish the app is about to ask
    /// about is not one — the answer's turn ends through here too — nor is a finish
    /// still sitting in a block of its own, nor a restart the daemon is about to undo.
    func waitEnding(for agent: Agent, next: AgentState, event: AgentEvent,
                    reasonThisEventSet: EndedReason?) -> WaitEnding.How? {
        switch next {
        case .finished:
            if willAskForOutcome(agentID: agent.id, reason: reasonThisEventSet) { return nil }
            if agent.report?.isOpenBlock == true { return nil }
            return .finished(outcome: agent.report?.outcome, message: agent.report?.message)
        case .stopped:
            if event == .foundDead, agent.mayBePickedUpAfterRestart { return nil }
            return .stopped(agent.endedReason)
        case .archived:
            return .archived
        case .starting, .running, .waitingOnUser:
            return nil
        }
    }

    /// Close every open wait on this agent, and say which blocked agents that touched.
    @discardableResult
    func closeWaits(on agentID: UUID, how: WaitEnding.How) -> [UUID] {
        let at = now()
        var touched: [UUID] = []
        for var agent in agents.values where agent.id != agentID {
            guard var report = agent.report, report.isOpenBlock, var block = report.block,
                  block.waits.contains(where: { $0.agentID == agentID && $0.ending == nil })
            else { continue }
            for index in block.waits.indices where block.waits[index].agentID == agentID {
                block.waits[index].ending = block.waits[index].ending ?? WaitEnding(at: at, how: how)
            }
            report.block = block
            agent.report = report
            changed(agent)
            touched.append(agent.id)
        }
        return touched
    }

    /// Resume this agent if its block has cleared. The whole of it: the one write, and
    /// then the send.
    func resumeIfCleared(_ agentID: UUID) async {
        guard let promptID = queueResume(agentID, now: now()) else { return }
        await sendResume(agentID, promptID: promptID)
    }

    /// The one write: mark the block cleared and queue the prompt that says so, or do
    /// nothing. No `await` in here, which on an actor is what makes it happen once.
    func queueResume(_ agentID: UUID, now: Date) -> UUID? {
        guard var agent = agents[agentID], agent.state == .finished,
              var report = agent.report, report.outcome == .blocked,
              var block = report.block, block.shouldResume(now: now),
              agent.queuedPrompts.isEmpty, turnTasks[agentID] == nil, !sending.contains(agentID)
        else { return nil }
        let why: Block.Clearing = (!block.waits.isEmpty && block.allWaitsClosed) ? .waits : .time
        let text = block.resumePrompt(message: report.message, name: { self.waitName($0) }, why: why)
        block.clearedAt = now
        block.clearedBy = why
        report.block = block
        agent.report = report
        let prompt = QueuedPrompt(text: text, from: .app)
        agent.queuedPrompts.append(prompt)
        changed(agent)
        return prompt.id
    }

    /// Send a queued resume, and if it cannot go, say so where the person looks
    /// (FR-018): the words come back out of the queue and the agent reports stuck, with
    /// the reason, under Needs attention.
    func sendResume(_ agentID: UUID, promptID: UUID) async {
        var failure: String?
        do {
            try await sendNextQueued(to: agentID)
        } catch {
            failure = reason(error)
        }
        guard var agent = agents[agentID], agent.queuedPrompts.first?.id == promptID,
              !agent.state.hasTurnInFlight, turnTasks[agentID] == nil, !sending.contains(agentID)
        else { return }
        // Still waiting and nothing threw: a spending limit is holding it.
        let why = failure ?? "a spending limit is holding it."
        agent.queuedPrompts.removeAll { $0.id == promptID }
        agent.report = WorkReport(outcome: .stuck,
                                  wire: "Could not carry on after the block cleared: \(why)",
                                  at: now())
        changed(agent)
        await record(.runtimeNote("Could not carry on after the block cleared: \(why)"), for: agentID)
        reconsider()
    }

    // MARK: Time and restarts

    /// Every open block whose time to check again has come (US4). Called on the
    /// workflow heartbeat, which is what catches a Mac that slept through the time.
    func resumeDueBlocks(now: Date) async {
        let due = agents.values.filter {
            $0.state == .finished && $0.report?.isOpenBlock == true
                && $0.report?.block?.isDue(now: now) == true
        }.map(\.id)
        for id in due {
            if let promptID = queueResume(id, now: now) { await sendResume(id, promptID: promptID) }
        }
    }

    /// What a restart owes the blocked (FR-020). A wait on an agent that has gone, or
    /// that ended in a way the last daemon never got to close, is closed now; a resume
    /// the last daemon queued and never sent is sent; and anything that cleared, or came
    /// due, while nothing was running is resumed — each once.
    func resumeBlocksAfterRestart() async {
        for agent in agents.values {
            guard let block = agent.report?.block, agent.report?.isOpenBlock == true else { continue }
            for wait in block.waits where wait.ending == nil {
                guard let target = agents[wait.agentID] else {
                    closeWaits(on: wait.agentID, how: .gone)
                    continue
                }
                if resuming.contains(target.id) || interrupted[target.id] != nil { continue }
                switch target.state {
                case .archived: closeWaits(on: target.id, how: .archived)
                case .stopped: closeWaits(on: target.id, how: .stopped(target.endedReason))
                case .finished where target.report?.isOpenBlock != true && target.queuedPrompts.isEmpty:
                    closeWaits(on: target.id, how: .finished(outcome: target.report?.outcome,
                                                              message: target.report?.message))
                default: break
                }
            }
        }
        // A resume queued and never sent: the block says cleared, and the prompt is
        // still first in line.
        let unsent = agents.values.filter { agent in
            agent.state == .finished && agent.report?.outcome == .blocked
                && agent.report?.block?.clearedAt != nil && agent.report?.block?.clearedBy != .dropped
                && agent.queuedPrompts.first?.from == .app
        }
        for agent in unsent {
            guard let promptID = agent.queuedPrompts.first?.id else { continue }
            await sendResume(agent.id, promptID: promptID)
        }
        let now = now()
        for id in agents.keys {
            if let promptID = queueResume(id, now: now) { await sendResume(id, promptID: promptID) }
        }
    }

    // MARK: Dropping

    /// Mark an open block dropped, so nothing is sent for it (FR-017). Nothing else:
    /// the report stays, saying what the agent was waiting on when it was put away.
    func dropBlock(_ agentID: UUID) {
        guard var agent = agents[agentID], var report = agent.report, report.isOpenBlock else { return }
        var block = report.block ?? Block()
        block.clearedAt = now()
        block.clearedBy = .dropped
        report.block = block
        agent.report = report
        changed(agent)
    }
}
