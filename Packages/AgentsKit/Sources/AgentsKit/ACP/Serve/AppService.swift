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
/// that act mid-turn, `show_file` and `manage_workflows`. Five more act on other
/// agents — `start_agent`, `stop_agent`, `park_agent`, `archive_agent` (#120) and
/// `list_my_agents` (028) — and are offered only to an agent the person or a workflow started.
///
/// This speaks MCP itself rather than pulling in an SDK: it is four methods of
/// JSON-RPC over a pipe, which is what `JSONRPCConnection` already does for ACP.
public actor AppService {
    /// The one call that ends a turn (023): how it went, and what to ask next. A
    /// runtime may prefix it — the Claude adapter shows it as
    /// `mcp__agents__finish_turn` — so every name here is matched on the end rather
    /// than whole.
    public static let finishTurnToolName = AppTool.finishTurn

    /// The other one: show the user a file.
    public static let showFileToolName = AppTool.showFile

    /// And the third: read and write the project's standing arrangements.
    public static let workflowToolName = AppTool.manageWorkflows

    /// Ask the person and wait: the form card every runtime can reach.
    public static let askFormToolName = AppTool.askForm

    /// And five that act on other agents (028), offered only to an agent the person or
    /// a workflow started: start one in this project, and stop, park, archive (#120) or
    /// list the ones this agent started.
    public static let startAgentToolName = AppTool.startAgent
    public static let stopAgentToolName = AppTool.stopAgent
    public static let parkAgentToolName = AppTool.parkAgent
    public static let archiveAgentToolName = AppTool.archiveAgent
    public static let listMyAgentsToolName = AppTool.listMyAgents
    public static let listSessionsToolName = AppTool.listSessions
    public static let readSessionToolName = AppTool.readSession
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

    /// Where a file to show goes.
    public typealias FileSink = @Sendable (ShownFile) async -> Outcome

    /// Where an `ask_form` goes. May take as long as the person takes to answer.
    public typealias AskFormSink = @Sendable (String?, [DaemonAPI.AskFormRequest.Question]) async -> Outcome

    /// Where a workflow question goes. Unlike the other two this can take a while:
    /// a write waits on somebody answering.
    public typealias WorkflowSink =
        @Sendable (DaemonAPI.ManageWorkflowsRequest.Action, String?, String?) async -> Outcome

    /// Where the one call goes: the outcome's wire spelling, the sentence, the chips,
    /// which may be none, and the conversation's new title. The outcome is still a
    /// string here — the daemon owns which words it knows, because it is the daemon
    /// that has to refuse one it does not. One sink for the lot, because the daemon
    /// refuses the whole call or lands the whole call.
    public typealias FinishSink = @Sendable (String, String, [SuggestedPrompt], String?, BlockWords) async -> Outcome

    /// What a `blocked` outcome carries besides its sentence (039): the agents it waits
    /// on, as written, and when to check again. Empty for every other outcome — and
    /// refused here if it is not, so the agent hears it before the call goes further.
    /// And, on `finish_turn` alone, where the agent asked to be put once the turn is
    /// over, and where it asked to move to (053) — carried here so the sink's shape
    /// stays as it was.
    public struct BlockWords: Sendable, Equatable {
        public var waitingOn: [String]?
        public var checkAgainInMinutes: Int?
        public var afterwards: AfterTurn?
        public var addLabels: [String]
        public var removeLabels: [String]
        public var move: MoveCall?

        public init(waitingOn: [String]? = nil, checkAgainInMinutes: Int? = nil,
                    afterwards: AfterTurn? = nil,
                    addLabels: [String] = [], removeLabels: [String] = [],
                    move: MoveCall? = nil) {
            self.waitingOn = waitingOn
            self.checkAgainInMinutes = checkAgainInMinutes
            self.afterwards = afterwards
            self.addLabels = addLabels
            self.removeLabels = removeLabels
            self.move = move
        }

        public static let none = BlockWords()
    }

    /// One of the calls that act on other agents (028), as the agent made it.
    /// Nothing is decided here beyond whether the words are there at all: the daemon
    /// is what knows whose agent is whose.
    public enum AgentCall: Sendable, Equatable {
        case start(prompt: String, runtime: String?, model: String?, permissionMode: String?,
                   worktree: String? = nil, labels: [String] = [])
        case stop(agentID: String)
        case park(agentID: String)
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
        case wait(action: String?, events: [String]?, where: [String: DetailFilter]?, from: Int64?,
                  untilMinutes: Int?, limit: Int?)
        case cancel
        case publish(name: String, message: String?, details: [String: String]?)
    }

    /// Where those go. A wait may take up to the hold limit to come back.
    public typealias EventsSink = @Sendable (EventCall) async -> Outcome

    /// A move asked for on `finish_turn` (053), as the agent made it: one move, which
    /// the daemon checks and keeps for when the turn ends.
    public enum MoveCall: Sendable, Equatable {
        case move(target: MoveTarget, removeLeft: Bool, discardChanges: Bool)
    }

    /// `list_sessions` or `read_session` (065), as the agent made it. Neither names a
    /// project: the daemon takes it from the caller.
    public enum SessionCall: Sendable, Equatable {
        case list
        case read(session: String)
    }

    /// Where those go.
    public typealias SessionsSink = @Sendable (SessionCall) async -> Outcome

    private let connection: JSONRPCConnection
    private let finishSink: FinishSink
    private let fileSink: FileSink
    private let askFormSink: AskFormSink
    private let workflowSink: WorkflowSink
    private let agentsSink: AgentsSink
    private let leasesSink: LeasesSink
    private let eventsSink: EventsSink
    private let sessionsSink: SessionsSink
    private let dashboardSink: DashboardSink
    /// Whether the agent tools are offered. False for an agent another agent
    /// started (028), which the daemon says by starting this with `--no-agent-tools`.
    private let managesAgents: Bool
    /// Whether `finish_turn` offers the move arguments. False for an agent on a runtime
    /// that cannot carry its conversation into another folder (053), said with
    /// `--no-move-tools`.
    private let movesItself: Bool
    private let box = ServiceBox()

    public init(transport: any LineTransport,
                managesAgents: Bool = true,
                movesItself: Bool = true,
                finishTurn: @escaping FinishSink = { _, _, _, _, _ in
                    .refused("This app cannot end a turn.")
                },
                showFile: @escaping FileSink = { _ in .refused("This app cannot show a file.") },
                askForm: @escaping AskFormSink = { _, _ in
                    .refused("This app cannot ask the person.")
                },
                workflows: @escaping WorkflowSink = { _, _, _ in
                    .refused("This app cannot manage workflows.")
                },
                agents: @escaping AgentsSink = { _ in
                    .refused("This app cannot start or stop agents.")
                },
                leases: @escaping LeasesSink = { _ in
                    .refused("This app cannot lease resources.")
                },
                events: @escaping EventsSink = { _ in
                    .refused("This app cannot wait on or publish events.")
                },
                sessions: @escaping SessionsSink = { _ in
                    .refused("This app cannot read other sessions.")
                },
                dashboard: @escaping DashboardSink = { _ in
                    .refused("This app has no Dashboard.")
                }) {
        let box = self.box
        self.finishSink = finishTurn
        self.fileSink = showFile
        self.askFormSink = askForm
        self.workflowSink = workflows
        self.agentsSink = agents
        self.leasesSink = leases
        self.eventsSink = events
        self.sessionsSink = sessions
        self.dashboardSink = dashboard
        self.managesAgents = managesAgents
        self.movesItself = movesItself
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
            return .success(["tools": .array(Self.tools(managesAgents: managesAgents, movesItself: movesItself))])

        case "tools/call":
            let name = params?["name"]?.stringValue ?? ""
            let arguments = params?["arguments"]

            // Longest suffix wins, though nothing here shares one: a runtime is free
            // to prefix a tool's name and none of them changes what follows it.
            if name.hasSuffix(Self.finishTurnToolName) {
                // The outcome's checks run here as well as at the daemon so an agent
                // that got the word wrong is told which five there are before the call
                // goes any further. Never rounded to the nearest one: an unknown outcome
                // read as `done` is exactly the unearned tick this exists to remove. The
                // chips are cleaned, and may come to nothing: the call is the outcome;
                // the chips ride along (FR-003).
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
                let prompts = SuggestedPrompt.next(arguments?["next_prompt"])
                var words: BlockWords
                switch Self.blockWords(raw, arguments) {
                case .success(let read): words = read
                case .failure(let problem): return .success(Self.reply(problem.message, isError: true))
                }
                switch Self.afterwards(raw, arguments) {
                case .success(let read): words.afterwards = read
                case .failure(let problem): return .success(Self.reply(problem.message, isError: true))
                }
                for (key, assign) in [("add_labels", true), ("remove_labels", false)] {
                    if arguments?[key] != nil && arguments?[key]?.arrayValue == nil {
                        return .success(Self.reply("Nothing was recorded: `\(key)` must be an array of label strings.", isError: true))
                    }
                    let values = arguments?[key]?.arrayValue ?? []
                    guard values.allSatisfy({ $0.stringValue != nil }) else {
                        return .success(Self.reply("Nothing was recorded: `\(key)` must contain only strings.", isError: true))
                    }
                    if assign { words.addLabels = values.compactMap(\.stringValue) }
                    else { words.removeLabels = values.compactMap(\.stringValue) }
                }
                switch Self.moveCall(arguments) {
                case .success(let read): words.move = read
                case .failure(let problem): return .success(Self.reply(problem.message, isError: true))
                }
                if words.move != nil && !movesItself {
                    return .success(Self.reply("""
                        Nothing was recorded: this runtime cannot carry its conversation \
                        into another folder, so you stay where you are. Call again without \
                        worktree or leave_worktree.
                        """, isError: true))
                }
                return .success(Self.reply(await finishSink(raw, message, prompts, title, words)))
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

            if name.hasSuffix(Self.askFormToolName) {
                switch Self.askFormCall(arguments) {
                case .failure(let problem):
                    return .success(Self.reply(problem.message, isError: true))
                case .success(let call):
                    return .success(Self.reply(await askFormSink(call.title, call.questions)))
                }
            }

            if name.hasSuffix(Self.workflowToolName) {
                guard let raw = arguments?["action"]?.stringValue,
                      let action = DaemonAPI.ManageWorkflowsRequest.Action(rawValue: raw) else {
                    return .success(Self.reply("""
                        Nothing was done: `action` has to be one of list, read, write, \
                        remove, enable or disable.
                        """, isError: true))
                }
                return .success(Self.reply(await workflowSink(action,
                                                              arguments?["id"]?.stringValue,
                                                              arguments?["content"]?.stringValue)))
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

            if let call = Self.dashboardCall(named: name, arguments) {
                switch call {
                case .failure(let problem): return .success(Self.reply(problem.message, isError: true))
                case .success(let call): return .success(Self.reply(await dashboardSink(call)))
                }
            }

            if let call = Self.sessionCall(named: name, arguments) {
                switch call {
                case .failure(let problem): return .success(Self.reply(problem.message, isError: true))
                case .success(let call): return .success(Self.reply(await sessionsSink(call)))
                }
            }

            if let call = Self.agentCall(named: name, arguments) {
                guard managesAgents else {
                    return .success(Self.reply("""
                        Nothing was done: an agent that another agent started cannot \
                        start, stop, park or list agents of its own.
                        """, isError: true))
                }
                switch call {
                case .failure(let problem): return .success(Self.reply(problem.message, isError: true))
                case .success(let call): return .success(Self.reply(await agentsSink(call)))
                }
            }

            return .failure(JSONRPCError(code: JSONRPCError.invalidParams,
                                         message: "No tool called \(name.isEmpty ? "that" : name)."))

        default:
            return .failure(.methodNotFound(method))
        }
    }

    /// Which of the agent calls a tool name is, with its arguments read — or the
    /// refusal for a call that is missing what it needs, as a sentence saying what was
    /// missing. `nil` when the name is none of them.
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
            guard arguments?["labels"] == nil || arguments?["labels"]?.arrayValue != nil,
                  (arguments?["labels"]?.arrayValue ?? []).allSatisfy({ $0.stringValue != nil }) else {
                return .failure("Nothing was started: `labels` must contain only strings.")
            }
            return .success(.start(prompt: prompt, runtime: text("runtime"), model: text("model"),
                                   permissionMode: text("permission_mode"),
                                   worktree: text("worktree"),
                                   labels: arguments?["labels"]?.arrayValue?.compactMap(\.stringValue) ?? []))
        }
        if name.hasSuffix(stopAgentToolName) || name.hasSuffix(parkAgentToolName)
            || name.hasSuffix(archiveAgentToolName) {
            guard let id = text("id") else {
                return .failure("Nothing changed: `id` has to be the id start_agent or list_my_agents gave.")
            }
            if name.hasSuffix(stopAgentToolName) { return .success(.stop(agentID: id)) }
            if name.hasSuffix(archiveAgentToolName) { return .success(.archive(agentID: id)) }
            return .success(.park(agentID: id))
        }
        if name.hasSuffix(listMyAgentsToolName) {
            return .success(.list)
        }
        return nil
    }

    /// Which of the two session calls a tool name is, with its arguments read (065).
    /// `nil` when the name is neither.
    static func sessionCall(named name: String,
                            _ arguments: JSONValue?) -> Result<SessionCall, AgentCallProblem>? {
        if name.hasSuffix(listSessionsToolName) { return .success(.list) }
        if name.hasSuffix(readSessionToolName) {
            let value = arguments?["session"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !value.isEmpty else { return .failure(AgentCallProblem(stringLiteral: SessionLookup.noValue)) }
            return .success(.read(session: value))
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
        /// Each key's value, one or a list (073 FR-016). The first key holding
        /// anything else, which used to be dropped without a word.
        func readFilters(_ value: JSONValue?) -> Result<[String: DetailFilter]?, AgentCallProblem> {
            guard let object = value?.objectValue else { return .success(nil) }
            var out: [String: DetailFilter] = [:]
            for key in object.keys.sorted() {
                guard let filter = object[key].flatMap(WorkflowTrigger.filter) else {
                    return .failure(AgentCallProblem(stringLiteral:
                        "Nothing is waited for: the \"\(key)\" in where is not a value. A value is text, "
                        + "a number, true or false, or a list of those, e.g. {\"outcome\": [\"done\", \"nothing_to_do\"]}."))
                }
                out[key] = filter
            }
            return .success(out)
        }
        func integer(_ value: JSONValue?) -> Int? {
            if let number = value?.intValue { return number }
            return value?.stringValue.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        }
        if name.hasSuffix(waitForEventToolName) {
            var events = arguments?["events"]?.arrayValue?.compactMap(\.stringValue)
            // One name given as a string rather than a list of one.
            if events == nil, let one = arguments?["events"]?.stringValue { events = [one] }
            let filters: [String: DetailFilter]?
            switch readFilters(arguments?["where"]) {
            case .success(let read): filters = read
            case .failure(let problem): return .failure(problem)
            }
            return .success(.wait(action: arguments?["action"]?.stringValue, events: events,
                                  where: filters,
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

    /// Every tool this server offers, in the order they are listed.
    static func tools(managesAgents: Bool, movesItself: Bool = true) -> [JSONValue] {
        // The one that ends a turn first, then the ones that act mid-turn. The two
        // older names for its halves were retired on 2026-09-29 (023 R5).
        // The agent tools after the workflow tool, and only for an agent that
        // may use them (028).
        let agentTools = managesAgents
            ? [Self.startAgentTool, Self.stopAgentTool, Self.parkAgentTool, Self.archiveAgentTool,
               Self.listMyAgentsTool]
            : []
        // The three lease tools after those, for every agent: waiting for the
        // simulator is not managing anyone (036).
        let leaseTools = [Self.leaseResourceTool, Self.releaseResourceTool, Self.listResourcesTool]
        // The three event tools, for every agent (042).
        let eventTools = [Self.waitForEventTool, Self.cancelWaitTool, Self.publishEventTool]
        // The two for reading another session in this project, for every agent (065).
        let sessionTools = [Self.listSessionsTool, Self.readSessionTool]
        // The four for the project's Dashboard, for every agent (074, #147).
        let dashboardTools = [Self.setTileTool, Self.removeTileTool, Self.readDashboardTool, Self.moveTileTool]
        // Moving itself rides on the call that ends the turn, since that is when a move
        // happens (053); not offered on a runtime that would forget the conversation on
        // the way.
        return [Self.finishTurnTool(movesItself: movesItself), Self.showFileTool, Self.workflowTool,
                Self.askFormTool]
            + agentTools + sessionTools + leaseTools
            + eventTools + dashboardTools
    }

    /// The questions an `ask_form` call carried, or why it cannot be asked.
    static func askFormCall(_ arguments: JSONValue?)
        -> Result<(title: String?, questions: [DaemonAPI.AskFormRequest.Question]), AgentCallProblem> {
        let title = arguments?["title"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedTitle = (title?.isEmpty == false) ? title : nil
        guard let raw = arguments?["questions"]?.arrayValue, !raw.isEmpty else {
            return .failure("Nothing was asked: send at least one question in `questions`.")
        }
        var questions: [DaemonAPI.AskFormRequest.Question] = []
        for item in raw {
            let id = item["id"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let prompt = item["prompt"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !id.isEmpty, !prompt.isEmpty else {
                return .failure("Nothing was asked: each question needs an `id` and a `prompt`.")
            }
            let options = item["options"]?.arrayValue?.compactMap { option -> DaemonAPI.AskFormRequest.Question.Option? in
                let optionID = option["id"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !optionID.isEmpty else { return nil }
                return .init(id: optionID, label: option["label"]?.stringValue)
            }
            questions.append(.init(id: id, prompt: prompt,
                                   options: (options?.isEmpty == false) ? options : nil,
                                   allowMultiple: item["allow_multiple"]?.boolValue))
        }
        return .success((cleanedTitle, questions))
    }

    /// The move a `finish_turn` call asks for (053), with its arguments read. `nil` when
    /// it asks for none.
    static func moveCall(_ arguments: JSONValue?) -> Result<MoveCall?, AgentCallProblem> {
        func text(_ key: String) -> String? {
            let value = arguments?[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            return value?.isEmpty == false ? value : nil
        }
        let discard = arguments?["discard_changes"]?.boolValue ?? false
        let worktree = text("worktree"), leaving = text("leave_worktree")
        if worktree != nil, leaving != nil {
            return .failure("Nothing was recorded: give worktree to move into one, or leave_worktree to go back to the project folder, not both.")
        }
        if let worktree {
            guard !discard else {
                return .failure("Nothing was recorded: discard_changes only goes with leave_worktree remove.")
            }
            if worktree.hasPrefix("/") {
                return .success(.move(target: .existing(URL(filePath: worktree, directoryHint: .isDirectory)),
                                      removeLeft: false, discardChanges: false))
            }
            return .success(.move(target: .newWorktree(name: worktree), removeLeft: false, discardChanges: false))
        }
        switch leaving {
        case nil:
            guard !discard else {
                return .failure("Nothing was recorded: discard_changes only goes with leave_worktree remove.")
            }
            return .success(nil)
        case "keep":
            guard !discard else {
                return .failure("Nothing was recorded: discard_changes only goes with leave_worktree remove.")
            }
            return .success(.move(target: .projectFolder, removeLeft: false, discardChanges: false))
        case "remove":
            return .success(.move(target: .projectFolder, removeLeft: true, discardChanges: discard))
        default:
            return .failure("Nothing was recorded: leave_worktree has to be keep or remove.")
        }
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
    /// Where the agent asked to be put once the turn is over, read and checked against
    /// the outcome — here and again at the daemon, as the block's words are. Left out,
    /// or null, is where its ending puts it.
    static func afterwards(_ outcome: String, _ arguments: JSONValue?)
        -> Result<AfterTurn?, AgentCallProblem> {
        guard let value = arguments?["afterwards"], value != .null else { return .success(nil) }
        guard let after = value.stringValue.flatMap(AfterTurn.init(wire:)) else {
            return .failure(AgentCallProblem(stringLiteral: AfterTurn.unknown))
        }
        guard let ending = WorkOutcome(wire: outcome), after.goes(with: ending) else {
            return .failure(AgentCallProblem(stringLiteral: after.refusal))
        }
        return .success(after)
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
    static func finishTurnTool(movesItself: Bool) -> JSONValue {
        guard !movesItself else { return finishTurnTool }
        guard case .object(var tool) = finishTurnTool,
              case .object(var schema)? = tool["inputSchema"],
              case .object(var properties)? = schema["properties"],
              let description = tool["description"]?.stringValue else { return finishTurnTool }
        for key in movingArguments { properties.removeValue(forKey: key) }
        schema["properties"] = .object(properties)
        tool["inputSchema"] = .object(schema)
        tool["description"] = .string(description.replacingOccurrences(of: "\n\n" + movingParagraph, with: ""))
        return .object(tool)
    }

    /// The arguments that move the agent (053), left out on a runtime that cannot move.
    static let movingArguments = ["worktree", "leave_worktree", "discard_changes"]

    /// What an agent is told about moving itself. The move happens when the turn ends,
    /// so asking for it on the call that ends the turn leaves no stretch of the turn in
    /// which edits land in the folder being left. Words from contracts/move.md.
    static let movingParagraph = """
        To move into a git worktree of this project, give worktree: a name for a new \
        one, or the absolute path of one already there. Do it on your own judgement \
        when the work turns into a change that should be on its own branch, or when \
        asked. To go back to the project folder, give leave_worktree: keep leaves the \
        worktree and its branch as they are; remove takes the worktree away, and its \
        branch if the app made it and it is merged. Remove is refused for a worktree \
        the app did not make or another agent works in, and, unless discard_changes \
        is true, when anything in it is uncommitted or unmerged: ask the person before \
        discarding. You move once this turn ends and are started again there to carry \
        on, so the outcome is how the work stands now, and a move does not go with \
        needs_answer, blocked or afterwards. Nothing uncommitted comes with you, and a \
        new worktree starts from the commit you have checked out: commit first what \
        you want to bring.
        """

    static let finishTurnTool: JSONValue = [
        "name": .string(finishTurnToolName),
        "title": "Finish the turn",
        "description": .string("""
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
            can't see, say what it is and give check_again_in_minutes. Either way the \
            person sees you under Waiting, knowing you will carry on by yourself; name \
            nothing and give no time and you sit under Blocked until they carry you on. \
            It is not for a \
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

            When you have finished and cleaned up after yourself — merged, removed \
            what you made — you may ask to be parked (put down, to come back to) once \
            this turn ends, with afterwards set to park. Park goes with done, \
            nothing_to_do or partly_done. Leave it out and the conversation stays \
            where its ending puts it. If the person sends something before the turn \
            is over, the ask is dropped. You cannot archive yourself: the person can, \
            and so can the agent that started you, if one did.

            If you can carry on once you have an answer, do not use this: ask with your \
            question or form tool, which stops and waits for them. This one does not \
            wait. It is how you end.

            \(movingParagraph)
            """),
        "inputSchema": [
            "type": "object",
            "properties": [
                "worktree": [
                    "type": "string",
                    "description": """
                        Move into a git worktree of this project once this turn ends: a \
                        name for a new one, or the absolute path of one already there. \
                        Not with leave_worktree.
                        """,
                ],
                "leave_worktree": [
                    "type": "string",
                    "enum": .array(["keep", "remove"]),
                    "description": """
                        Move back to the project folder once this turn ends. keep leaves \
                        the worktree as it is; remove takes it away after you have left.
                        """,
                ],
                "discard_changes": [
                    "type": "boolean",
                    "description": "Only with leave_worktree remove. Remove even though work would be lost.",
                ],
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
                "afterwards": [
                    "type": "string",
                    "enum": .array(["park"]),
                    "description": """
                        Once this turn ends: park to put the conversation down to come \
                        back to. Goes with done, nothing_to_do or partly_done. Leave \
                        out to stay where the ending puts it. You cannot archive \
                        yourself: the person can, and so can the agent that started you.
                        """,
                ],
                "add_labels": ["type": "array", "items": ["type": "string"],
                               "description": "Agent-owned labels to add to this session."],
                "remove_labels": ["type": "array", "items": ["type": "string"],
                                  "description": "Agent-owned labels to remove. Person labels are protected."],
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

    /// Ask the person a question and wait. The channel every runtime can reach.
    static let askFormTool: JSONValue = [
        "name": .string(askFormToolName),
        "title": "Ask the person a question",
        "description": """
            Ask me a question or a short form and wait for my answer. Use this when \
            something is mine to decide — a choice between real alternatives, a missing \
            credential, anything hard to undo — rather than guessing or ending the turn \
            with the question in your reply.

            Your question reaches me wherever I am, including on my phone, and the call \
            waits until I answer, skip or cancel. Prefer your runtime's own question \
            tool when you have one; use this when you do not, or when that tool is not \
            in your catalogue.

            Each question may offer options to pick, or leave options out for free \
            text. Set allow_multiple when more than one option may be chosen.
            """,
        "inputSchema": [
            "type": "object",
            "properties": [
                "title": [
                    "type": "string",
                    "description": "Optional heading for the form as a whole.",
                ],
                "questions": [
                    "type": "array",
                    "minItems": .int(1),
                    "items": [
                        "type": "object",
                        "properties": [
                            "id": [
                                "type": "string",
                                "description": "A short stable id for this question.",
                            ],
                            "prompt": [
                                "type": "string",
                                "description": "The question in your own words.",
                            ],
                            "options": [
                                "type": "array",
                                "items": [
                                    "type": "object",
                                    "properties": [
                                        "id": ["type": "string"],
                                        "label": ["type": "string"],
                                    ],
                                    "required": .array(["id"]),
                                ],
                                "description": """
                                    Choices to pick from. Leave out, or pass an empty \
                                    list, for a free-text answer.
                                    """,
                            ],
                            "allow_multiple": [
                                "type": "boolean",
                                "description": "True when more than one option may be chosen.",
                            ],
                        ],
                        "required": .array(["id", "prompt"]),
                    ],
                    "description": "One or more questions. Keep it short.",
                ],
            ],
            "required": .array(["questions"]),
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

            `cooldown:` (e.g. `15m`, `2h`, `1d`) is the least time from the start of one \
            run to the start of the next. Triggers that arrive sooner, or while a run is \
            going, are held and run once, with the latest of them, when it ends. Set one \
            for a workflow on a busy event such as `agent.finished`.

            Once its runtime has been used in this project, reading a workflow also \
            lists what that runtime offers for each of these, in the words the file \
            takes. To change how an existing workflow runs, \
            read it, then write it back whole with the settings changed.

            Nothing here asks the person, but a workflow you write or change does not run \
            until they approve it on the project page; removing one takes effect at once. \
            A new workflow you write also starts turned off, whatever its file says: \
            after approving it, the person turns it on from its page when they are \
            ready. Changing one that exists leaves it on or off as it was. So write one \
            only when they asked for it, and say in your reply what you set up, that it \
            is waiting for their OK, and that they turn it on once approved.

            A project may have at most \(WorkflowLimit.project.allowed) workflows \
            waiting for approval; a write that would make another is refused until the \
            person approves or removes one. Approved workflows do not count towards \
            that, only towards the \(WorkflowLimit.total.allowed) that may run across \
            every project.

            `disable` turns a workflow off without touching its file: it stays listed, \
            marked off, and none of its triggers run it; `list` says which are off and \
            why. `enable` turns one back on, but only one an agent turned off: one the \
            person turned off, one an agent wrote and nobody has turned on yet, and one \
            whose file says `enabled: false` are theirs to turn on.

            Under on:, besides schedule and today's hyphenated names (agent-finished and \
            the rest), any event name works, narrowed by its details written under it, \
            e.g. `- workflow.completed:` with `workflow: nightly` under it.
            """ + "\n" + EventCatalogue.describe()),
        "inputSchema": [
            "type": "object",
            "properties": [
                "action": [
                    "type": "string",
                    "enum": .array(["list", "read", "write", "remove", "enable", "disable"]),
                    "description": "What to do.",
                ],
                "id": [
                    "type": "string",
                    "description": """
                        The workflow's file name without its extension, e.g. \
                        `morning-build-check`. Required for read, write, remove, \
                        enable and disable.
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
    /// calls, not in a refusal after: this project only, two limits across the project
    /// that the person sets, and only the person frees a not-archived place. No number
    /// is written here: the limits are the project's own, and a result says them. And the restraint,
    /// as the workflow tool carries its own — an agent told it can start agents will
    /// start agents.
    static let startAgentTool: JSONValue = [
        "name": .string(startAgentToolName),
        "title": "Start an agent in this project",
        "description": """
            Start another agent in this project, with a prompt of its own, to do a part \
            of the work that can run alongside the rest. It starts in this project's \
            folder — there is no way to start one anywhere else — and appears in the \
            person's list of agents, marked as started by you. The person can open it, \
            talk to it, stop it, park it or archive it at any time.

            This project has two limits on agents started by agents, counting every agent \
            here, which only the person sets (in Project Settings): how many may be \
            running — working, waiting on a question, or waiting to carry on by \
            itself — and how many may exist not yet archived, where stopped, parked and \
            finished ones still count. A start that would break either is refused, \
            saying which. Use list_my_agents to see yours and how many places of each \
            are in use. Stop one with stop_agent, or park one with park_agent, when its \
            part is done: that frees its running place, and it keeps its other place \
            until it is archived. Once its work is merged or abandoned, archive it with \
            archive_agent to free that place too (where the person allows it); archive \
            a finished helper rather than removing its worktree under it.

            Start one only when part of the work can genuinely run alongside the rest. \
            Do not start one for work you could simply do yourself. The agent you \
            start cannot start agents of its own.

            Returns the new agent's id, which stop_agent, park_agent and archive_agent take.
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
                    "description": """
                        Optional. The runtime to run it on, by id, as a workflow's \
                        `runtime:`; leave out for the default. list_my_agents ends with \
                        the ones available here and each one's model. One that is not \
                        available (not installed, not signed in, out of the pool) is \
                        refused before anything starts, naming the ones that are.
                        """,
                ],
                "model": [
                    "type": "string",
                    "description": """
                        Optional. The model, as a workflow's `model:`. One the runtime \
                        does not offer is refused, naming the ones it does.
                        """,
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
                "labels": ["type": "array", "items": ["type": "string"],
                           "description": "Labels for the helper, owned by that helper."],
            ],
            "required": .array(["prompt"]),
        ],
    ]

    /// The id schema stop, park and archive share.
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
            It stays in the list with its conversation. Stopping frees its running \
            place; it keeps its not-archived place until it is archived. Only agents you started can be stopped this way; not yourself, \
            and not anyone else's.
            """,
        "inputSchema": agentIDSchema,
    ]

    static let parkAgentTool: JSONValue = [
        "name": .string(parkAgentToolName),
        "title": "Park an agent you started",
        "description": """
            Park an agent you started with start_agent, as the person's own Park would: \
            put it down to come back to later. If it is still working, the turn finishes \
            first and it parks when that ends. It stays in the list under Parked. Parking \
            frees its running place; it keeps its not-archived place until it is \
            archived. Parking one that has already finished is fine. Only agents you \
            started can be parked this way; not yourself (set afterwards to park on \
            finish_turn), and not anyone else's. To free its not-archived place too, \
            archive it with archive_agent.
            """,
        "inputSchema": agentIDSchema,
    ]

    static let archiveAgentTool: JSONValue = [
        "name": .string(archiveAgentToolName),
        "title": "Archive an agent you started",
        "description": """
            Archive an agent you started with start_agent, as the person's own Archive \
            would, once its work is merged or abandoned. It leaves the list for Archived, \
            frees its not-archived place, and its conversation says you archived it. The \
            person can bring it back. Archive a finished helper rather than removing its \
            worktree under it.

            Refused while it is still working: wait for it to finish, or stop it with \
            stop_agent first if its work is no longer wanted. Only agents you started can \
            be archived; never yourself (set afterwards to park on finish_turn), never \
            the person's own sessions, and never another agent's. The person can turn \
            this off for a project in Project Settings.
            """,
        "inputSchema": agentIDSchema,
    ]


    static let listMyAgentsTool: JSONValue = [
        "name": .string(listMyAgentsToolName),
        "title": "List the agents you started",
        "description": """
            The agents you started with start_agent that have not been archived: each \
            one's id, what it is doing, what it last said, and its labels with owners. Also \
            how many of this project's running and not-archived places are in use, out \
            of the limits the person set. And which runtimes start_agent can start one \
            on here, as of now, with the model each starts on where known, and why the \
            others cannot. Archive the finished ones whose work is merged or abandoned \
            with archive_agent, so their places are free for the next.
            """,
        "inputSchema": ["type": "object", "properties": .object([:])],
    ]

    // MARK: Sessions (065). Words from contracts/session-tools.md.

    static let listSessionsTool: JSONValue = [
        "name": .string(listSessionsToolName),
        "title": "List the sessions in this project",
        "description": """
            Every session in this project, most recent first, yours included: each one's \
            id, title, runtime, status, labels with owners, and what it last said. Use it to find a session \
            the person asks you to continue, then read it with read_session.
            """,
        "inputSchema": ["type": "object", "properties": .object([:])],
    ]

    static let readSessionTool: JSONValue = [
        "name": .string(readSessionToolName),
        "title": "Read another session's history",
        "description": """
            The app's record of one session in this project: what the person asked, what \
            the agent said, the tools it ran and the files they touched, and its plan as it \
            last stood. Use it when asked to continue another session's work. Reading it \
            does not change that session. A long one keeps the first request and the latest \
            turns and says how many were left out.
            """,
        "inputSchema": [
            "type": "object",
            "properties": [
                "session": [
                    "type": "string",
                    "description": "The session's id, as list_sessions gave it, or its exact title.",
                ],
            ],
            "required": ["session"],
        ],
    ]

    // MARK: Events (042). Words from contracts/event-tools.md.

    static let waitForEventTool: JSONValue = [
        "name": .string(waitForEventToolName),
        "title": "Wait for something to happen",
        "description": """
            Wait until something happens: an event in this project or on this Mac, such as \
            agent.finished, workflow.completed, mac.wake or custom.build_green. Your \
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
                        as agent.*.
                        """,
                ],
                "where": [
                    "type": "object",
                    "description": """
                        Narrow them by their details, e.g. {"workflow": "nightly"} or \
                        {"agent": "Fix login"}. A list means any of them, e.g. \
                        {"labels": "deploy", "outcome": ["done", "nothing_to_do"]}.
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
            see the names. The person may have declared resources, such as "build", each \
            with a description of when to take it and how many agents may hold it at \
            once: lease a declared resource whenever its description applies to what you \
            are about to do.
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
                    "description": "How long. Default 30, at most 240, unless the resource was declared with its own.",
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
            and waits first. Resources the person declared come next, with a description \
            of when to lease each: whenever one applies to what you are about to do, lease \
            it with lease_resource first.
            """,
        "inputSchema": ["type": "object", "properties": .object([:])],
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
