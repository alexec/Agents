import AgentsKitCore
import SwiftUI

/// Settings ▸ Control plane: the organisation's policy, read only, and the kill switch for an
/// admin (#998).
struct PolicySettingsRow: View {
    @Environment(RemoteModel.self) private var model

    var body: some View {
        if !model.needsPairing {
            NavigationLink {
                OrgPolicyPane(control: model.controlPlane, isAdmin: model.people.you?.isAdmin == true)
                    .navigationTitle(OrgPolicyWords.title)
                    .navigationBarTitleDisplayMode(.inline)
            } label: {
                Label(OrgPolicyWords.title, systemImage: OrgPolicyWords.symbol)
            }
        }
    }
}
