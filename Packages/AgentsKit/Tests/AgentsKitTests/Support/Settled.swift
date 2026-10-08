import Foundation
import Testing
@testable import AgentsKit

/// Wait until an agent is finished and nothing more is coming of its own accord:
/// nothing queued, no turn going and none being sent.
///
/// A turn that ended saying nothing is no longer asked how it went (#479): its ending
/// is worked out before the agent reads as finished, so finished is settled.
func settled(_ core: DaemonCore, _ id: UUID, _ what: String = "the agent settled",
             sourceLocation: SourceLocation = #_sourceLocation) async {
    await eventually(what, sourceLocation: sourceLocation) {
        guard let agent = await core.agent(id) else { return false }
        let turning = await core.turnTasks[id] != nil
        let sending = await core.sending.contains(id)
        return agent.state == .finished && agent.queuedPrompts.isEmpty && !turning && !sending
    }
}
