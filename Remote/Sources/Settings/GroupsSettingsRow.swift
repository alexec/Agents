import AgentsKitCore
import SwiftUI

/// Settings ▸ Control plane: groups, which own machine providers (#1761): an admin's,
/// and a member's in a group, who sees the groups they are in (#2076).
struct GroupsSettingsRow: View {
    @Environment(RemoteModel.self) private var model

    var body: some View {
        if !model.needsPairing, model.people.showsGroups {
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
