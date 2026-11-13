import AgentsKitCore
import SwiftUI

/// The account's strip (#5034, third of the session's strips; #999): the session's account can
/// no longer reach the model: the organisation removed it, or its policy refuses it now. Why,
/// and **Continue in New**, which starts a session that reads this one on the runtime's account
/// for new sessions.
struct AccountMoveStrip: View {
    @Environment(AppModel.self) private var model
    let agent: Agent
    let reason: String

    var body: some View {
        Strip(tone: .warning, symbol: "person.crop.circle.badge.exclamationmark", line: reason,
              primary: StripButton(title: OrgAccountWords.continueInNew,
                                   help: "Start a new session that reads this one and carries on, on the account new sessions use") {
                  Task { await model.continueInNew(agent.id) }
              })
    }
}
