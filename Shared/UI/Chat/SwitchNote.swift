import AgentsKitCore
import SwiftUI

/// A chat carried on with another runtime (052, wireframes §2). A runtime note with a
/// warm tint, so a switch stands out when scrolling back; everything else about it is
/// words.
struct SwitchNote: View {
    let record: SwitchRecord
    @Environment(\.chatActions) private var actions

    var body: some View {
        let note = PoolWords.switchNote(record, now: .now)
        VStack(alignment: .leading, spacing: 6) {
            Text("⇄ " + note.headline)
                .appText(.reading).fontWeight(.semibold)
            ForEach(note.lines, id: \.self) { line in
                Text(line).appText(.reading).foregroundStyle(.secondary)
            }
            HStack(spacing: 18) {
                Button("Change what it carried on with…") { actions.adjustSwitch(record) }
                    .linkStyle()
                Button("Pool") { actions.showPool() }
                    .linkStyle()
            }
            .appText(.reading)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StateTint.attention.color?.opacity(0.07) ?? .clear, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder((StateTint.attention.color ?? .secondary).opacity(0.25)))
    }
}

/// What the new runtime was handed (052, R4): folded under the switch note, never drawn
/// as the person's words.
struct HandoffLine: View {
    let markdown: String
    let characters: Int
    @State private var isOpen = false

    var body: some View {
        DisclosureGroup(isExpanded: $isOpen) {
            Text(markdown)
                .appText(.reading)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text("What it was handed (\(characters.formatted()) characters)")
                .appText(.reading).foregroundStyle(.tertiary)
        }
    }
}
