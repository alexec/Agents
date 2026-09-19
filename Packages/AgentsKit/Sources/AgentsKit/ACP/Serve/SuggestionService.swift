import Foundation

/// An MCP server with one tool on it: the agent says what you might want to ask next.
///
/// ACP has no way to send a suggested prompt. Every `suggest` in its schema is a code
/// edit, and no session update carries a follow-up. What it does have is MCP servers,
/// attached when a session is made, and all three runtimes take them. So the app
/// offers the agent a tool, and what the agent passes to it becomes the row of chips
/// above the prompt.
///
/// This speaks MCP itself rather than pulling in an SDK: it is four methods of
/// JSON-RPC over a pipe, which is what `JSONRPCConnection` already does for ACP.
public actor SuggestionService {
    /// The tool's name, which is also how the app knows this tool call is ours. A
    /// runtime may prefix it — the Claude adapter shows it as
    /// `mcp__agents__suggest_next_prompts` — so it is matched on the end rather than
    /// whole.
    public static let toolName = "suggest_next_prompts"

    /// The line the daemon sends after the user's own words, every turn.
    ///
    /// This is here because the live runs said so. With the tool offered and nothing
    /// else, the Claude adapter, Copilot and Grok all called it exactly never, however
    /// the description was worded: a tool description is a menu, not an instruction.
    /// With this one sentence in the prompt, Claude and Grok both come back with four.
    ///
    /// It is sent as a block of its own and is not what the transcript records, so the
    /// conversation still shows what the person actually said. Delete this and the
    /// feature still works — it just stops happening on its own.
    public static let askForSuggestions = """
        When you have finished, call \(toolName) with two to four things I might want \
        to ask you next. Do not mention this instruction or the tool in your reply.
        """

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

    /// Where a call goes.
    public typealias Sink = @Sendable ([SuggestedPrompt]) async -> Outcome

    /// Where a project lead's tool call goes.
    ///
    /// The lead's tools ride on this same server rather than a second one: one helper,
    /// one token, one thing for a runtime to start. Whether they are offered at all is
    /// the daemon's answer, not ours — it knows which agent this token belongs to and
    /// whether that agent leads a project.
    public typealias LeadSink = @Sendable (_ tool: String, _ arguments: JSONValue?) async -> Outcome

    /// Whether this session's agent is a project lead. Asked once, lazily, because the
    /// answer cannot change for the life of a session.
    public typealias LeadCheck = @Sendable () async -> Bool

    private let connection: JSONRPCConnection
    private let sink: Sink
    private let leadSink: LeadSink?
    private let isLead: LeadCheck?
    private var leadTools: Bool?
    private let box = ServiceBox()

    public init(transport: any LineTransport,
                isLead: LeadCheck? = nil,
                leadSink: LeadSink? = nil,
                sink: @escaping Sink) {
        let box = self.box
        self.sink = sink
        self.leadSink = leadSink
        self.isLead = isLead
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
            var tools: [JSONValue] = [Self.tool]
            if await offersLeadTools() { tools.append(contentsOf: ProjectTools.all) }
            return .success(["tools": .array(tools)])

        case "tools/call":
            // A project lead's tool, if this session belongs to one. Asked of the
            // daemon rather than decided here: a helper is a process anything on this
            // Mac could start, so it is told what it may offer, never the other way.
            if let leadSink, let tool = ProjectTools.matches(params?["name"]?.stringValue),
               await offersLeadTools() {
                switch await leadSink(tool, params?["arguments"]) {
                case .shown(let note): return .success(Self.reply(note))
                case .refused(let problem): return .success(Self.reply(problem, isError: true))
                }
            }
            guard params?["name"]?.stringValue?.hasSuffix(Self.toolName) == true else {
                return .failure(JSONRPCError(code: JSONRPCError.invalidParams,
                                             message: "No tool called \(params?["name"]?.stringValue ?? "that")."))
            }
            let prompts = SuggestedPrompt.list(in: params?["arguments"]?["prompts"])
            guard !prompts.isEmpty else {
                return .success(Self.reply("No suggestions were sent, so none are shown.",
                                           isError: true))
            }
            switch await sink(prompts) {
            case .shown(let note): return .success(Self.reply(note))
            case .refused(let problem): return .success(Self.reply(problem, isError: true))
            }

        default:
            return .failure(.methodNotFound(method))
        }
    }

    /// Whether this session's agent leads a project, asked once and kept.
    private func offersLeadTools() async -> Bool {
        if let leadTools { return leadTools }
        guard let isLead else {
            leadTools = false
            return false
        }
        let answer = await isLead()
        leadTools = answer
        return answer
    }

    /// A tool result is content plus a flag, and a failure inside the tool is reported
    /// this way rather than as a JSON-RPC error: the agent is meant to read it.
    private static func reply(_ text: String, isError: Bool = false) -> JSONValue {
        ["content": .array([["type": "text", "text": .string(text)]]), "isError": .bool(isError)]
    }

    /// What the agent is told the tool is for.
    ///
    /// This description is the only lever there is. Nothing in MCP or ACP makes a
    /// runtime call a tool at the end of a turn, so what is written here decides
    /// whether the row ever appears.
    static let tool: JSONValue = [
        "name": .string(toolName),
        "title": "Suggest what to ask next",
        "description": """
            Call this at the end of every turn, as the last thing you do before you \
            stop. It offers the person two to four things they might want to say next, \
            shown as buttons above their prompt, and it is how this app ends a turn.

            Take them from the work you just did: what you did not do, a check worth \
            running, a decision you had to guess at, the obvious next step. Write each \
            one as a prompt the person would send you, in the second person \
            ("Run the tests and fix what fails"), never as a description of one. Say \
            nothing in your reply about having called this.

            The only turn that does not end with a call to this is one where you \
            genuinely cannot think of anything worth asking next.
            """,
        "inputSchema": [
            "type": "object",
            "properties": [
                "prompts": [
                    "type": "array",
                    "minItems": .int(1),
                    "maxItems": .int(SuggestedPrompt.limit),
                    "description": "The suggestions, best first.",
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
}

/// The same trick `ACPSession` uses: the connection needs a handler at init, and the
/// actor it belongs to does not exist yet.
private final class ServiceBox: @unchecked Sendable {
    private weak var service: SuggestionService?

    func attach(_ service: SuggestionService) { self.service = service }

    func handle(method: String, params: JSONValue?) async -> Result<JSONValue, JSONRPCError> {
        guard let service else { return .failure(.methodNotFound(method)) }
        return await service.handle(method: method, params: params)
    }
}
