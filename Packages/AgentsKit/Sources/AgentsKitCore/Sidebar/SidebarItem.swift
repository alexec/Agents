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
    /// The Multiplier page (#3986): what the window shows with nothing else open, first under
    /// Usage so there is a way back to it. The Mac window's only: the Remote never has it.
    case multiplier
    case spending
    /// The tokens the work used, and the token limits (#956): Cost's figures in tokens.
    case tokens
    /// Where the time of running chats went (#852): the agent, its tools, and waiting.
    case time
    /// One of Work's lists (#3119), a row each under the Work group (#4004): the issues and pull
    /// requests from the forges, with lineage on top, the features, and the milestones and releases
    /// lineage knows. An item's page keeps its list's row. The Remote has no Features row (#3269).
    case work(WorkList.Kind)
    /// The folders' docs and the docs connectors', each doc a page (#3321, spec 3319). Mac + web:
    /// the Remote has no row for it (#2796).
    case docs
    /// The daily summary's page (#3721), from the Summary row at the top of the sidebar: the
    /// newest saved page, the earlier ones in a picker, and the control. Core: every client.
    case summary
    /// Every resource an agent can lease, and who holds and waits for each (036). The Remote's
    /// only: the Mac and the web page show a machine's resources on its page (#3629).
    case resources
    /// What happened, and what came of it (042).
    case events
    /// Each runtime and where its allowance stands (065). Status, not a control, so it
    /// is here rather than in Settings. On the Mac it is **Your setup** (#3631): each runtime
    /// once, with the accounts, and a line per machine.
    case runtimes
    /// The person's own MCP servers (#488, #589, #753): every one in `~/.agents/mcp.json`,
    /// and how each is doing. On the Mac it is under **Your setup** (#3632).
    case mcpServers
    /// The person's secrets and cards, kept by the control plane and sent to each machine of
    /// theirs (#1760), under **Your setup** (#3632). Mac + web: the Remote has no row for it (#2796).
    case secrets
    /// The person's outside accounts (#3967), under **Your setup**, beside Secrets. Mac + web.
    case accounts
    /// One machine's page (#3626): its CPU, memory and disks, from its row under Machines.
    /// Mac + web: the Remote has no row for it (#2796).
    case machine(MachineRef)
    /// A folder's MCP servers (#753), under its folder when its `.agents/mcp.json` has any.
    case folderMCPServers(FolderKey)
    /// A change waiting for an OK, on its Review page (#1472), by its `Approval.id`, from
    /// its row under Needs You or Review… on its card.
    case review(String, in: FolderKey)
}
