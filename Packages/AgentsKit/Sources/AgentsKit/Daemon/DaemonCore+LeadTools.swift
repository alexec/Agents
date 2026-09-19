import Foundation

/// What a project lead can do to the agents in its project, and what it is asked first.
///
/// The tools arrive over the MCP server every agent is already given, so this is a
/// token and a tool name rather than anything new on the wire. Only a lead is offered
/// them, and a lead only ever reaches its own folder.
///
/// The permission question is ours, not the runtime's. Whether a runtime asks before
/// calling an MCP tool is its own decision, it differs between the three, and an answer
/// given inside a runtime is invisible to us — so "always" would live somewhere we
/// cannot read and the declined calls would be missing from the transcript. Holding the
/// call here is the only design where the promise is a property of our code.
extension DaemonCore {
    /// The tools, by the names the lead calls them.
    public enum LeadTool: String, CaseIterable, Sendable {
        case listAgents = "list_agents"
        case startAgent = "start_agent"
        case promptAgent = "prompt_agent"
        case readTranscript = "read_transcript"
        case stopAgent = "stop_agent"

        /// Reads are served; anything that changes something is asked about first.
        /// The same rule 003 set for files: a read is recorded, a change is asked.
        var changesSomething: Bool {
            switch self {
            case .listAgents, .readTranscript: return false
            case .startAgent, .promptAgent, .stopAgent: return true
            }
        }

        var question: String {
            switch self {
            case .startAgent: return "Start an agent"
            case .promptAgent: return "Give an agent more to do"
            case .stopAgent: return "Stop an agent"
            case .listAgents: return "List the agents"
            case .readTranscript: return "Read an agent's transcript"
            }
        }
    }

    /// Whether the agent behind a token leads a project.
    ///
    /// The helper asks before it offers the tools, so a worker's runtime is never shown
    /// a menu it may not order from. The guard still runs on every call: this answer is
    /// a courtesy to the runtime, not the thing that keeps anyone out.
    public func isLead(token: String) -> Bool {
        guard let id = suggestionTokens[token], let agent = agents[id] else { return false }
        return agent.role == .lead
    }

    /// Answer a lead's tool call.
    ///
    /// Returns what the lead is told, which is a sentence either way: a refusal is
    /// something it reads and acts on, never a transport error it cannot see.
    public func callLeadTool(_ request: DaemonAPI.LeadToolRequest) async throws -> String {
        guard let callerID = suggestionTokens[request.token], let caller = agents[callerID] else {
            throw JSONRPCError(code: DaemonAPI.Failure.noSuchAgent,
                               message: "That conversation is not open any more.")
        }
        guard let tool = LeadTool(rawValue: request.tool) else {
            throw JSONRPCError(code: JSONRPCError.invalidParams,
                               message: "There is no tool called \(request.tool).")
        }
        if let refusal = ProjectToolGuards.check(caller: caller) {
            return refusal.message(projectName: projectName(for: caller.cwd))
        }

        let folder = Project.standardize(caller.cwd)
        let name = projectName(for: folder)

        // The target is resolved and scope-checked before anything is asked of the
        // user, so a question is never raised about an agent the lead may not touch.
        var target: Agent?
        if let id = request.agentID {
            guard let found = agents[id] else {
                return "There is no agent with that id in \(name)."
            }
            target = found
            let refusal: ProjectToolGuards.Refusal?
            switch tool {
            case .stopAgent: refusal = ProjectToolGuards.checkStop(caller: caller, target: found,
                                                                   projectName: name)
            case .promptAgent: refusal = ProjectToolGuards.checkPrompt(caller: caller, target: found,
                                                                       projectName: name)
            default: refusal = ProjectToolGuards.check(caller: caller, target: found,
                                                       projectName: name)
            }
            if let refusal { return refusal.message(projectName: name) }
        }

        if tool.changesSomething {
            let allowed = await askLeadPermission(tool: tool, caller: caller,
                                                  target: target, folder: folder)
            guard allowed else {
                await record(.runtimeNote("Declined: \(tool.question.lowercased())."), for: callerID)
                return "The user declined that. Ask them, or try something else."
            }
        }

        return try await perform(tool, request: request, caller: caller, target: target,
                                 folder: folder, projectName: name)
    }

    // MARK: Doing it

    private func perform(_ tool: LeadTool, request: DaemonAPI.LeadToolRequest,
                         caller: Agent, target: Agent?, folder: URL,
                         projectName name: String) async throws -> String {
        switch tool {
        case .listAgents:
            let workers = agents.values
                .filter { $0.role == .worker && Project.standardize($0.cwd) == folder }
                .sorted { $0.lastActivityAt > $1.lastActivityAt }
            guard !workers.isEmpty else { return "No agents in \(name) yet." }
            let lines = workers.map { worker in
                "\(worker.id.uuidString) — \(worker.title ?? "Untitled") — \(worker.group.rawValue)"
            }
            return lines.joined(separator: "\n")

        case .readTranscript:
            guard let target else { return "Say which agent to read." }
            let page = try await store.transcript(for: target.id, before: request.before,
                                                  limit: request.limit ?? 50)
            let text = page.entries.compactMap(\.text).filter { !$0.isEmpty }.joined(separator: "\n")
            return text.isEmpty ? "That agent has said nothing yet." : text

        case .startAgent:
            guard let instruction = request.text, !instruction.isEmpty else {
                return "Say what the agent should do."
            }
            guard Self.isDirectory(folder) else {
                return "\(folder.path) is not there any more."
            }
            let runtimeID = request.runtimeID ?? caller.runtimeID
            let started = try await start(DaemonAPI.StartRequest(
                runtimeID: runtimeID,
                cwd: folder,
                prompt: instruction))
            await record(.runtimeNote("Started an agent: \(request.title ?? instruction)"),
                         for: caller.id)
            return "Started. Its id is \(started.uuidString)."

        case .promptAgent:
            guard let target else { return "Say which agent to prompt." }
            guard let text = request.text, !text.isEmpty else { return "Say what to tell it." }
            try await prompt(DaemonAPI.PromptRequest(agentID: target.id, text: text))
            await record(.runtimeNote("Told \(target.title ?? "an agent"): \(text)"), for: caller.id)
            return "Queued. It will take that when its current turn ends."

        case .stopAgent:
            guard let target else { return "Say which agent to stop." }
            try await stop(target.id)
            await record(.runtimeNote("Stopped \(target.title ?? "an agent")."), for: caller.id)
            return "Stopped."
        }
    }

    // MARK: Asking

    /// Raise the ordinary permission question and wait for the ordinary answer.
    ///
    /// The window shows it the way it shows any tool call's question, and answers it
    /// through `permissions/answer` as usual. Nothing here is a second mechanism.
    private func askLeadPermission(tool: LeadTool, caller: Agent, target: Agent?,
                                   folder: URL) async -> Bool {
        let remembered = LeadAlwaysKey(folder: folder, tool: tool)
        if leadAlwaysAllowed.contains(remembered) { return true }

        let title: String
        if let target {
            title = "\(tool.question): \(target.title ?? "an agent")"
        } else {
            title = tool.question
        }
        let request = PermissionRequest(
            agentID: caller.id,
            toolCall: ToolCall(title: title, name: tool.rawValue, kind: "other"),
            options: [
                PermissionOption(optionID: "allow_once", name: "Allow", kind: .allowOnce),
                PermissionOption(optionID: "allow_always", name: "Always allow", kind: .allowAlways),
                PermissionOption(optionID: "reject_once", name: "Decline", kind: .rejectOnce),
            ])

        pendingPermissions[request.id] = Pending(request: request, agentID: caller.id)
        await record(.permissionAsked(request), for: caller.id)
        await move(caller.id, on: .permissionAsked)
        broadcast(DaemonAPI.Notification.agentPermission,
                  DaemonAPI.PermissionNotification(agentID: caller.id, request: request))

        let optionID = await withCheckedContinuation { continuation in
            leadPermissionWaiters[request.id] = continuation
        }
        if optionID == "allow_always" { leadAlwaysAllowed.insert(remembered) }
        return optionID.hasPrefix("allow")
    }

    /// Called from `answerPermission` when the question was one of ours rather than a
    /// runtime's. Returns whether it was.
    func resumeLeadPermission(_ id: UUID, optionID: String) -> Bool {
        guard let waiter = leadPermissionWaiters.removeValue(forKey: id) else { return false }
        waiter.resume(returning: optionID)
        return true
    }

    /// What this project is called, for a sentence the lead reads.
    func projectName(for folder: URL) -> String {
        projectSummary(for: folder)?.name ?? Project.standardize(folder).lastPathComponent
    }
}

/// One remembered "always", per project and per tool. Allowing a lead to start agents
/// in one project says nothing about another.
struct LeadAlwaysKey: Hashable, Sendable {
    var folder: URL
    var tool: DaemonCore.LeadTool
}
