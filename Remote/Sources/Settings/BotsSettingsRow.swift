import AgentsKitCore
import SwiftUI

/// Settings ▸ Control plane ▸ Bots (#2132): the bots that run the team's workflows, apart from
/// the people, an admin's.
struct BotsSettingsRow: View {
    @Environment(RemoteModel.self) private var model

    var body: some View {
        if !model.needsPairing, model.people.you?.isAdmin == true {
            NavigationLink {
                PeoplePane(control: model.controlPlane, people: model.people, kind: .bot)
                    .navigationTitle(BotWords.title)
                    .navigationBarTitleDisplayMode(.inline)
            } label: {
                Label(BotWords.title, systemImage: "gearshape.2")
            }
        }
    }
}
