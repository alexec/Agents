import AgentsKitCore
import SwiftUI

/// The window's `ReviewPage` (#1472): the change found by its id in the project's
/// approvals, read and answered through the project's host as Needs You's sheet was.
/// Answered, it goes back to the session that made the change, or to the project.
struct ReviewDestination: View {
    @Environment(AppModel.self) private var model
    /// In a project's own window, how it opens what is picked (#1090).
    @Environment(\.windowOpen) private var windowOpen
    let id: String
    let project: ProjectKey

    var body: some View {
        if let approval = model.work.project(project)?.approvals?.first(where: { $0.id == id }) {
            ReviewPage(approval: approval, place: place,
                       read: { await model.readApproval(approval, for: project) },
                       answer: { action, digest, note in
                           await model.answerApproval(approval, action, digest: digest, note: note, for: project)
                       },
                       isOffline: model.hosts.isOffline(project.host),
                       openAgent: { open(.session($0)) },
                       done: { open(approval.agentID.flatMap { model.work.agent($0) != nil ? .session($0) : nil }) })
                .id(approval)
        } else {
            ReviewGonePage()
        }
    }

    private var place: String? {
        model.work.project(project).map { SidebarOrder.label($0) { model.hosts.label($0) } }
    }

    /// In this window: a project's own, or the main window's selection. Nil is the project.
    private func open(_ item: SidebarItem?) {
        if let windowOpen { windowOpen(item) } else { model.sidebarItem = item ?? .project(project) }
    }
}
