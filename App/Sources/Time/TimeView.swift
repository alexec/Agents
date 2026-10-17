import AgentsKitCore
import SwiftUI

/// Where the time of every host's running chats went (#852, #1267): the agent working, its tools,
/// waiting on others, and waiting for you, drawn as the usage charts on Cost are.
///
/// A page in the detail column, picked from Activity in the sidebar. Read-only.
struct TimeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            TimeMilestonesUnder(milestones: model.work.milestones) {
                TimeChartsSection(load: { await model.timeHistory() })
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
        .navigationTitle("Time")
    }
}

/// Time's row in Activity: the title alone (#587), what it is in the tooltip.
struct TimeRow: View {
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Time").foregroundStyle(.primary)
            Spacer()
        }
        .help("Where the time of running chats went: the agent, its tools, and waiting")
    }
}

/// The milestones as a page (#1067): the newcomer's checklist, from its row in Usage
/// while any is still to earn. Read-only.
struct MilestonesView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            if let milestones = model.work.milestones {
                MilestonesSection(milestones: milestones)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(24)
            }
        }
        .navigationTitle("Milestones")
    }
}

/// Milestones' row in Usage: the title alone (#587), what it is in the tooltip.
struct MilestonesRow: View {
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Milestones").foregroundStyle(.primary)
            Spacer()
        }
        .help("The first steps taken in Agents, and the ones still to take")
    }
}
