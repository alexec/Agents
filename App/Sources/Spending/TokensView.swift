import AgentsKitCore
import SwiftUI

/// What the work used in tokens (#956): the usage charts in tokens, then today's tokens
/// against the token limits. It was a switch on Cost; a page of its own is one place to
/// look for one question.
///
/// A page in the detail column, picked from Usage in the sidebar. Read-only: the limits
/// are set in Settings ▸ Agents ▸ Policy (#2957).
struct TokensView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Over time, as Health draws it (#823).
                UsageChartsSection(metric: .tokens, load: { await model.usageHistory() }, refresh: model.costState)
                    .padding(.bottom, 8)
                if let state = model.costState { TokensToday(state: state) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
        .navigationTitle("Tokens")
    }
}

/// The day's tokens, and the token limits where there are any (#838).
private struct TokensToday: View {
    let state: DaemonAPI.CostState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Today")
                .appText(.supporting)
                .foregroundStyle(.secondary)
            Text("\(state.tokensToday.formatted()) tokens")
                .appText(.title).fontWeight(.semibold)
                .monospacedDigit()
                .textSelection(.enabled)
            if let dailyTokens = state.limits.dailyTokens {
                Text("Daily token limit \(dailyTokens.formatted()) · \((state.dayTokenHeadroom ?? 0).formatted()) left")
                    .monospacedDigit()
                    .foregroundStyle((state.dayTokensAreCloseToFull ? StateTint.failure : .none).style(or: .secondary))
            }
            if let perAgentTokens = state.limits.perAgentTokens {
                Text("Each agent up to \(perAgentTokens.formatted()) tokens")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Tokens' row in Usage: the title alone (#587), the day's tokens in the tooltip, and
/// near the daily token limit the row's icon turns red.
struct TokensRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Tokens").foregroundStyle(.primary)
            Spacer()
        }
        .help(figures.map { "\($0). What the work used in tokens. Opens Tokens." } ?? "What the work used in tokens")
        .accessibilityValue(figures ?? "")
    }

    /// Today's tokens, and what is left of a daily token limit where there is one.
    private var figures: String? {
        guard let state = model.costState else { return nil }
        let today = "\(state.tokensToday.formatted()) tokens today"
        guard let left = state.dayTokenHeadroom else { return today }
        return "\(today), \(left.formatted()) left"
    }
}
