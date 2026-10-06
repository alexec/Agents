import Foundation
import AgentsKitCore

// The project's Dashboard (074): four tools every agent has, helpers included. Words
// from specs/074-project-dashboard/contracts/agent-tools.md.
extension AppService {
    public static let setTileToolName = AppTool.setTile
    public static let removeTileToolName = AppTool.removeTile
    public static let readDashboardToolName = AppTool.readDashboard
    public static let moveTileToolName = AppTool.moveTile
    public static let pinPageToolName = AppTool.pinPage
    public static let unpinPageToolName = AppTool.unpinPage
    public static let movePinToolName = AppTool.movePin
    public static let pinSessionToolName = AppTool.pinSession

    /// One of the three Dashboard calls, as the agent made it. A set's arguments go to the
    /// daemon as they are: it is the one place that knows a tile's rules.
    public enum DashboardCall: Sendable, Equatable {
        case set(arguments: JSONValue)
        case remove(id: String)
        case read
        /// `move_tile`'s arguments, checked by the daemon as a set's are (#147).
        case move(arguments: JSONValue)
        /// `pin_page`, `unpin_page` and `move_pin` (#159): the project's pinned pages,
        /// beside its Dashboard, checked by the daemon.
        case pin(arguments: JSONValue)
        case unpin(arguments: JSONValue)
        case movePin(arguments: JSONValue)
        /// `pin_session` (#180): the caller's own session, at the top of its project.
        case pinSession(arguments: JSONValue)
    }

    /// Where those go.
    public typealias DashboardSink = @Sendable (DashboardCall) async -> Outcome

    /// Which of the three a tool name is. `nil` when none.
    static func dashboardCall(named name: String,
                              _ arguments: JSONValue?) -> Result<DashboardCall, AgentCallProblem>? {
        if name.hasSuffix(setTileToolName) {
            return .success(.set(arguments: arguments ?? .object([:])))
        }
        if name.hasSuffix(removeTileToolName) {
            let id = arguments?["id"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !id.isEmpty else { return .failure("Nothing was removed: say which tile, in `id`.") }
            return .success(.remove(id: id))
        }
        if name.hasSuffix(readDashboardToolName) { return .success(.read) }
        if name.hasSuffix(moveTileToolName) { return .success(.move(arguments: arguments ?? .object([:]))) }
        // unpin_page before pin_page: it ends with it, and a name is matched by its end.
        if name.hasSuffix(unpinPageToolName) { return .success(.unpin(arguments: arguments ?? .object([:]))) }
        if name.hasSuffix(pinPageToolName) { return .success(.pin(arguments: arguments ?? .object([:]))) }
        if name.hasSuffix(movePinToolName) { return .success(.movePin(arguments: arguments ?? .object([:]))) }
        if name.hasSuffix(pinSessionToolName) { return .success(.pinSession(arguments: arguments ?? .object([:]))) }
        return nil
    }

    static let setTileTool: JSONValue = [
        "name": .string(setTileToolName),
        "title": "Keep a tile on the project's Dashboard",
        "description": """
            Create or replace a tile on this project's Dashboard, the page the person \
            glances at to see how the project stands. If you keep something the person \
            checks often (a count, whether something is live, a short list), keep it as a \
            tile and set it again when it changes. A tile is a number (with its trend), a \
            status light, a table, a note, a link, or a page: a Markdown or HTML file in \
            the project drawn live on the tile. You keep the tiles you set (an agent a \
            workflow started keeps them for the workflow); no one else may change them. \
            Setting the same value again only refreshes its age. Each tile is written to \
            .agents/dashboard/<id>.json in the project folder, never in a worktree; never \
            edit those files by hand. Past stale_after_hours a tile is greyed out. At most \
            120 sets an hour, 60 tiles a project.
            """,
        "inputSchema": [
            "type": "object",
            "properties": [
                "id": ["type": "string",
                       "description": "1 to 40 lowercase letters, digits, _ and -, not starting with _, unique in the project, e.g. open_bugs."],
                "title": ["type": "string", "description": "What the person reads on the tile, up to 80 characters."],
                "type": ["type": "string", "enum": ["number", "status", "table", "note", "link", "page"]],
                "section": ["type": "string", "description": "A heading to group it under, e.g. Shipping."],
                "source": ["type": "string",
                           "description": "Where the value came from, in one line. Required for number and table."],
                "stale_after_hours": ["type": "integer",
                                      "description": "Grey it out after this many hours without a set: 1 to 168, default 24."],
                "value": ["type": "number", "description": "number: the value. Each set records a point for its trend."],
                "unit": ["type": "string", "description": "number: a unit, e.g. ms."],
                "good": ["type": "string", "enum": ["up", "down"], "description": "number: which way is good news."],
                "level": ["type": "string", "enum": ["ok", "warn", "bad", "unknown"], "description": "status: the light."],
                "line": ["type": "string", "description": "status: what it is, up to 200 characters."],
                "since": ["type": "string", "description": "status: since when, e.g. 16:59."],
                "columns": ["type": "array", "items": ["type": "string"], "description": "table: 1 to 6 headings."],
                "rows": ["type": "array",
                         "description": "table: up to 50 rows, each a list of cells (text, or {text, url})."],
                "markdown": ["type": "string", "description": "note: Markdown, up to 4 KB, no images."],
                "url": ["type": "string", "description": "link: a web address."],
                "session": ["type": "string", "description": "link: a session's id in this project."],
                "file": ["type": "string", "description": """
                    link: a file in the project, from its folder. page: the Markdown or HTML \
                    file to draw, from the project folder, e.g. docs/roadmap.md.
                    """],
                "workflow": ["type": "string", "description": "link: a workflow's id."],
                "take_over": ["type": "boolean", "description": """
                    Take over a tile whose keeper is archived, or whose session you are \
                    continuing and have read with read_session.
                    """],
            ],
            "required": .array(["id", "title", "type"]),
        ],
    ]

    static let pinPageTool: JSONValue = [
        "name": .string(pinPageToolName),
        "title": "Pin a page to the project",
        "description": """
            Pin a Markdown document or HTML page in this project under the project in the \
            person's sidebar, beside its Dashboard, such as a roadmap, a coverage report or \
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
            move wins. Only when asked. The Dashboard is always first.
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

    static let removeTileTool: JSONValue = [
        "name": .string(removeTileToolName),
        "title": "Remove a Dashboard tile",
        "description": "Remove a tile you keep from the project's Dashboard, with its history.",
        "inputSchema": [
            "type": "object",
            "properties": ["id": ["type": "string", "description": "The tile's id."]],
            "required": .array(["id"]),
        ],
    ]

    static let moveTileTool: JSONValue = [
        "name": .string(moveTileToolName),
        "title": "Move a Dashboard tile",
        "description": """
            Put a tile somewhere else on this project's Dashboard: next to another tile, \
            first or last in its section, or into another section. Any tile, not only the \
            ones you keep; the person drags tiles too, and the latest move wins. Only move \
            tiles when asked to: setting a tile again never moves it. The order is kept in \
            .agents/dashboard/_order.json in the project folder; never edit it by hand. \
            read_dashboard lists the tiles in the order shown.
            """,
        "inputSchema": [
            "type": "object",
            "properties": [
                "id": ["type": "string", "description": "The tile to move."],
                "before": ["type": "string", "description": "Put it just before this tile, in that tile's section."],
                "after": ["type": "string", "description": "Put it just after this tile, in that tile's section."],
                "position": ["type": "string", "enum": ["first", "last"],
                             "description": "First or last in its section (or in `section`)."],
                "section": ["type": "string", "description": """
                    The section to put it in, by its heading; an empty string for the tiles \
                    under no heading. A heading that is not there yet is added at the end.
                    """],
            ],
            "required": .array(["id"]),
        ],
    ]

    static let readDashboardTool: JSONValue = [
        "name": .string(readDashboardToolName),
        "title": "Read the project's Dashboard",
        "description": """
            This project's pinned pages, then every tile on its Dashboard, in the order shown, under its section \
            headings and numbered: its value, who keeps it, how old it is, whether the \
            person hid it, and a number's last 10 points. Read it to build on \
            other agents' tiles, or to pick up the tiles of a session you are continuing.
            """,
        "inputSchema": ["type": "object", "properties": .object([:])],
        "_meta": ["ui": ["resourceUri": .string(AppViewCatalog.dashboardURI), "visibility": ["model", "app"]]],
        "ui/resourceUri": .string(AppViewCatalog.dashboardURI),
    ]
}
