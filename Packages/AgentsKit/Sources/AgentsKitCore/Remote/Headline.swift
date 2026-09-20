import Foundation

/// The three short strings a banner is allowed, and there is no fourth.
///
/// `h1` the project's folder name, `h2` the agent's title, `h3` what is wanted in a few
/// words. Three because a push carries at most three keys of about a hundred characters
/// each (research §11), and built here in Core, once, so the Mac banner and the phone
/// banner say the same words about the same agent — the rule `AgentState.startingLabel`
/// exists to defend.
///
/// Each field is cut to the budget **before** anything seals it: a headline cut
/// mid-ciphertext is unreadable, where a headline cut mid-word is merely short. One that
/// will not fit at all degrades to the placeholder rather than to nothing.
public struct Headline: Hashable, Sendable, Codable {
    public var h1: String
    public var h2: String
    public var h3: String

    public init(h1: String, h2: String, h3: String) {
        self.h1 = h1
        self.h2 = h2
        self.h3 = h3
    }

    /// The most a field may carry, in characters. Research §11's figure, with room.
    public static let budget = 100

    /// What a banner says when nothing better fits. It still says something needs a
    /// person, which is the whole of what a banner is for.
    public static let placeholder = Headline(h1: "Agents", h2: "An agent", h3: "needs you")

    /// This headline with every field cut to `budget`, and an empty field given a word:
    /// an agent with no title or a project with no name must still identify itself,
    /// truncated rather than blank (spec edge case).
    public func truncating(to budget: Int = Headline.budget) -> Headline {
        func cut(_ text: String, or fallback: String) -> String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return fallback }
            guard trimmed.count > budget else { return trimmed }
            return String(trimmed.prefix(max(1, budget - 1))) + "…"
        }
        return Headline(h1: cut(h1, or: Self.placeholder.h1),
                        h2: cut(h2, or: Self.placeholder.h2),
                        h3: cut(h3, or: Self.placeholder.h3))
    }

    /// Whether every field is within the budget, which is what may be sealed.
    public func fits(_ budget: Int = Headline.budget) -> Bool {
        [h1, h2, h3].allSatisfy { !$0.isEmpty && $0.count <= budget }
    }
}
