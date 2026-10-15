import AgentsKitCore
import SwiftUI

/// The milestones (#984): the first steps the person has taken, each with its
/// day, then the ones not taken yet, greyed with how. The second list is the newcomer's
/// checklist. Drawn by the window and the Remote; the page draws `Milestones` in
/// Milestones.tsx. Kept and worked out on the host, in `Milestones`.
struct MilestonesSection: View {
    let milestones: Milestones
    /// Earned and not seen on this device yet: marked New (the iPhone, which shows no card).
    var fresh: Set<Milestone> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Milestones").appText(.fine).fontWeight(.semibold).foregroundStyle(.secondary)
                Text("\(milestones.ordered.filter { $0.at != nil }.count) of \(Milestone.allCases.count)")
                    .appText(.fine)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            ForEach(milestones.ordered, id: \.milestone) { row in
                HStack(alignment: .firstTextBaseline) {
                    ChecklistRow(title: row.milestone.title, how: row.milestone.how, isDone: row.at != nil,
                                 doneNote: row.at.map(Self.dayWords))
                    if fresh.contains(row.milestone) {
                        Text("New")
                            .appText(.fine)
                            .fontWeight(.semibold)
                            .foregroundStyle(Paper.accent)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Milestones")
    }

    /// "12 Oct 2026".
    static func dayWords(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated).year())
    }
}

/// The Time page with its milestones under the charts, once all are earned (#984). Until
/// then they are a page of their own, with a row in the sidebar (#1067).
struct TimeMilestonesUnder<Content: View>: View {
    let milestones: Milestones?
    var fresh: Set<Milestone> = []
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            content()
            if let milestones, milestones.isComplete {
                MilestonesSection(milestones: milestones, fresh: fresh)
            }
        }
    }
}

/// The one-time card when a milestone is earned (#984), on the Mac and the iPad; the page
/// draws `MilestoneCard` in MilestoneCard.tsx. Small, and it goes when closed or opened. No
/// notification is ever sent for one.
struct MilestoneCard: View {
    let milestone: Milestone
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
                Text("Milestone").appText(.fine).foregroundStyle(.secondary)
                Text(milestone.title)
                    .fixedSize(horizontal: false, vertical: true)
                Button("See Milestones", action: open)
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
            .accessibilityLabel("Dismiss milestone")
        }
        .appText(.supporting)
        .padding(12)
        .background(Paper.raised, in: RoundedRectangle(cornerRadius: Paper.Radius.card))
        .overlay { RoundedRectangle(cornerRadius: Paper.Radius.card).strokeBorder(Paper.rule) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Milestone earned: \(milestone.title)")
    }
}
