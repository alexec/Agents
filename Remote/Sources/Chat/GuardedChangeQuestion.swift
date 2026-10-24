import AgentsKitCore
import SwiftUI

/// The Remote's `GuardedChangeCard` (#531): read and answered through the folder's host.
/// Review… opens the change's page (#1472): pushed over the chat it is asked in, or the
/// detail's own page from the folder's.
struct GuardedChangeQuestion: View {
    @Environment(RemoteModel.self) private var model
    let change: GuardedChange
    let key: FolderKey

    var body: some View {
        GuardedChangeCard(change: change,
                          read: { await model.readGuardedChange(change, for: key) },
                          settle: { reading, keep in await model.settleGuardedChange(reading, keep: keep, for: key) },
                          review: review)
    }

    private func review() {
        if model.selection != nil {
            model.openReview = change.approvalID
        } else {
            model.sidebarItem = .review(change.approvalID, in: key)
        }
    }
}
