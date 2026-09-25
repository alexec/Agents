import AgentsKitCore
import SwiftUI

/// The short form of what an agent holds or waits for, for its row on the Mac and its
/// card on the phone (036 FR-010): "▣ Holds Screen · 18 min", with "and 1 more" under
/// it when there is more.
///
/// A line of its own under the report, because the title line already carries the
/// workflow, starter and worktree marks. Untinted secondary text. An idle agent that
/// still holds something is exactly what this is for (US5-AS3).
struct LeaseMark: View {
    let status: LeaseStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("\(status.markSymbol) \(status.mark)")
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if status.moreCount > 0 {
                Text("and \(status.moreCount) more")
                    .foregroundStyle(.tertiary)
            }
        }
        .appText(.fine)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(status.fullLine)
    }
}
