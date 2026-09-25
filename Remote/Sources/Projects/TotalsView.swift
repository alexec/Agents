import AgentsKitCore
import SwiftUI

/// What all of the work has cost, and where it went.
///
/// Feature 012's page, on the iPad. Reported, never estimated: every figure here is
/// folded from `ProjectSummary.costToDate`, which is what the runtimes actually
/// charged. Nothing is worked out from a token count the app was not given a price
/// for, and a project that has spent nothing shows no figure rather than a zero.
///
/// The grand total and the shares beneath it are folded from the same array in the
/// same render — the Mac's rule, kept — so the total cannot disagree with the lines
/// under it. It fetches only the archived projects, which nothing else here needs.
///
/// Read only. Setting a limit stays at the Mac (spec, Out of scope): this page says
/// what has been spent, and nothing on it changes what may be.
struct TotalsView: View {
    @Environment(RemoteModel.self) private var model

    private var spending: Spending { Spending(model.allProjects) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
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
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .readableWidth()
        }
        .paperGround()
        .navigationTitle("Spending")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top, spacing: 0) { StaleBanner() }
        .markedStale(model.isStale)
        .task { await model.loadArchivedProjects() }
        .refreshable {
            await model.refreshEverything()
            await model.loadArchivedProjects()
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
        if let state = model.costState, !state.today.isEmpty {
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
        let spent = Cost.total(of: state.today) ?? ""
        guard let daily = state.limits.daily else { return spent }
        return "\(spent) of \(daily.amount.formatted(.currency(code: daily.currency)))"
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

/// One project's share of the bill. Archived projects are listed like any other and
/// worded the way the project list words them, so the two describe the same project
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

/// This project's own total, on its page.
///
/// A fact about the work, which is what puts it in scope where setting a limit is not.
/// Nothing when nothing has been spent: `costToDate` is empty until a runtime reports
/// a price, and an empty figure is a different thing from a zero.
struct ProjectTotal: View {
    let summary: DaemonAPI.ProjectSummary

    var body: some View {
        if let total = Cost.total(of: summary.costToDate) {
            HStack(spacing: 6) {
                Text(total)
                    .monospacedDigit()
                if summary.unmeasuredAgents > 0 {
                    // The same qualification the spending page makes, in one word,
                    // so the figure is never read as the whole when it is a floor.
                    Text("at least")
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            .appText(.fine)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(summary.unmeasuredAgents > 0
                                ? "Spent on this project: at least \(total)"
                                : "Spent on this project: \(total)")
        }
    }
}
