import AgentsKitCore
import SwiftUI

/// The Remote's `GuardedChangeCard` (#531): read and answered through the project's host.
struct GuardedChangeQuestion: View {
    @Environment(RemoteModel.self) private var model
    let change: GuardedChange
    let key: ProjectKey

    var body: some View {
        GuardedChangeCard(change: change,
                          read: { await model.readGuardedChange(change, for: key) },
                          settle: { reading, keep in await model.settleGuardedChange(reading, keep: keep, for: key) })
    }
}
