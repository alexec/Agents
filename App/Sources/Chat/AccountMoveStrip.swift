import AgentsKitCore
import SwiftUI

/// Over a chat whose account can no longer reach the model (#999): the organisation removed
/// it, or its policy refuses it now. Why, and **Continue in New**, which starts a session that
/// reads this one on the runtime's account for new sessions. Where the missing-folder strip is.
struct AccountMoveStrip: View {
    @Environment(AppModel.self) private var model
    let agent: Agent
    let reason: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text(reason).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "building.2").foregroundStyle(.secondary)
            }
            .appText(.fine)
            HStack(spacing: 8) {
                Button {
                    Task { await model.continueInNew(agent.id) }
                } label: {
                    Label(OrgAccountWords.continueInNew, systemImage: "arrow.turn.down.right")
                }
                .help("Start a new session that reads this one and carries on, on the account new sessions use")
                Spacer(minLength: 0)
            }
            .buttonStyle(.paper)
            .appText(.fine)
        }
        .chatColumn()
        .padding(.vertical, 8)
    }
}
