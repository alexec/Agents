import AgentsKitCore
import SwiftUI

/// Where the time of the Mac's running chats went (#852): the agent working, its tools,
/// waiting on others, and waiting for you, drawn as the usage charts on Cost are. The
/// window's TimeView, from Activity in the sidebar. Read-only.
struct TimeView: View {
    @Environment(RemoteModel.self) private var model

    var body: some View {
        ScrollView {
            TimeMilestonesUnder(milestones: model.work.milestones, fresh: model.freshMilestones) {
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

/// The milestones as a page (#1067): the newcomer's checklist, from its row in Usage
/// while any is still to earn. The window's MilestonesView. On the iPhone, a milestone
/// earned since the last look is marked New until the page is left.
struct MilestonesView: View {
    @Environment(RemoteModel.self) private var model

    var body: some View {
        ScrollView {
            if let milestones = model.work.milestones {
                MilestonesSection(milestones: milestones, fresh: model.freshMilestones)
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .readableWidth()
            }
        }
        .paperGround()
        .navigationTitle("Milestones")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { model.sawMilestones() }
        .safeAreaInset(edge: .top, spacing: 0) { StaleBanner() }
        .markedStale(model.isStale)
    }
}

/// Milestones' row in Usage: the title alone (#587).
struct MilestonesRow: View {
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Milestones")
            Spacer()
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens Milestones: the first steps taken, and the ones still to take")
    }
}
