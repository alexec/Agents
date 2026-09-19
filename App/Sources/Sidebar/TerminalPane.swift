import AgentsKit
import SwiftUI

/// Placeholder. Built in this feature's Terminal story.
struct TerminalPane: View {
    let agent: Agent
    let state: AgentPaneState

    var body: some View {
        Text("Terminal")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
