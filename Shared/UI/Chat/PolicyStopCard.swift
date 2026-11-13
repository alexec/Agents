import AgentsKitCore
import SwiftUI

/// A rule of the policy stopped this agent (#2957, FR-025, frame E): **Stopped by a policy**,
/// the rule, the layer that decides and its value, and why. **Change** opens that layer's
/// pane where the person can edit it (your layer, a folder's); an organisation's rule offers
/// Spending for a budget, or Organisation Policy. At the organisation's budget, **Ask for
/// More** asks an admin to raise it for today (#3262), and the card then says where the
/// request stands. The web page's is `Web/src/views/chat/PolicyStopCard.tsx`.
struct PolicyStopCard: View {
    let refusal: DaemonAPI.PolicyRefusal
    @Environment(\.chatActions) private var actions
    @State private var asked: DaemonAPI.BudgetRequest?
    @State private var asking = false
    @State private var problem: String?

    private var action: PolicyLayersWords.StopAction { PolicyLayersWords.stopAction(refusal) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(PolicyLayersWords.stopTitle, icon: PolicyLayersWords.stopSymbol)
                .appText(.reading).fontWeight(.semibold)
                .tinted(.warning)
            if let rule = refusal.rule {
                Text(PolicyLayersWords.ruleTitle(rule)).appText(.reading)
            }
            if let line = PolicyLayersWords.stopLine(refusal) {
                Label(line, icon: "lock.fill")
                    .appText(.fine).foregroundStyle(.secondary)
            }
            Text(refusal.words)
                .appText(.reading)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let asked {
                Text(PolicyLayersWords.asked(asked))
                    .appText(.fine).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let problem {
                Text(problem).appText(.fine).tinted(.failure)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if actions.openPolicy != nil || askForMore != nil {
                HStack {
                    Spacer()
                    if let askForMore {
                        Button(PolicyLayersWords.askForMore) { Task { await ask(askForMore) } }
                            .buttonStyle(.paper)
                            .help(PolicyLayersWords.askForMoreHelp)
                            .disabled(asking)
                    }
                    if let open = actions.openPolicy {
                        Button(PolicyLayersWords.stopActionTitle(action)) { open(action) }
                            .buttonStyle(.paper)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StateTint.warning.color?.opacity(0.05) ?? .clear, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder((StateTint.warning.color ?? .secondary).opacity(0.25)))
        .accessibilityElement(children: .contain)
    }

    /// Ask for More, while it is offered: at the organisation's budget, not asked yet here.
    private var askForMore: (@MainActor () async throws -> DaemonAPI.BudgetRequest)? {
        guard asked == nil, PolicyLayersWords.canAskForMore(refusal) else { return nil }
        return actions.askForMore
    }

    private func ask(_ send: @MainActor () async throws -> DaemonAPI.BudgetRequest) async {
        asking = true
        defer { asking = false }
        do {
            asked = try await send()
            problem = nil
        } catch {
            problem = PolicyLayersWords.askRefusal(error)
        }
    }
}
