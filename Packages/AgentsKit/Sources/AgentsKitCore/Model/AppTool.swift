import Foundation

/// The names of the tools the app itself serves an agent.
///
/// Here, in the half both platforms hold, rather than beside the server that
/// implements them: a phone reading a transcript has to tell the app's own tool calls
/// from the agent's work, and it does that by name. The server that answers them is
/// the Mac's, and stays there.
///
/// A runtime is free to prefix these — the Claude adapter shows the first as
/// `mcp__agents__suggest_next_prompts` — so they are matched on the end of a name and
/// never whole.
public enum AppTool {
    /// What one passes to this becomes the row of chips above the prompt.
    public static let suggestPrompts = "suggest_next_prompts"

    /// And what one passes to this becomes the file open in the sidebar.
    public static let showFile = "show_file"

    /// And this one reads and writes the project's standing arrangements: the prompts
    /// that run themselves when something happens.
    public static let manageWorkflows = "manage_workflows"

    /// And the fourth: how the work went, said at the end of it.
    public static let reportOutcome = "report_outcome"
}
