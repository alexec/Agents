import AgentsKitCore
import SwiftUI

/// Settings ▸ You: the settings and secrets the control plane keeps for you (#1760).
struct UserScopeSettingsRow: View {
    @Environment(RemoteModel.self) private var model

    var body: some View {
        if !model.needsPairing {
            NavigationLink {
                UserScopePane(control: model.controlPlane, state: model.userScope)
                    .navigationTitle(UserScopeWords.title)
                    .navigationBarTitleDisplayMode(.inline)
            } label: {
                Label(UserScopeWords.title, systemImage: "arrow.triangle.2.circlepath")
            }
        }
    }
}
