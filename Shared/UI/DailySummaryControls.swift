import AgentsKitCore
import SwiftUI

/// The daily summary's one control (#3351), for all folders: Off, Summary only or Summary and
/// checks (#3395), the time it runs, and how often the checks run. The Mac draws it above Settings ▸ Agent Configuration ▸ Workflows, the Remote in a
/// section of its Settings; the web page has the same. The home folder's Daily summary
/// workflow keeps it, on weekdays unless that workflow says other days.
struct DailySummaryControls: View {
    let settings: DailySummarySettings
    let set: (DailySummarySettings) -> Void

    /// What the control does, under it.
    static let footer = "Once a day, an agent writes one short page from every folder: what landed, "
        + "what failed or stopped, what waits on you and what the agents suggest next. "
        + "It runs on weekdays, on the Auto runtime, and only reads."

    /// What the checks do, under it with Summary and checks.
    static let checksFooter = "Between summaries, an agent checks the folders that had no work: "
        + "failing CI, pull requests that went stale or are in conflict, and issues no session has. "
        + "The next summary lists what it finds. It only reads."

    /// What the control says under it in this mode.
    static func footer(for mode: DailySummarySettings.Mode) -> String {
        mode == .summaryAndChecks ? footer + " " + checksFooter : footer
    }

    var body: some View {
        Picker("Daily summary", selection: Binding(
            get: { settings.mode },
            set: { mode in set(DailySummarySettings(mode: mode, at: settings.at, checksEvery: settings.checksEvery)) })) {
            ForEach(DailySummarySettings.Mode.allCases, id: \.self) { mode in
                Text(mode.label).tag(mode)
            }
        }
        if settings.mode != .off {
            Picker("Time", selection: Binding(
                get: { settings.at },
                set: { at in set(DailySummarySettings(mode: settings.mode, at: at, checksEvery: settings.checksEvery)) })) {
                ForEach(times, id: \.self) { at in
                    Text(DailySummarySettings.timeLabel(at)).tag(at)
                }
            }
        }
        if settings.mode == .summaryAndChecks {
            Picker("Checks", selection: Binding(
                get: { settings.checksEvery },
                set: { every in set(DailySummarySettings(mode: settings.mode, at: settings.at, checksEvery: every)) })) {
                ForEach(DailySummarySettings.checksEveryChoices, id: \.self) { every in
                    Text(DailySummarySettings.everyLabel(every)).tag(every)
                }
            }
        }
    }

    /// Every half hour, and the stored time when a hand edit set one that is none of them.
    private var times: [String] {
        let all = DailySummarySettings.times
        return all.contains(settings.at) ? all : (all + [settings.at]).sorted()
    }
}
