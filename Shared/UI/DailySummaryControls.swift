import AgentsKitCore
import SwiftUI

/// The daily summary's one control (#3351), for all folders: Off or Summary only, and the time
/// it runs. The Mac draws it above Settings ▸ Agent Configuration ▸ Workflows, the Remote in a
/// section of its Settings; the web page has the same. The home folder's Daily summary
/// workflow keeps it, on weekdays unless that workflow says other days.
struct DailySummaryControls: View {
    let settings: DailySummarySettings
    let set: (DailySummarySettings) -> Void

    /// What the control does, under it.
    static let footer = "Once a day, an agent writes one short page from every folder: what landed, "
        + "what failed or stopped, what waits on you and what the agents suggest next. "
        + "It runs on weekdays, on the Auto runtime, and only reads."

    var body: some View {
        Picker("Daily summary", selection: Binding(
            get: { settings.mode },
            set: { mode in set(DailySummarySettings(mode: mode, at: settings.at)) })) {
            ForEach(DailySummarySettings.Mode.allCases, id: \.self) { mode in
                Text(mode.label).tag(mode)
            }
        }
        if settings.mode != .off {
            Picker("Time", selection: Binding(
                get: { settings.at },
                set: { at in set(DailySummarySettings(mode: settings.mode, at: at)) })) {
                ForEach(times, id: \.self) { at in
                    Text(DailySummarySettings.timeLabel(at)).tag(at)
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
