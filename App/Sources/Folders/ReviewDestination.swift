import AgentsKitCore
import SwiftUI

/// The window's `ReviewPage` (#1472): the change found by its id in the folder's
/// approvals, read and answered through the folder's host as Needs You's sheet was.
/// Answered, it goes back to the session that made the change, or to the folder.
struct ReviewDestination: View {
    @Environment(AppModel.self) private var model
    /// In a folder's own window, how it opens what is picked (#1090).
    @Environment(\.windowOpen) private var windowOpen
    let id: String
    let folder: FolderKey

    var body: some View {
        if let approval = model.work.folder(folder)?.approvals?.first(where: { $0.id == id }) {
            ReviewPage(approval: approval, place: place,
                       read: { await model.readApproval(approval, for: folder) },
                       answer: { action, digest, note in
                           await model.answerApproval(approval, action, digest: digest, note: note, for: folder)
                       },
                       isOffline: model.hosts.isOffline(folder.host),
                       openAgent: { open(.session($0)) },
                       done: { open(approval.agentID.flatMap { model.work.agent($0) != nil ? .session($0) : nil }) })
                .id(approval)
        } else {
            ReviewGonePage()
        }
    }

    private var place: String? {
        model.work.folder(folder).map { SidebarOrder.label($0) { model.hosts.label($0) } }
    }

    /// In this window: a folder's own, or the main window's selection. Nil is the folder.
    private func open(_ item: SidebarItem?) {
        if let windowOpen { windowOpen(item) } else { model.sidebarItem = item ?? .folder(folder) }
    }
}
