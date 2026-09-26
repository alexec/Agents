import AgentsKit
import SwiftUI

/// Settings ▸ Agents: the agents themselves, as against the runtimes they run on (Agent
/// Runtimes). For now, how long archived agents are kept (051).
struct AgentsSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            ArchiveSettingsSection()
        }
        .paperForm()
        .task { await model.refreshRetentionState() }
    }
}
