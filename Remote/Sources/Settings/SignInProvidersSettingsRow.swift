import AgentsKitCore
import SwiftUI

/// Settings ▸ Control plane: which providers people sign in with (#995), an admin's.
struct SignInProvidersSettingsRow: View {
    @Environment(RemoteModel.self) private var model

    var body: some View {
        if !model.needsPairing, model.people.you?.isAdmin == true {
            NavigationLink {
                SignInPane(control: model.controlPlane, revision: model.people.revision)
                    .navigationTitle(SignInWords.paneTitle)
                    .navigationBarTitleDisplayMode(.inline)
            } label: {
                Label(SignInWords.paneTitle, systemImage: SignInWords.paneSymbol)
            }
        }
    }
}
