import AgentsKitCore
import SwiftUI

/// Settings ▸ Agents ▸ Spending: what today has cost, the organisation's budget, and what the
/// limits have stopped (#838). The limits themselves, in money and in tokens, and how many
/// workflows may run (#506), are rules of Agents ▸ Policy now (#2957, FR-018, FR-023).
///
/// Read only: nothing on this page starts, stops or changes anything.
struct CostSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                if let state = model.costState { today(state) }
                // The ledger or the limits set aside as unreadable (#171).
                if let note = model.costState?.note {
                    Label(note, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Today")
            } footer: {
                Text("Your limits per agent and per day are in Agents ▸ Policy, with the layer that sets each one."
                     + (model.hosts.isEmpty ? "" : " Each server keeps to them on its own."))
            }
            .paperListRow()

            // The organisation's budgets, beside these (#998): the lower of the two is used.
            if !OrgPolicyWords.budgetRows(model.costState?.organisation).isEmpty {
                Section("Your organisation’s budget") {
                    OrgBudgetRows(state: model.costState)
                }
                .paperListRow()
            }

            Section {
                Label("Only Claude reports a price. Codex, OpenCode and Copilot report "
                      + "tokens, so only a token limit stops them. Cursor, Antigravity and Grok "
                      + "report neither, so no limit applies to them: an agent on one runs past "
                      + "every limit, and while it is running the day's totals are a floor rather "
                      + "than a fact.",
                      systemImage: "questionmark.circle")
                    .foregroundStyle(.secondary)
            }
            .paperListRow()

            if !stoppedByALimit.isEmpty { stopped }
        }
        .paperForm()
        .task { await model.refreshCostState() }
    }

    // MARK: What today has cost

    /// Today, and what is left of it. Beside the field it is measured against, so the
    /// answer to "have I room for this" is in one place.
    @ViewBuilder
    private func today(_ state: DaemonAPI.CostState) -> some View {
        LabeledContent("Today") {
            VStack(alignment: .trailing, spacing: 2) {
                // Nothing spent shows nothing, not a zero: they are different facts.
                Text(Cost.total(of: state.today) ?? "Nothing yet")
                    .monospacedDigit()
                if let left = state.dayHeadroom, let daily = state.limits.daily {
                    Text("\(left.money(in: daily.currency)) left")
                        .appText(.fine)
                        // Colour means the limit is about to bite, on the app's one
                        // existing threshold rather than a second number to learn.
                        .foregroundStyle((state.dayIsCloseToFull ? StateTint.failure : .none)
                                            .style(or: .secondary))
                }
                if state.tokensToday > 0 || state.limits.dailyTokens != nil {
                    Text(state.dayTokenHeadroom.map { "\(state.tokensToday.formatted()) tokens · \($0.formatted()) left" }
                         ?? "\(state.tokensToday.formatted()) tokens")
                        .appText(.fine)
                        .monospacedDigit()
                        .foregroundStyle((state.dayIsCloseToFull ? StateTint.failure : .none)
                                            .style(or: .secondary))
                }
            }
        }
    }

    // MARK: What the limits have stopped

    /// So the answer to "why did that not run" sits beside the number that caused it.
    private var stopped: some View {
        Section("What the limits have stopped") {
            ForEach(stoppedByALimit) { agent in
                LabeledContent(agent.title ?? "Untitled") {
                    Text(Cost.total(of: agent.costToDate)
                         ?? (agent.tokensToDate > 0 ? "\(agent.tokensToDate.formatted()) tokens" : ""))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
        .paperListRow()
    }

    private var stoppedByALimit: [Agent] {
        model.agents.filter { $0.endedReason == .costLimit }
    }
}
