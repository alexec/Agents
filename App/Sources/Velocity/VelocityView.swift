import AgentsKitCore
import SwiftUI

/// The pull requests that landed, over time (#4595, #4597): D / W / M / 3M bars of the PRs the
/// Multiplier counts, the daily average above them, a picked bar's own figure, and the shares
/// by repository, drawn as Cost, Tokens and Time are.
///
/// A page in the detail column, picked from Usage in the sidebar or View ▸ Velocity. Read-only.
/// It reads `velocity/history` on open and again when `multiplier/changed` arrives, so a merge
/// moves its bar at once. The chart is `VelocityChartsSection` in Shared/UI, which the Remote
/// draws too (#4758); the web page draws the same in VelocityCharts.tsx (#4598).
struct VelocityView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VelocityChartsSection(load: { await model.velocityHistory() }, refresh: model.work.multiplier)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
        }
        .navigationTitle("Velocity")
    }
}

/// Velocity's row in Usage: the title alone (#587), the last 7 days' PRs in the tooltip, as
/// the Multiplier counts them.
struct VelocityRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Velocity").foregroundStyle(.primary)
            Spacer()
        }
        .help(figure.map { "\($0). The pull requests that landed, over time. Opens Velocity." }
            ?? "The pull requests that landed, over time")
        .accessibilityValue(figure ?? "")
    }

    private var figure: String? {
        guard let multiplier = model.work.multiplier else { return nil }
        return multiplier.prsMerged == 1 ? "1 PR in the last 7 days"
            : "\(multiplier.prsMerged.formatted()) PRs in the last 7 days"
    }
}
