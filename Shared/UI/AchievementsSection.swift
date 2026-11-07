import AgentsKitCore
import SwiftUI

/// The achievements (#984): the first steps the person has taken, each with its
/// day, then the ones not taken yet, greyed with how. The second list is the newcomer's
/// checklist. Drawn by the window and the Remote; the page draws `Achievements` in
/// Achievements.tsx. Kept and worked out on the host, in `Achievements`.
struct AchievementsSection: View {
    let achievements: Achievements
    /// Earned and not seen on this device yet: marked New (the iPhone, which shows no card).
    var fresh: Set<Achievement> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Achievements").appText(.fine).fontWeight(.semibold).foregroundStyle(.secondary)
                Text("\(achievements.ordered.filter { $0.at != nil }.count) of \(Achievement.allCases.count)")
                    .appText(.fine)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            ForEach(achievements.ordered, id: \.achievement) { row in
                HStack(alignment: .firstTextBaseline) {
                    ChecklistRow(title: row.achievement.title, how: row.achievement.how, isDone: row.at != nil,
                                 doneNote: row.at.map(Self.dayWords))
                    if fresh.contains(row.achievement) {
                        Text("New")
                            .appText(.fine)
                            .fontWeight(.semibold)
                            .foregroundStyle(Paper.accent)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Achievements")
    }

    /// "12 Oct 2026".
    static func dayWords(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated).year())
    }
}

/// The Time page with its achievements under the charts, once all are earned (#984). Until
/// then they are a page of their own, with a row in the sidebar (#1067).
struct TimeAchievementsUnder<Content: View>: View {
    let achievements: Achievements?
    var fresh: Set<Achievement> = []
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            content()
            if let achievements, achievements.isComplete {
                AchievementsSection(achievements: achievements, fresh: fresh)
            }
        }
    }
}

/// The one-time card when an achievement is earned (#984), on the Mac and the iPad; the page
/// draws `AchievementCard` in AchievementCard.tsx. Small, and it goes when closed or opened. No
/// notification is ever sent for one.
struct AchievementCard: View {
    let achievement: Achievement
    let open: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "checkmark.seal.fill")
                // Decorative: the card says what it is in words.
                .glyph(size: 13)
                .foregroundStyle(Paper.accent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Achievement").appText(.fine).foregroundStyle(.secondary)
                Text(achievement.title)
                    .fixedSize(horizontal: false, vertical: true)
                Button("See Achievements", action: open)
                    .buttonStyle(.borderless)
                    .tint(Paper.accent)
                    .appText(.fine)
                    .padding(.top, 2)
            }
            Spacer(minLength: 0)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    // Decorative: the button's label is said below.
                    .glyph(size: 10, weight: .semibold)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Dismiss")
            .accessibilityLabel("Dismiss achievement")
        }
        .appText(.supporting)
        .padding(12)
        .background(Paper.raised, in: RoundedRectangle(cornerRadius: Paper.Radius.card))
        .overlay { RoundedRectangle(cornerRadius: Paper.Radius.card).strokeBorder(Paper.rule) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Achievement earned: \(achievement.title)")
    }
}
