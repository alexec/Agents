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
    /// A folder's archived sessions, as a page (#495, #4448), by the day each was archived.
    case archivedSessions(FolderKey)
    /// A folder's archived workflows, as a page (#4448), by name.
    case archivedWorkflows(FolderKey)
    /// The Multiplier page (#3986): what the window shows with nothing else open, first under
    /// Usage so there is a way back to it. The Mac window's only: the Remote never has it.
    case multiplier
    case spending
    /// The tokens the work used, and the token limits (#956): Cost's figures in tokens.
    case tokens
    /// Where the time of running chats went (#852): the agent, its tools, and waiting.
    case time
    /// The pull requests that landed, over time (#4597): the Multiplier's count drawn by hour,
    /// day and week. Core: the Remote has it under Status, after the Multiplier (#4758).
    case velocity
    /// One of Work's lists (#3119), a row each under the Work group (#4004): the issues and pull
    /// requests from the forges, with lineage on top, the features, and the releases
    /// lineage knows. An item's page keeps its list's row. The Remote has no Features row (#3269).
    case work(WorkList.Kind)
    /// The folders' docs and the docs connectors', each doc a page (#3321, spec 3319). Mac + web:
    /// the Remote has no row for it (#2796).
    case docs
    /// The messaging connectors' conversations, read only (#4344), from the Messages row below Work. Mac + web:
    /// the Remote has no row for it (#2796).
    case messages
    /// The daily summary's page (#3721), from the Summary row at the top of the sidebar: the
    /// newest saved page, the earlier ones in a picker, and the control. Core: every client.
    case summary
    /// Every resource an agent can lease, and who holds and waits for each (036). The Remote's
    /// only: the Mac and the web page show a machine's resources on its page (#3629).
    case resources
    /// What happened, and what came of it (042), under **Status** (#3998).
    case events
    /// Each runtime and where its allowance stands (065). Status, not a control, so it
    /// is here rather than in Settings: under **Status** (#3998), each runtime once, with the
    /// accounts, and a line per machine (#3631). The person's connectors, secrets and outside
    /// accounts are settings, in Settings ▸ You (#3998).
    case runtimes
    /// Status ▸ Secrets (#4161): what happened last to each of the person's secrets, newest first.
    /// Status only: a press opens the secret in Settings ▸ You ▸ Secrets. Core: every client.
    case secretsStatus
    /// Status ▸ Accounts (#4161): the same for the person's outside accounts.
    case accountsStatus
    /// One machine's page (#3626): its CPU, memory and disks, from its row under Machines.
    /// Mac + web: the Remote has no row for it (#2796).
    case machine(MachineRef)
    /// A folder's MCP servers (#753), under its folder when its `.agents/mcp.json` has any.
    case folderMCPServers(FolderKey)
    /// A change waiting for an OK, on its Review page (#1472), by its `Approval.id`, from
    /// its row under Needs You or Review… on its card.
    case review(String, in: FolderKey)
}
