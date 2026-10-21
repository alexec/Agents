import AgentsKitCore
import SwiftUI

/// Settings ▸ You: how you sign in on your other clients (#995).
struct SignInsSettingsRow: View {
    @Environment(RemoteModel.self) private var model

    var body: some View {
        if !model.needsPairing {
            NavigationLink {
                Form {
                    SignInsSection(control: model.controlPlane, controlKey: RemoteControl.controlKey,
                                   revision: model.people.revision)
                        .paperListRow()
                }
                .paperForm()
                .navigationTitle(SignInWords.signInsTitle)
                .navigationBarTitleDisplayMode(.inline)
            } label: {
                Label(SignInWords.signInsTitle, systemImage: "person.badge.key")
            }
        }
    }
}
