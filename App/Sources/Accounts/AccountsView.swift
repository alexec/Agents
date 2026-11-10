import AgentsKitCore
import SwiftUI

/// Settings ▸ You ▸ Accounts (#3967, #3998): `Shared/UI/UserScope/AccountsPane.swift`, which the
/// Remote draws too (#4033), through the window's own connection.
struct AccountsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        AccountsPane(control: model.controlRequests, state: model.userScope,
                     machineNames: SecretInfoWords.names(model.controlPlaneHosts ?? [], thisMac: model.thisMacHostID))
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .navigationTitle(AccountsWords.title)
    }
}
