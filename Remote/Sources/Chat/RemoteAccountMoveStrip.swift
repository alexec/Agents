import AgentsKitCore
import SwiftUI

/// Over a chat whose account can no longer reach the model (#999): the organisation removed
/// it, or its policy refuses it now. Why, and **Continue in New**, as the Mac's strip has them:
/// an attention banner (#4737).
struct RemoteAccountMoveStrip: View {
    @Environment(RemoteModel.self) private var model
    let agent: Agent
    let reason: String

    var body: some View {
        PaneBanner(tone: .attention, reason) {
            Button(OrgAccountWords.continueInNew) {
                Task { await model.continueInNew(agent.id) }
            }
        }
        .paneBannerInset()
        .remoteBannerGround()
    }
}
