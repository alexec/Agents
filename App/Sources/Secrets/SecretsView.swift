import AgentsKitCore
import SwiftUI

/// Settings ▸ You ▸ Secrets (#3998): the person's secrets and cards, kept by the control plane and
/// sent to each machine of theirs (#1760), then this Mac's secrets for one session (#3548) and what agents saved on it (#5122). Was
/// Settings ▸ You ▸ Secrets (#3632), and before that Settings ▸ Machines ▸ Secrets. The web page draws
/// the same in Settings ▸ You ▸ Secrets.
struct SecretsView: View {
    @Environment(AppModel.self) private var model
    /// Reveal and Copy (#5115), opened with this window's own key.
    @State private var show = SecretShowState { ControlConfig.sealing() }

    var body: some View {
        // Through the window's own connection, which hears when they change (#1760).
        SecretsPane(control: model.controlRequests, state: model.userScope,
                    machineNames: SecretInfoWords.names(model.controlPlaneHosts ?? [], thisMac: model.thisMacHostID),
                    show: show) {
                        SessionSecretsSection(model: model)
                        LocalSecretsSection(model: model)
                    }
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .navigationTitle(UserScopeWords.secretsTitle)
    }
}
