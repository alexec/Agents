import AgentsKitCore
import SwiftUI

/// Settings ▸ Control plane ▸ Machine providers (#1819), as the page's Settings has them:
/// only where the control plane runs them, as the window's `providersHere` (#2260).
struct MachineProvidersSettingsRow: View {
    @Environment(RemoteModel.self) private var model

    var body: some View {
        Group {
            if !model.needsPairing, model.providersHere {
                NavigationLink { MachineProvidersView() } label: {
                    Label(MachineProviderWords.heading, systemImage: "cloud")
                }
            }
        }
        .task { await model.checkProvidersHere() }
    }
}
