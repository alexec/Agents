import Foundation
import AgentsKitCore

// The project's pinned pages (#159) and pinned sessions (#180): four tools every agent
// has, helpers included.
extension AppService {
    public static let pinPageToolName = AppTool.pinPage
    public static let unpinPageToolName = AppTool.unpinPage
    public static let movePinToolName = AppTool.movePin
    public static let pinSessionToolName = AppTool.pinSession

    /// One of the pin calls, as the agent made it. Its arguments go to the daemon as they
    /// are: it is the one place that knows a pin's rules.
    public enum PinCall: Sendable, Equatable {
        /// `pin_page`, `unpin_page` and `move_pin` (#159): the project's pinned pages.
        case pin(arguments: JSONValue)
        case unpin(arguments: JSONValue)
        case movePin(arguments: JSONValue)
        /// `pin_session` (#180): the caller's own session, at the top of its project.
        case pinSession(arguments: JSONValue)
    }

    /// Where those go.
    public typealias PinsSink = @Sendable (PinCall) async -> Outcome

    /// Which of the four a tool name is. `nil` when none.
    static func pinCall(named name: String,
                        _ arguments: JSONValue?) -> Result<PinCall, AgentCallProblem>? {
        // unpin_page before pin_page: it ends with it, and a name is matched by its end.
        if name.hasSuffix(unpinPageToolName) { return .success(.unpin(arguments: arguments ?? .object([:]))) }
        if name.hasSuffix(pinPageToolName) { return .success(.pin(arguments: arguments ?? .object([:]))) }
        if name.hasSuffix(movePinToolName) { return .success(.movePin(arguments: arguments ?? .object([:]))) }
        if name.hasSuffix(pinSessionToolName) { return .success(.pinSession(arguments: arguments ?? .object([:]))) }
        return nil
    }

    static let pinPageTool: JSONValue = [
        "name": .string(pinPageToolName),
        "title": "Pin a page to the project",
        "description": """
            Pin a Markdown document or HTML page in this project under the project in the \
            person's sidebar, such as a roadmap, a coverage report or \
            a review the person will come back to. It opens live, as show_file does. Pin \
            what lasts, not what you are writing this turn (show it with show_file). The \
            path is in the project folder: an agent in a worktree pins the same path, and \
            the pin opens the project folder's copy once the branch lands. Pinning a path \
            already pinned changes only its title. Or pin a view (`view` instead of \
            `path`): a ui:// view of the agents server, opened by calling the read-only \
            tool that feeds it with the arguments given. The pins are kept in \
            .agents/pins.json in the project folder; never edit it by hand. At most 10 a \
            project, pages and views together.
            """,
        "inputSchema": [
            "type": "object",
            "properties": [
                "path": ["type": "string",
                         "description": "The .md or .html file, from the project folder (e.g. docs/roadmap.md), or absolute."],
                "view": [
                    "type": "object",
                    "description": "A view to pin instead of a file. Its arguments are shared through git: never a secret.",
                    "properties": [
                        "server": ["type": "string", "description": "The MCP server whose view it is: agents."],
                        "uri": ["type": "string", "description": "The view's ui:// address."],
                        "tool": ["type": "string",
                                 "description": "The read-only tool that feeds the view, called each time the pin opens."],
                        "arguments": ["type": "object", "description": "That tool's arguments, at most 2 KB of JSON."],
                    ],
                    "required": .array(["server", "uri", "tool"]),
                ],
                "title": ["type": "string", "description": "What the row says, up to 60 characters. The file's name if left out."],
                "position": ["type": "string", "enum": ["first", "last"], "description": "Where among the pins; last if left out."],
            ],
        ],
    ]

    static let unpinPageTool: JSONValue = [
        "name": .string(unpinPageToolName),
        "title": "Unpin a page",
        "description": "Unpin a page or view you pinned (or your workflow did) from the project. The file is left as it is.",
        "inputSchema": [
            "type": "object",
            "properties": ["path": ["type": "string",
                                    "description": "The pinned file, from the project folder, or a pinned view's ui:// address."]],
            "required": .array(["path"]),
        ],
    ]

    static let movePinTool: JSONValue = [
        "name": .string(movePinToolName),
        "title": "Move a pinned page",
        "description": """
            Put a pinned page somewhere else among the project's pins: before or after \
            another, or first or last. Any pin, as the person can drag any pin; the latest \
            move wins. Only when asked.
            """,
        "inputSchema": [
            "type": "object",
            "properties": [
                "path": ["type": "string", "description": "The pinned page to move, or a pinned view's ui:// address."],
                "before": ["type": "string", "description": "Put it just before this pinned page or view."],
                "after": ["type": "string", "description": "Put it just after this pinned page or view."],
                "position": ["type": "string", "enum": ["first", "last"]],
            ],
            "required": .array(["path"]),
        ],
    ]

    static let pinSessionTool: JSONValue = [
        "name": .string(pinSessionToolName),
        "title": "Pin this session",
        "description": """
            Pin this session at the top of its project in the person's sidebar, under the \
            pinned pages, where it stays whatever state it is in, so the person can always \
            find it. For a long-running session the person keeps coming back to, such as a \
            project lead or an intake chat; only when it is that, or when asked. With \
            pinned false, unpin it, if you were the one who pinned it. The person can unpin \
            any session. Archiving a session unpins it. At most 10 a project.
            """,
        "inputSchema": [
            "type": "object",
            "properties": [
                "pinned": ["type": "boolean", "description": "true (the default) to pin this session; false to unpin it."],
                "position": ["type": "string", "enum": ["first", "last"],
                             "description": "Where among the pinned sessions; last if left out."],
            ],
        ],
    ]
}
