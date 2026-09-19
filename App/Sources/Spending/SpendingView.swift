import AgentsKit
import SwiftUI

/// What all of the work has cost, and where it went.
///
/// A window of its own rather than a page in the detail column, so closing it returns
/// you to exactly the project and chat you left — true by construction, with no flag to
/// unwind — and so it can sit open beside the work while the figures move.
///
/// It reads `model.projects` and nothing else. The grand total and the shares beneath it
/// are folded from the same array in the same render, which is what makes it impossible
/// for the total to disagree with the lines under it, or for either to be stale relative
/// to the sidebar. It fetches nothing.
///
/// Read-only. Nothing on this page starts, stops, archives or deletes anything.
struct SpendingView: View {
    @Environment(AppModel.self) private var model

    private var spending: Spending { Spending(model.projects) }

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
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
        .navigationTitle("Spending")
    }

    /// The first thing on the page, because it is the question the page answers. One
    /// figure per currency, joined rather than added.
    private var grandTotal: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("All time")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(Cost.total(of: spending.grandTotal) ?? "")
                .font(.largeTitle.weight(.semibold))
                .monospacedDigit()
                .textSelection(.enabled)
        }
    }

    /// Where it went, largest first.
    ///
    /// One section per currency and ordered within it: £100 and $120 cannot be ranked
    /// without a rate the app deliberately does not have, so nothing is ever compared
    /// across a section boundary. With a single currency — the ordinary case — there is
    /// nothing to section and no heading is drawn.
    @ViewBuilder
    private func section(for currency: String, showsHeading: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsHeading {
                Text(currency)
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            ForEach(spending.shares(in: currency)) { share in
                ShareRow(share: share, currency: currency)
            }
        }
    }

    /// Said in a sentence rather than as a row of zeroes: nothing has been spent is a
    /// different fact from everything costing nothing.
    private var nothingSpent: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Nothing has been spent yet")
                .font(.title2.weight(.semibold))
            Text("What the work costs appears here once a runtime reports a price for it.")
                .foregroundStyle(.secondary)
        }
    }

    /// So the grand total reads as a floor rather than as the whole.
    private var unmeasured: some View {
        let chats = spending.unmeasuredAgents == 1 ? "1 chat" : "\(spending.unmeasuredAgents) chats"
        return Label("At least this much: \(chats) ran on a runtime that reported no price.",
                     systemImage: "questionmark.circle")
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.top, 4)
    }
}

/// One project's share of the bill.
private struct ShareRow: View {
    let share: Spending.Share
    let currency: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            // Archived projects are listed with their spend like any other — nothing
            // filters — and worded the way the sidebar words them, so the two surfaces
            // describe the same project the same way.
            Text(share.name)
                .lineLimit(1)
                .foregroundStyle(share.isArchived ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            if share.isArchived {
                Text("Archived")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 24)
            Text(share.amount.formatted(.currency(code: currency)))
                .monospacedDigit()
                .foregroundStyle(share.isArchived ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
        }
        .help(share.folder.path)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    /// Said in words, because "greyed out" is not something VoiceOver can read.
    private var accessibilityLabel: String {
        let amount = share.amount.formatted(.currency(code: currency))
        return share.isArchived ? "\(share.name), archived, \(amount)" : "\(share.name), \(amount)"
    }
}
