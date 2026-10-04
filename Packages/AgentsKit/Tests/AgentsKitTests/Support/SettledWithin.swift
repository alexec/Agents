import Foundation
import Testing
@testable import AgentsKit

extension Eventually {
    /// How long to wait for a chain of turns: an agent picked back up, asked how it
    /// went, and what that sets off, each starting a runtime of its own. Every step is
    /// waited on rather than slept through, but under a full parallel suite on a loaded
    /// Mac the chain together took longer than `timeout` (#225). Inside the suites'
    /// one-minute limit, and only ever waited out by a test that is failing.
    static let chain: Duration = .seconds(45)
}

/// `settled`, waiting as long as the caller says: for an agent whose way to settled is
/// several turns long.
func settled(_ core: DaemonCore, _ id: UUID, _ what: String = "the agent settled", within: Duration,
             sourceLocation: SourceLocation = #_sourceLocation) async {
    await eventually(what, within: within, sourceLocation: sourceLocation) {
        guard let agent = await core.agent(id) else { return false }
        let turning = await core.turnTasks[id] != nil
        let sending = await core.sending.contains(id)
        return agent.state == .finished && agent.queuedPrompts.isEmpty && !turning && !sending
            && (agent.report != nil || agent.outcomeAsked)
    }
}
