import AgentsKitCore
import SwiftUI

/// The limits, in money and in tokens (#838), and what they have stopped; and how many
/// workflows may run (#506).
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
                TokenLimitField(title: "Tokens per agent",
                                limit: model.costLimits.perAgentTokens,
                                alreadyReachedBy: agentsAlreadyOverTokens) { limit in
                    await model.setCostLimits(perAgentTokens: .some(limit))
                }
            } header: {
                Text("The most one agent may spend")
            } footer: {
                Text("Money, tokens or both: whichever is reached first stops it. "
                     + "An agent that reaches this finishes the turn it is in and then takes "
                     + "no further prompt. A turn is never cut short, so the figure it ends "
                     + "on may be a little over the limit — that is the last turn, not a "
                     + "mistake.")
            }
            .paperListRow()

            Section {
                LimitField(title: "Per day",
                           caption: "Everything, in every folder, in one local day.",
                           limit: model.costLimits.daily,
                           alreadyReachedBy: dayAlreadyOver) { limit in
                    await model.setCostLimits(daily: .some(limit))
                }
                TokenLimitField(title: "Tokens per day",
                                limit: model.costLimits.dailyTokens,
                                alreadyReachedBy: dayAlreadyOverTokens) { limit in
                    await model.setCostLimits(dailyTokens: .some(limit))
                }
                if let state = model.costState { today(state) }
                // The ledger or the limits set aside as unreadable (#171).
                if let note = model.costState?.note {
                    Label(note, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("The most a day may spend")
            } footer: {
                Text("When the day reaches this, nothing new starts and no prompt is sent — "
                     + "including a workflow firing on a schedule. Whatever is working "
                     + "finishes its turn and holds. What you typed stays where it is and "
                     + "goes when the day rolls over."
                     + (model.hosts.isEmpty ? "" : " Each server keeps to this limit on its own."))
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

            workflows
        }
        .paperForm()
        .task { await model.refreshCostState() }
        .task { await model.refreshWorkflowLimit() }
    }

    // MARK: Workflows (#506)

    /// How many workflows turned on may run in each folder, as a menu of the
    /// numbers it may be, its default marked and choosing it putting it back.
    private var workflows: some View {
        let kept = model.workflowLimit ?? WorkflowLimitSettings()
        let current = kept.effectiveTotal
        return Section {
            Picker("Turned on at once in each folder", selection: Binding(get: { current }, set: { chosen in
                Task { await model.setWorkflowLimit(WorkflowLimitSettings(total: chosen)) }
            })) {
                ForEach(Array(WorkflowLimit.totalRange), id: \.self) { number in
                    Text(number == WorkflowLimit.defaultTotal ? "\(number) (default)" : "\(number)").tag(number)
                }
            }
            .disabled(model.workflowLimit == nil)
        } header: {
            Text("The most workflows that may run in each folder")
        } footer: {
            Text("Approved workflows turned on in each folder. One turned off or archived "
                 + "takes no place. Past this, a workflow is listed but none of its triggers run it, "
                 + "and turning another on in that folder is refused until you turn one off or archive one. "
                 + "Agents can't change this."
                 + (model.hosts.isEmpty ? "" : " Each server keeps to this number in each folder."))
        }
        .paperListRow()
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

    private func agentsAlreadyOverTokens(_ proposed: Int) -> String? {
        let over = model.agents.filter { !$0.tokensAreUnmeasured && $0.tokensToDate >= proposed }
        guard !over.isEmpty else { return nil }
        let chats = over.count == 1 ? "1 chat has" : "\(over.count) chats have"
        return "\(chats) already used this many tokens. They are at the limit from now."
    }

    private func dayAlreadyOverTokens(_ proposed: Int) -> String? {
        guard let used = model.costState?.tokensToday, used >= proposed else { return nil }
        return "Today has already used this many tokens. Nothing new starts until it rolls over."
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
                .appText(.fine)
                .foregroundStyle(.secondary)
            if let warning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .appText(.fine)
                    .tinted(.failure)
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

/// One token limit (#838): a whole number of tokens, and an explicit way back to no limit,
/// on the same terms as `LimitField`.
private struct TokenLimitField: View {
    let title: String
    let limit: Int?
    let alreadyReachedBy: (Int) -> String?
    let save: (Int?) async -> Void

    @State private var amount = ""
    @State private var warning: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent(title) {
                HStack(spacing: 8) {
                    TextField("No limit", text: $amount)
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                        .frame(width: 120)
                        .onSubmit { Task { await commit() } }
                    Button("Set") { Task { await commit() } }
                        .disabled(parsed == nil)
                    Button("No limit") { Task { await clear() } }
                        .disabled(limit == nil)
                }
            }
            Text("Fresh input and output; a cache read is not counted.")
                .appText(.fine)
                .foregroundStyle(.secondary)
            if let warning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .appText(.fine)
                    .tinted(.failure)
            }
        }
        .onAppear(perform: showWhatIsSet)
        .onChange(of: limit) { showWhatIsSet() }
    }

    /// Digits, with any grouping a person types ("2,000,000") taken out.
    private var parsed: Int? {
        let digits = amount.filter { !$0.isWhitespace && $0 != "," && $0 != "_" && $0 != "." }
        guard !digits.isEmpty, let value = Int(digits), value >= 0 else { return nil }
        return value
    }

    private func showWhatIsSet() {
        guard let limit else {
            amount = ""
            warning = nil
            return
        }
        amount = limit.formatted()
        warning = alreadyReachedBy(limit)
    }

    private func commit() async {
        guard let parsed else { return }
        warning = alreadyReachedBy(parsed)
        await save(parsed)
    }

    private func clear() async {
        warning = nil
        await save(nil)
    }
}
