import AgentsKitCore
import SwiftUI

/// Where the time of the Mac's running chats went (#852): the agent working, its tools,
/// waiting on others, and waiting for you, drawn as the usage charts on Cost are. The
/// window's TimeView, from Activity in the sidebar. Read-only.
struct TimeView: View {
    @Environment(RemoteModel.self) private var model

    var body: some View {
        ScrollView {
            TimeMilestonesAround(milestones: model.work.milestones, fresh: model.freshMilestones) {
                TimeChartsSection(load: { await model.timeHistory() })
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .readableWidth()
        }
        .paperGround()
        .navigationTitle("Time")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { model.sawMilestones() }
        .safeAreaInset(edge: .top, spacing: 0) { StaleBanner() }
        .markedStale(model.isStale)
    }
}

/// Time's row in Activity: the title alone (#587).
struct TimeRow: View {
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Time")
            Spacer()
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens Time: where the time of running chats went")
    }
}
