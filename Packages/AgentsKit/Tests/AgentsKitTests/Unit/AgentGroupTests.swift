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
        #expect(AgentGroup(for: .waitingOnUser) == .needsInput)
        #expect(AgentGroup(for: .running) == .working)
        #expect(AgentGroup(for: .finished) == .completed)
        #expect(AgentGroup(for: .stopped) == .completed)
        #expect(AgentGroup(for: .archived) == .archived)
    }

    @Test("every group is reachable from some state")
    func everyGroupReachable() {
        let reached = Set(AgentState.allCases.map(AgentGroup.init(for:)))
        #expect(reached == Set(AgentGroup.allCases))
    }

    @Test("the three live groups are in the order the panel draws them")
    func liveOrder() {
        #expect(AgentGroup.live == [.needsInput, .working, .completed])
        #expect(!AgentGroup.live.contains(.archived))
    }

    @Test("titles are the words the spec uses")
    func titles() {
        #expect(AgentGroup.needsInput.title == "Needs input")
        #expect(AgentGroup.working.title == "Working")
        #expect(AgentGroup.completed.title == "Completed")
    }
}
