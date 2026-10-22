import AgentsKitCore
import SwiftUI

/// Settings ▸ Control plane: groups, which own workspace providers (#1761), an admin's.
struct GroupsSettingsRow: View {
    @Environment(RemoteModel.self) private var model

    var body: some View {
        if !model.needsPairing, model.people.you?.isAdmin != false {
            NavigationLink {
                GroupsPane(control: model.controlPlane, state: model.people)
                    .navigationTitle(GroupWords.title)
                    .navigationBarTitleDisplayMode(.inline)
            } label: {
                Label(GroupWords.title, systemImage: "person.3")
            }
        }
    }
}
