import AgentsKitCore
import Foundation

/// The achievements (#984): kept on the host, drawn on the Achievements page (#1067), and a
/// one-time card in the sidebar for each one earned while this window has been looking.
extension AppModel {
    /// As asked on connecting; then heard as it changes.
    func takeAchievements(_ achievements: Achievements) {
        work.replaceAchievements(achievements)
        // The first look on this root: what was earned before is not news.
        if achievementsSeen == nil { keepAchievementsSeen(achievements.unseen(nil).seen) }
    }

    /// The card to show: the first achievement earned and not yet seen in this window.
    var achievementCard: Achievement? {
        guard let achievementsSeen else { return nil }
        return work.achievements?.unseen(achievementsSeen).show.first
    }

    /// Closed or opened: it does not come back.
    func dismissAchievement(_ achievement: Achievement) {
        keepAchievementsSeen((achievementsSeen ?? []).union([achievement.rawValue]))
    }

    private func keepAchievementsSeen(_ seen: Set<String>) {
        achievementsSeen = seen
        AchievementsSeenStore.seen = seen
    }
}

/// The achievements this window has shown, in `WindowDefaults` as `GetStartedStore` is.
enum AchievementsSeenStore {
    static var seen: Set<String>? {
        get { WindowDefaults.store.stringArray(forKey: "achievements.seen").map(Set.init) }
        set { WindowDefaults.store.set(newValue.map { $0.sorted() }, forKey: "achievements.seen") }
    }
}
