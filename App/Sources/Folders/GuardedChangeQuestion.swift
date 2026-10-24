import AgentsKitCore
import SwiftUI

/// The window's `GuardedChangeCard` (#531): read and answered through the folder's host.
/// Review… opens the change's page in the detail column (#1472).
struct GuardedChangeQuestion: View {
    @Environment(AppModel.self) private var model
    /// In a folder's own window, how it opens what is picked (#1090).
    @Environment(\.windowOpen) private var windowOpen
    let change: GuardedChange
    let key: FolderKey
    /// What the card is on goes first: Folder Settings closes before the page opens.
    var leaving: () -> Void = {}

    var body: some View {
        GuardedChangeCard(change: change,
                          read: { await model.readGuardedChange(change, for: key) },
                          settle: { reading, keep in await model.settleGuardedChange(reading, keep: keep, for: key) },
                          review: review,
                          isOffline: model.hosts.isOffline(key.host))
            .help(model.hosts.isOffline(key.host) ? model.offlineHelp(for: key.host) : "")
    }

    private func review() {
        leaving()
        let item = SidebarItem.review(change.approvalID, in: key)
        if let windowOpen { windowOpen(item) } else { model.sidebarItem = item }
    }
}
