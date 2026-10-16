import AgentsKitCore
import Foundation

/// The milestones (#984): kept on the host, drawn on the Milestones page (#1067), and a
/// one-time card in the sidebar for each one earned while this window has been looking.
extension AppModel {
    /// As asked on connecting; then heard as it changes.
    func takeMilestones(_ milestones: Milestones) {
        work.replaceMilestones(milestones)
        // The first look on this root: what was earned before is not news.
        if milestonesSeen == nil { keepMilestonesSeen(milestones.unseen(nil).seen) }
    }

    /// The card to show: the first milestone earned and not yet seen in this window.
    var milestoneCard: Milestone? {
        guard let milestonesSeen else { return nil }
        return work.milestones?.unseen(milestonesSeen).show.first
    }

    /// Closed or opened: it does not come back.
    func dismissMilestone(_ milestone: Milestone) {
        keepMilestonesSeen((milestonesSeen ?? []).union([milestone.rawValue]))
    }

    private func keepMilestonesSeen(_ seen: Set<String>) {
        milestonesSeen = seen
        MilestonesSeenStore.seen = seen
    }
}

/// The milestones this window has shown, in `WindowDefaults` as `GetStartedStore` is.
enum MilestonesSeenStore {
    static var seen: Set<String>? {
        get { WindowDefaults.store.stringArray(forKey: "milestones.seen").map(Set.init) }
        set { WindowDefaults.store.set(newValue.map { $0.sorted() }, forKey: "milestones.seen") }
    }
}
