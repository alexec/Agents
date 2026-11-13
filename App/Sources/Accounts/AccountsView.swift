import AgentsKitCore
import SwiftUI

/// Settings ▸ You ▸ Accounts (#3967, #3998): `Shared/UI/UserScope/AccountsPane.swift`, which the
/// Remote draws too (#4033), through the window's own connection.
struct AccountsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        AccountsPane(control: model.controlRequests, state: model.userScope,
                     machineNames: SecretInfoWords.names(model.controlPlaneHosts ?? [], thisMac: model.thisMacHostID),
                     reveal: reveal)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .navigationTitle(AccountsWords.title)
    }

    /// This window's own copy of a secret, opened with its key (#5116): nil while the control
    /// plane can not be reached or the window is not paired, so there is no Details….
    private var reveal: SecretReveal? {
        guard let control = model.controlRequests, ControlConfig.client != nil else { return nil }
        return { request in
            // The key is read from the Keychain only when a person asks, not at each draw.
            guard let (key, client) = ControlConfig.sealing() else { throw SecretRevealWords.RevealFailure() }
            return try await ClientSealing.reveal(request, on: control, key: key, client: client)
        }
    }
}
