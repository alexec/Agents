import AgentsKitCore
import SwiftUI

/// Settings ▸ Machines ▸ Secrets: the secrets the control plane keeps for you and sends to each
/// machine of yours (#1760, #2157).
struct SecretsSettingsRow: View {
    @Environment(RemoteModel.self) private var model

    var body: some View {
        if !model.needsPairing {
            NavigationLink {
                SecretsPane(control: model.controlPlane, state: model.userScope)
                    .navigationTitle(UserScopeWords.secretsTitle)
                    .navigationBarTitleDisplayMode(.inline)
            } label: {
                Label(UserScopeWords.secretsTitle, systemImage: "key")
            }
        }
    }
}
