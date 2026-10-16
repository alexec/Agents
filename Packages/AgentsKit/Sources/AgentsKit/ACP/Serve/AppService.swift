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
/// that act mid-turn, `show_file` and `manage_workflows`. The session tools (#638) act on
/// sessions: `start_session` and `stop_session` (028) are offered only to an agent the person
/// or a workflow started; `archive_session` (#584), `list_sessions`, `read_session` (065) and
/// `message_session` (#560) to every agent.
///
/// This speaks MCP itself rather than pulling in an SDK: it is four methods of
/// JSON-RPC, which the daemon's loopback endpoint hands it one request at a time
/// (`AppToolsEndpoint`, #185). A transport is still taken, for tests that talk to it
/// over a pipe.
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

    /// Offer the person one optional next prompt.
    public static let suggestNextPromptToolName = AppTool.suggestNextPrompt

    /// And the session tools (#638): start a session in this project and stop one this
    /// agent started (028), offered only to an agent the person or a workflow started;
    /// archive itself or one it started, list, read and message, offered to every agent.
    public static let startSessionToolName = AppTool.startSession
    public static let stopSessionToolName = AppTool.stopSession
    public static let archiveSessionToolName = AppTool.archiveSession
    public static let listSessionsToolName = AppTool.listSessions
    public static let readSessionToolName = AppTool.readSession
    public static let messageSessionToolName = AppTool.messageSession
    public static let leaseResourceToolName = AppTool.leaseResource
    public static let waitForEventToolName = AppTool.waitForEvent
    public static let cancelWaitToolName = AppTool.cancelWait
    public static let releaseResourceToolName = AppTool.releaseResource
    public static let listResourcesToolName = AppTool.listResources
    public static let setSessionLabelsToolName = AppTool.setSessionLabels
    public static let moveWorktreeToolName = AppTool.moveWorktree

    /// The last version of MCP this was written against. A client that asks for one it
    /// knows is answered with its own, which is what the specification says to do and
    /// what keeps this working when a runtime moves ahead of us.
    static let protocolVersion = "2025-06-18"

    /// What the daemon did with a call. The agent is told either way, so a token the
    /// daemon does not recognise reads as a refusal rather than as a silent success.
    public enum Outcome: Sendable {
        case shown(String)
        case shownResult(JSONValue)
        case refused(String)
    }

    /// Where a file to show goes.
    public typealias FileSink = @Sendable (ShownFile) async -> Outcome

    /// Where an `ask_form` goes. May take as long as the person takes to answer.
    public typealias AskFormSink = @Sendable (String?, [DaemonAPI.AskFormRequest.Question]) async -> Outcome

    /// Where an optional next prompt goes.
    public typealias SuggestedPromptSink = @Sendable (SuggestedPrompt) async -> Outcome

    /// Where a workflow question goes. Unlike the other two this can take a while:
    /// a write waits on somebody answering.
    public typealias WorkflowSink =
        @Sendable (DaemonAPI.ManageWorkflowsRequest.Action, String?, String?) async -> Outcome

    /// One of the calls that act on sessions this agent started (028), as the agent made it.
    /// Nothing is decided here beyond whether the words are there at all: the daemon
    /// is what knows whose agent is whose.
    public enum AgentCall: Sendable, Equatable {
        case start(prompt: String, runtime: String?, model: String?, permissionMode: String?,
                   worktree: String? = nil, labels: [String] = [])
        case stop(agentID: String)
        case requestArchive(agentID: String)
        /// `list_sessions` with `started_by: me`.
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

    /// One of the two event calls (042), as the agent made it.
    public enum EventCall: Sendable, Equatable {
        case wait(action: String?, events: [String]?, where: [String: DetailFilter]?, from: Int64?,
                  untilMinutes: Int?, limit: Int?)
        case cancel
    }

    /// Where those go. A wait may take up to the hold limit to come back.
    public typealias EventsSink = @Sendable (EventCall) async -> Outcome

    /// A move asked for on `finish_turn` (053), as the agent made it: one move, which
    /// the daemon checks and keeps for when the turn ends.
    public enum MoveCall: Sendable, Equatable {
        case move(target: MoveTarget, removeLeft: Bool, discardChanges: Bool)
    }

    /// What an agent asks of its own session (#481), each once on the tool that does it:
    /// to be put away once the turn ends (`archive_session` with no id), its
    /// labels, a move (none takes one back), or a wait on agents or a time.
    public enum SelfCall: Sendable, Equatable {
        case afterTurn(AfterTurn)
        case labels(add: [String], remove: [String])
        case move(MoveCall?)
        case waitOn(agents: [String], wakeOn: Block.WakeOn?, untilMinutes: Int?, message: String?)
    }

    /// Where those go.
    public typealias SelfSink = @Sendable (SelfCall) async -> Outcome

    /// `list_sessions` or `read_session` (065), as the agent made it. Neither names a
    /// project: the daemon takes it from the caller.
    public enum SessionCall: Sendable, Equatable {
        case list(limit: Int? = nil, after: String? = nil)
        case read(session: String)
        /// `message_session` (#560): the daemon decides whether it goes now, waits, or not at all.
        case message(to: String, text: String)
    }

    /// Where those go.
    public typealias SessionsSink = @Sendable (SessionCall) async -> Outcome

    /// A workspace tool (#691 US6), as the agent made it.
    public typealias WorkspacesSink = @Sendable (DaemonAPI.WorkspaceToolRequest) async -> Outcome

    /// A writer's tool (#858), by its name, with its arguments as the agent gave them.
    public typealias DraftSink = @Sendable (String, JSONValue?) async -> Outcome

    private let connection: JSONRPCConnection?
    private let fileSink: FileSink
    private let askFormSink: AskFormSink
    private let suggestedPromptSink: SuggestedPromptSink
    private let workflowSink: WorkflowSink
    private let agentsSink: AgentsSink
    private let leasesSink: LeasesSink
    private let eventsSink: EventsSink
    private let sessionsSink: SessionsSink
    private let selfSink: SelfSink
    private let workspacesSink: WorkspacesSink
    private let draftSink: DraftSink
    /// The agent writing a provider's map (#858): offered the writer's tools, and nothing else.
    private let writer: Bool
    private let viewToolSink: ViewToolSink
    /// Whether the test view and its tools are offered (#187).
    private let offersTestView: Bool
    /// Whether `move_worktree` is offered. False for an agent on a runtime that cannot
    /// carry its conversation into another folder (053).
    private let movesItself: Bool
    private let box = ServiceBox()

    public init(transport: (any LineTransport)?,
                movesItself: Bool = true,
                writer: Bool = false,
                showFile: @escaping FileSink = { _ in .refused("This app cannot show a file.") },
                askForm: @escaping AskFormSink = { _, _ in
                    .refused("This app cannot ask the person.")
                },
                suggestNextPrompt: @escaping SuggestedPromptSink = { _ in
                    .refused("This app cannot suggest a next prompt.")
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
                    .refused("This app cannot wait on events.")
                },
                sessions: @escaping SessionsSink = { _ in
                    .refused("This app cannot read other sessions.")
                },
                itself: @escaping SelfSink = { _ in
                    .refused("This app cannot change this session.")
                },
                workspaces: @escaping WorkspacesSink = { _ in
                    .refused("This app has no workspaces.")
                },
                draft: @escaping DraftSink = { _, _ in
                    .refused("This session isn't writing a provider's map.")
                },
                viewTool: @escaping ViewToolSink = { _, _ in
                    .failure("This app draws no views.")
                },
                offersTestView: Bool = AppViewCatalog.offersTestView) {
        let box = self.box
        self.fileSink = showFile
        self.askFormSink = askForm
        self.suggestedPromptSink = suggestNextPrompt
        self.workflowSink = workflows
        self.agentsSink = agents
        self.leasesSink = leases
        self.eventsSink = events
        self.sessionsSink = sessions
        self.selfSink = itself
        self.workspacesSink = workspaces
        self.writer = writer
        self.draftSink = draft
        self.viewToolSink = viewTool
        self.offersTestView = offersTestView
        self.movesItself = movesItself
        self.connection = transport.map { transport in
            JSONRPCConnection(transport: transport) { method, params in
                await box.handle(method: method, params: params)
            }
        }
        if connection != nil { Task { await self.attach() } }
    }

    private func attach() async {
        box.attach(self)
        await connection?.start()
    }

    /// Answer until the other end closes the pipe. Returns at once without one.
    public func run() async {
        guard let connection else { return }
        for await _ in connection.incomingNotifications() {
            // `notifications/initialized` and whatever else a client sends. None of it
            // needs an answer; draining the stream is what keeps this task alive.
        }
    }

    public func close() async {
        await connection?.close()
    }

    /// One request, answered: what the endpoint calls for each POST, and the pipe for
    /// each line. Anything not here (`server/discover`, which Claude and Copilot send
    /// before `initialize`, #186) is -32601, and the client carries on.
    func handle(method: String, params: JSONValue?) async -> Result<JSONValue, JSONRPCError> {
        switch method {
        case "initialize":
            let asked = params?["protocolVersion"]?.stringValue
            return .success([
                "protocolVersion": .string(asked ?? Self.protocolVersion),
                "capabilities": ["tools": ["listChanged": false], "resources": ["listChanged": false]],
                "serverInfo": ["name": "agents", "version": "1.0.0"],
            ])

        case "ping":
            return .success([:])

        case "tools/list" where writer:
            return .success(["tools": .array(Self.writerTools)])

        case "resources/list" where writer:
            return .success(["resources": []])

        case "tools/call" where writer:
            // The writer's tools and no other (FR-010): the agent writing a provider's map
            // has nothing else of the app's, as it has nothing of its runtime's.
            let name = params?["name"]?.stringValue ?? ""
            guard let tool = AppTool.writerTools.first(where: { name.hasSuffix($0) }) else {
                return .failure(JSONRPCError(code: JSONRPCError.invalidParams,
                                             message: "No tool called \(name.isEmpty ? "that" : name)."))
            }
            return .success(Self.reply(await draftSink(tool, params?["arguments"])))

        case "tools/list":
            // A view's tools too (#187), but never one only a view may call: no runtime
            // filters by `visibility`, so what the model is not to see is not listed.
            let views = AppViewCatalog.tools(testView: offersTestView).filter(\.forModel).map(\.definition)
            return .success(["tools": .array(Self.tools(movesItself: movesItself) + views)])

        case "resources/list":
            return .success(["resources": .array(AppViewCatalog.resources(testView: offersTestView).map(Self.listed))])

        case "resources/read":
            let uri = params?["uri"]?.stringValue ?? ""
            guard let resource = AppViewCatalog.resource(uri, testView: offersTestView) else {
                return .failure(JSONRPCError(code: JSONRPCError.invalidParams, message: "No resource at \(uri)."))
            }
            return .success(["contents": [Self.contents(resource)]])

        case "tools/call":
            let name = params?["name"]?.stringValue ?? ""
            let arguments = params?["arguments"]

            // Longest suffix wins, though nothing here shares one: a runtime is free
            // to prefix a tool's name and none of them changes what follows it.
            if let call = Self.selfCall(named: name, arguments, movesItself: movesItself) {
                switch call {
                case .failure(let problem): return .success(Self.reply(problem.message, isError: true))
                case .success(let call): return .success(Self.reply(await selfSink(call)))
                }
            }

            if let tool = AppViewCatalog.tool(named: name, testView: offersTestView) {
                guard tool.forModel else {
                    return .success(Self.reply("Nothing was done: \(tool.name) is for the view, not for you.",
                                               isError: true))
                }
                switch await viewToolSink(tool.name, arguments) {
                case .success(let result): return .success(result)
                case .failure(let problem): return .success(Self.reply(problem.message, isError: true))
                }
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

            if name.hasSuffix(Self.suggestNextPromptToolName) {
                guard let arguments,
                      let suggestion = SuggestedPrompt(wire: arguments),
                      arguments["label"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
                      arguments["prompt"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                    return .success(Self.reply("Nothing was suggested: send a non-empty `label` and `prompt`.",
                                               isError: true))
                }
                return .success(Self.reply(await suggestedPromptSink(suggestion)))
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

            if let call = Self.sessionCall(named: name, arguments) {
                switch call {
                case .failure(let problem): return .success(Self.reply(problem.message, isError: true))
                case .success(let call): return .success(Self.reply(await sessionsSink(call)))
                }
            }

            if let call = Self.workspaceCall(named: name, arguments) {
                switch call {
                case .failure(let problem): return .success(Self.reply(problem.message, isError: true))
                case .success(let call): return .success(Self.reply(await workspacesSink(call)))
                }
            }

            if let call = Self.agentCall(named: name, arguments) {
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

    /// Which of the calls on the agent's own session a tool is (#481), with its arguments
    /// read. `nil` when it is none of them — `archive_session` with an id is a helper's, and a
    /// `wait_for_event` on events is an event wait.
    static func selfCall(named name: String, _ arguments: JSONValue?,
                         movesItself: Bool) -> Result<SelfCall, AgentCallProblem>? {
        func given(_ key: String) -> Bool {
            let value = arguments?[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            return value?.isEmpty == false
        }
        func strings(_ key: String) -> Result<[String], AgentCallProblem> {
            guard let value = arguments?[key], value != .null else { return .success([]) }
            if let one = value.stringValue { return .success([one]) }
            guard let list = value.arrayValue, list.allSatisfy({ $0.stringValue != nil }) else {
                return .failure(AgentCallProblem(stringLiteral: "Nothing changed: `\(key)` must be a list of strings."))
            }
            return .success(list.compactMap(\.stringValue))
        }
        if name.hasSuffix(archiveSessionToolName), !given("id") { return .success(.afterTurn(.requestArchive)) }
        if name.hasSuffix(setSessionLabelsToolName) {
            let add: [String], remove: [String]
            switch strings("add") {
            case .success(let read): add = read
            case .failure(let problem): return .failure(problem)
            }
            switch strings("remove") {
            case .success(let read): remove = read
            case .failure(let problem): return .failure(problem)
            }
            guard !add.isEmpty || !remove.isEmpty else {
                return .failure("Nothing changed: give labels in add, remove, or both.")
            }
            return .success(.labels(add: add, remove: remove))
        }
        if name.hasSuffix(moveWorktreeToolName) {
            guard movesItself else {
                return .failure("""
                    Nothing was moved: this runtime cannot carry its conversation into \
                    another folder, so you stay where you are.
                    """)
            }
            return moveCall(arguments).map(SelfCall.move)
        }
        if name.hasSuffix(waitForEventToolName) {
            let action = arguments?["action"]?.stringValue?.lowercased() ?? "wait"
            let agents: [String]
            switch strings("agents") {
            case .success(let read): agents = read.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            case .failure(let problem): return .failure(problem)
            }
            let hasEvents = arguments?["events"]?.stringValue != nil
                || arguments?["events"]?.arrayValue?.isEmpty == false
            let minutes: Int? = arguments?["until_minutes"].flatMap { value in
                value.intValue ?? value.stringValue.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            }
            guard action == "wait", !hasEvents || !agents.isEmpty, !agents.isEmpty || minutes != nil else { return nil }
            guard !hasEvents else {
                return .failure("Nothing is waited for: name agents or events, not both. Wait on agent.finished for events about agents.")
            }
            var wakeOn: Block.WakeOn?
            if let raw = arguments?["wake_on"]?.stringValue {
                guard let known = Block.WakeOn(rawValue: raw) else {
                    return .failure(AgentCallProblem(stringLiteral: Block.unknownWakeOn))
                }
                wakeOn = known
            }
            guard let minutes else {
                return .failure(AgentCallProblem(stringLiteral: "Nothing is waited for: " + EventWords.deadlineRequired()))
            }
            if !Block.checkAgainMinutes.contains(minutes) {
                return .failure(AgentCallProblem(stringLiteral: """
                    Nothing is waited for: until_minutes has to be a whole number from \
                    \(Block.checkAgainMinutes.lowerBound) to \(Block.checkAgainMinutes.upperBound).
                    """))
            }
            let message = arguments?["message"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            return .success(.waitOn(agents: agents, wakeOn: wakeOn, untilMinutes: minutes,
                                    message: message?.isEmpty == false ? message : nil))
        }
        return nil
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
        if name.hasSuffix(startSessionToolName) {
            guard let prompt = text("prompt") else {
                return .failure("Nothing was started: say what the session is to do, in `prompt`.")
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
        if name.hasSuffix(stopSessionToolName) || name.hasSuffix(archiveSessionToolName) {
            guard let id = text("id") else {
                return .failure("Nothing changed: `id` has to be the id start_session or list_sessions gave.")
            }
            if name.hasSuffix(stopSessionToolName) { return .success(.stop(agentID: id)) }
            return .success(.requestArchive(agentID: id))
        }
        if name.hasSuffix(listSessionsToolName), text("started_by") == "me" {
            return .success(.list)
        }
        return nil
    }

    /// Which of the two session calls a tool name is, with its arguments read (065).
    /// `nil` when the name is neither.
    static func sessionCall(named name: String,
                            _ arguments: JSONValue?) -> Result<SessionCall, AgentCallProblem>? {
        if name.hasSuffix(listSessionsToolName) {
            let startedBy = arguments?["started_by"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            // The sessions this agent started are an agent call (#638).
            if startedBy == "me" { return nil }
            guard startedBy.isEmpty else {
                return .failure("Nothing was listed: `started_by` can only be me, or left out for every session.")
            }
            let after = arguments?["after"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            return .success(.list(limit: arguments?["limit"]?.intValue,
                                  after: after?.isEmpty == false ? after : nil))
        }
        if name.hasSuffix(readSessionToolName) {
            let value = arguments?["session"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !value.isEmpty else { return .failure(AgentCallProblem(stringLiteral: SessionLookup.noValue)) }
            return .success(.read(session: value))
        }
        if name.hasSuffix(messageSessionToolName) {
            let to = arguments?["to"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !to.isEmpty else {
                return .failure("Nothing was sent: say which session, by id or exact title, in `to`.")
            }
            let text = arguments?["message"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty else { return .failure("Nothing was sent: say what to tell it, in `message`.") }
            return .success(.message(to: to, text: text))
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

    /// Which of the two event calls a tool name is, with its arguments read (042).
    static func eventCall(named name: String,
                          _ arguments: JSONValue?) -> Result<EventCall, AgentCallProblem>? {
        /// Each key's value, one or a list (073 FR-016). The first key holding
        /// anything else, which used to be dropped without a word.
        func readFilters(_ value: JSONValue?) -> Result<[String: DetailFilter]?, AgentCallProblem> {
            guard let object = value?.objectValue else { return .success(nil) }
            var out: [String: DetailFilter] = [:]
            for key in object.keys.sorted() {
                guard let filter = object[key].flatMap(WorkflowTrigger.filter) else {
                    return .failure(AgentCallProblem(stringLiteral:
                        "Nothing is waited for: the \"\(key)\" in where is not a value. A value is text, "
                        + "a number, true or false, or a list of those, e.g. {\"branch\": [\"main\", \"develop\"]}."))
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
        return nil
    }

    /// Every tool this server offers, in the order they are listed.
    static func tools(movesItself: Bool = true) -> [JSONValue] {
        // `finish_turn` is gone (#479, #481, then removed): the app works out how a turn
        // ended, and an agent that needs the person asks them.
        // Starting, stopping and archiving sessions after the workflow tool, for every
        // agent, whoever started it (028, #940): the project's helper limits are the bound.
        let agentTools = [Self.startSessionTool, Self.stopSessionTool, Self.archiveSessionTool]
        // The three lease tools after those, for every agent: waiting for the
        // simulator is not managing anyone (036).
        let leaseTools = [Self.leaseResourceTool, Self.releaseResourceTool, Self.listResourcesTool]
        // The two event tools, for every agent (042).
        let eventTools = [Self.waitForEventTool, Self.cancelWaitTool]
        // The two for reading another session in this project, and the one for telling it
        // something, for every agent (065, #560).
        let sessionTools = [Self.listSessionsTool, Self.readSessionTool, Self.messageSessionTool]
        // The agent's own session: labels, and moving, which is not offered on a runtime
        // that would forget the conversation on the way (053, #481).
        let selfTools = [Self.setSessionLabelsTool] + (movesItself ? [Self.moveWorktreeTool] : [])
        // The control plane's workspaces, for every agent (#691 US6).
        let workspaceTools = [Self.listWorkspacesTool, Self.startWorkspaceTool, Self.stopWorkspaceTool,
                              Self.makeWorkspaceTool, Self.deleteWorkspaceTool]
        let tools = [Self.showFileTool, Self.workflowTool, Self.askFormTool, Self.suggestNextPromptTool]
            + agentTools + selfTools + sessionTools + leaseTools
            + eventTools + workspaceTools
        return tools.map(withCallDescription)
    }

    /// The optional `description` every app tool takes (#708): why the agent is making
    /// this call, in a sentence for the person. The chat draws any tool call by its
    /// `description` argument when it has one, as it already does for a shell command,
    /// so these calls read as the agent's reason rather than the tool's name. Added here
    /// rather than in each schema so no tool is left without it; the handlers ignore it.
    static let callDescriptionProperty: JSONValue = [
        "type": "string",
        "description": "Why you are making this call, in one short sentence for the person.",
    ]

    private static func withCallDescription(_ tool: JSONValue) -> JSONValue {
        guard case .object(var fields) = tool,
              case .object(var schema)? = fields["inputSchema"] else { return tool }
        var properties = schema["properties"]?.objectValue ?? [:]
        properties["description"] = callDescriptionProperty
        schema["properties"] = .object(properties)
        fields["inputSchema"] = .object(schema)
        return .object(fields)
    }

    /// Which workspace tool a call is (#691 US6), with its arguments read; nil for none. The
    /// token is the relay's to fill in.
    static func workspaceCall(named name: String, _ arguments: JSONValue?)
        -> Result<DaemonAPI.WorkspaceToolRequest, AgentCallProblem>? {
        func text(_ key: String) -> String? {
            guard let value = arguments?[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else { return nil }
            return value
        }
        let action: DaemonAPI.WorkspaceToolRequest.Action
        if name.hasSuffix(AppTool.listWorkspaces) { action = .list }
        else if name.hasSuffix(AppTool.startWorkspace) { action = .start }
        else if name.hasSuffix(AppTool.stopWorkspace) { action = .stop }
        else if name.hasSuffix(AppTool.makeWorkspace) { action = .make }
        else if name.hasSuffix(AppTool.deleteWorkspace) { action = .delete }
        else { return nil }
        switch action {
        case .start, .stop, .delete:
            guard text("host") != nil else { return .failure("Nothing was done: say which host, by its name, in `host`.") }
        case .make:
            guard text("provider") != nil, text("name") != nil else {
                return .failure("Nothing was made: say which `provider`, and the new workspace's `name`.")
            }
            if let options = arguments?["options"], options.objectValue == nil {
                return .failure("Nothing was made: `options` has to be an object of the provider's choices.")
            }
        case .list:
            break
        }
        return .success(DaemonAPI.WorkspaceToolRequest(
            token: "", action: action, host: text("host"), provider: text("provider"), name: text("name"),
            options: arguments?["options"], confirmRunning: arguments?["confirm_running"]?.boolValue))
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

    /// The move a `move_worktree` call asks for (053), with its arguments read. `nil` when
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

    /// A tool result is content plus a flag, and a failure inside the tool is reported
    /// this way rather than as a JSON-RPC error: the agent is meant to read it.
    private static func reply(_ text: String, isError: Bool = false) -> JSONValue {
        ["content": .array([["type": "text", "text": .string(text)]]), "isError": .bool(isError)]
    }

    private static func reply(_ outcome: Outcome) -> JSONValue {
        switch outcome {
        case .shown(let note): return reply(note)
        case .shownResult(let result): return result
        case .refused(let problem): return reply(problem, isError: true)
        }
    }

    /// What an agent is told about moving itself (053), on the tool that does it (#481).
    /// The move happens when the turn ends, so no stretch of the turn has edits landing in
    /// the folder being left. Words from contracts/move.md.
    static let moveWorktreeTool: JSONValue = [
        "name": .string(moveWorktreeToolName),
        "title": "Move to a worktree or back",
        "description": """
            Move once this turn ends: into a git worktree of this project, or back to the \
            project folder. Do it when the work turns into a change that should be on its \
            own branch, or when asked. You are started again there to carry on, or stay \
            there if you asked to be archived. Nothing uncommitted comes with you, and a new \
            worktree starts from the commit you have checked out: commit first. Give \
            neither argument to take back a move you asked for. Not with a wait.
            """,
        "inputSchema": [
            "type": "object",
            "properties": [
                "worktree": [
                    "type": "string",
                    "description": "A name for a new worktree, or the absolute path of one already there.",
                ],
                "leave_worktree": [
                    "type": "string",
                    "enum": .array(["keep", "remove"]),
                    "description": """
                        Back to the project folder. remove takes the worktree away, and its \
                        branch if the app made it and it is merged; refused if anything is \
                        uncommitted, or another agent works there.
                        """,
                ],
                "discard_changes": [
                    "type": "boolean",
                    "description": "Only with remove: remove even with uncommitted changes. Ask the person first.",
                ],
            ],
        ],
    ]

    /// The agent's own labels on its session (#481).
    static let setSessionLabelsTool: JSONValue = [
        "name": .string(setSessionLabelsToolName),
        "title": "Label this session",
        "description": "Add or remove your own labels on this session. The person's labels are theirs.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "add": ["type": "array", "items": ["type": "string"]],
                "remove": ["type": "array", "items": ["type": "string"]],
            ],
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
            holds it. For a flowchart or a sequence diagram, write it as Mermaid: a \
            ```mermaid fence in the document, or a file named *.mmd shown here \
            (graph/flowchart with its node shapes and links, no subgraphs; \
            sequenceDiagram with participants, messages, notes, loop/alt/opt). For \
            any other diagram, write an SVG file beside the document and reference \
            it as an image.

            For a chart, show a Vega-Lite spec (a file named *.vl.json: one mark of \
            bar, line, point or area; encoding x, y and an optional color field; \
            data.values inline or data.url naming a CSV beside it), or show a CSV \
            with `chart` saying how to draw it. Either is drawn as a chart, and the \
            conversation shows a card for every file shown here, with a preview of \
            a chart, a diagram or a picture.

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
                "chart": [
                    "type": "object",
                    "description": "For a CSV file: draw it as a chart of column y against column x.",
                    "properties": [
                        "mark": ["type": "string", "enum": ["bar", "line", "point", "area"]],
                        "x": ["type": "string", "description": "The column along the bottom."],
                        "y": ["type": "string", "description": "The column of numbers."],
                        "color": ["type": "string", "description": "A column that splits the rows into series."],
                        "title": ["type": "string"],
                    ],
                    "required": .array(["x", "y"]),
                ],
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
            something is mine to decide — anything hard to undo, spending money or \
            making an outside account, a restart or an install, a missing credential, \
            a choice with no clear best answer — rather than guessing or ending the \
            turn with the question in your reply. When you would mark one answer \
            recommended and it is easy to undo, do not ask: take it, and write \
            `Decided: <what>, because <why>.` where I will see it.

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

    /// Add or replace the single suggested prompt shown above the prompt bar.
    static let suggestNextPromptTool: JSONValue = [
        "name": .string(suggestNextPromptToolName),
        "title": "Suggest the next prompt",
        "description": "Near the end of your turn, optionally offer one useful next prompt. Call at most once; a later call replaces it. Use a 2–5 word label and the full prompt text.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "label": ["type": "string", "description": "A 2–5 word chip label."],
                "prompt": ["type": "string", "description": "The prompt sent when the person taps the chip."],
            ],
            "required": .array(["label", "prompt"]),
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

            A workflow meant only to be run by hand, with Run now on its page, says \
            `on: manual` (or leaves `on:` out). Nothing else runs it.

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

            `hosts:` names the computers that run it, by machine id: a Mac's hardware \
            UUID, or on Linux the contents of `/etc/machine-id`. Leave it out and every \
            host that has the project runs it and lists it. Name ids and only those \
            hosts run it and list it, on a schedule, on an event, or by hand. The id is \
            the computer's, not its name. The workflow page writes it from the hosts \
            the control plane knows; do not invent an id.

            `when-done:` says what a run may do with its session once it is done: \
            `keep` (the default) keeps every run in the list; `archive-allowed` lets a \
            run that finishes done or nothing_to_do archive itself; `archive` archives \
            every run that finishes so. Leave it out unless the person asks for runs to \
            be put away.

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

            A project may have at most \(WorkflowLimit.projectAllowed) workflows \
            waiting for approval; a write that would make another is refused until the \
            person approves or removes one. Approved workflows do not count towards \
            that. Those turned on count towards how many may run across every project, \
            which only the person sets (\(WorkflowLimit.defaultTotal) unless they changed \
            it); turning one on past it is refused until they turn one off or archive one.

            `disable` turns a workflow off without touching its file: it stays listed, \
            marked off, and none of its triggers run it; `list` says which are off and \
            why. `enable` turns one back on, but only one an agent turned off: one the \
            person turned off, one an agent wrote and nobody has turned on yet, and one \
            whose file says `enabled: false` are theirs to turn on.

            Under on:, besides schedule, any event name works, narrowed by what its \
            inputSchema below takes written under it, e.g. `- branch.moved:` with \
            `branch: main` under it. The project's MCP servers' events are listed by \
            wait_for_event with action list.
            """ + "\n" + EventList.text()),
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

    /// Start a session in this project (028).
    ///
    /// The description carries the limits because the agent needs them before it
    /// calls, not in a refusal after: this project only, two limits across the project
    /// that the person sets, and only the person frees a not-archived place. No number
    /// is written here: the limits are the project's own, and a result says them. And the restraint,
    /// as the workflow tool carries its own — an agent told it can start sessions will
    /// start sessions.
    static let startSessionTool: JSONValue = [
        "name": .string(startSessionToolName),
        "title": "Start a session in this project",
        "description": """
            Start another session in this project, with a prompt of its own, to do a part \
            of the work that can run alongside the rest. It starts in this project's \
            folder — there is no way to start one anywhere else — and appears in the \
            person's list of sessions, marked as started by you. The person can open it, \
            talk to it, stop it or archive it at any time.

            This project has two limits on sessions started by sessions, counting every \
            one here, which only the person sets (in Project Settings): how many may be \
            running — working, waiting on a question, or waiting to carry on by \
            itself — and how many may exist not yet archived, where stopped, finished \
            and asking-to-be-archived ones still count. A start that would break either is queued \
            instead, saying which: nothing runs yet, and it starts by itself, oldest \
            first, once a running place and a not-archived place are both free, behind \
            the working and waiting ones. So you can queue work up front rather than \
            wait and try again; wait for a queued session with wait_for_event as for any \
            other. A third limit says how many may be queued; past it a start is \
            refused. Use list_sessions with started_by me to see yours and how many places \
            of each are in use. Stop one with stop_session when its part is no longer \
            wanted: that frees its running place, and it keeps its other place until it \
            is archived. Once its work is merged or abandoned, call archive_session on it \
            to free that place too (at once where the person allows it, otherwise by \
            asking them); archive a finished session rather than removing its worktree \
            under it.

            Start one only when part of the work can genuinely run alongside the rest. \
            Do not start one for work you could simply do yourself. The session you \
            start cannot start sessions of its own.

            Returns the new session's id, which stop_session and archive_session take.
            """,
        "inputSchema": [
            "type": "object",
            "properties": [
                "prompt": [
                    "type": "string",
                    "description": "What the new session is to do. Sent to it as its first message.",
                ],
                "runtime": [
                    "type": "string",
                    "description": """
                        Optional. The runtime to run it on, by id, as a workflow's \
                        `runtime:`; leave out for the default. list_sessions with started_by me ends with \
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
                        Optional. Where the new session works. Leave out to work in the \
                        project folder. "new" makes a fresh git worktree, on its own \
                        branch, named from the prompt — for parallel work that should \
                        not touch the same files. Or the name of a worktree of this \
                        repository that is already there, as `git worktree list` shows it. \
                        Or the name of a branch not checked out anywhere, local or on a \
                        remote, to make a fresh worktree on that branch.
                        """,
                ],
                "labels": ["type": "array", "items": ["type": "string"],
                           "description": "Labels for the new session, owned by that session."],
            ],
            "required": .array(["prompt"]),
        ],
    ]

    /// The id stop takes.
    private static let sessionIDSchema: JSONValue = [
        "type": "object",
        "properties": [
            "id": [
                "type": "string",
                "description": "The id start_session or list_sessions gave.",
            ],
        ],
        "required": .array(["id"]),
    ]

    static let stopSessionTool: JSONValue = [
        "name": .string(stopSessionToolName),
        "title": "Stop a session you started",
        "description": """
            Stop a session you started with start_session, as the person's own Stop would. \
            It stays in the list with its conversation. Stopping frees its running \
            place; it keeps its not-archived place until it is archived. Stopping a \
            queued one takes it off the queue, and it never starts. Only sessions you \
            started, and the ones they started, can be stopped this way; not yourself, \
            and not anyone else's.
            """,
        "inputSchema": sessionIDSchema,
    ]

    /// The id archive takes, which may be left out to mean the caller (#481).
    private static let ownOrStartedIDSchema: JSONValue = [
        "type": "object",
        "properties": [
            "id": [
                "type": "string",
                "description": "The id start_session or list_sessions gave. Leave out for yourself.",
            ],
        ],
    ]

    static let archiveSessionTool: JSONValue = [
        "name": .string(archiveSessionToolName),
        "title": "Archive this session or one you started",
        "description": """
            With no id: archive this session once this turn ends, when you have \
            finished and cleaned up. Only if the turn ends done, nothing_to_do or \
            partly_done; anything the person sends first drops it. Where nobody needs \
            to approve it — your workflow lets its run archive itself, or the session \
            that started you may archive you — it is archived, if the turn ends done or \
            nothing_to_do. Otherwise the person approves archiving it from your row, or \
            leaves it. Goes with move_worktree: you move, and stay there waiting for \
            approval.

            With an id: the same for a session you started with start_session, or one it \
            started, once its work is merged or abandoned. Where this project lets you archive the sessions \
            you started (a Project Settings switch) it is archived now, or once its turn \
            ends; otherwise the person approves it. Either way its running place is freed \
            once it is done; it keeps its not-archived place until it is archived. Archive \
            a finished session rather than removing its worktree under it. Never the \
            person's own sessions or another session's.
            """,
        "inputSchema": ownOrStartedIDSchema,
    ]

    // MARK: Sessions (065). Words from contracts/session-tools.md.

    static let listSessionsTool: JSONValue = [
        "name": .string(listSessionsToolName),
        "title": "List the sessions in this project",
        "description": """
            The sessions in this project, a page at a time: the ones not archived first, \
            then the archived, each most recent first, yours included. Each one's \
            id, title, runtime, status, worktree and branch, the resources it holds, labels with owners, \
            and what it last said. The page ends by saying how many more there are and \
            what to pass as `after` for the next. Use it to find a session \
            the person asks you to continue, then read it with read_session.

            With started_by me: only the sessions you started with start_session, and \
            the ones they started, that have not been archived, each one's id, what it is doing, what it last said, \
            and its labels with owners; first, how many of this project's running and \
            not-archived places are in use out of the limits the person set, and which \
            of yours are queued and where; last, which runtimes start_session can start \
            one on here, as of now, with the model each starts on where known, and why \
            the others cannot. Archive the finished ones whose work is merged or \
            abandoned with archive_session, so their places are free for the next.
            """,
        "inputSchema": [
            "type": "object",
            "properties": [
                "limit": [
                    "type": "integer",
                    "description": "How many sessions to list, at most 100. 30 when left out.",
                ],
                "after": [
                    "type": "string",
                    "description": "The id of the last session the previous page listed, for the next page.",
                ],
                "started_by": [
                    "type": "string",
                    "enum": ["me"],
                    "description": "me: only the sessions you started, with the limits and runtimes.",
                ],
            ],
        ],
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

    static let messageSessionTool: JSONValue = [
        "name": .string(messageSessionToolName),
        "title": "Tell another session something",
        "description": .string("""
            Say something to another session in this project, which it reads as a prompt \
            marked as yours, not the person's; the person sees it in that chat too. A session \
            that is working gets it after its turn; one that is done or asking to be archived is woken by it, \
            whoever started it, within the project's running limit for sessions started by sessions; \
            one that is stopped waits until it is next started. \
            It never answers a question that session is waiting on. A reply comes back the \
            same way, as a message to you. Limits: \(AgentMessageLimits.characters) characters, \
            \(AgentMessageLimits.perHour) an hour, and at most \(AgentMessageLimits.hops) messages \
            between sessions in a row with no prompt from the person.
            """),
        "inputSchema": [
            "type": "object",
            "properties": [
                "to": [
                    "type": "string",
                    "description": "The session's id, as list_sessions gave it, or its exact title.",
                ],
                "message": [
                    "type": "string",
                    "description": "What to tell it.",
                ],
            ],
            "required": ["to", "message"],
        ],
    ]

    // MARK: Events (042). Words from contracts/event-tools.md.

    static let waitForEventTool: JSONValue = [
        "name": .string(waitForEventToolName),
        "title": "Wait for something to happen",
        "description": """
            Wait until something happens: an event in this project or on this Mac, such as \
            agent.finished, workflow.completed, mac.wake or branch.moved. Your \
            turn can end while you wait, and it costs nothing: when the event happens you \
            are started again with it. The call itself waits up to 45 seconds; if nothing \
            has happened by then it says you are still waiting and keeps your place. Use \
            this instead of polling. Also lists recent events (action "recent") and every \
            event you can wait on (action "list"). The same names work as workflow triggers. \
            An MCP server's event (such as pr.merged) is checked against what the project's \
            servers offer, and the wait subscribes to it until it ends.

            To wait for agents, name them in agents instead of events: your turn ends at \
            once, and you are resumed with how each ended when all have finished (or the \
            first, with wake_on any). until_minutes, with agents or alone, resumes you then \
            anyway, to check on something the app can't see, like CI; say what in message. \
            Anything you started in the background stops when the turn ends.

            Every wait needs until_minutes, so none can last for ever: when it runs out you \
            are started again, and can wait again.
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
                        Narrow them by what each event's inputSchema takes in action list: \
                        branch on branch.moved, e.g. {"branch": "agents/fix-640"}, or why on person.away \
                        and person.back. A list means any of them, e.g. {"why": ["locked", \
                        "idle"]}. For an MCP server's event, such as pr.merged, these are its \
                        own, sent to it, e.g. {"pr": 640}; server narrows which \
                        servers. Nothing else narrows an event.
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
                    "description": """
                        Required to wait: give up after this many minutes, 1 to 1440. You are \
                        started again either way, and can wait again.
                        """,
                ],
                "agents": [
                    "type": "array",
                    "items": ["type": "string"],
                    "description": "Agents in this project to wait for, by id or exact title.",
                ],
                "wake_on": [
                    "type": "string",
                    "enum": ["any", "all"],
                    "description": "With agents: all (the default) or any.",
                ],
                "message": [
                    "type": "string",
                    "description": "With agents or until_minutes alone: what you are waiting for, for the person's row.",
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

    // MARK: Workspaces (#691 US6)

    private static let hostProperty: JSONValue = [
        "type": "string",
        "description": "The host, by its name as list_workspaces gives it.",
    ]

    static let listWorkspacesTool: JSONValue = [
        "name": .string(AppTool.listWorkspaces),
        "title": "List workspaces",
        "description": """
            The machines this control plane's hosts run on, from every workspace provider:             each workspace's state, the host it is linked to and that host's state, and, for             a provider that can make workspaces, the choices a new one takes.
            """,
        "inputSchema": ["type": "object", "properties": [:]],
        "annotations": ["readOnlyHint": true],
    ]

    static let startWorkspaceTool: JSONValue = [
        "name": .string(AppTool.startWorkspace),
        "title": "Start a workspace",
        "description": """
            Start the workspace a stopped host runs on. It answers at once; the host is up             when it connects, which you can wait for with wait_for_event on server.online.             Then you can start a session in a project there.
            """,
        "inputSchema": ["type": "object", "properties": ["host": hostProperty], "required": .array(["host"])],
    ]

    static let stopWorkspaceTool: JSONValue = [
        "name": .string(AppTool.stopWorkspace),
        "title": "Stop a workspace",
        "description": """
            Stop the workspace a host runs on. Every agent there stops with it. While agents             are working there it is refused, naming them, unless confirm_running is true.
            """,
        "inputSchema": [
            "type": "object",
            "properties": [
                "host": hostProperty,
                "confirm_running": ["type": "boolean", "description": "Stop it even though agents are working there."],
            ],
            "required": .array(["host"]),
        ],
    ]

    static let makeWorkspaceTool: JSONValue = [
        "name": .string(AppTool.makeWorkspace),
        "title": "Make a workspace",
        "description": """
            Make a new workspace at a provider that can (see list_workspaces), which joins as             a host of the same name. The person is asked first, on the question card, and             nothing is made without their yes. It may cost money while it runs.
            """,
        "inputSchema": [
            "type": "object",
            "properties": [
                "provider": ["type": "string", "description": "The provider, by its name or id from list_workspaces."],
                "name": ["type": "string", "description": "The new workspace's and host's name: letters, digits and dashes."],
                "options": ["type": "object", "description": "Its choices, as the provider's options in list_workspaces describe them."],
            ],
            "required": .array(["provider", "name"]),
        ],
    ]

    static let deleteWorkspaceTool: JSONValue = [
        "name": .string(AppTool.deleteWorkspace),
        "title": "Delete a workspace",
        "description": """
            Delete the workspace a host runs on, with everything on its disk, and remove the             host and its agents. The person is asked first, on the question card, and nothing             is deleted without their yes.
            """,
        "inputSchema": ["type": "object", "properties": ["host": hostProperty], "required": .array(["host"])],
        "annotations": ["destructiveHint": true],
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
