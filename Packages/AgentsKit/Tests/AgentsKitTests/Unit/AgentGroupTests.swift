import Foundation
import Testing
@testable import AgentsKit

/// The one property that stops an agent disappearing: every state is in exactly one
/// group. A state added later and not thought about fails this rather than quietly
/// becoming an agent nobody can see.
@Suite("Agent grouping")
struct AgentGroupTests {
    @Test("every state maps to a group")
    func totalOverStates() {
        for state in AgentState.allCases {
            _ = AgentGroup(for: state)
        }
        #expect(AgentState.allCases.count == 5)
    }

    @Test("each state maps to the group the spec names")
    func mappingIsTheSpecs() {
        #expect(AgentGroup(for: .waitingOnUser) == .needsAttention)
        #expect(AgentGroup(for: .running) == .running)
        #expect(AgentGroup(for: .finished) == .finished)
        #expect(AgentGroup(for: .stopped) == .stopped)
        #expect(AgentGroup(for: .archived) == .archived)
    }

    @Test("every group is reachable from some state")
    func everyGroupReachable() {
        let reached = Set(AgentState.allCases.map(AgentGroup.init(for:)))
        #expect(reached == Set(AgentGroup.allCases))
    }

    @Test("the four live groups are in the order the panel draws them")
    func liveOrder() {
        #expect(AgentGroup.live == [.needsAttention, .running, .finished, .stopped])
        #expect(!AgentGroup.live.contains(.archived))
    }

    @Test("titles are the words the spec uses")
    func titles() {
        #expect(AgentGroup.needsAttention.title == "Needs attention")
        #expect(AgentGroup.running.title == "Running")
        #expect(AgentGroup.finished.title == "Finished")
        #expect(AgentGroup.stopped.title == "Stopped")
    }

    @Test("one group per state, so a row never needs a second reading")
    func oneGroupPerState() {
        #expect(AgentGroup.allCases.count == AgentState.allCases.count)
    }
}
