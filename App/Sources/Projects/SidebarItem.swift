import AgentsKit
import Foundation

/// What can be picked in the window's first column.
///
/// The column is the folders you work in and, at its foot, what the work costs. Two
/// kinds of thing in one list, so one value says which of them is picked — with two
/// bindings a project and Spending could both look chosen, and the reader would have
/// to guess which one the detail column was showing.
enum SidebarItem: Hashable {
    case project(ProjectKey)
    case spending
    /// Every resource an agent can lease, and who holds and waits for each (036).
    case resources
}
