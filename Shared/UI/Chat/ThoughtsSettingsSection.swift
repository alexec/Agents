import AgentsKitCore
import SwiftUI

/// Whether the chat draws the agent's thoughts (#1725). Off at first: most people do not
/// want to read the agent's thinking. Kept on this device only, as the smart-group switches
/// are (#846); the web page keeps the same choice in its local storage.
enum ChatThoughts {
    static let showsKey = "showsThoughts"
    static let showsAtFirst = false

    /// `items` as the chat draws them: with the thoughts, or with them left off.
    static func shown(_ items: [TranscriptItem], showsThoughts: Bool) -> [TranscriptItem] {
        showsThoughts ? items : items.omittingThoughts()
    }
}

/// The Show thoughts switch, in Settings ▸ Appearance on the Mac and the Remote.
struct ThoughtsSettingsSection: View {
    /// The Remote's Settings has no Appearance pane of its own, so the section says it.
    var header: String? = nil
    @AppStorage(ChatThoughts.showsKey, store: WindowDefaults.store) private var showsThoughts = ChatThoughts.showsAtFirst

    var body: some View {
        Section {
            Toggle("Show thoughts", isOn: $showsThoughts)
        } header: {
            if let header { Text(header) }
        } footer: {
            Text("On, the chat shows each of the agent's thoughts as one folded line. Off, they are not shown.")
                .appText(.fine)
                .foregroundStyle(.secondary)
        }
        .paperListRow()
    }
}
