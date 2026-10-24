import AgentsKitCore
import SwiftUI

/// The Remote's `ReviewPage` (#1472), the window's `ReviewDestination`: the change found by
/// its id in the folder's approvals, read and answered through the folder's host.
/// Answered, a page pushed over a chat goes back to it; one opened from Needs You goes to
/// the session that made the change, or to the folder.
struct RemoteReviewDestination: View {
    @Environment(RemoteModel.self) private var model
    let id: String
    let folder: FolderKey

    var body: some View {
        if let approval = model.work.folder(folder)?.approvals?.first(where: { $0.id == id }) {
            ReviewPage(approval: approval, place: place,
                       read: { await model.readApproval(approval, for: folder) },
                       answer: { action, digest, note in
                           await model.answerApproval(approval, action, digest: digest, note: note, for: folder)
                       },
                       isOffline: !model.isConnected,
                       openAgent: { model.sidebarItem = .session($0) },
                       done: { leave(approval) })
                .id(approval)
        } else {
            ReviewGonePage()
        }
    }

    private var place: String? {
        model.work.folder(folder).map { SidebarOrder.label($0) { model.hostLabel($0) } }
    }

    private func leave(_ approval: Approval) {
        if model.selection != nil {
            model.openReview = nil
        } else if let agent = approval.agentID, model.work.agent(agent) != nil {
            model.sidebarItem = .session(agent)
        } else {
            // Nothing picked in its folder, not New session (#2090).
            model.sidebarItem = .folder(folder)
            model.composing = false
        }
    }
}
