import AgentsKitCore
import SwiftUI

extension AppModel {
    /// Who something sent to this agent goes to, as the pending mark (`Telling`) names it.
    func answerRecipient(_ agentID: UUID) -> String {
        let host = work.agent(agentID)?.host ?? .mac
        return host == .mac ? "your Mac" : hosts.label(host)
    }
}
