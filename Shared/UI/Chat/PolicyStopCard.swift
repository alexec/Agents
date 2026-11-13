import AgentsKitCore
import SwiftUI

/// A rule of the policy stopped this agent (#2957, FR-025, frame E): **Stopped by a policy**,
/// the rule, the layer that decides and its value, and why. **Change** opens that layer's
/// pane where the person can edit it (your layer, a folder's); an organisation's rule offers
/// Spending for a budget, or Organisation Policy. At the organisation's budget, **Ask for
/// More** asks an admin to raise it for today (#3262), as an Ask at the end of the chat while
/// it can be raised (`PolicyStopAsk`, #5031), and this record then says where the request stands. The web page's is `Web/src/views/chat/PolicyStopCard.tsx`.
struct PolicyStopCard: View {
    let refusal: DaemonAPI.PolicyRefusal
    let entryID: UUID
    @Environment(\.chatActions) private var actions

    private var action: PolicyLayersWords.StopAction { PolicyLayersWords.stopAction(refusal) }
    private var asked: DaemonAPI.BudgetRequest? { PolicyStopAsks.shared.asked[entryID] }

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
            if let open = actions.openPolicy {
                HStack {
                    Spacer()
                    AskDecline(PolicyLayersWords.stopActionTitle(action)) { open(action) }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StateTint.warning.color?.opacity(0.05) ?? .clear, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder((StateTint.warning.color ?? .secondary).opacity(0.25)))
        .accessibilityElement(children: .contain)
    }
}

/// Ask for More's answers, by the policy stop's entry: the record and its Ask say the same (#5031).
@MainActor @Observable
final class PolicyStopAsks {
    static let shared = PolicyStopAsks()
    var asked: [UUID: DaemonAPI.BudgetRequest] = [:]

    /// The policy stop the agent is still stopped by: the last one, with no message of the
    /// person's after it, while the agent does not run, at the organisation's budget, not asked
    /// yet from here.
    func raisable(_ entries: [TranscriptEntry], agent: Agent) -> (id: UUID, refusal: DaemonAPI.PolicyRefusal)? {
        guard agent.state != .running, agent.state != .starting, agent.state != .archived else { return nil }
        for entry in entries.reversed() {
            switch entry.kind {
            case .userMessage:
                return nil
            case .policyStopped(let refusal):
                guard asked[entry.id] == nil, PolicyLayersWords.canAskForMore(refusal) else { return nil }
                return (entry.id, refusal)
            default:
                continue
            }
        }
        return nil
    }
}

/// A policy stop that can be raised (#3262), as an Ask (#5031): Ask for More the primary, and
/// where to change the rule on the left. The web page's is `PolicyStopAsk` in `PolicyStopCard.tsx`.
struct PolicyStopAsk: View {
    let refusal: DaemonAPI.PolicyRefusal
    let entryID: UUID
    let askForMore: @MainActor () async throws -> DaemonAPI.BudgetRequest
    let openPolicy: (@MainActor (PolicyLayersWords.StopAction) -> Void)?
    @State private var asking = false
    @State private var problem: String?

    private var action: PolicyLayersWords.StopAction { PolicyLayersWords.stopAction(refusal) }

    var body: some View {
        AskCard(icon: PolicyLayersWords.stopSymbol, title: PolicyLayersWords.stopTitle) {
            if let rule = refusal.rule {
                Text(PolicyLayersWords.ruleTitle(rule)).appText(.reading)
            }
            Text(refusal.words)
                .appText(.supporting)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let problem {
                Text(problem).appText(.fine).tinted(.failure)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } decline: {
            if let openPolicy {
                AskDecline(PolicyLayersWords.stopActionTitle(action)) { openPolicy(action) }
            }
        } buttons: {
            Button(PolicyLayersWords.askForMore) { Task { await ask() } }
                .buttonStyle(.paperProminent)
                .help(PolicyLayersWords.askForMoreHelp)
                .disabled(asking)
        }
    }

    private func ask() async {
        asking = true
        defer { asking = false }
        do {
            PolicyStopAsks.shared.asked[entryID] = try await askForMore()
            problem = nil
        } catch {
            problem = PolicyLayersWords.askRefusal(error)
        }
    }
}
