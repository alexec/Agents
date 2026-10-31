import AgentsKitCore
import SwiftUI

/// Over a chat whose account can no longer reach the model (#999): the organisation removed
/// it, or its policy refuses it now. Why, and **Continue in New**, as the Mac's strip has them.
struct RemoteAccountMoveStrip: View {
    @Environment(RemoteModel.self) private var model
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
            Button(OrgAccountWords.continueInNew) {
                Task { await model.continueInNew(agent.id) }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .appText(.fine)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}
