import AgentsKitCore
import SwiftUI

/// Settings ▸ Control plane: who uses the control plane, and what belongs to them (#994).
struct PeopleSettingsRow: View {
    @Environment(RemoteModel.self) private var model

    var body: some View {
        if !model.needsPairing {
            NavigationLink {
                PeoplePane(control: model.controlPlane, people: model.people)
                    .navigationTitle("People")
                    .navigationBarTitleDisplayMode(.inline)
            } label: {
                Label("People", systemImage: "person.2")
            }
        }
    }
}
