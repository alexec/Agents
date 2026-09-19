import Foundation

/// The MCP server the app serves every agent: the things an agent can ask of the
/// window rather than of the machine.
///
/// ACP has no way to send a suggested prompt, and no way to say "look at this file".
/// Every `suggest` in its schema is a code edit, no session update carries a follow-up,
/// and a `resource_link` is a thing handed over rather than a thing opened. What ACP
/// does have is MCP servers, attached when a session is made, and all four runtimes
/// take them. So the app offers the agent tools of its own: what one passes to
/// `suggest_next_prompts` becomes the row of chips above the prompt, and what it
/// passes to `show_file` becomes the file open in the sidebar.
///
/// This speaks MCP itself rather than pulling in an SDK: it is four methods of
/// JSON-RPC over a pipe, which is what `JSONRPCConnection` already does for ACP.
public actor AppService {
    /// The suggestion tool's name, which is also how the app knows a tool call is
    /// ours. A runtime may prefix it — the Claude adapter shows it as
    /// `mcp__agents__suggest_next_prompts` — so it is matched on the end rather than
    /// whole.
    public static let toolName = AppTool.suggestPrompts

    /// The other one: show the user a file.
    public static let showFileToolName = AppTool.showFile

    /// And the third: read and write the project's standing arrangements.
    public static let workflowToolName = AppTool.manageWorkflows

    /// The line about this tool that the daemon sends after the user's own words on
    /// the first prompt of a conversation. See `Briefing`, which holds it and the rest
    /// of what an agent is told, and says why saying it in words is necessary at all.
    public static let askForSuggestions = Briefing.suggestions

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

    private let connection: JSONRPCConnection
    private let sink: Sink
    private let fileSink: FileSink
    private let workflowSink: WorkflowSink
    private let box = ServiceBox()

    public init(transport: any LineTransport,
                sink: @escaping Sink,
                showFile: @escaping FileSink = { _ in .refused("This app cannot show a file.") },
                workflows: @escaping WorkflowSink = { _, _, _ in
                    .refused("This app cannot manage workflows.")
                }) {
        let box = self.box
        self.sink = sink
        self.fileSink = showFile
        self.workflowSink = workflows
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
            return .success(["tools": .array([Self.tool, Self.showFileTool, Self.workflowTool])])

        case "tools/call":
            let name = params?["name"]?.stringValue ?? ""
            let arguments = params?["arguments"]

            // Longest suffix wins, though nothing here shares one: a runtime is free
            // to prefix a tool's name and none of them changes what follows it.
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

            return .failure(JSONRPCError(code: JSONRPCError.invalidParams,
                                         message: "No tool called \(name.isEmpty ? "that" : name)."))

        default:
            return .failure(.methodNotFound(method))
        }
    }

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

            It shows; it does not edit, select or run anything, and the pane it opens \
            in is read-only. The file has to be inside the folders this agent was \
            given, and has to exist.

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
        "description": """
            List, read, create, change and remove this project's agentic workflows. A \
            workflow is a prompt that runs itself when something happens — on a \
            schedule, or when an agent finishes, asks for permission, raises a form, \
            or stops.

            A workflow is a Markdown file with YAML front matter. The front matter says \
            what makes it run (`on:`) and which agent runs it (`agent:` — `new`, \
            `standing`, or `triggering`); everything under the front matter is the \
            prompt, sent verbatim.

            Listing and reading ask nobody. Creating, changing or removing one asks the \
            person first, in plain words, and does nothing if they decline.
            """,
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
                        ---

                        Check the build and say whether it is green.
                        """,
                ],
            ],
            "required": .array(["action"]),
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
