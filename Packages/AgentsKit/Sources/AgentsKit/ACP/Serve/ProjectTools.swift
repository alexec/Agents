import Foundation

/// The tools a project lead is offered, as MCP sees them.
///
/// Definitions only. Nothing here decides anything: every rule about who may call
/// these and what happens when they do lives in the daemon, where a test reaches it.
/// This is the menu, and the menu is the only lever there is for whether a runtime
/// ever picks one up.
public enum ProjectTools {
    public static let names = ["list_agents", "start_agent", "prompt_agent",
                               "read_transcript", "stop_agent"]

    /// Whether a tool call by this name is one of ours.
    ///
    /// Matched on the end, because a runtime is free to prefix it: the Claude adapter
    /// shows the suggestion tool as `mcp__agents__suggest_next_prompts`.
    public static func matches(_ name: String?) -> String? {
        guard let name else { return nil }
        return names.first { name.hasSuffix($0) }
    }

    /// What the lead is told it can do. Written in the second person because it is the
    /// lead reading it, and it is the only place that says what this agent is for.
    public static let all: [JSONValue] = [listAgents, startAgent, promptAgent,
                                          readTranscript, stopAgent]

    static let listAgents: JSONValue = [
        "name": "list_agents",
        "title": "List the agents in this project",
        "description": """
            Every agent working in this project: its id, what it is called, whether it \
            needs the person, is working, or is done, and what it cost. Start here when \
            you are asked how things are going. This does not change anything and the \
            person is not asked about it.
            """,
        "inputSchema": ["type": "object", "properties": [:]],
    ]

    static let startAgent: JSONValue = [
        "name": "start_agent",
        "title": "Start an agent on a piece of work",
        "description": """
            Start a new agent in this project's folder and give it one job. Use this to \
            split work up: one agent per piece, each with an instruction it can act on \
            without needing the rest. Write the instruction the way the person would \
            write it to you.

            The person is asked before this happens, and may decline. You cannot start \
            another project lead, and you cannot start anything outside this project.
            """,
        "inputSchema": [
            "type": "object",
            "properties": [
                "instruction": ["type": "string",
                                "description": "What this agent should do, in full. It cannot see your conversation."],
                "title": ["type": "string",
                          "description": "A few words naming the job, for the person's list."],
                "runtime": ["type": "string",
                            "description": "Which runtime to use. Leave this out to use the same one you are running on."],
            ],
            "required": .array(["instruction"]),
        ],
    ]

    static let promptAgent: JSONValue = [
        "name": "prompt_agent",
        "title": "Give an agent more to do",
        "description": """
            Send more words to an agent that is already going. If it is mid-turn this \
            waits its turn rather than interrupting. Use it to answer a question it \
            raised, to correct it, or to give it the next piece.

            The person is asked before this happens.
            """,
        "inputSchema": [
            "type": "object",
            "properties": [
                "agent": ["type": "string", "description": "The agent's id, from list_agents."],
                "text": ["type": "string", "description": "What to tell it."],
            ],
            "required": .array(["agent", "text"]),
        ],
    ]

    static let readTranscript: JSONValue = [
        "name": "read_transcript",
        "title": "Read what an agent has been doing",
        "description": """
            The conversation an agent in this project has had: what it was asked, what \
            it said, what it did. Read this before reporting on it, rather than \
            guessing from its state. This does not change anything and the person is \
            not asked about it.
            """,
        "inputSchema": [
            "type": "object",
            "properties": [
                "agent": ["type": "string", "description": "The agent's id, from list_agents."],
                "limit": ["type": "integer", "description": "How many entries, newest last. 50 by default."],
            ],
            "required": .array(["agent"]),
        ],
    ]

    static let stopAgent: JSONValue = [
        "name": "stop_agent",
        "title": "Stop an agent",
        "description": """
            Stop an agent in this project that has gone wrong or is no longer needed. \
            It keeps everything it has done; it just stops going.

            The person is asked before this happens. You cannot stop yourself — ask the \
            person to do that.
            """,
        "inputSchema": [
            "type": "object",
            "properties": [
                "agent": ["type": "string", "description": "The agent's id, from list_agents."],
                "reason": ["type": "string", "description": "Why, for the record."],
            ],
            "required": .array(["agent"]),
        ],
    ]
}
