import AgentsKitCore
import SwiftUI

/// A rule of the policy stopped this agent (#2957, FR-025, frame E): **Stopped by a policy**,
/// the rule, the layer that decides and its value, and why. **Change** opens that layer's
/// pane where the person can edit it (your layer, a folder's); an organisation's rule offers
/// Spending for a budget, or Organisation Policy. The web page's is
/// `Web/src/views/chat/PolicyStopCard.tsx`.
struct PolicyStopCard: View {
    let refusal: DaemonAPI.PolicyRefusal
    @Environment(\.chatActions) private var actions

    private var action: PolicyLayersWords.StopAction { PolicyLayersWords.stopAction(refusal) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(PolicyLayersWords.stopTitle, systemImage: PolicyLayersWords.stopSymbol)
                .appText(.reading).fontWeight(.semibold)
                .tinted(.attention)
            if let rule = refusal.rule {
                Text(PolicyLayersWords.ruleTitle(rule)).appText(.reading)
            }
            if let line = PolicyLayersWords.stopLine(refusal) {
                Label(line, systemImage: "lock.fill")
                    .appText(.fine).foregroundStyle(.secondary)
            }
            Text(refusal.words)
                .appText(.reading)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let open = actions.openPolicy {
                HStack {
                    Spacer()
                    Button(PolicyLayersWords.stopActionTitle(action)) { open(action) }
                        .buttonStyle(.paper)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StateTint.attention.color?.opacity(0.05) ?? .clear, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder((StateTint.attention.color ?? .secondary).opacity(0.25)))
        .accessibilityElement(children: .contain)
    }
}
