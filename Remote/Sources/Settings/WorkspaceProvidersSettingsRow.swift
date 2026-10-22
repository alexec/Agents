import AgentsKitCore
import SwiftUI

/// Settings ▸ Control plane ▸ Workspace providers (#1819), as the page's Settings has them:
/// only where the control plane runs them, as the window's `providersHere` (#2260).
struct WorkspaceProvidersSettingsRow: View {
    @Environment(RemoteModel.self) private var model

    var body: some View {
        Group {
            if !model.needsPairing, model.providersHere {
                NavigationLink { WorkspaceProvidersView() } label: {
                    Label(WorkspaceProviderWords.heading, systemImage: "cloud")
                }
            }
        }
        .task { await model.checkProvidersHere() }
    }
}
