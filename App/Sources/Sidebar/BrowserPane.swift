import AgentsKit
import SwiftUI

/// Placeholder. Built in this feature's Browser story.
struct BrowserPane: View {
    let agent: Agent
    let state: AgentPaneState

    var body: some View {
        Text("Browser")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
