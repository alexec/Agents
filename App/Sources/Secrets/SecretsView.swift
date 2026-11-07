import AgentsKitCore
import SwiftUI

/// Your setup ▸ Secrets (#3632): the person's secrets and cards, kept by the control plane and
/// sent to each machine of theirs (#1760), then this Mac's secrets for one session (#3548). Was
/// Settings ▸ Machines ▸ Secrets. The web page draws the same in Your setup ▸ Secrets.
struct SecretsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        // Through the window's own connection, which hears when they change (#1760).
        SecretsPane(control: model.controlRequests, state: model.userScope) { SessionSecretsSection() }
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .navigationTitle(UserScopeWords.secretsTitle)
    }
}

struct SecretsRow: View {
    var body: some View {
        // The title alone (#587).
        HStack(alignment: .firstTextBaseline) {
            Text(UserScopeWords.secretsTitle).foregroundStyle(.primary)
            Spacer()
        }
        .help("Your secrets and cards, sent to each machine of yours")
    }
}
