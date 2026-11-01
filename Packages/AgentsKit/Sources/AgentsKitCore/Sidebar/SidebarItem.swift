import Foundation

/// What can be picked in the window's one sidebar (#145), and in the Remote's, which is
/// the same list (#226).
///
/// The sidebar is Activity at the top, then every folder folded open on its sessions
/// and workflows. All of those in one list, so one value says which of them is picked —
/// with a binding each, a folder and a session could both look chosen, and the reader
/// would have to guess which one the detail was showing.
public enum SidebarItem: Hashable, Sendable {
    /// The folder itself: its new-session form, with its settings a sheet over it.
    case folder(FolderKey)
    /// One session, under its folder.
    case session(UUID)
    /// One workflow, under its folder. The folder goes with it, because a workflow's
    /// id is its folder's path and a server can have the same path as this Mac.
    case workflow(Workflow.ID, in: FolderKey)
    /// One of the folder's pinned pages (#159), by its path in the folder, under the
    /// folder's row and above its sessions.
    case pin(String, in: FolderKey)
    /// A folder's archived sessions and workflows, as a page (#495), with Unarchive.
    case archive(FolderKey)
    case spending
    /// The tokens the work used, and the token limits (#956): Cost's figures in tokens.
    case tokens
    /// Where the time of running chats went (#852): the agent, its tools, and waiting.
    case time
    /// The work's cost, time and links from any start (#3087): Cost's Lineage pane.
    case lineage
    /// The first steps taken, and the ones still to take (#984, #1067): a row only while
    /// some are still to earn.
    case milestones
    /// Every resource an agent can lease, and who holds and waits for each (036).
    case resources
    /// What happened, and what came of it (042).
    case events
    /// Each runtime and where its allowance stands (065). Status, not a control, so it
    /// is here rather than in Settings.
    case runtimes
    /// The person's own MCP servers (#488, #589, #753): every one in `~/.agents/mcp.json`,
    /// and how each is doing.
    case mcpServers
    /// Every folder's worktrees and how much each holds on disk (#790), with Remove and
    /// Remove build output. Changing, so here rather than in Folder Settings.
    case worktrees
    /// A folder's MCP servers (#753), under its folder when its `.agents/mcp.json` has any.
    case folderMCPServers(FolderKey)
    /// A change waiting for an OK, on its Review page (#1472), by its `Approval.id`, from
    /// its row under Needs You or Review… on its card.
    case review(String, in: FolderKey)
}
