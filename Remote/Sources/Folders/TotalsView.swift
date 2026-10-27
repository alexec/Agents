import AgentsKitCore
import SwiftUI

/// What all of the work has cost, and where it went.
///
/// Feature 012's page, on the iPad. Reported, never estimated: every figure here is
/// folded from `FolderSummary.costToDate`, which is what the runtimes actually
/// charged. Nothing is worked out from a token count the app was not given a price
/// for, and a folder that has spent nothing shows no figure rather than a zero.
///
/// The grand total and the shares beneath it are folded from the same array in the
/// same render — the Mac's rule, kept — so the total cannot disagree with the lines
/// under it. It fetches only the archived folders, which nothing else here needs.
///
/// Read only. Setting a limit stays at the Mac (spec, Out of scope): this page says
/// what has been spent, and nothing on it changes what may be.
struct TotalsView: View {
    @Environment(RemoteModel.self) private var model

    private var spending: Spending { Spending(model.allFolders) }

    /// Cost, or Reports: every person's machines, from the control plane (#1811).
    @State private var pane: Pane = .cost

    enum Pane: String, CaseIterable, Identifiable {
        case cost = "Cost"
        case reports = "Reports"

        var id: Self { self }
    }

    var body: some View {
        Group {
            switch pane {
            case .cost: cost
            case .reports:
                ReportsPane(control: model.controlPlane)
                    .paperGround()
                    .navigationTitle("Reports")
                    .navigationBarTitleDisplayMode(.inline)
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Show", selection: $pane) {
                    ForEach(Pane.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        }
    }

    private var cost: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // The day's ledger or the limits set aside as unreadable (#171).
                if let note = model.costState?.note {
                    Label(note, systemImage: "exclamationmark.triangle")
                        .appText(.supporting)
                        .foregroundStyle(.secondary)
                }
                // Every host's use over time, as Health draws it (#823, #1267).
                UsageChartsSection(metric: .cost, load: { await model.usageHistory() }, refresh: model.costState)
                    .padding(.bottom, 8)
                if spending.isEmpty {
                    nothingSpent
                } else {
                    grandTotal
                    ForEach(spending.currencies, id: \.self) { currency in
                        section(for: currency, showsHeading: spending.currencies.count > 1)
                    }
                    if spending.unmeasuredAgents > 0 { unmeasured }
                }
                today
                // The money limits, by host; the token ones are on Tokens (#956).
                ForEach(model.costStates.filter { $0.1.limits.daily != nil || $0.1.limits.perAgent != nil
                    || !OrgPolicyWords.budgetRows($0.1.organisation).isEmpty }, id: \.0) { host, state in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(host).appText(.supporting).foregroundStyle(.secondary)
                        if let daily = state.limits.daily {
                            Text("Daily limit \(daily.amount.formatted(.currency(code: daily.currency))) · \((state.dayHeadroom ?? 0).money(in: daily.currency)) left")
                                .appText(.fine).monospacedDigit().foregroundStyle(.secondary)
                        }
                        if let perAgent = state.limits.perAgent {
                            Text("Each agent up to \(perAgent.amount.formatted(.currency(code: perAgent.currency)))")
                                .appText(.fine).monospacedDigit().foregroundStyle(.secondary)
                        }
                        // The organisation's budgets, beside these: the lower is used (#998).
                        OrgBudgetRows(state: state).appText(.fine)
                    }
                    .padding(.top, 8)
                }
                // Where each runtime's allowance stands, a tap away (065).
                RuntimesLink()
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .readableWidth()
        }
        .paperGround()
        .navigationTitle("Cost")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top, spacing: 0) { StaleBanner() }
        .markedStale(model.isStale)
        .task { await model.loadArchivedFolders() }
        .shows([.costs])
        .refreshable {
            await model.catchUp()
            await model.loadArchivedFolders()
        }
    }

    /// The first thing on the page, because it is the question the page answers. One
    /// figure per currency, joined rather than added: £100 and $120 cannot be summed
    /// without a rate this app deliberately does not have.
    private var grandTotal: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("All time")
                .appText(.supporting)
                .foregroundStyle(.secondary)
            Text(Cost.total(of: spending.grandTotal) ?? "")
                .appText(.title).fontWeight(.semibold)
                .monospacedDigit()
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func section(for currency: String, showsHeading: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsHeading {
                Text(currency)
                    .appText(.reading).fontWeight(.semibold)
                    .foregroundStyle(.secondary)
            }
            ForEach(spending.shares(in: currency)) { share in
                ShareRow(share: share, currency: currency)
            }
        }
    }

    /// What the day has cost against the limit, where there is one.
    ///
    /// Shown, not set. The person on the train needs to know why nothing new will
    /// start; changing the number is a decision to make at the desk (010, and the
    /// spec's Out of scope).
    @ViewBuilder
    private var today: some View {
        if let state = model.costState,
           !state.today.merging(model.serversToday, uniquingKeysWith: +).isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Today")
                    .appText(.supporting)
                    .foregroundStyle(.secondary)
                Text(todayLine(state))
                    .appText(.reading).fontWeight(.medium)
                    .monospacedDigit()
                    .foregroundStyle((state.dayLimitReached ? StateTint.failure : .none)
                                        .style(or: .primary))
                if state.dayLimitReached {
                    Text("Nothing new will start until tomorrow. The limit is set on your Mac.")
                        .appText(.fine)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 8)
        }
    }

    private func todayLine(_ state: DaemonAPI.CostState) -> String {
        let today = state.today.merging(model.serversToday, uniquingKeysWith: +)
        let spent = Cost.total(of: today) ?? ""
        return spent
    }

    /// So the grand total reads as a floor rather than as the whole.
    private var unmeasured: some View {
        let chats = spending.unmeasuredAgents == 1 ? "1 chat" : "\(spending.unmeasuredAgents) chats"
        return Label("At least this much: \(chats) ran on a runtime that reported no price.",
                     systemImage: "questionmark.circle")
            .appText(.supporting)
            .foregroundStyle(.secondary)
            .padding(.top, 4)
    }

    private var nothingSpent: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Nothing has been spent yet")
                .appText(.reading).fontWeight(.semibold)
            Text("What the work costs appears here once a runtime reports a price for it.")
                .appText(.supporting)
                .foregroundStyle(.secondary)
        }
    }
}

extension RemoteModel {
    /// Each host's day and limits, This Mac first, then the servers by name: Cost and
    /// Tokens (#956) both list them.
    var costStates: [(String, DaemonAPI.CostState)] {
        var states: [(String, DaemonAPI.CostState)] = []
        if let state = costState { states.append(("This Mac", state)) }
        states += serverCosts.map { (hostLabel($0.key), $0.value) }
            .sorted { $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending }
        return states
    }
}

/// One folder's share of the bill. Archived folders are listed like any other and
/// worded the way the folder list words them, so the two describe the same folder
/// the same way.
private struct ShareRow: View {
    let share: Spending.Share
    let currency: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(share.name)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(share.isArchived ? AnyShapeStyle(.secondary)
                                                  : AnyShapeStyle(.primary))
            if share.isArchived {
                Text("Archived")
                    .appText(.fine)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            Text(share.amount.money(in: currency))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .appText(.reading)
        .accessibilityElement(children: .combine)
    }
}
