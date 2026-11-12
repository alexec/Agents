import AgentsKitCore
import SwiftUI

/// Over a chat whose account can no longer reach the model (#999): the organisation removed
/// it, or its policy refuses it now. Why, and **Continue in New**, which starts a session that
/// reads this one on the runtime's account for new sessions. An attention banner (#4737),
/// where the missing-folder banner is.
struct AccountMoveStrip: View {
    @Environment(AppModel.self) private var model
    let agent: Agent
    let reason: String

    var body: some View {
        PaneBanner(tone: .attention, reason) {
            Button {
                Task { await model.continueInNew(agent.id) }
            } label: {
                Label(OrgAccountWords.continueInNew, systemImage: "arrow.turn.down.right")
            }
            .help("Start a new session that reads this one and carries on, on the account new sessions use")
        }
        .chatColumn()
        .padding(.top, 8)
    }
}
