import AgentsKit
import SwiftUI

/// The two limits, and what they have stopped.
///
/// The app's first preferences of any kind. Writing lives here rather than in the
/// Spending window because that window is read-only by construction — nothing on it
/// starts, stops or changes anything — and a limit is the one number in this app a
/// person types.
///
/// Everything on this page is the reader's. Nothing an agent or a workflow can reach
/// calls any of it: a runaway able to raise its own limit is not stopped by one.
struct CostSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                LimitField(title: "Per agent",
                           caption: "Across an agent's whole life, not one turn.",
                           limit: model.costLimits.perAgent,
                           alreadyReachedBy: agentsAlreadyOver) { limit in
                    await model.setCostLimits(perAgent: .some(limit))
                }
            } header: {
                Text("The most one agent may spend")
            } footer: {
                Text("An agent that reaches this finishes the turn it is in and then takes "
                     + "no further prompt. A turn is never cut short, so the figure it ends "
                     + "on may be a little over the limit — that is the last turn, not a "
                     + "mistake.")
            }

            Section {
                LimitField(title: "Per day",
                           caption: "Everything, in every project, in one local day.",
                           limit: model.costLimits.daily,
                           alreadyReachedBy: dayAlreadyOver) { limit in
                    await model.setCostLimits(daily: .some(limit))
                }
                if let state = model.costState { today(state) }
            } header: {
                Text("The most a day may spend")
            } footer: {
                Text("When the day reaches this, nothing new starts and no prompt is sent — "
                     + "including a workflow firing on a schedule. Whatever is working "
                     + "finishes its turn and holds. What you typed stays where it is and "
                     + "goes when the day rolls over.")
            }

            Section {
                Label("A runtime that reports no price cannot be capped. An agent on one "
                      + "runs past both limits, and while it is running the day's total is a "
                      + "floor rather than a fact.",
                      systemImage: "questionmark.circle")
                    .foregroundStyle(.secondary)
            }

            if !stoppedByALimit.isEmpty { stopped }
        }
        .formStyle(.grouped)
        .frame(width: 460)
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
                    Text("\(left.formatted(.currency(code: daily.currency))) left")
                        .font(.caption)
                        // Colour means a person is needed, on the app's one existing
                        // threshold rather than a second number to learn.
                        .foregroundStyle(state.dayIsCloseToFull ? AnyShapeStyle(.red)
                                                                : AnyShapeStyle(.secondary))
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
                    Text(Cost.total(of: agent.costToDate) ?? "")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var stoppedByALimit: [Agent] {
        model.agents.filter { $0.endedReason == .costLimit }
    }

    /// Agents already over the figure being typed, so setting a limit that is already
    /// reached says so at the moment it is set rather than at the next refusal.
    private func agentsAlreadyOver(_ proposed: Cost) -> String? {
        let over = model.agents.filter {
            !$0.costIsUnmeasured && ($0.costToDate[proposed.currency] ?? 0) >= proposed.amount
        }
        guard !over.isEmpty else { return nil }
        let chats = over.count == 1 ? "1 chat has" : "\(over.count) chats have"
        return "\(chats) already spent this much. They are at the limit from now."
    }

    private func dayAlreadyOver(_ proposed: Cost) -> String? {
        guard let today = model.costState?.today,
              (today[proposed.currency] ?? 0) >= proposed.amount else { return nil }
        return "Today has already cost this much. Nothing new starts until it rolls over."
    }
}

/// One limit: an amount, a currency, and an explicit way back to no limit.
///
/// Clearing is its own action and never a zero. A zero is a real limit that stops
/// everything, and collapsing the two would make the strictest setting mean its
/// opposite.
private struct LimitField: View {
    let title: String
    let caption: String
    let limit: Cost?
    /// What to say when the figure typed is already reached, or nil when it is not.
    let alreadyReachedBy: (Cost) -> String?
    let save: (Cost?) async -> Void

    @State private var amount = ""
    @State private var currency = "USD"
    @State private var warning: String?

    private static let currencies = ["USD", "GBP", "EUR", "AUD", "CAD", "JPY"]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent(title) {
                HStack(spacing: 8) {
                    TextField("No limit", text: $amount)
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                        .frame(width: 90)
                        .onSubmit { Task { await commit() } }
                    Picker("", selection: $currency) {
                        ForEach(Self.currencies, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 80)
                    .onChange(of: currency) { Task { await commit() } }
                    Button("Set") { Task { await commit() } }
                        .disabled(parsed == nil)
                    // Its own action, and only offered when there is something to
                    // clear, so "no limit" is never one keystroke away from "nothing
                    // may run".
                    Button("No limit") { Task { await clear() } }
                        .disabled(limit == nil)
                }
            }
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let warning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .onAppear(perform: showWhatIsSet)
        .onChange(of: limit) { showWhatIsSet() }
    }

    private var parsed: Cost? {
        let text = amount.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, let value = Decimal(string: text), value >= 0 else { return nil }
        return Cost(amount: value, currency: currency)
    }

    private func showWhatIsSet() {
        guard let limit else {
            amount = ""
            warning = nil
            return
        }
        amount = "\(limit.amount)"
        currency = limit.currency
        warning = alreadyReachedBy(limit)
    }

    private func commit() async {
        guard let parsed else { return }
        // Said at the moment it is set, not discovered when the next thing refuses.
        warning = alreadyReachedBy(parsed)
        await save(parsed)
    }

    private func clear() async {
        warning = nil
        await save(nil)
    }
}
