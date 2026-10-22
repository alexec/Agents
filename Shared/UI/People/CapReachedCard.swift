import AgentsKitCore
import SwiftUI

/// A bot stopped at its cap (#1761, #2073): what it spent of which cap, with Group and Cap…
/// and OK. In the sidebar beside the join cards on the Mac and the Remote, so an admin sees
/// it without opening People; the web page's is in Console ▸ Requests.
struct CapReachedCard: View {
    let reached: DaemonAPI.CapReached
    /// The control plane, or nil while it cannot be reached.
    let control: DaemonClient?
    let people: PeopleState

    @State private var isChanging = false

    private var bot: DaemonAPI.PersonRow? { people.list?.people.first { $0.id == reached.user } }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "dollarsign.circle")
                // Decorative: the card says what it is in words.
                .glyph(size: 13)
                .foregroundStyle(StateTint.attention.style(or: .primary))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(BotWords.capReachedTitle(reached)).fontWeight(.semibold)
                    .fixedSize(horizontal: false, vertical: true)
                Text(BotWords.capReached(reached))
                    .appText(.fine)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button(BotWords.setCap) { isChanging = true }
                        .buttonStyle(.borderedProminent)
                        .disabled(bot == nil || control == nil)
                    Button("OK") { people.dismissCap(reached) }
                        .buttonStyle(.bordered)
                }
                .cardButtons()
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .appText(.supporting)
        .padding(12)
        .background(Paper.raised, in: RoundedRectangle(cornerRadius: Paper.Radius.card))
        .overlay { RoundedRectangle(cornerRadius: Paper.Radius.card).strokeBorder(Paper.rule) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(BotWords.capReachedTitle(reached))
        .sheet(isPresented: $isChanging) {
            if let bot {
                // A change is told as control/peopleChanged, which takes the card away.
                BotSheet(control: control, bot: bot, groups: people.groups) {}
                    .paperSheet()
            }
        }
    }
}
