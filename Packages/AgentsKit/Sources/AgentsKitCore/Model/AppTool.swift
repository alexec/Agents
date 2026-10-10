import Foundation

/// The names of the tools the app itself serves an agent.
///
/// Here, in the half both platforms hold, rather than beside the server that
/// implements them: a phone reading a transcript has to tell the app's own tool calls
/// from the agent's work, and it does that by name. The server that answers them is
/// the Mac's, and stays there.
///
/// A runtime is free to prefix these — the Claude adapter shows the first as
/// `mcp__agents__finish_turn` — so they are matched on the end of a name and never
/// whole.
public enum AppTool {
    /// The optional call that says how a turn ended: what one passes to it becomes the
    /// line under the agent's name. Since #481 it says only that; waiting, parking,
    /// moving and labels each have a tool of their own.
    public static let finishTurn = "finish_turn"

    /// Add or remove the agent's own labels on its session (#481).
    public static let setSessionLabels = "set_session_labels"

    /// Move into a worktree, or back to the project folder, once the turn ends (#481).
    /// Offered only on a runtime that can carry its conversation across folders.
    public static let moveWorktree = "move_worktree"

    /// What one passes to this becomes the file open in the sidebar.
    public static let showFile = "show_file"

    /// And this one reads and writes the project's standing arrangements: the prompts
    /// that run themselves when something happens.
    public static let manageWorkflows = "manage_workflows"

    /// Ask the person a question or a short form and wait for the answer. The
    /// fallback for runtimes whose own ask tool never reaches the model, and the
    /// only channel on runtimes that have none. Named `ask_form` rather than
    /// `ask_question` so it does not collide with Antigravity's own tool.
    public static let askForm = "ask_form"

    // Five that act on other agents (028): start one in this project, and stop, park,
    // archive (#120) or list the ones this agent started. An agent never archives itself
    // or the person's sessions. Never offered to an agent another agent started.

    /// Start an agent in the caller's own project.
    public static let startAgent = "start_agent"

    /// Stop an agent the caller started.
    public static let stopAgent = "stop_agent"

    /// Park an agent the caller started, to come back to later.
    public static let parkAgent = "park_agent"

    /// Archive an agent the caller started, once it has stopped working (#120).
    public static let archiveAgent = "archive_agent"

    /// The agents the caller started that are still here, and the places in use.
    public static let listMyAgents = "list_my_agents"

    // Two for reading another session in the same project (065). Offered to every
    // agent, including one another agent started: reading is not managing anyone.

    /// The sessions in the caller's project, newest first.
    public static let listSessions = "list_sessions"

    /// One session's history, by id or exact title.
    public static let readSession = "read_session"

    /// Say something to another session in the project (#560), which it reads as a
    /// prompt marked as this agent's. Offered to every agent, as reading is.
    public static let messageAgent = "message_agent"

    // Three more for taking turns with the Mac's shared things (036). Offered to every
    // agent, including one another agent started: waiting for the simulator is not
    // managing anyone.

    /// Take a lease on a resource, extend one already held, or wait in line for it.
    public static let leaseResource = "lease_resource"

    /// Give a lease back, or leave the line for one.
    public static let releaseResource = "release_resource"

    /// What can be leased on this Mac, and who holds what.
    public static let listResources = "list_resources"

    // Three for waiting on what happens, and saying that something has (042). Offered
    // to every agent, including one another agent started. None of the three names
    // ends with another tool's name, which is how the app tells tools apart (see 036's
    // release_resource).

    /// Wait for an event, read the recent ones, or list what can be waited on.
    public static let waitForEvent = "wait_for_event"

    /// Stop waiting.
    public static let cancelWait = "cancel_wait"

    /// Say that something happened, as a `custom.` event.
    public static let publishEvent = "publish_event"

    /// Pin a Markdown or HTML page under the project (#159).
    public static let pinPage = "pin_page"
    /// Unpin a page this agent pinned (#159).
    public static let unpinPage = "unpin_page"
    /// Put a pinned page somewhere else among the pins (#159).
    public static let movePin = "move_pin"
    /// Pin or unpin the agent's own session at the top of its project (#180).
    public static let pinSession = "pin_session"

    /// The older names for the two halves of `finishTurn`, served from 2026-09-23 (023)
    /// until 2026-09-29. No longer offered or answered; kept only so a conversation that
    /// called them still draws without them, the way it did.
    public static let retiredEndOfTurn = ["suggest_next_prompts", "report_outcome"]

    /// The name the app's MCP server goes by in a runtime's session (`mcpServers`).
    public static let serverName = "agents"

    /// Every tool the app's MCP server serves.
    public static let all: [String] = [
        finishTurn, showFile, manageWorkflows, askForm, startAgent, stopAgent, parkAgent,
        listMyAgents, leaseResource, releaseResource, listResources, waitForEvent,
        cancelWait, publishEvent, listSessions, readSession, archiveAgent,
        pinPage, unpinPage, movePin, pinSession, setSessionLabels, moveWorktree, messageAgent,
    ]

    /// How runtimes put the server's name in front of a tool's, as measured: Claude's
    /// adapter says `mcp__agents__finish_turn`, Antigravity `agents_finish_turn` (049).
    static let serverPrefixes = ["mcp__\(serverName)__", "\(serverName)_", "\(serverName)-", "\(serverName)/"]

    /// Whether `called` is one of the app's own tools, named with the app's server in front.
    /// Never a bare name: a runtime's own tool can share one — Antigravity has a
    /// `list_resources` of its own — and only the server in front says whose it is.
    public static func isServedByTheApp(_ called: String) -> Bool {
        serverPrefixes.contains { prefix in
            called.hasPrefix(prefix) && all.contains(String(called.dropFirst(prefix.count)))
        }
    }
}
