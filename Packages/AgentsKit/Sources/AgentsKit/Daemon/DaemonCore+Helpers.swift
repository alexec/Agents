import Foundation

/// An agent starting, stopping, archiving and listing agents of its own (028).
///
/// The whole of the deciding is here, for the reason the other app tools give: the
/// helper process only relays. What makes it safe is what the caller cannot say. It
/// names no folder, because its project is its own; it can only touch agents whose
/// `startedByAgent` is itself; and every agent another agent started, across a whole
/// project, shares `HelperLimit.perProject` places. An agent another agent started
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
        let inUse = HelperLimit.placesInUse(in: folder, agents: agents.values,
                                            reserved: reservedStarts[folder, default: 0])
        guard inUse < HelperLimit.perProject else {
            let names = HelperLimit.helpers(in: folder, agents: agents.values)
                .map { "\u{201C}\($0.title ?? "Untitled")\u{201D}" }
            let naming = names.isEmpty ? "" : " — " + names.joined(separator: ", ")
            throw JSONRPCError(
                code: DaemonAPI.Failure.notYours,
                message: "Nothing was started: this project already has \(HelperLimit.perProject) "
                    + "agents started by agents\(naming). Archive one to free its place.")
        }
        // Read now, while the caller's own run — if it has one — is still in flight.
        // The helper can outlive that run by hours, and a depth worked out from it then
        // would be zero.
        let depth = workflowChainDepth(causedBy: caller.id)
        reservedStarts[folder, default: 0] += 1
        defer { reservedStarts[folder, default: 1] -= 1 }

        let settings = WorkflowSettings(permissionMode: request.permissionMode,
                                        runtimeID: request.runtime, model: request.model)
        let agentID: UUID
        do {
            let worktree = try await helperWorktree(request.worktree, in: folder)
            var start = try await startRequest(settings: settings, folder: folder,
                                               prompt: prompt, managesAgents: false)
            start.worktree = worktree
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
        let now = HelperLimit.placesInUse(in: folder, agents: agents.values,
                                          reserved: reservedStarts[folder, default: 1] - 1)
        var note = "Started \u{201C}\(title)\u{201D} (id \(agentID.uuidString)). "
            + "\(now) of \(HelperLimit.perProject) places in this project are now in use."
        if let worktree = agents[agentID]?.worktree {
            note += " It is working in worktree \(worktree.name)"
                + (worktree.branch.map { " on \($0)." } ?? ".")
        }
        return (note, agentID)
    }

    /// What an agent wrote for `worktree`, as a choice: nothing, "new", the name of a
    /// worktree of this project's repository (030), or a branch to make one on. A name
    /// that is none of those is said, with the names there are, rather than quietly
    /// starting in the project folder.
    private func helperWorktree(_ written: String?, in folder: URL) async throws -> WorktreeChoice? {
        guard let written = written?.trimmingCharacters(in: .whitespacesAndNewlines), !written.isEmpty else {
            return nil
        }
        if written.lowercased() == "new" { return .new }
        let listed = await listWorktrees(for: folder)
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

    // MARK: Stopping and archiving

    public func stopHelper(_ request: DaemonAPI.HelperRequest) async throws -> String {
        let (caller, target) = try helperTarget(request, doing: "stop")
        let title = target.title ?? "Untitled"
        // Nothing to stop. Said, rather than refused: the agent asked for a thing
        // that is already true, and a stop that finds nothing running is not an error.
        let isComingBack = resuming.contains(target.id) || interrupted[target.id] != nil
        // A blocked helper (039) has no turn going but has a resume coming, and
        // stopping it is how that resume is called off.
        let isBlocked = target.state == .finished && target.report?.isOpenBlock == true
        guard target.state.holdsRuntime || isComingBack || isBlocked else {
            return "\u{201C}\(title)\u{201D} had already stopped; nothing changed."
        }
        try await stop(target.id, by: .agent(caller.id))
        return "Stopped \u{201C}\(title)\u{201D}. It keeps its place until it is archived."
    }

    public func archiveHelper(_ request: DaemonAPI.HelperRequest) async throws -> String {
        let (caller, target) = try helperTarget(request, doing: "archive")
        let folder = caller.projectFolder
        try await archive(target.id, by: .agent(caller.id))
        let now = HelperLimit.placesInUse(in: folder, agents: agents.values,
                                          reserved: reservedStarts[folder, default: 0])
        return "Archived \u{201C}\(target.title ?? "Untitled")\u{201D}. "
            + "\(now) of \(HelperLimit.perProject) places in this project are now in use."
    }

    // MARK: Listing

    public func listHelpers(_ request: DaemonAPI.ListHelpersRequest) throws -> String {
        let caller = try helperCaller(token: request.token, refusing: "Nothing was listed")
        let folder = caller.projectFolder
        let inUse = HelperLimit.placesInUse(in: folder, agents: agents.values,
                                            reserved: reservedStarts[folder, default: 0])
        let places = "\(inUse) of \(HelperLimit.perProject) places in this project are in use."
        let mine = HelperLimit.helpers(in: folder, agents: agents.values)
            .filter { $0.startedByAgent == caller.id }
        guard !mine.isEmpty else {
            return "You have not started any agents that are still here. \(places)"
        }
        let lines = mine.map { agent in
            "- \(agent.id.uuidString): \u{201C}\(agent.title ?? "Untitled")\u{201D} — \(helperStatus(agent))"
        }
        return ([places] + lines).joined(separator: "\n")
    }

    /// What one of an agent's own agents is doing, in a few words the agent can repeat.
    private func helperStatus(_ agent: Agent) -> String {
        if resuming.contains(agent.id) || interrupted[agent.id] != nil { return "coming back" }
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
        }
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
                                   + "stop, archive or list agents of its own.")
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
                               message: "Nothing changed: an agent cannot \(verb) itself.")
        }
        guard target.startedByAgent == caller.id else {
            throw JSONRPCError(code: DaemonAPI.Failure.notYours,
                               message: "Nothing changed: you can only stop or archive agents you started.")
        }
        guard target.state != .archived else {
            throw JSONRPCError(code: DaemonAPI.Failure.notYours,
                               message: "Nothing changed: \u{201C}\(target.title ?? "Untitled")\u{201D} is already archived.")
        }
        return (caller, target)
    }
}
