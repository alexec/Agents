import AgentsKitCore
import UIKit

/// The milestones (#984): kept on the Mac's host, drawn on the Milestones page
/// (#1067) while any is still to earn and under Time's charts once all are. A milestone
/// earned while this device has been looking is a one-time card on the iPad; on the
/// iPhone it is marked New on that page instead (Alex, #984), until the page is left.
extension RemoteModel {
    /// What the catch-up carried, or what was asked for on its own.
    func takeMilestones(_ milestones: Milestones) {
        work.replaceMilestones(milestones)
        // The first look on this device: what was earned before is not news.
        if milestonesSeen == nil { keepMilestonesSeen(milestones.unseen(nil).seen) }
    }

    private var unseenMilestones: [Milestone] {
        guard let milestonesSeen else { return [] }
        return work.milestones?.unseen(milestonesSeen).show ?? []
    }

    private var showsMilestoneCards: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    /// The iPad's card: the first milestone earned and not yet seen here.
    var milestoneCard: Milestone? { showsMilestoneCards ? unseenMilestones.first : nil }

    /// The iPhone's New marks on the Milestones page (or Time's, for the last one).
    var freshMilestones: Set<Milestone> { showsMilestoneCards ? [] : Set(unseenMilestones) }

    /// Closed or opened: it does not come back.
    func dismissMilestone(_ milestone: Milestone) {
        keepMilestonesSeen((milestonesSeen ?? []).union([milestone.rawValue]))
    }

    /// The Milestones or Time page was left: what it marked New has been seen.
    func sawMilestones() {
        let fresh = freshMilestones
        guard !fresh.isEmpty else { return }
        keepMilestonesSeen((milestonesSeen ?? []).union(fresh.map(\.rawValue)))
    }

    private func keepMilestonesSeen(_ seen: Set<String>) {
        milestonesSeen = seen
        UserDefaults.standard.set(seen.sorted(), forKey: Self.milestonesSeenKey)
    }

    static let milestonesSeenKey = "milestones.seen"
    static var keptMilestonesSeen: Set<String>? {
        UserDefaults.standard.stringArray(forKey: milestonesSeenKey).map(Set.init)
    }
}

/// The Blob's celebrations (#986): the model holds the next one; the root plays it.
extension RemoteModel {
    /// A question card is on screen, so the Blob waits: the open session asks something.
    var asksOnScreen: Bool {
        work.permission(for: selection) != nil || work.elicitation(for: selection) != nil
    }
}
