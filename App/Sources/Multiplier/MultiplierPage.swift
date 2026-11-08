import AgentsKitCore
import SwiftUI

/// The detail with nothing picked (#3904, in place of #145's page): the Multiplier, the
/// work of how many engineers the agents did in the last 7 days, the crowd of them over it
/// (#3985), three big numbers under it, and the earned achievements as badges (#3987). A
/// show-off page: nothing else, and the key hints in one small line.
///
/// The numbers count to each new value (about 1 s), from the last values this window
/// showed when it opens. When a PR merges or a revert does, a line says so and fades.
/// Under Reduce Motion they change with no count and no line.
/// The page's row, first under Usage (#3986): the way back to it from a session or a page.
struct MultiplierRow: View {
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Multiplier").foregroundStyle(.primary)
            Spacer()
        }
        .help("The work of how many engineers your agents did in the last 7 days")
    }
}

struct MultiplierPage: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// What the page showed last, so the next open counts from there (the first, from 0).
    @AppStorage("hero.multiplier", store: WindowDefaults.store) private var lastMultiplier = 0.0
    @AppStorage("hero.prsMerged", store: WindowDefaults.store) private var lastPRs = 0.0
    @AppStorage("hero.engineerHours", store: WindowDefaults.store) private var lastHours = 0.0
    @AppStorage("hero.agentsWorking", store: WindowDefaults.store) private var lastAgents = 0.0
    @State private var shown = MultiplierFigures()
    @State private var news: MultiplierNews?

    private var multiplier: DaemonAPI.Multiplier? { model.work.multiplier }

    /// This window's agents with a turn starting or running, so "agents now" moves as they
    /// do, with no wait for a merge.
    private var agentsWorking: Int {
        model.agents.count { $0.state == .starting || $0.state == .running }
    }

    private var target: MultiplierFigures {
        MultiplierFigures(multiplier: multiplier?.multiplier ?? 0, prsMerged: Double(multiplier?.prsMerged ?? 0),
                    engineerHours: multiplier?.engineerHours ?? 0, agentsWorking: Double(agentsWorking))
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            Crowd(multiplier: multiplier?.multiplier == nil ? nil : shown.multiplier)
                .frame(maxWidth: 820)
                .padding(.bottom, 12)
            if multiplier?.multiplier == nil {
                empty
            } else {
                figures
            }
            Spacer()
            footer
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            shown = MultiplierFigures(multiplier: lastMultiplier, prsMerged: lastPRs,
                                engineerHours: lastHours, agentsWorking: lastAgents)
            Task { @MainActor in show(target) }
        }
        .onChange(of: target) { _, figures in show(figures) }
        .onChange(of: multiplier) { old, new in announce(from: old, to: new) }
        .task { await model.refreshMultiplier() }
    }

    private var figures: some View {
        VStack(spacing: 0) {
            Text("Last 7 days")
                .appText(.reading)
                .foregroundStyle(.secondary)
            CountingText(value: shown.multiplier, digits: 1, suffix: "×")
                .appFigure(.hero)
                .padding(.top, 8)
            CountingText(value: shown.multiplier, digits: 1, prefix: "the work of ", suffix: " engineers")
                .appText(.title)
                .foregroundStyle(.secondary)
                .padding(.bottom, 56)
            HStack(alignment: .top, spacing: 72) {
                stat(shown.prsMerged, "PRs merged")
                stat(shown.engineerHours, "engineer-hours")
                stat(shown.agentsWorking, "agents now")
            }
            EarnedBadges(achievements: model.work.achievements)
                .padding(.top, 40)
            Group {
                if let news {
                    Text(news.words)
                        .appText(.reading)
                        .fontWeight(.semibold)
                        .foregroundStyle(news.up ? Paper.accent : .secondary)
                        .id(news.id)
                        .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity),
                                                removal: .move(edge: .top).combined(with: .opacity)))
                }
            }
            .frame(height: 28)
            .padding(.top, 20)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.3)
    }

    private func stat(_ value: Double, _ label: String) -> some View {
        VStack(spacing: 4) {
            CountingText(value: value, digits: 0)
                .appFigure(.big)
            Text(label)
                .appText(.supporting)
                .foregroundStyle(.secondary)
        }
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Text("— ×")
                .appFigure(.hero)
                .foregroundStyle(.secondary)
            Text("No merged work in the last 7 days.")
                .appText(.reading)
            Text("Your number starts when an agent’s first PR merges.")
                .appText(.supporting)
                .foregroundStyle(.secondary)
            EarnedBadges(achievements: model.work.achievements)
                .padding(.top, 24)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.3)
    }

    private var footer: some View {
        VStack(spacing: 4) {
            if let baseline = multiplier?.baseline {
                Text("An average engineer merged \(baseline.prsPerWeek.formatted()) PRs a week (\(baseline.source))")
            }
            Text("⌘0 Multiplier · ⌘N new session · ↑↓ move · ⌘F find")
        }
        .appText(.fine)
        .foregroundStyle(.secondary)
    }

    /// Count to figures, or jump there under Reduce Motion, and keep them for the next open.
    private func show(_ figures: MultiplierFigures) {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 1)) { shown = figures }
        lastMultiplier = figures.multiplier
        lastPRs = figures.prsMerged
        lastHours = figures.engineerHours
        lastAgents = figures.agentsWorking
    }

    /// The line for the PR that changed the figure: `+0.3×  #1234 merged`, rising and fading.
    private func announce(from old: DaemonAPI.Multiplier?, to new: DaemonAPI.Multiplier?) {
        guard !reduceMotion, let new, let pr = new.changedBy else { return }
        let reverted = new.prsMerged < (old?.prsMerged ?? 0)
        let change = (new.multiplier ?? 0) - (old?.multiplier ?? 0)
        let sign = change < 0 ? "−" : "+"
        let words = "\(sign)\(abs(change).formatted(.number.precision(.fractionLength(1))))×  "
            + "\(pr.shortName) \(reverted ? "reverted" : "merged")"
        let next = MultiplierNews(words: words, up: !reverted)
        withAnimation(.easeOut(duration: 0.4)) { news = next }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.4))
            if news?.id == next.id { withAnimation(.easeIn(duration: 0.6)) { news = nil } }
        }
    }
}

/// The numbers the Multiplier page shows, as doubles so they can count.
struct MultiplierFigures: Equatable {
    var multiplier = 0.0
    var prsMerged = 0.0
    var engineerHours = 0.0
    var agentsWorking = 0.0
}

/// The line under the numbers about the PR that changed them.
private struct MultiplierNews: Identifiable {
    let id = UUID()
    let words: String
    let up: Bool
}

/// A number that counts through the values between, as it animates.
@Animatable
private struct CountingText: View {
    var value: Double
    @AnimatableIgnored var digits: Int
    @AnimatableIgnored var prefix = ""
    @AnimatableIgnored var suffix = ""

    var body: some View {
        Text(prefix + value.formatted(.number.precision(.fractionLength(digits))) + suffix)
    }
}
