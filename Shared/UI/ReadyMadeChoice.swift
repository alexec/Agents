import AgentsKitCore
import SwiftUI

/// Under an edited ready-made copy's status card (#4075): take the newer ready-made version,
/// or keep the copy and hear no more of this version. The Mac and the Remote draw the same
/// two buttons; the web page's WorkflowPage.tsx draws them too.
struct ReadyMadeChoice: View {
    var take: () async -> Void
    var keep: () async -> Void
    @State private var busy = false

    var body: some View {
        HStack(spacing: 10) {
            Button(WorkflowSummary.takeReadyMadeTitle) { run(take) }
                .buttonStyle(.paperProminent)
                .help(WorkflowSummary.takeReadyMadeHelp)
            Button(WorkflowSummary.keepEditedTitle) { run(keep) }
                .buttonStyle(.paper)
                .help(WorkflowSummary.keepEditedHelp)
        }
        .disabled(busy)
    }

    private func run(_ action: @escaping () async -> Void) {
        busy = true
        Task {
            await action()
            busy = false
        }
    }
}
