import Foundation

/// The writer's tools (#858, contracts/writer-tools.md): what the agent writing a provider's
/// tool map or commands is offered, and all it is offered. Each one is answered by the
/// control plane, which holds the draft, the secrets and the server or the CLI.
extension AppService {
    static let draftProperty: JSONValue = [
        "type": "object",
        "description": "The tool map, or the command provider's config, as JSON.",
    ]

    static let writerTools: [JSONValue] = [
        [
            "name": .string(AppTool.readTools),
            "title": "Read the server's tools",
            "description": """
                The MCP server's tools, as the control plane read them: each one's name, \
                description, input schema and annotations. Secrets are shown as ${NAME}.
                """,
            "inputSchema": ["type": "object", "properties": [:]],
            "annotations": ["readOnlyHint": true],
        ],
        [
            "name": .string(AppTool.readHelp),
            "title": "Read the CLI's help",
            "description": """
                The output of `<cli> <words…> --help`, run where the control plane runs. Give \
                no words for the CLI's own help. Each word is a subcommand the help printed: \
                at most three, none starting with -. Nothing else is run.
                """,
            "inputSchema": [
                "type": "object",
                "properties": ["words": ["type": "array", "items": ["type": "string"]]],
            ],
            "annotations": ["readOnlyHint": true],
        ],
        [
            "name": .string(AppTool.checkDraft),
            "title": "Check a draft",
            "description": """
                Check a tool map or config as Add Provider does, and list the workspaces once \
                with it. Answers what it listed, or why it failed. A list that may change \
                something is asked of the person first. At most 8 checks.
                """,
            "inputSchema": ["type": "object", "properties": ["draft": draftProperty], "required": .array(["draft"])],
        ],
        [
            "name": .string(AppTool.proveStart),
            "title": "Ask to start a workspace",
            "description": """
                Ask the person to start one workspace from the last list with the draft's start, \
                to prove it. It costs money and changes a machine, so the person is asked each \
                time; a no is an answer. Only when you are not sure of the start.
                """,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "draft": draftProperty,
                    "workspace": ["type": "string", "description": "The workspace's id or name, from the last list."],
                ],
                "required": .array(["draft", "workspace"]),
            ],
        ],
        [
            "name": .string(AppTool.proveStop),
            "title": "Ask to stop a workspace",
            "description": "As prove_start, with the draft's stop.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "draft": draftProperty,
                    "workspace": ["type": "string", "description": "The workspace's id or name, from the last list."],
                ],
                "required": .array(["draft", "workspace"]),
            ],
        ],
        [
            "name": .string(AppTool.sendDraft),
            "title": "Send the draft",
            "description": """
                Your result: the person reads it in the form and adds it. Send a draft that \
                passed check_draft. `note` is up to three lines for the person: what you did \
                not try, what to look at. Then end your turn.
                """,
            "inputSchema": [
                "type": "object",
                "properties": ["draft": draftProperty, "note": ["type": "string"]],
                "required": .array(["draft"]),
            ],
        ],
        [
            "name": .string(AppTool.giveUp),
            "title": "Give up",
            "description": "End with no draft, saying why in one sentence for the person. Then end your turn.",
            "inputSchema": [
                "type": "object",
                "properties": ["reason": ["type": "string"]],
                "required": .array(["reason"]),
            ],
        ],
    ]
}
