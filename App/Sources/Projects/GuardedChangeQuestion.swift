import AgentsKitCore
import SwiftUI

/// The window's `GuardedChangeCard` (#531): read and answered through the project's host.
struct GuardedChangeQuestion: View {
    @Environment(AppModel.self) private var model
    let change: GuardedChange
    let key: ProjectKey

    var body: some View {
        GuardedChangeCard(change: change,
                          read: { await model.readGuardedChange(change, for: key) },
                          settle: { reading, keep in await model.settleGuardedChange(reading, keep: keep, for: key) },
                          isOffline: model.hosts.isOffline(key.host))
            .help(model.hosts.isOffline(key.host) ? model.offlineHelp(for: key.host) : "")
    }
}
