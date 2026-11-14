import AgentsKitCore
import SwiftUI

/// What all of the work has cost, and where it went.
///
/// A page in the detail column, picked from the last row of the sidebar. It was a
/// window of its own until the money was somewhere a person could find it: a window
/// is a thing you have to know exists, and the figure that was supposed to advertise
/// it sat at the foot of a column hiding itself whenever nothing had been banked.
///
/// The usage charts at the top (#823) fetch the host's history; everything below them
/// reads `model.folders` and nothing else. The grand total and the shares beneath it
/// are folded from the same array in the same render, which is what makes it impossible
/// for the total to disagree with the lines under it, or for either to be stale relative
/// to the sidebar. It fetches nothing.
///
/// Read-only. Nothing on this page starts, stops, archives or deletes anything.
///
/// **Open Reports** (#4938) opens Reports ▸ Spend on the web page, in the Me scope and the range
/// the charts show: Reports is a Web + Mac link feature (#4937), so the Mac draws this one link
/// and nothing more. It shows only when this Mac can open the page; with no control plane, or no
/// page served, there is no link and no Reports.
struct SpendingView: View {
    @Environment(AppModel.self) private var model

    @State private var range: UsageChart.Range = .week
    /// Its own link to the control plane, while the page is open; nil with none.
    @State private var control: ControlSettingsModel?
    @State private var reportsProblem: String?

    private var spending: Spending { Spending(model.folders) }

    /// Whether this Mac can open the web page now.
    private var reportsShown: Bool {
        guard let control, control.isReachable else { return false }
        return BrowserOpening.linkPage(control.status, onThisMac: control.isOnThisMac) != nil
    }

    var body: some View {
        cost.navigationTitle("Cost")
            .toolbar {
                if reportsShown {
                    ToolbarItem {
                        Button(ReportsLink.title, icon: "chart.bar.doc.horizontal") { openReports() }
                            .labelStyle(.titleAndIcon)
                            .help(ReportsLink.help)
                    }
                }
            }
            .task {
                guard control == nil, let endpoint = ControlConfig.endpoint,
                      let made = ControlSettingsModel(endpoint: endpoint) else { return }
                control = made
                await made.refresh()
            }
            .onDisappear {
                control?.stop()
                control = nil
            }
            .alert("Agent Loops can’t open Reports", isPresented: Binding(get: { reportsProblem != nil },
                                                                      set: { if !$0 { reportsProblem = nil } })) {
                Button("OK") { reportsProblem = nil }
            } message: {
                Text(reportsProblem ?? "")
            }
    }

    private func openReports() {
        guard let control else { return }
        let place = ReportsLink.place(range: range)
        Task { reportsProblem = await control.openInBrowser(place: place) }
    }

    private var cost: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // The day's ledger or the limits set aside as unreadable (#171).
                if let note = model.costState?.note {
                    Label(note, icon: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // Over time, as Health draws it (#823).
                UsageChartsSection(metric: .cost, load: { await model.usageHistory() }, refresh: model.costState, shown: $range,
                                   alsoRead: model.work.costStateReadAt)
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
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
    }

    /// The first thing on the page, because it is the question the page answers. One
    /// figure per currency, joined rather than added.
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
                    .appText(.reading).fontWeight(.semibold)
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
                .appText(.title).fontWeight(.semibold)
            Text("What the work costs appears here once a runtime reports a price for it.")
                .foregroundStyle(.secondary)
        }
    }

    /// So the grand total reads as a floor rather than as the whole.
    private var unmeasured: some View {
        let chats = spending.unmeasuredAgents == 1 ? "1 chat" : "\(spending.unmeasuredAgents) chats"
        return Label("At least this much: \(chats) ran on a runtime that reported no price.",
                     icon: "questionmark.circle")
            .appText(.reading)
            .foregroundStyle(.secondary)
            .padding(.top, 4)
    }
}

/// One folder's share of the bill.
private struct ShareRow: View {
    let share: Spending.Share
    let currency: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            // Archived folders are listed with their spend like any other — nothing
            // filters — and worded the way the sidebar words them, so the two surfaces
            // describe the same folder the same way.
            Text(share.name)
                .lineLimit(1)
                .foregroundStyle(share.isArchived ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            if share.isArchived {
                Text("Archived")
                    .appText(.fine)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 24)
            Text(share.amount.money(in: currency))
                .monospacedDigit()
                .foregroundStyle(share.isArchived ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
        }
        .help(share.folder.path)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    /// Said in words, because "greyed out" is not something VoiceOver can read.
    private var accessibilityLabel: String {
        let amount = share.amount.money(in: currency)
        return share.isArchived ? "\(share.name), archived, \(amount)" : "\(share.name), \(amount)"
    }
}
