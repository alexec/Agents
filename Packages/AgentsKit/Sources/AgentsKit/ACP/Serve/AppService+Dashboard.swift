import Foundation
import AgentsKitCore

// The project's Dashboard (074): three tools every agent has, helpers included. Words
// from specs/074-project-dashboard/contracts/agent-tools.md.
extension AppService {
    public static let setTileToolName = AppTool.setTile
    public static let removeTileToolName = AppTool.removeTile
    public static let readDashboardToolName = AppTool.readDashboard

    /// One of the three Dashboard calls, as the agent made it. A set's arguments go to the
    /// daemon as they are: it is the one place that knows a tile's rules.
    public enum DashboardCall: Sendable, Equatable {
        case set(arguments: JSONValue)
        case remove(id: String)
        case read
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
            status light, a table, a note or a link. You keep the tiles you set (an agent a \
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
                       "description": "1 to 40 lowercase letters, digits, _ and -, unique in the project, e.g. open_bugs."],
                "title": ["type": "string", "description": "What the person reads on the tile, up to 80 characters."],
                "type": ["type": "string", "enum": ["number", "status", "table", "note", "link"]],
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
                "file": ["type": "string", "description": "link: a file in the project, from its folder."],
                "workflow": ["type": "string", "description": "link: a workflow's id."],
                "take_over": ["type": "boolean", "description": """
                    Take over a tile whose keeper is archived, or whose session you are \
                    continuing and have read with read_session.
                    """],
            ],
            "required": .array(["id", "title", "type"]),
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

    static let readDashboardTool: JSONValue = [
        "name": .string(readDashboardToolName),
        "title": "Read the project's Dashboard",
        "description": """
            Every tile on this project's Dashboard: its value, who keeps it, how old it is, \
            whether the person hid it, and a number's last 10 points. Read it to build on \
            other agents' tiles, or to pick up the tiles of a session you are continuing.
            """,
        "inputSchema": ["type": "object", "properties": .object([:])],
    ]
}
