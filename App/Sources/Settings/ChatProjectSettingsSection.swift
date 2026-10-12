import AgentsKitCore
import SwiftUI

/// Settings ▸ General ▸ Chat (#694): whether there is a chat project (#229) at all.
///
/// Read from the projects, not kept apart: on while any host's chat project is live. Off
/// archives each one and takes New Chat out of the File menu; on brings them back. Not
/// drawn where no host made one, as on a scratch root with no personal home.
struct ChatProjectSettingsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.hasChatProjects {
            Section {
                Toggle("Chat project", isOn: Binding(
                    get: { !model.chatProjectSwitchedOff },
                    set: { on in Task { await model.setChatProject(on) } }))
            } header: {
                Text("Chat")
            } footer: {
                Text("A project in ~/.agents/chat for chats that need no project of their own, opened by "
                     + "File ▸ New Chat. Off archives it" + (model.hosts.isEmpty ? "" : " on this Mac and every server")
                     + " and takes New Chat away. Its chats are kept, and come back when it is turned on.")
                    .appText(.fine)
                    .foregroundStyle(.secondary)
            }
            .paperListRow()
        }
    }
}
