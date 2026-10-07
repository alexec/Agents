import Foundation

/// An agent starting, stopping, archiving and listing agents of its own (028).
///
/// The whole of the deciding is here, for the reason the other app tools give: the
/// helper process only relays. What makes it safe is what the caller cannot say. It
/// names no folder, because its project is its own; it can only touch agents whose
/// `startedByAgent` is itself; and every agent another agent started, across a whole
/// project, is weighed against the project's two `HelperLimit`s — how many may run, and
/// how many may be there not archived — which the person sets and no agent can. An
/// agent another agent started
/// has none of this — it is not offered the tools, and it is refused here if it calls
/// them anyway.
///
/// Nothing asks the person first, the same call the workflow tool made. What the
/// person has instead is sight: every agent started this way is an ordinary agent in
/// their list, marked with who started it, and theirs to stop, archive or talk to.
extension DaemonCore {
    // MARK: Starting

    public func startHelper(_ request: DaemonAPI.StartHelperRequest) async throws -> (note: String, agentID: UUID) {
        // Every check before the first `await`. On an actor that is the whole of the
        // lock: two starts arriving together are decided one after the other here, and
        // the place the first takes is already counted when the second is weighed.
        let caller = try helperCaller(token: request.token, refusing: "Nothing was started")
        let folder = caller.projectFolder
        let prompt = request.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            throw JSONRPCError(code: JSONRPCError.invalidParams,
                               message: "Nothing was started: say what the agent is to do.")
        }
        // A mode it names may be its own or stricter, never looser: otherwise an agent
        // kept on a short lead starts one on none and hands it the work.
        if let wanted = request.permissionMode {
            let own = inheritedMode(from: caller, runtime: caller.runtimeID)
            guard let own, ModeLooseness.isNoLooser(wanted, than: own) else {
                throw JSONRPCError(
                    code: JSONRPCError.invalidParams,
                    message: "Nothing was started: \(wanted) would let it do more without asking "
                        + "than you may (\(own ?? "your runtime's own mode")). Name no mode and it takes yours.")
            }
        }
        // Read now, while the caller's own run — if it has one — is still in flight.
        // The helper can outlive that run by hours, and a depth worked out from it then
        // would be zero.
        let depth = workflowChainDepth(causedBy: caller.id)
        // Past a limit, or behind others already waiting, it queues (#362): first in,
        // first out, so a start that finds a place free does not jump the queue.
        if let full = helperLimitRefusal(in: folder) {
            return try await queueHelper(request, prompt: prompt, caller: caller, depth: depth, full: full)
        }
        if !HelperLimit.queue(in: folder, agents: agents.inProject(folder)).isEmpty
            || reservedQueue[folder, default: 0] > 0 {
            return try await queueHelper(request, prompt: prompt, caller: caller, depth: depth, full: nil)
        }
        reservedStarts[folder, default: 0] += 1
        defer { reservedStarts[folder, default: 1] -= 1 }

        let settings = WorkflowSettings(
            permissionMode: request.permissionMode ?? inheritedMode(from: caller, runtime: request.runtime),
            runtimeID: request.runtime, model: request.model)
        let agentID: UUID
        do {
            let worktree = try await helperWorktree(request.worktree, in: folder)
            var start = try await startRequest(settings: settings, folder: folder,
                                               prompt: prompt, managesAgents: false, checksDefault: true)
            start.worktree = worktree
            start.labels = request.labels
            agentID = try await self.start(start, startedBy: caller.id, chainDepth: depth)
        } catch let refused as SettingRefused {
            throw JSONRPCError(code: JSONRPCError.invalidParams,
                               message: "Nothing was started: \(refused.detail).")
        } catch let error as JSONRPCError {
            throw JSONRPCError(code: error.code, message: "Nothing was started: \(error.message)",
                               data: error.data)
        }

        let title = agents[agentID]?.title ?? "Untitled"
        // Counted with the new agent and without its reservation, which the `defer`
        // has not yet let go of.
        var note = "Started \u{201C}\(title)\u{201D} (id \(agentID.uuidString)). "
            + "This project now has \(helperPlaces(in: folder, reservationsToIgnore: 1))."
        if let worktree = agents[agentID]?.worktree {
            note += " It is working in worktree \(worktree.name)"
                + (worktree.branch.map { " on \($0)." } ?? ".")
        }
        return (note, agentID)
    }

    /// The permission mode the caller is working in, for a helper that named none.
    ///
    /// A helper is the caller's work carried on in another conversation, so it may do
    /// what the caller may and no more — the person chose that mode for this work, and
    /// a helper that quietly started in the runtime's default would be a way round it.
    /// Only on the caller's own runtime: a mode is a runtime's own string, and the same
    /// word on another runtime is not known to be the same promise (see
    /// `WorkflowSettings`). There the helper starts as the named runtime starts.
    func inheritedMode(from caller: Agent, runtime: String?) -> String? {
        let runtimeID = runtime ?? RuntimeCatalog.defaultRuntime.id
        guard runtimeID == caller.runtimeID,
              let option = ModeMemory.modeOption(in: caller.advertisedOptions),
              let value = caller.startOptions.values[option.id] ?? option.currentValue else {
            return nil
        }
        return value.stringValue
    }

    /// What an agent wrote for `worktree`, as a choice: nothing, "new", the name of a
    /// worktree of this project's repository (030), or a branch to make one on. A name
    /// that is none of those is said, with the names there are, rather than quietly
    /// starting in the project folder.
    func helperWorktree(_ written: String?, in folder: URL) async throws -> WorktreeChoice? {
        guard let written = written?.trimmingCharacters(in: .whitespacesAndNewlines), !written.isEmpty else {
            return nil
        }
        if written.lowercased() == "new" { return .new }
        let listed = await listWorktrees(for: folder, withStatus: false)
        guard listed.isRepository else {
            throw JSONRPCError(code: DaemonAPI.Failure.notAWorktree,
                               message: "this project is not a git repository, so it has no worktrees")
        }
        let others = listed.worktrees.filter { !$0.isProjectFolder }
        if let found = others.first(where: { $0.name == written || $0.branch == written }) {
            return .existing(found.root)
        }
        if listed.branches.contains(where: { $0.name == written }) {
            return .branch(written)
        }
        let names = others.map(\.name)
        throw JSONRPCError(code: DaemonAPI.Failure.notAWorktree,
                           message: "there is no worktree called \"\(written)\" here. "
                               + (names.isEmpty ? "There are none yet; say \"new\" to make one."
                                                : "There are: \(names.joined(separator: ", ")), or say \"new\"."))
    }

    // MARK: Stopping, parking and archiving

    public func stopHelper(_ request: DaemonAPI.HelperRequest) async throws -> String {
        let (caller, target) = try helperTarget(request, doing: "stop")
        let title = target.title ?? "Untitled"
        // Nothing to stop. Said, rather than refused: the agent asked for a thing
        // that is already true, and a stop that finds nothing running is not an error.
        let isComingBack = resuming.contains(target.id) || interrupted[target.id] != nil
        // A blocked helper (039) has no turn going but has a resume coming, and
        // stopping it is how that resume is called off.
        let isBlocked = target.state == .finished && target.report?.isOpenBlock == true
        // A queued one (#362) has nothing running; stopping it takes it off the queue.
        if target.state == .queued {
            try await stop(target.id, by: .agent(caller.id))
            return "Took \u{201C}\(title)\u{201D} off the queue; it will not start. "
                + "This project now has \(helperPlaces(in: target.projectFolder))."
        }
        guard target.state.holdsRuntime || isComingBack || isBlocked else {
            return "\u{201C}\(title)\u{201D} had already stopped; nothing changed."
        }
        try await stop(target.id, by: .agent(caller.id))
        return "Stopped \u{201C}\(title)\u{201D}, freeing its running place; it keeps its other place "
            + "until it is archived. This project now has \(helperPlaces(in: target.projectFolder))."
    }

    public func parkHelper(_ request: DaemonAPI.HelperRequest) throws -> String {
        let (_, target) = try helperTarget(request, doing: "park")
        let title = target.title ?? "Untitled"
        if target.parking?.isParked == true {
            return "\u{201C}\(title)\u{201D} was already parked; nothing changed."
        }
        if case .whenTurnEnds = target.parking {
            return "\u{201C}\(title)\u{201D} will already park when its turn ends; nothing changed."
        }
        let inFlight = target.state.hasTurnInFlight
        try park(target.id)
        if inFlight {
            return "\u{201C}\(title)\u{201D} will park when its turn ends, freeing its running place then."
        }
        return "Parked \u{201C}\(title)\u{201D}, freeing its running place; it keeps its other place "
            + "until it is archived. This project now has \(helperPlaces(in: target.projectFolder))."
    }

    /// Archive an agent the caller started (#120), as the person's Archive does: its
    /// not-archived place is freed, its transcript says who archived it, and
    /// `agent.archived` says `by` another agent. The person can bring it back.
    ///
    /// Only one that has stopped working: archiving a working helper would stop it
    /// too, and a stop is a choice the agent should make out loud with `stop_agent`.
    public func archiveHelper(_ request: DaemonAPI.HelperRequest) async throws -> String {
        // Itself first, whoever it is, so even a helper hears how it is put away.
        if let callerID = appTokens[request.token],
           UUID(uuidString: request.agentID.trimmingCharacters(in: .whitespacesAndNewlines)) == callerID {
            throw JSONRPCError(code: DaemonAPI.Failure.notYours, message: Self.cannotArchiveItself)
        }
        let (caller, target) = try helperTarget(request, doing: "archive")
        let title = target.title ?? "Untitled"
        guard agentsMayArchive(in: target.projectFolder) else {
            throw JSONRPCError(code: DaemonAPI.Failure.notYours,
                               message: "Nothing changed: in this project only the person archives; they can "
                                   + "let agents archive the helpers they started in Project Settings. "
                                   + "Park \u{201C}\(title)\u{201D} with \(AppTool.parkAgent) instead.")
        }
        guard !HelperLimit.isRunning(target, comingBack: comingBack) else {
            throw JSONRPCError(code: DaemonAPI.Failure.notYours,
                               message: "Nothing changed: \u{201C}\(title)\u{201D} is still working. "
                                   + "Wait for it to finish, or stop it with \(AppTool.stopAgent) if its work "
                                   + "is no longer wanted, then archive it.")
        }
        try await archive(target.id, by: .agent(caller.id))
        return "Archived \u{201C}\(title)\u{201D}, freeing its place; the person can bring it back. "
            + "This project now has \(helperPlaces(in: target.projectFolder))."
    }

    /// What an agent hears when it tries to archive itself (#120, Alex's words).
    static let cannotArchiveItself = "Nothing changed: you can't archive yourself. Park when your turn ends "
        + "with finish_turn's afterwards: park, and the person or the agent that started you can archive you."

    // MARK: Listing

    public func listHelpers(_ request: DaemonAPI.ListHelpersRequest) throws -> String {
        let caller = try helperCaller(token: request.token, refusing: "Nothing was listed")
        let folder = caller.projectFolder
        let places = "This project has \(helperPlaces(in: folder))."
        let mine = (HelperLimit.helpers(in: folder, agents: agents.inProject(folder))
                    + HelperLimit.queue(in: folder, agents: agents.inProject(folder)))
            .filter { $0.startedByAgent == caller.id }
        // Which runtimes it may name, last (#117): live, as a tool's description is not.
        let runtimes = runtimeChoices(in: folder)
        guard !mine.isEmpty else {
            return "You have not started any agents that are still here. \(places)\n\(runtimes)"
        }
        let lines = mine.map { agent in
            "- \(agent.id.uuidString): \u{201C}\(agent.title ?? "Untitled")\u{201D} — \(helperStatus(agent))\(SessionLookup.labels(of: agent))"
        }
        return ([places] + lines + [runtimes]).joined(separator: "\n")
    }

    /// What one of an agent's own agents is doing, in a few words the agent can repeat.
    private func helperStatus(_ agent: Agent) -> String {
        if agent.parking?.isParked == true { return "parked" }
        if case .whenTurnEnds = agent.parking { return "parking when the turn ends" }
        if resuming.contains(agent.id) || interrupted[agent.id] != nil { return "coming back" }
        if agent.state == .queued {
            let position = HelperLimit.queuePosition(of: agent, among: agents.inProject(agent.projectFolder))
            return "queued" + (position.map { " (position \($0))" } ?? "")
        }
        let said = agent.report.map { ": \($0.outcome.rawValue) — \($0.message)" } ?? ""
        switch agent.state {
        case .starting: return "starting"
        case .running: return "working"
        case .waitingOnUser: return "waiting on the person"
        case .finished where agent.report?.isOpenBlock == true:
            return "blocked: " + (agent.report?.message ?? "")
        case .finished: return "finished" + said
        case .stopped:
            let why = agent.endedReason?.summary.map { " (\($0.lowercased()))" } ?? ""
            return "stopped" + why + said
        case .archived: return "archived"
        case .queued: return "queued"
        }
    }

    // MARK: The limits

    /// Agents being brought back after a restart: running, though their record has not
    /// caught up yet.
    private var comingBack: Set<UUID> { resuming.union(interrupted.keys) }

    /// "2 of 3 running, 4 of 5 not archived": the project's places as a tool result
    /// says them, with its own limits. Reserved starts count in both, since each will
    /// be a running helper the moment it is made.
    func helperPlaces(in folder: URL, reservationsToIgnore: Int = 0) -> String {
        let limits = helperLimits(in: folder)
        let reserved = max(0, reservedStarts[folder, default: 0] - reservationsToIgnore)
        let running = HelperLimit.running(in: folder, agents: agents.inProject(folder), reserved: reserved,
                                          comingBack: comingBack)
        let kept = HelperLimit.placesInUse(in: folder, agents: agents.inProject(folder), reserved: reserved)
        let queued = HelperLimit.queue(in: folder, agents: agents.inProject(folder)).count
        // The queue only once there is one, so a project that never queues reads as it did.
        let queue = queued == 0 ? "" : ", \(queued) of \(queueLimit(in: folder)) queued"
        return "\(running) of \(limits.running) running, \(kept) of \(limits.notArchived) not archived\(queue)"
    }

    /// Why one more helper cannot start in this project, naming the limit it would
    /// break and the helpers holding it; nil when it can. Both limits are said when
    /// both are full, since only one way out frees both.
    func helperLimitRefusal(in folder: URL) -> String? {
        let limits = helperLimits(in: folder)
        let reserved = reservedStarts[folder, default: 0]
        let quoted: ([Agent]) -> String = { held in
            held.isEmpty ? "" : " — " + held.map { "\u{201C}\($0.title ?? "Untitled")\u{201D}" }
                .joined(separator: ", ")
        }
        let starting = reserved == 0 ? "" : " (\(reserved) still starting)"
        var full: [String] = []
        let kept = HelperLimit.helpers(in: folder, agents: agents.inProject(folder))
        if kept.count + reserved >= limits.notArchived {
            full.append("this project already has \(kept.count + reserved) of \(limits.notArchived) "
                + "agents started by agents not yet archived\(quoted(kept))\(starting). "
                + (agentsMayArchive(in: folder)
                    ? "Archive one of yours with \(AppTool.archiveAgent) once its work is merged or abandoned, "
                        + "or ask the person to archive one, to free that place."
                    : "Only the person can archive one to free that place."))
        }
        let running = HelperLimit.runningHelpers(in: folder, agents: agents.inProject(folder), comingBack: comingBack)
        if running.count + reserved >= limits.running {
            full.append("this project already has \(running.count + reserved) of \(limits.running) "
                + "agents started by agents running\(quoted(running))\(starting). "
                + "Park or stop one of yours with \(AppTool.parkAgent) or \(AppTool.stopAgent) when its part is done, "
                + "or wait for one to finish.")
        }
        guard !full.isEmpty else { return nil }
        return full.joined(separator: " And ")
    }

    // MARK: Who may

    /// The agent a token speaks for, provided it may use these tools at all.
    private func helperCaller(token: String, refusing lead: String) throws -> Agent {
        guard let callerID = appTokens[token], let caller = agents[callerID] else {
            throw JSONRPCError(code: DaemonAPI.Failure.noSuchAgent,
                               message: "That conversation is not open any more, so nothing was changed.")
        }
        // One level only. The helper was told to leave these tools out; this is what
        // holds if a runtime offered them anyway.
        guard caller.startedByAgent == nil else {
            throw JSONRPCError(code: DaemonAPI.Failure.notYours,
                               message: "\(lead): an agent that another agent started cannot start, "
                                   + "stop, park, archive or list agents of its own.")
        }
        return caller
    }

    /// The caller, and the agent it named — provided it is the caller's to touch.
    ///
    /// In this order, so the refusal is the most useful true one: there is such an
    /// agent, it is not the caller, the caller started it, and it is still here.
    private func helperTarget(_ request: DaemonAPI.HelperRequest,
                              doing verb: String) throws -> (caller: Agent, target: Agent) {
        let caller = try helperCaller(token: request.token, refusing: "Nothing changed")
        guard let id = UUID(uuidString: request.agentID.trimmingCharacters(in: .whitespacesAndNewlines)),
              let target = agents[id] else {
            throw JSONRPCError(code: DaemonAPI.Failure.noSuchAgent,
                               message: "Nothing changed: there is no agent with that id.")
        }
        guard target.id != caller.id else {
            throw JSONRPCError(code: DaemonAPI.Failure.notYours,
                               message: verb == "park"
                                   ? "Nothing changed: an agent cannot park itself this way; "
                                       + "set afterwards to park on finish_turn."
                                   : verb == "archive" ? Self.cannotArchiveItself
                                   : "Nothing changed: an agent cannot \(verb) itself.")
        }
        guard target.startedByAgent == caller.id else {
            let whose = target.startedByAgent != nil ? "another agent started that one"
                : target.startedByWorkflow != nil ? "a workflow started that one"
                : "that is one of the person's own sessions"
            throw JSONRPCError(code: DaemonAPI.Failure.notYours,
                               message: "Nothing changed: \(whose). You can only stop, park or archive agents you started.")
        }
        guard target.state != .archived else {
            throw JSONRPCError(code: DaemonAPI.Failure.notYours,
                               message: "Nothing changed: \u{201C}\(target.title ?? "Untitled")\u{201D} is already archived.")
        }
        return (caller, target)
    }
}
