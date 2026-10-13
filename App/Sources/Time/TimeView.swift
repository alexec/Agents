import AgentsKitCore
import SwiftUI

/// Where the time of this Mac's running chats went (#852): the agent working, its tools,
/// waiting on others, and waiting for you, drawn as the usage charts on Cost are.
///
/// A page in the detail column, picked from Activity in the sidebar. Read-only.
struct TimeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            TimeChartsSection(load: { await model.timeHistory() })
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
