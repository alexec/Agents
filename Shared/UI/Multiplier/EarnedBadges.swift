import AgentsKitCore
import SwiftUI

/// The earned achievements on the Multiplier page (#3987), in place of their own page: a badge
/// for each one earned, earliest first, "5 of 7" beside them, and a Next line with the first
/// one still to earn and how. All earned: the badges alone. None earned: the Next line alone.
///
/// A badge earned while the page is open scales in (about 0.5 s); under Reduce Motion it
/// shows with no movement.
struct EarnedBadges: View {
    let achievements: Achievements?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The badges drawn, set from `achievements` so only a change after the first look moves.
    @State private var shown: [EarnedAchievementBadge] = []

    private static func badges(_ achievements: Achievements?) -> [EarnedAchievementBadge] {
        (achievements?.ordered ?? []).compactMap { row in
            row.at.map { EarnedAchievementBadge(achievement: row.achievement, at: $0) }
        }
    }

    /// The first not earned yet, in the order a newcomer meets them.
    private var next: Achievement? {
        Achievement.allCases.first { !(achievements?.has($0) ?? false) }
    }

    var body: some View {
        VStack(spacing: 10) {
            if !shown.isEmpty {
                HStack(spacing: 8) {
                    ForEach(shown) { badge in
                        EarnedBadge(badge: badge)
                            .transition(.scale)
                    }
                    if next != nil {
                        Text("\(shown.count) of \(Achievement.allCases.count)")
                            .appText(.supporting)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .padding(.leading, 6)
                    }
                }
            }
            if let next {
                Text("\(Text("Next:").foregroundStyle(.secondary)) \(Text(next.how).fontWeight(.semibold))")
                    .appText(.supporting)
            }
        }
        .onAppear { shown = Self.badges(achievements) }
        .onChange(of: achievements) { old, new in
            let badges = Self.badges(new)
            // The first answer from the host is what was there, not news.
            guard old != nil, !reduceMotion else { shown = badges; return }
            withAnimation(.spring(duration: 0.5, bounce: 0.45)) { shown = badges }
        }
    }
}

/// One earned achievement and its day, as a badge draws it.
struct EarnedAchievementBadge: Identifiable, Equatable {
    let achievement: Achievement
    let at: Date
    var id: Achievement { achievement }
}

/// A round badge in the accent colour with the achievement's symbol; its title and day in the
/// tooltip and the accessibility label ("First agent started, 12 Oct 2026").
private struct EarnedBadge: View {
    let badge: EarnedAchievementBadge

    private var words: String {
        "\(badge.achievement.title), \(badge.at.formatted(.dateTime.day().month(.abbreviated).year()))"
    }

    var body: some View {
        Image(icon: badge.achievement.symbol)
            .glyph(size: 14, weight: .semibold)
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .background(Paper.accent, in: Circle())
            .help(words)
            .accessibilityElement()
            .accessibilityLabel(words)
    }
}

extension Achievement {
    /// The SF Symbol on its badge.
    var symbol: String {
        switch self {
        case .firstAgent: "play.fill"
        case .firstPairing: "iphone"
        case .firstRemoteAnswer: "bubble.left.fill"
        case .firstWorkflow: "clock"
        case .firstCloudHost: "cloud.fill"
        case .firstLandedPR: "arrow.triangle.merge"
        case .fiveAtOnce: "5.circle"
        }
    }
}
