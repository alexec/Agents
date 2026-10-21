import AgentsKitCore
import SwiftUI

/// Settings ▸ Control plane: channel identities linked to people (#1762).
struct ChannelsSettingsRow: View {
    @Environment(RemoteModel.self) private var model

    var body: some View {
        if !model.needsPairing {
            NavigationLink {
                ChannelsPane(control: model.controlPlane, people: model.people)
                    .navigationTitle(ChannelLinkWords.title)
                    .navigationBarTitleDisplayMode(.inline)
            } label: {
                Label(ChannelLinkWords.title, systemImage: "bubble.left.and.bubble.right")
            }
        }
    }
}
