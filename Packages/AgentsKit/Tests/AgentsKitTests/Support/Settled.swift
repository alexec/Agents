import Foundation
import Testing
@testable import AgentsKit

/// Wait until an agent is finished and nothing more is coming of its own accord:
/// nothing queued, no turn going and none being sent.
///
/// A turn that ended saying nothing is asked how it went a moment after it ends, and
/// that question can start a runtime of its own. So such an agent is not settled until
/// the question has been asked; a test that acts straight after would otherwise race it,
/// which a quiet machine never shows and a shared runner often does.
func settled(_ core: DaemonCore, _ id: UUID, _ what: String = "the agent settled",
             sourceLocation: SourceLocation = #_sourceLocation) async {
    await eventually(what, sourceLocation: sourceLocation) {
        guard let agent = await core.agent(id) else { return false }
        let turning = await core.turnTasks[id] != nil
        let sending = await core.sending.contains(id)
        return agent.state == .finished && agent.queuedPrompts.isEmpty && !turning && !sending
            && (agent.report != nil || agent.outcomeAsked)
    }
}
