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
    /// The one call that ends a turn: how it went, and what to ask next. What one
    /// passes to it becomes the line under the agent's name and the row of chips
    /// above the prompt.
    public static let finishTurn = "finish_turn"

    /// What one passes to this becomes the file open in the sidebar.
    public static let showFile = "show_file"

    /// And this one reads and writes the project's standing arrangements: the prompts
    /// that run themselves when something happens.
    public static let manageWorkflows = "manage_workflows"

    // Four more that act on other agents (028): start one in this project, and stop,
    // archive or list the ones this agent started. Never offered to an agent another
    // agent started.

    /// Start an agent in the caller's own project.
    public static let startAgent = "start_agent"

    /// Stop an agent the caller started.
    public static let stopAgent = "stop_agent"

    /// Archive an agent the caller started, which gives its place back.
    public static let archiveAgent = "archive_agent"

    /// The agents the caller started that are still here, and the places in use.
    public static let listMyAgents = "list_my_agents"

    // The older names for the two halves of `finishTurn`, kept since 2026-09-23 (023).
    // The briefing that named them is sent once and lives in the runtime's own
    // history, so a conversation begun before that date and resumed after it calls
    // these, and must find them. Remove the two together, once no such conversation
    // could be resumed; nothing else depends on them.

    /// The older name for the suggestions half: the row of chips, on its own.
    public static let suggestPrompts = "suggest_next_prompts"

    /// The older name for the outcome half: how the work went, on its own.
    public static let reportOutcome = "report_outcome"
}
