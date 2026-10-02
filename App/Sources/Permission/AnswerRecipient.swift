import AgentsKitCore
import SwiftUI

/// What an answer looks like while it is on its way: on the button that sent it, with
/// every other answer on the card held, so a double click or a repeated ⌘1 is not a
/// second answer (#86). The Remote's sheets say the same, "telling your Mac".
///
/// Inside the button's own label rather than over it: the card is the button, and
/// anything laid over it keeps the clicks.
struct Telling: View {
    let host: String

    var body: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text("telling \(host)")
                .appText(.fine)
                .foregroundStyle(.secondary)
        }
    }
}

extension AppModel {
    /// Who an answer to this agent's question goes to, as the pending mark names it.
    func answerRecipient(_ agentID: UUID) -> String {
        let host = work.agent(agentID)?.host ?? .mac
        return host == .mac ? "your Mac" : hosts.label(host)
    }
}
