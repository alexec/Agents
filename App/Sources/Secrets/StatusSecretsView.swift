import AgentsKitCore
import SwiftUI

/// Status ▸ Secrets and Status ▸ Accounts (#4161): what happened last to each of the person's secrets
/// or outside accounts, read only. A press opens Settings ▸ You ▸ Secrets or Accounts. The Remote and
/// the web page draw the same.
struct StatusSecretsView: View {
    let kind: StatusSecretsKind
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        StatusSecretsPage(kind: kind, control: model.controlRequests, state: model.userScope) { _ in
            model.settingsPaneAsked = kind == .secrets ? .secrets : .accounts
            openSettings()
        }
        .frame(maxWidth: 640)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle(kind.title)
    }
}
