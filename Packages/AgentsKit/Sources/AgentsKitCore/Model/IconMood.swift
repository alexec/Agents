import Foundation

/// How the Blob on the Dock tile and the web favicon looks (#1317), from the groups the
/// sidebar counts: quizzical while a question waits, happy while an agent works, and
/// asleep with neither. A waiting question wins, because it is the one thing that needs
/// the person. Unread finishes are not a mood: the badge counts them.
public enum IconMood: String, Sendable, CaseIterable {
    case asleep
    case happy
    case quizzical

    /// From each live folder's group counts.
    public init(counts: some Sequence<[AgentGroup: Int]>) {
        var working = false
        for count in counts {
            if count[.needsAttention, default: 0] + count[.blocked, default: 0] > 0 {
                self = .quizzical
                return
            }
            if count[.running, default: 0] > 0 { working = true }
        }
        self = working ? .happy : .asleep
    }
}
