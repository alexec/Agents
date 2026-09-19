import AgentsKit
import SwiftUI

/// Placeholder. Built in this feature's Files story.
struct FilesPane: View {
    let agent: Agent
    let state: AgentPaneState

    var body: some View {
        Text("Files")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
