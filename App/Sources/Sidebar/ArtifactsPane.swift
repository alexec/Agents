import AgentsKit
import SwiftUI

/// Placeholder. Built in this feature's Artifacts story.
struct ArtifactsPane: View {
    let agent: Agent
    let state: AgentPaneState

    var body: some View {
        Text("Artifacts")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
