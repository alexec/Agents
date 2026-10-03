import AgentsKitCore
import Foundation

/// What can be picked in the window's one sidebar (#145).
///
/// The sidebar is Activity at the top, then every project folded open on its sessions
/// and workflows. All of those in one list, so one value says which of them is picked —
/// with a binding each, a project and a session could both look chosen, and the reader
/// would have to guess which one the detail was showing.
enum SidebarItem: Hashable {
    /// The project's own pages: its Dashboard, with its settings a sheet over it.
    case project(ProjectKey)
    /// One session, under its project.
    case session(UUID)
    /// One workflow, under its project. The project goes with it, because a workflow's
    /// id is its folder's path and a server can have the same path as this Mac.
    case workflow(Workflow.ID, in: ProjectKey)
    case spending
    /// Every resource an agent can lease, and who holds and waits for each (036).
    case resources
    /// What happened, and what came of it (042).
    case events
    /// Each runtime and where its allowance stands (065). Status, not a control, so it
    /// is here rather than in Settings.
    case runtimes
}
