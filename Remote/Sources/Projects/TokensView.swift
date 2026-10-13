import AgentsKitCore
import SwiftUI

/// What the work used in tokens (#956): the Mac's usage charts in tokens, then each
/// host's tokens today against its token limits. The window's TokensView, from Usage in
/// the sidebar. Read only: the limits are set on the Mac.
struct TokensView: View {
    @Environment(RemoteModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // The Mac's use over time, as Health draws it (#823).
                UsageChartsSection(metric: .tokens, load: { await model.usageHistory() }, refresh: model.costState)
                    .padding(.bottom, 8)
                ForEach(model.costStates, id: \.0) { host, state in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(host).appText(.supporting).foregroundStyle(.secondary)
                        Text("\(state.tokensToday.formatted()) tokens today")
                            .appText(.reading).fontWeight(.medium).monospacedDigit()
                        if let dailyTokens = state.limits.dailyTokens {
                            Text("Daily token limit \(dailyTokens.formatted()) · \((state.dayTokenHeadroom ?? 0).formatted()) left")
                                .appText(.fine).monospacedDigit()
                                .foregroundStyle((state.dayTokensAreCloseToFull ? StateTint.failure : .none).style(or: .secondary))
                        }
                        if let perAgentTokens = state.limits.perAgentTokens {
                            Text("Each agent up to \(perAgentTokens.formatted()) tokens")
                                .appText(.fine).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 8)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .readableWidth()
        }
        .paperGround()
        .navigationTitle("Tokens")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top, spacing: 0) { StaleBanner() }
        .markedStale(model.isStale)
        .shows([.costs])
        .refreshable { await model.catchUp() }
    }
}

/// Tokens' row in Usage: the title alone (#587), the day's tokens VoiceOver's, and near
/// the daily token limit the row's icon turns red.
struct TokensRow: View {
    @Environment(RemoteModel.self) private var model

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Tokens")
            Spacer()
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(figures ?? "")
        .accessibilityHint("Opens Tokens")
    }

    /// Today's tokens, and what is left of a daily token limit where there is one.
    private var figures: String? {
        guard let state = model.costState else { return nil }
        let today = "\(state.tokensToday.formatted()) tokens today"
        guard let left = state.dayTokenHeadroom else { return today }
        return "\(today), \(left.formatted()) left"
    }
}
