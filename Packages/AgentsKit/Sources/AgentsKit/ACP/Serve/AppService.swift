import Foundation

/// The MCP server the app serves every agent: the things an agent can ask of the
/// window rather than of the machine.
///
/// ACP has no way to say how the work went, no way to send a suggested prompt, and
/// no way to say "look at this file". Every `suggest` in its schema is a code edit, no
/// session update carries a follow-up, and a `resource_link` is a thing handed over
/// rather than a thing opened. What ACP does have is MCP servers, attached when a
/// session is made, and all four runtimes take them. So the app offers the agent
/// tools of its own: one that ends a turn — what one passes to `finish_turn` becomes
/// the line under the agent's name and the row of chips above the prompt — and two
/// that act mid-turn, `show_file` and `manage_workflows`. Four more act on other
/// agents — `start_agent`, `stop_agent`, `archive_agent` and `list_my_agents` (028) —
/// and are offered only to an agent the person or a workflow started. Two older names
/// for the halves of the first are still served, for conversations briefed with them.
///
/// This speaks MCP itself rather than pulling in an SDK: it is four methods of
/// JSON-RPC over a pipe, which is what `JSONRPCConnection` already does for ACP.
public actor AppService {
    /// The one call that ends a turn (023): how it went, and what to ask next. A
    /// runtime may prefix it — the Claude adapter shows it as
    /// `mcp__agents__finish_turn` — so every name here is matched on the end rather
    /// than whole.
    public static let finishTurnToolName = AppTool.finishTurn

    /// The older name for the chips half of `finishTurnToolName`, still served so a
    /// conversation briefed with it finds what it was told.
    public static let toolName = AppTool.suggestPrompts

    /// The other one: show the user a file.
    public static let showFileToolName = AppTool.showFile

    /// And the third: read and write the project's standing arrangements.
    public static let workflowToolName = AppTool.manageWorkflows

    /// And the older name for the outcome half: say how the work went, on its own.
    public static let reportOutcomeToolName = AppTool.reportOutcome

    /// And four that act on other agents (028), offered only to an agent the person or
    /// a workflow started: start one in this project, and stop, archive or list the
    /// ones this agent started.
    public static let startAgentToolName = AppTool.startAgent
    public static let stopAgentToolName = AppTool.stopAgent
    public static let archiveAgentToolName = AppTool.archiveAgent
    public static let listMyAgentsToolName = AppTool.listMyAgents
    public static let pushPullRequestToolName = AppTool.pushPullRequest
    public static let replyOnPullRequestToolName = AppTool.replyOnPullRequest
    public static let leaseResourceToolName = AppTool.leaseResource
    public static let waitForEventToolName = AppTool.waitForEvent
    public static let cancelWaitToolName = AppTool.cancelWait
    public static let publishEventToolName = AppTool.publishEvent
    public static let releaseResourceToolName = AppTool.releaseResource
    public static let listResourcesToolName = AppTool.listResources

    /// The last version of MCP this was written against. A client that asks for one it
    /// knows is answered with its own, which is what the specification says to do and
    /// what keeps this working when a runtime moves ahead of us.
    static let protocolVersion = "2025-06-18"

    /// What the daemon did with a call. The agent is told either way, so a token the
    /// daemon does not recognise reads as a refusal rather than as a silent success.
    public enum Outcome: Sendable {
        case shown(String)
        case refused(String)
    }

    /// Where a suggestion goes.
    public typealias Sink = @Sendable ([SuggestedPrompt]) async -> Outcome

    /// Where a file to show goes.
    public typealias FileSink = @Sendable (ShownFile) async -> Outcome

    /// Where a workflow question goes. Unlike the other two this can take a while:
    /// a write waits on somebody answering.
    public typealias WorkflowSink =
        @Sendable (DaemonAPI.ManageWorkflowsRequest.Action, String?, String?) async -> Outcome

    /// Where an outcome goes: the wire spelling, and the agent's own sentence. Both
    /// still strings here — the daemon owns which words it knows, because it is the
    /// daemon that has to refuse one it does not.
    public typealias OutcomeSink = @Sendable (String, String, BlockWords) async -> Outcome

    /// Where the one call goes: the outcome's wire spelling, the sentence, the chips,
    /// which may be none, and the conversation's new title. One sink rather than the
    /// two above in turn, because the daemon refuses the whole call or lands the whole
    /// call, and two sinks could do half of each.
    public typealias FinishSink = @Sendable (String, String, [SuggestedPrompt], String?, BlockWords) async -> Outcome

    /// What a `blocked` outcome carries besides its sentence (039): the agents it waits
    /// on, as written, and when to check again. Empty for every other outcome — and
    /// refused here if it is not, so the agent hears it before the call goes further.
    public struct BlockWords: Sendable, Equatable {
        public var waitingOn: [String]?
        public var checkAgainInMinutes: Int?

        public init(waitingOn: [String]? = nil, checkAgainInMinutes: Int? = nil) {
            self.waitingOn = waitingOn
            self.checkAgainInMinutes = checkAgainInMinutes
        }

        public static let none = BlockWords()
    }

    /// One of the four calls that act on other agents (028), as the agent made it.
    /// Nothing is decided here beyond whether the words are there at all: the daemon
    /// is what knows whose agent is whose.
    public enum AgentCall: Sendable, Equatable {
        case start(prompt: String, runtime: String?, model: String?, permissionMode: String?,
                   worktree: String? = nil)
        case stop(agentID: String)
        case archive(agentID: String)
        case list
    }

    /// Where those go.
    public typealias AgentsSink = @Sendable (AgentCall) async -> Outcome

    /// One of the three lease calls (036), as the agent made it.
    public enum LeaseCall: Sendable, Equatable {
        case lease(name: String, minutes: Int?, wait: Bool?)
        case release(name: String)
        case list
    }

    /// Where those go. A lease call may take up to the wait limit to come back.
    public typealias LeasesSink = @Sendable (LeaseCall) async -> Outcome

    /// One of the three event calls (042), as the agent made it.
    public enum EventCall: Sendable, Equatable {
        case wait(action: String?, events: [String]?, where: [String: String]?, from: Int64?,
                  untilMinutes: Int?, limit: Int?)
        case cancel
        case publish(name: String, message: String?, details: [String: String]?)
    }

    /// Where those go. A wait may take up to the hold limit to come back.
    public typealias EventsSink = @Sendable (EventCall) async -> Outcome

    /// One of the two pull-request calls (038), as the agent made it. Neither names a
    /// pull request, a branch or a repository: the daemon takes those from the run.
    public enum PullRequestCall: Sendable, Equatable {
        case push
        case reply(body: String, inReplyTo: Int?)
    }

    /// Where those go.
    public typealias PullRequestsSink = @Sendable (PullRequestCall) async -> Outcome

    private let connection: JSONRPCConnection
    private let finishSink: FinishSink
    private let sink: Sink
    private let fileSink: FileSink
    private let workflowSink: WorkflowSink
    private let outcomeSink: OutcomeSink
    private let agentsSink: AgentsSink
    private let leasesSink: LeasesSink
    private let eventsSink: EventsSink
    private let pullRequestsSink: PullRequestsSink
    /// Whether the four agent tools are offered. False for an agent another agent
    /// started (028), which the daemon says by starting this with `--no-agent-tools`.
    private let managesAgents: Bool
    private let box = ServiceBox()

    public init(transport: any LineTransport,
                managesAgents: Bool = true,
                finishTurn: @escaping FinishSink = { _, _, _, _, _ in
                    .refused("This app cannot end a turn.")
                },
                sink: @escaping Sink,
                showFile: @escaping FileSink = { _ in .refused("This app cannot show a file.") },
                workflows: @escaping WorkflowSink = { _, _, _ in
                    .refused("This app cannot manage workflows.")
                },
                reportOutcome: @escaping OutcomeSink = { _, _, _ in
                    .refused("This app cannot record an outcome.")
                },
                agents: @escaping AgentsSink = { _ in
                    .refused("This app cannot start or stop agents.")
                },
                pullRequests: @escaping PullRequestsSink = { _ in
                    .refused("Only a run started for a pull request can push or reply; ask the person to do it.")
                },
                leases: @escaping LeasesSink = { _ in
                    .refused("This app cannot lease resources.")
                },
                events: @escaping EventsSink = { _ in
                    .refused("This app cannot wait on or publish events.")
                }) {
        let box = self.box
        self.finishSink = finishTurn
        self.sink = sink
        self.fileSink = showFile
        self.workflowSink = workflows
        self.outcomeSink = reportOutcome
        self.agentsSink = agents
        self.leasesSink = leases
        self.eventsSink = events
        self.pullRequestsSink = pullRequests
        self.managesAgents = managesAgents
        self.connection = JSONRPCConnection(transport: transport) { method, params in
            await box.handle(method: method, params: params)
        }
        Task { await self.attach() }
    }

    private func attach() async {
        box.attach(self)
        await connection.start()
    }

    /// Answer until the runtime closes the pipe, which it does when its session ends.
    public func run() async {
        for await _ in connection.incomingNotifications() {
            // `notifications/initialized` and whatever else a client sends. None of it
            // needs an answer; draining the stream is what keeps this task alive.
        }
    }

    public func close() async {
        await connection.close()
    }

    func handle(method: String, params: JSONValue?) async -> Result<JSONValue, JSONRPCError> {
        switch method {
        case "initialize":
            let asked = params?["protocolVersion"]?.stringValue
            return .success([
                "protocolVersion": .string(asked ?? Self.protocolVersion),
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "agents", "version": "1.0.0"],
            ])

        case "ping":
            return .success([:])

        case "tools/list":
            // The one that ends a turn first, the two that act mid-turn, and the two
            // older names last, described as such (023).
            // The four agent tools after the workflow tool, and only for an agent that
            // may use them (028).
            let agentTools = managesAgents
                ? [Self.startAgentTool, Self.stopAgentTool, Self.archiveAgentTool, Self.listMyAgentsTool]
                : []
            // The three lease tools after those, for every agent: waiting for the
            // simulator is not managing anyone (036).
            let leaseTools = [Self.leaseResourceTool, Self.releaseResourceTool, Self.listResourcesTool]
            // The two pull-request tools, for every agent (038 R7): the list is fixed
            // when a session is made, and a standing or triggering run resumes a session
            // made long before. Outside such a run they refuse, in words.
            let pullRequestTools = [Self.pushPullRequestTool, Self.replyOnPullRequestTool]
            // The three event tools, for every agent (042).
            let eventTools = [Self.waitForEventTool, Self.cancelWaitTool, Self.publishEventTool]
            return .success(["tools": .array([Self.finishTurnTool, Self.showFileTool,
                                              Self.workflowTool] + agentTools + leaseTools
                                             + eventTools + pullRequestTools
                                             + [Self.tool, Self.reportOutcomeTool])])

        case "tools/call":
            let name = params?["name"]?.stringValue ?? ""
            let arguments = params?["arguments"]

            // Longest suffix wins, though nothing here shares one: a runtime is free
            // to prefix a tool's name and none of them changes what follows it.
            if name.hasSuffix(Self.finishTurnToolName) {
                // The outcome's checks are the report's, and they run here as well as
                // at the daemon so an agent that got the word wrong is told which five
                // there are before the call goes any further. The chips are cleaned
                // the way the older tool cleans them, and may come to nothing: the
                // call is the outcome; the chips ride along (FR-003).
                let raw = (arguments?["outcome"]?.stringValue ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard WorkOutcome(wire: raw) != nil else {
                    return .success(Self.reply(Self.unknownOutcome, isError: true))
                }
                let message = (arguments?["message"]?.stringValue ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !message.isEmpty else {
                    return .success(Self.reply(Self.noWords, isError: true))
                }
                // The title names the conversation's goal, which outlasts a turn, so
                // it is sent only when the goal changes: one left out, or that cleans
                // to nothing, keeps the name the row already has.
                let title = arguments?["title"]?.stringValue.flatMap(Agent.cleanedTitle)
                let prompts = SuggestedPrompt.next(one: arguments?["next_prompt"],
                                                   orFirstOf: arguments?["next_prompts"])
                let words: BlockWords
                switch Self.blockWords(raw, arguments) {
                case .success(let read): words = read
                case .failure(let problem): return .success(Self.reply(problem.message, isError: true))
                }
                return .success(Self.reply(await finishSink(raw, message, prompts, title, words)))
            }

            if name.hasSuffix(Self.toolName) {
                let prompts = SuggestedPrompt.list(in: arguments?["prompts"])
                guard !prompts.isEmpty else {
                    return .success(Self.reply("No suggestions were sent, so none are shown.",
                                               isError: true))
                }
                return .success(Self.reply(await sink(prompts)))
            }

            if name.hasSuffix(Self.showFileToolName) {
                guard let file = ShownFile(wire: arguments) else {
                    return .success(Self.reply("""
                        No file was shown: `path` has to be an absolute path, \
                        starting at `/`.
                        """, isError: true))
                }
                return .success(Self.reply(await fileSink(file)))
            }

            if name.hasSuffix(Self.workflowToolName) {
                guard let raw = arguments?["action"]?.stringValue,
                      let action = DaemonAPI.ManageWorkflowsRequest.Action(rawValue: raw) else {
                    return .success(Self.reply("""
                        Nothing was done: `action` has to be one of list, read, write \
                        or remove.
                        """, isError: true))
                }
                return .success(Self.reply(await workflowSink(action,
                                                              arguments?["id"]?.stringValue,
                                                              arguments?["content"]?.stringValue)))
            }

            if let call = Self.pullRequestCall(named: name, arguments) {
                switch call {
                case .failure(let problem): return .success(Self.reply(problem.message, isError: true))
                case .success(let call): return .success(Self.reply(await pullRequestsSink(call)))
                }
            }

            if let call = Self.eventCall(named: name, arguments) {
                switch call {
                case .failure(let problem): return .success(Self.reply(problem.message, isError: true))
                case .success(let call): return .success(Self.reply(await eventsSink(call)))
                }
            }

            if let call = Self.leaseCall(named: name, arguments) {
                switch call {
                case .failure(let problem): return .success(Self.reply(problem.message, isError: true))
                case .success(let call): return .success(Self.reply(await leasesSink(call)))
                }
            }

            if let call = Self.agentCall(named: name, arguments) {
                guard managesAgents else {
                    return .success(Self.reply("""
                        Nothing was done: an agent that another agent started cannot \
                        start, stop, archive or list agents of its own.
                        """, isError: true))
                }
                switch call {
                case .failure(let problem): return .success(Self.reply(problem.message, isError: true))
                case .success(let call): return .success(Self.reply(await agentsSink(call)))
                }
            }

            if name.hasSuffix(Self.reportOutcomeToolName) {
                // Checked here as well as at the daemon, so an agent that sent a word
                // we do not know is told which five we do before the call goes any
                // further. Never rounded to the nearest one: an unknown outcome read
                // as `done` is exactly the unearned tick this tool exists to remove.
                let raw = (arguments?["outcome"]?.stringValue ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard WorkOutcome(wire: raw) != nil else {
                    return .success(Self.reply(Self.unknownOutcome, isError: true))
                }
                let message = (arguments?["message"]?.stringValue ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !message.isEmpty else {
                    return .success(Self.reply(Self.noWords, isError: true))
                }
                switch Self.blockWords(raw, arguments) {
                case .success(let words): return .success(Self.reply(await outcomeSink(raw, message, words)))
                case .failure(let problem): return .success(Self.reply(problem.message, isError: true))
                }
            }

            return .failure(JSONRPCError(code: JSONRPCError.invalidParams,
                                         message: "No tool called \(name.isEmpty ? "that" : name)."))

        default:
            return .failure(.methodNotFound(method))
        }
    }

    /// Which of the four agent calls a tool name is, with its arguments read — or the
    /// sentence saying what was missing. `nil` when the name is none of them.
    static func agentCall(named name: String,
                          _ arguments: JSONValue?) -> Result<AgentCall, AgentCallProblem>? {
        func text(_ key: String) -> String? {
            let value = arguments?[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            return value?.isEmpty == false ? value : nil
        }
        if name.hasSuffix(startAgentToolName) {
            guard let prompt = text("prompt") else {
                return .failure("Nothing was started: say what the agent is to do, in `prompt`.")
            }
            return .success(.start(prompt: prompt, runtime: text("runtime"), model: text("model"),
                                   permissionMode: text("permission_mode"),
                                   worktree: text("worktree")))
        }
        if name.hasSuffix(stopAgentToolName) || name.hasSuffix(archiveAgentToolName) {
            guard let id = text("id") else {
                return .failure("Nothing changed: `id` has to be the id start_agent or list_my_agents gave.")
            }
            return .success(name.hasSuffix(stopAgentToolName) ? .stop(agentID: id) : .archive(agentID: id))
        }
        if name.hasSuffix(listMyAgentsToolName) {
            return .success(.list)
        }
        return nil
    }

    /// Which of the two pull-request calls a tool name is, with its arguments read.
    static func pullRequestCall(named name: String,
                                _ arguments: JSONValue?) -> Result<PullRequestCall, AgentCallProblem>? {
        if name.hasSuffix(pushPullRequestToolName) { return .success(.push) }
        if name.hasSuffix(replyOnPullRequestToolName) {
            let body = arguments?["body"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !body.isEmpty else { return .failure("Nothing was posted: say what to reply, in `body`.") }
            let inReplyTo = arguments?["in_reply_to"].flatMap { value -> Int? in
                if let number = value.intValue { return number }
                return value.stringValue.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            }
            return .success(.reply(body: body, inReplyTo: inReplyTo))
        }
        return nil
    }

    /// Which of the three lease calls a tool name is, with its arguments read. `nil`
    /// when the name is none of them.
    static func leaseCall(named name: String,
                          _ arguments: JSONValue?) -> Result<LeaseCall, AgentCallProblem>? {
        let resource = arguments?["name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // Release first: "release_resource" ends with "lease_resource", so a suffix
        // test for the lease tool matches both, and every release became an
        // extension. Found on the real app, 2026-09-25.
        if name.hasSuffix(releaseResourceToolName) {
            guard !resource.isEmpty else {
                return .failure("Nothing was released: say which resource, in `name`.")
            }
            return .success(.release(name: resource))
        }
        if name.hasSuffix(leaseResourceToolName) {
            guard !resource.isEmpty else { return .failure(AgentCallProblem(stringLiteral: LeaseWords.emptyName)) }
            let minutes = arguments?["minutes"].flatMap { value -> Int? in
                if let number = value.intValue { return number }
                return value.stringValue.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            }
            let wait = arguments?["wait"]?.boolValue
            return .success(.lease(name: resource, minutes: minutes, wait: wait))
        }
        if name.hasSuffix(listResourcesToolName) {
            return .success(.list)
        }
        return nil
    }

    /// Which of the three event calls a tool name is, with its arguments read (042).
    static func eventCall(named name: String,
                          _ arguments: JSONValue?) -> Result<EventCall, AgentCallProblem>? {
        func strings(_ value: JSONValue?) -> [String: String]? {
            guard let object = value?.objectValue else { return nil }
            var out: [String: String] = [:]
            for (key, value) in object {
                if let text = value.stringValue { out[key] = text }
                else if let number = value.intValue { out[key] = String(number) }
                else if let flag = value.boolValue { out[key] = String(flag) }
            }
            return out
        }
        func integer(_ value: JSONValue?) -> Int? {
            if let number = value?.intValue { return number }
            return value?.stringValue.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        }
        if name.hasSuffix(waitForEventToolName) {
            var events = arguments?["events"]?.arrayValue?.compactMap(\.stringValue)
            // One name given as a string rather than a list of one.
            if events == nil, let one = arguments?["events"]?.stringValue { events = [one] }
            return .success(.wait(action: arguments?["action"]?.stringValue, events: events,
                                  where: strings(arguments?["where"]),
                                  from: integer(arguments?["from"]).map(Int64.init),
                                  untilMinutes: integer(arguments?["until_minutes"]),
                                  limit: integer(arguments?["limit"])))
        }
        if name.hasSuffix(cancelWaitToolName) {
            return .success(.cancel)
        }
        if name.hasSuffix(publishEventToolName) {
            let event = arguments?["name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !event.isEmpty else {
                return .failure("Nothing was published: say what happened in `name`, e.g. custom.build_green.")
            }
            return .success(.publish(name: event, message: arguments?["message"]?.stringValue,
                                     details: strings(arguments?["details"])))
        }
        return nil
    }

    /// What was wrong with an agent call's arguments, in the sentence the agent reads.
    struct AgentCallProblem: Error, ExpressibleByStringLiteral {
        let message: String
        init(stringLiteral value: String) { message = value }
    }

    /// The two refusals an outcome can meet before it reaches the daemon, by either
    /// door. Said once here so the one call and the older name cannot drift.
    static let unknownOutcome = """
        Nothing was recorded: outcome has to be one of done, nothing_to_do, \
        needs_answer, partly_done, stuck or blocked.
        """

    /// The two block arguments, read, with contract §1's two local refusals: neither
    /// goes with any outcome but `blocked`, and the minutes are a whole number in range.
    /// Which agents exist, and whether waiting on them is allowed, is the daemon's.
    static func blockWords(_ outcome: String, _ arguments: JSONValue?)
        -> Result<BlockWords, AgentCallProblem> {
        let names = arguments?["waiting_on"]?.arrayValue?.compactMap(\.stringValue)
        let minutesValue = arguments?["check_again_in_minutes"]
        let written = (names?.isEmpty == false) || (minutesValue != nil && minutesValue != .null)
        guard outcome == WorkOutcome.blocked.rawValue else {
            return written
                ? .failure("Nothing was recorded: waiting_on and check_again_in_minutes only go with blocked.")
                : .success(.none)
        }
        var minutes: Int?
        if let minutesValue, minutesValue != .null {
            // A whole number, however the runtime spelled it: some send "25".
            let number: Int? = switch minutesValue {
            case .int(let whole): whole
            case .double(let value): value == value.rounded() ? Int(exactly: value) : nil
            case .string(let text): Int(text.trimmingCharacters(in: .whitespaces))
            default: nil
            }
            guard let number, Block.checkAgainMinutes.contains(number) else {
                return .failure(AgentCallProblem(stringLiteral: """
                    Nothing was recorded: check_again_in_minutes has to be a whole number \
                    from \(Block.checkAgainMinutes.lowerBound) to \(Block.checkAgainMinutes.upperBound).
                    """))
            }
            minutes = number
        }
        return .success(BlockWords(waitingOn: names, checkAgainInMinutes: minutes))
    }
    static let noWords = """
        Nothing was recorded: say in a sentence how it went. An outcome with no words \
        is no more use than the turn simply ending.
        """

    /// A tool result is content plus a flag, and a failure inside the tool is reported
    /// this way rather than as a JSON-RPC error: the agent is meant to read it.
    private static func reply(_ text: String, isError: Bool = false) -> JSONValue {
        ["content": .array([["type": "text", "text": .string(text)]]), "isError": .bool(isError)]
    }

    private static func reply(_ outcome: Outcome) -> JSONValue {
        switch outcome {
        case .shown(let note): return reply(note)
        case .refused(let problem): return reply(problem, isError: true)
        }
    }

    /// The one call that ends a turn (023).
    ///
    /// It says what 014's outcome tool said, and then asks for the chips the older
    /// suggestion tool asked for, in the same breath. The paragraph 014 had ordering
    /// this after `suggest_next_prompts` is gone, because there is nothing left to
    /// order. The last paragraph is 014's verbatim: the line between ending a turn
    /// and asking a question that waits still has to be drawn, and this is the one
    /// place an agent reads it at the moment it matters.
    ///
    /// `Briefing` says the harder truth about descriptions — one alone got the
    /// suggestion tool called exactly never — so this is written for an agent already
    /// told, in the briefing, to call it. The description's job is to say which of
    /// the five is true and what the chips are for.
    static let finishTurnTool: JSONValue = [
        "name": .string(finishTurnToolName),
        "title": "Finish the turn",
        "description": """
            Call this once, as the very last thing you do before you stop. It says how \
            the work actually went, and it is the only thing that does: without it the \
            app can only say your turn ended, which it will show as an ending nobody \
            accounted for.

            Pick the one that is true:

              done            You did what was asked. Nothing is left for anyone.
              nothing_to_do   You looked, and there was nothing that needed doing.
              needs_answer    You cannot go further until the person answers something.
              partly_done     You did some of it. The rest needs a decision that is not yours.
              stuck           You could not do it, and you know why.
              blocked         You are waiting on something other than the person:
                              agents you started, another agent's change, a CI run.

            For blocked, name the agents in waiting_on and you will be resumed, with \
            how each one ended, once they have all finished; for something the app \
            can't see, say what it is and give check_again_in_minutes. It is not for a \
            question to the person (that is needs_answer) or a dead end (that is stuck). \
            Your turn ends and costs nothing while you wait — and anything you started \
            in the background stops with it, so never block on a command of your own: \
            wait for that in this turn.

            The message is one or two sentences in your own words, and it is what the \
            person reads on the row before they open anything — so write it for \
            somebody who has not read the conversation. For needs_answer, the message \
            is the question itself.

            The title is the name on that row: a few words naming what the person \
            wants from this conversation — its goal, not the step you just took — \
            like "Login redirect" or "Test account for staging". Send it on your \
            first turn, and again only when the person moves the conversation on to \
            a different goal; leave it out otherwise and the name stays as it is. \
            What you did this turn belongs in the message, not here. Do not put the \
            outcome in it.

            With it, offer the one thing the person is most likely to want to say next, \
            which waits in their empty prompt for them to take. Take it from the work \
            you just did: what you did not do, a check worth running, a decision you \
            had to guess at, the obvious next step. Write it as a prompt the person \
            would send you, in the second person ("Run the tests and fix what fails"). \
            Leave it out only if there is genuinely nothing worth asking next. Say \
            nothing in your reply about having called this.

            If you can carry on once you have an answer, do not use this: ask with your \
            question or form tool, which stops and waits for them. This one does not \
            wait. It is how you end.
            """,
        "inputSchema": [
            "type": "object",
            "properties": [
                "outcome": [
                    "type": "string",
                    "enum": .array(["done", "nothing_to_do", "needs_answer",
                                    "partly_done", "stuck", "blocked"]),
                    "description": "The one that is true.",
                ],
                "message": [
                    "type": "string",
                    "description": """
                        One or two sentences, for somebody who has not read the \
                        conversation. For needs_answer, the question itself.
                        """,
                ],
                "title": [
                    "type": "string",
                    "description": """
                        A few words naming the conversation's goal, which becomes \
                        the name on its row. Send it on the first turn and when the \
                        goal changes; leave it out to keep the name as it is.
                        """,
                ],
                "waiting_on": [
                    "type": "array",
                    "items": ["type": "string"],
                    "description": """
                        Only with blocked. The agents in this project you are waiting on, \
                        by id (as start_agent or list_my_agents gave it) or by exact \
                        title. You will be resumed once every one has finished.
                        """,
                ],
                "check_again_in_minutes": [
                    "type": "integer",
                    "minimum": 1,
                    "maximum": 1440,
                    "description": """
                        Only with blocked. When to be resumed anyway, to check on \
                        something the app can't see, like a CI run or a review.
                        """,
                ],
                // One, since 031. The list this replaced is still read by the
                // handler, for a conversation told about it before, but no longer
                // offered: a fresh agent shown both would send both.
                "next_prompt": [
                    "type": "object",
                    "description": """
                        The one thing the person is most likely to say next. Leave out \
                        if there is nothing worth asking.
                        """,
                    "properties": [
                        "label": ["type": "string",
                                  "description": "Two to five words naming it, e.g. \"Run the tests\"."],
                        "prompt": ["type": "string",
                                   "description": "The prompt itself, addressed to you, which goes into their prompt box when they take it."],
                    ],
                    "required": .array(["label", "prompt"]),
                ],
            ],
            "required": .array(["outcome", "message"]),
        ],
    ]

    // The two older names. Kept because the briefing that named them is sent once
    // and lives in the runtime's history, so a conversation begun before 2026-09-23
    // and resumed after it calls these and has to find them. Listed, because some
    // runtimes check a name against the list before calling it; described as the
    // older names, because a fresh agent reading the whole list should be pointed at
    // the one tool rather than left to pick. Their schemas and rules are untouched,
    // but for the ceiling on the list below: since 031 only the first is kept, and a
    // conversation told "up to four" must not be refused by a runtime checking the
    // count against the schema before it calls.
    //
    // Removing them is deleting these two entries, their two branches in `handle`,
    // their two sinks in the helper, and their two predicates in `PermissionRequest`.
    // Nothing else may come to depend on them (023 FR-014).

    /// The older name for the chips half of `finishTurnTool`.
    static let tool: JSONValue = [
        "name": .string(toolName),
        "title": "Suggest what to ask next (older name)",
        "description": """
            The older name for the suggestions half of finish_turn. Use finish_turn \
            instead: it takes the same prompts and the outcome together. This still \
            works, and shows the first prompt in the person's empty prompt.
            """,
        "inputSchema": [
            "type": "object",
            "properties": [
                "prompts": [
                    "type": "array",
                    "minItems": .int(1),
                    "description": "The suggestions, best first. Only the first is shown.",
                    "items": [
                        "type": "object",
                        "properties": [
                            "label": ["type": "string",
                                      "description": "Two to five words for the button, e.g. \"Run the tests\"."],
                            "prompt": ["type": "string",
                                       "description": "The prompt itself, addressed to you, which goes into their prompt box when they tap it."],
                        ],
                        "required": .array(["label", "prompt"]),
                    ],
                ],
            ],
            "required": .array(["prompts"]),
        ],
    ]

    /// Put a file in front of the person, where they are already reading.
    ///
    /// The description says what it is not, as well as what it is. An agent that has
    /// just written a file will call this on every file it touched unless it is told
    /// that the pane already marks those, and a sidebar that opens itself six times a
    /// turn is worse than one that never does.
    static let showFileTool: JSONValue = [
        "name": .string(showFileToolName),
        "title": "Show the person a file",
        "description": """
            Open a file in the app's files pane, beside the conversation, at the line \
            you name. Use it when the person needs to be looking at something to \
            follow what you are saying: the function you are about to change, the \
            config that explains the failure, the test that is wrong.

            A Markdown file opens as a page the person reads and can type on, and the \
            page follows your edits: each time you change the file, the page shows \
            what changed and goes there. So when you begin writing a document, show \
            it once, at the start, and then just write — a Markdown file does not \
            have to exist yet; the page opens empty and fills as you write it. A \
            line you name on a Markdown file takes them to the part of the page that \
            holds it. For a diagram or a graph, write an SVG file beside the \
            document and reference it as an image.

            It shows; it does not edit, select or run anything. Any other file has \
            to exist, and every file has to be inside the folders this agent was \
            given.

            Not for every file you touch. Files you changed are already marked in that \
            pane, and every edit you make is already in the conversation, so calling \
            this on each one takes the person's window away from them for nothing. \
            One file, when there is one worth looking at.
            """,
        "inputSchema": [
            "type": "object",
            "properties": [
                "path": ["type": "string",
                         "description": "The absolute path of the file to open."],
                "line": ["type": "integer",
                         "minimum": .int(1),
                         "description": """
                            The line to put them on, counted from one. Leave it out \
                            for the top of the file.
                            """],
            ],
            "required": .array(["path"]),
        ],
    ]

    /// Read and write the project's workflows.
    ///
    /// One tool with an action rather than four, because that is how the surface reads
    /// to a model: an agent that has found this once knows the whole of it.
    ///
    /// This one is named in the `Briefing` as well as offered here, because an agent
    /// that does not know the app owns standing arrangements writes a crontab instead.
    /// What the briefing is careful about is the other half: it says to use this when
    /// asked, and not to invent a workflow nobody asked for, which is the behaviour the
    /// chain-depth limit exists to contain.
    static let workflowTool: JSONValue = [
        "name": .string(workflowToolName),
        "title": "Manage this project's workflows",
        "description": .string("""
            List, read, create, change and remove this project's agentic workflows. A \
            workflow is a prompt that runs itself when something happens — on a \
            schedule, or when an agent finishes, asks for permission, raises a form, \
            or stops, or on any event below.

            A workflow is a Markdown file with YAML front matter. The front matter says \
            what makes it run (`on:`) and which agent runs it (`agent:` — `new`, \
            `standing`, or `triggering`); everything under the front matter is the \
            prompt, sent verbatim.

            A workflow may also say how its agent runs: `permission-mode:` (the \
            runtime's own mode, e.g. a read-only or plan mode), `runtime:`, `model:`, \
            `effort:` (how hard it thinks, e.g. `low` or `high`), and under \
            `options:` any other option the runtime offers, by its own id — for \
            example `fast: true` for fast mode. Leave them out and it runs on the \
            default runtime with that runtime's own defaults. Set `permission-mode:` \
            when the person says the workflow must not change anything — a workflow \
            runs unattended, so this is the only chance to say so. A value the runtime \
            does not offer stops the workflow running rather than falling back.

            Once its runtime has been used in this project, reading a workflow also \
            lists what that runtime offers for each of these, in the words the file \
            takes. To change how an existing workflow runs, \
            read it, then write it back whole with the settings changed.

            Nothing here asks the person first. Creating or changing a workflow takes \
            effect at once and it is live straight away; removing one deletes its file. \
            The person has their say afterwards, on the project page, where they can \
            run a workflow or archive it — so write one only when they asked for it, \
            and tell them what you wrote.

            Under on:, besides schedule and today's hyphenated names (agent-finished and \
            the rest), any event name works, narrowed by its details written under it, \
            e.g. `- pull_request.merged:` with `number: 41` under it.
            """ + "\n" + EventCatalogue.describe()),
        "inputSchema": [
            "type": "object",
            "properties": [
                "action": [
                    "type": "string",
                    "enum": .array(["list", "read", "write", "remove"]),
                    "description": "What to do.",
                ],
                "id": [
                    "type": "string",
                    "description": """
                        The workflow's file name without its extension, e.g. \
                        `morning-build-check`. Required for read, write and remove.
                        """,
                ],
                // The example carries `permission-mode:` so the shape an agent copies
                // is the shape with the setting in it. `WorkflowExample.prompt` had to
                // name the tool because two runtimes went and wrote a crontab instead;
                // the same lesson applies to showing the key rather than describing it.
                "content": [
                    "type": "string",
                    "description": """
                        The whole file, front matter and prompt. Required for write. \
                        For example:

                        ---
                        on:
                          - schedule:
                              at: [":00"]
                              between: "09:00-09:00"
                              days: [mon, tue, wed, thu, fri]
                        agent: new
                        permission-mode: plan
                        ---

                        Check the build and say whether it is green.
                        """,
                ],
            ],
            "required": .array(["action"]),
        ],
    ]

    /// Start an agent in this project (028).
    ///
    /// The description carries the limits because the agent needs them before it
    /// calls, not in a refusal after: this project only, three at once across the
    /// project, archiving gives a place back. And the restraint, as the workflow tool
    /// carries its own — an agent told it can start agents will start agents.
    static let startAgentTool: JSONValue = [
        "name": .string(startAgentToolName),
        "title": "Start an agent in this project",
        "description": """
            Start another agent in this project, with a prompt of its own, to do a part \
            of the work that can run alongside the rest. It starts in this project's \
            folder — there is no way to start one anywhere else — and appears in the \
            person's list of agents, marked as started by you. The person can open it, \
            talk to it, stop it or archive it at any time.

            At most three agents started by agents can exist in this project at once, \
            counting every agent here, and stopped or finished ones still count. \
            Archiving one with archive_agent frees its place. Use list_my_agents to see \
            yours and how many places are in use.

            Start one only when part of the work can genuinely run alongside the rest. \
            Do not start one for work you could simply do yourself. The agent you \
            start cannot start agents of its own.

            Returns the new agent's id, which stop_agent and archive_agent take.
            """,
        "inputSchema": [
            "type": "object",
            "properties": [
                "prompt": [
                    "type": "string",
                    "description": "What the new agent is to do. Sent to it as its first message.",
                ],
                "runtime": [
                    "type": "string",
                    "description": "Optional. The runtime to run it on, as a workflow's `runtime:`.",
                ],
                "model": [
                    "type": "string",
                    "description": "Optional. The model, as a workflow's `model:`.",
                ],
                "permission_mode": [
                    "type": "string",
                    "description": """
                        Optional. The runtime's own permission mode, as a workflow's \
                        `permission-mode:` — e.g. a read-only or plan mode. Leave out \
                        to start it in the mode you are in now, when it runs on your \
                        runtime.
                        """,
                ],
                "worktree": [
                    "type": "string",
                    "description": """
                        Optional. Where the new agent works. Leave out to work in the \
                        project folder. "new" makes a fresh git worktree, on its own \
                        branch, named from the prompt — for parallel work that should \
                        not touch the same files. Or the name of a worktree of this \
                        repository that is already there, as `git worktree list` shows it. \
                        Or the name of a branch not checked out anywhere, local or on a \
                        remote, to make a fresh worktree on that branch.
                        """,
                ],
            ],
            "required": .array(["prompt"]),
        ],
    ]

    /// The id schema stop and archive share.
    private static let agentIDSchema: JSONValue = [
        "type": "object",
        "properties": [
            "id": [
                "type": "string",
                "description": "The id start_agent or list_my_agents gave.",
            ],
        ],
        "required": .array(["id"]),
    ]

    static let stopAgentTool: JSONValue = [
        "name": .string(stopAgentToolName),
        "title": "Stop an agent you started",
        "description": """
            Stop an agent you started with start_agent, as the person's own Stop would. \
            It stays in the list with its conversation, and keeps its place until it is \
            archived. Only agents you started can be stopped this way; not yourself, \
            and not anyone else's.
            """,
        "inputSchema": agentIDSchema,
    ]

    static let archiveAgentTool: JSONValue = [
        "name": .string(archiveAgentToolName),
        "title": "Archive an agent you started",
        "description": """
            Archive an agent you started with start_agent, as the person's own Archive \
            would, stopping it first if it is working. This gives its place in the \
            project back. Only agents you started can be archived this way; not \
            yourself, and not anyone else's.
            """,
        "inputSchema": agentIDSchema,
    ]

    static let listMyAgentsTool: JSONValue = [
        "name": .string(listMyAgentsToolName),
        "title": "List the agents you started",
        "description": """
            The agents you started with start_agent that have not been archived: each \
            one's id, what it is doing, and what it last said about its work. Also how \
            many of this project's three places are in use.
            """,
        "inputSchema": ["type": "object", "properties": .object([:])],
    ]

    // MARK: Pull requests (038). Words from contracts/pull-requests.md.

    static let pushPullRequestTool: JSONValue = [
        "name": .string(pushPullRequestToolName),
        "title": "Push to the pull request",
        "description": """
            Push this worktree's commits to the pull request you were started for. Never \
            force-pushes: if the remote has commits you don't, bring them in first and \
            push again. Only works in a run started for a pull request.
            """,
        "inputSchema": ["type": "object", "properties": .object([:])],
    ]

    static let replyOnPullRequestTool: JSONValue = [
        "name": .string(replyOnPullRequestToolName),
        "title": "Reply on the pull request",
        "description": """
            Reply on the pull request you were started for. Give in_reply_to (a comment \
            id from your prompt) to answer a review comment in its thread; leave it out \
            to comment on the pull request itself.
            """,
        "inputSchema": [
            "type": "object",
            "properties": [
                "body": ["type": "string"],
                "in_reply_to": ["type": "integer"],
            ],
            "required": .array(["body"]),
        ],
    ]

    // MARK: Events (042). Words from contracts/event-tools.md.

    static let waitForEventTool: JSONValue = [
        "name": .string(waitForEventToolName),
        "title": "Wait for something to happen",
        "description": """
            Wait until something happens: an event in this project or on this Mac, such as \
            pull_request.checks_passed, agent.finished, mac.wake or custom.build_green. Your \
            turn can end while you wait, and it costs nothing: when the event happens you \
            are started again with it. The call itself waits up to 45 seconds; if nothing \
            has happened by then it says you are still waiting and keeps your place. Use \
            this instead of polling. Also lists recent events (action "recent") and every \
            event you can wait on (action "list"). The same names work as workflow triggers.
            """,
        "inputSchema": [
            "type": "object",
            "properties": [
                "action": [
                    "type": "string",
                    "enum": ["wait", "recent", "list"],
                    "description": "wait (the default), recent, or list.",
                ],
                "events": [
                    "type": "array",
                    "items": ["type": "string"],
                    "description": """
                        What to wait for; any one will do. A name, or a subject with .* such \
                        as pull_request.*.
                        """,
                ],
                "where": [
                    "type": "object",
                    "description": """
                        Narrow them by their details, e.g. {"number": "41"} or \
                        {"agent": "Fix login"}.
                        """,
                ],
                "from": [
                    "type": "integer",
                    "description": """
                        Only events after this position count. Take it from recent, so that \
                        nothing between checking and waiting is missed.
                        """,
                ],
                "until_minutes": [
                    "type": "integer",
                    "description": "Give up after this many minutes, 1 to 1440. You are started again either way.",
                ],
                "limit": [
                    "type": "integer",
                    "description": "For recent: how many, 1 to 50. Default 20.",
                ],
            ],
        ],
    ]

    static let cancelWaitTool: JSONValue = [
        "name": .string(cancelWaitToolName),
        "title": "Stop waiting",
        "description": "Stop waiting. Nothing will start you again for the wait you had.",
        "inputSchema": ["type": "object", "properties": [:]],
    ]

    static let publishEventTool: JSONValue = [
        "name": .string(publishEventToolName),
        "title": "Say that something happened",
        "description": """
            Tell other agents and workflows in this project that something happened. The \
            name must start with custom., e.g. custom.build_green. Agents waiting on it are \
            started, and workflows that trigger on it run. At most 30 an hour.
            """,
        "inputSchema": [
            "type": "object",
            "properties": [
                "name": [
                    "type": "string",
                    "description": "custom. and lowercase letters, digits and _, up to 40 characters.",
                ],
                "message": [
                    "type": "string",
                    "description": "A short message for whoever wakes on it, up to 500 characters.",
                ],
                "details": [
                    "type": "object",
                    "description": "Up to 10 string details, which waits and workflows can narrow by.",
                ],
            ],
            "required": .array(["name"]),
        ],
    ]

    // MARK: Leases (036). Words from contracts/lease-tools.md.

    static let leaseResourceTool: JSONValue = [
        "name": .string(leaseResourceToolName),
        "title": "Take a turn with a shared resource",
        "description": """
            Take a turn with something on this Mac that only one agent should use at a \
            time: a simulator, a browser, the screen (mouse, keyboard, front window), or \
            anything you name, such as a port. Lease it before you use it, and release it \
            as soon as you are done. If you already hold it, this extends your lease. If \
            someone else holds it, this waits for up to 45 seconds. If it is still not \
            yours after that, you keep your place in line. You can call this again to go \
            on waiting, or end your turn, and you will be started again when it is yours. \
            Take several resources in the same order every time. Use list_resources to \
            see the names.
            """,
        "inputSchema": [
            "type": "object",
            "properties": [
                "name": [
                    "type": "string",
                    "description": """
                        A name from list_resources, a simulator's UDID, a browser's name, \
                        or any name of your own. Case and surrounding spaces don't matter.
                        """,
                ],
                "minutes": [
                    "type": "integer",
                    "description": "How long. Default 30, at most 240.",
                ],
                "wait": [
                    "type": "boolean",
                    "description": """
                        Default true. With false, you are told at once whether you got \
                        it, and you don't join the line.
                        """,
                ],
            ],
            "required": .array(["name"]),
        ],
    ]

    static let releaseResourceTool: JSONValue = [
        "name": .string(releaseResourceToolName),
        "title": "Give back a shared resource",
        "description": """
            Give back a lease you hold, or leave the line for a resource you are waiting \
            for. Do this as soon as you are done with it, so the next agent can have it.
            """,
        "inputSchema": [
            "type": "object",
            "properties": [
                "name": ["type": "string", "description": "The resource, as you leased it."],
            ],
            "required": .array(["name"]),
        ],
    ]

    static let listResourcesTool: JSONValue = [
        "name": .string(listResourcesToolName),
        "title": "List shared resources",
        "description": """
            List what can be leased on this Mac and who holds what, with your own leases \
            and waits first.
            """,
        "inputSchema": ["type": "object", "properties": .object([:])],
    ]

    /// The older name for the outcome half of `finishTurnTool`. See `tool`.
    static let reportOutcomeTool: JSONValue = [
        "name": .string(reportOutcomeToolName),
        "title": "Say how the work went (older name)",
        "description": """
            The older name for the outcome half of finish_turn. Use finish_turn \
            instead: it takes the same outcome and message and your suggestions \
            together. This still works, and records how the work went.
            """,
        "inputSchema": [
            "type": "object",
            "properties": [
                "outcome": [
                    "type": "string",
                    "enum": .array(["done", "nothing_to_do", "needs_answer",
                                    "partly_done", "stuck", "blocked"]),
                    "description": "The one that is true.",
                ],
                "message": [
                    "type": "string",
                    "description": """
                        One or two sentences, for somebody who has not read the \
                        conversation. For needs_answer, the question itself.
                        """,
                ],
                "waiting_on": [
                    "type": "array",
                    "items": ["type": "string"],
                    "description": """
                        Only with blocked. The agents in this project you are waiting on, \
                        by id (as start_agent or list_my_agents gave it) or by exact \
                        title. You will be resumed once every one has finished.
                        """,
                ],
                "check_again_in_minutes": [
                    "type": "integer",
                    "minimum": 1,
                    "maximum": 1440,
                    "description": """
                        Only with blocked. When to be resumed anyway, to check on \
                        something the app can't see, like a CI run or a review.
                        """,
                ],
            ],
            "required": .array(["outcome", "message"]),
        ],
    ]
}

/// The same trick `ACPSession` uses: the connection needs a handler at init, and the
/// actor it belongs to does not exist yet.
private final class ServiceBox: @unchecked Sendable {
    private weak var service: AppService?

    func attach(_ service: AppService) { self.service = service }

    func handle(method: String, params: JSONValue?) async -> Result<JSONValue, JSONRPCError> {
        guard let service else { return .failure(.methodNotFound(method)) }
        return await service.handle(method: method, params: params)
    }
}
