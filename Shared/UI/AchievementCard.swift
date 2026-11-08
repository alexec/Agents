import AgentsKitCore
import SwiftUI

/// The one-time card when an achievement is earned (#984), on the Mac and the iPad; the page
/// draws `AchievementCard` in AchievementCard.tsx. Small, and it goes when closed or opened.
/// On the Mac, See Achievements opens the Multiplier page, where the badges are (#3987). No
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
