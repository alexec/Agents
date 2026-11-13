import AgentsKitCore
import SwiftUI

/// The account's strip (#5034, third of the session's strips; #999): the session's account can
/// no longer reach the model. Why, and **Continue in New**, as the Mac's strip has them.
struct RemoteAccountMoveStrip: View {
    @Environment(RemoteModel.self) private var model
    let agent: Agent
    let reason: String

    var body: some View {
        Strip(tone: .warning, symbol: "person.crop.circle.badge.exclamationmark", line: reason,
              primary: StripButton(title: OrgAccountWords.continueInNew) {
                  Task { await model.continueInNew(agent.id) }
              })
    }
}
