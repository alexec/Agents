import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

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
        let reached = Set(AgentState.allCases.map { AgentGroup(for: $0) })
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
        #expect(AgentGroup.running.title == "Working")
        #expect(AgentGroup.finished.title == "Complete")
        #expect(AgentGroup.stopped.title == "Stopped")
    }

    @Test("one group per state, so a row never needs a second reading")
    func oneGroupPerState() {
        #expect(AgentGroup.allCases.count == AgentState.allCases.count)
    }

    /// An agent that has asked to be looked at, which is a mark and not a state.
    ///
    /// The property is the same one the rest of this suite holds: exactly one group
    /// per agent, never none. Widened to both inputs rather than relaxed.
    @Test func wantingToBeLookedAtIsStillExactlyOneGroup() {
        for state in AgentState.allCases {
            for wantsEyes in [true, false] {
                let group = AgentGroup(for: state, wantsEyes: wantsEyes)
                #expect(AgentGroup.allCases.contains(group))
            }
        }
    }

    /// A working agent that has asked for a file goes where the person will see it.
    @Test func aWorkingAgentThatAskedToBeLookedAtNeedsAttention() {
        #expect(AgentGroup(for: .running, wantsEyes: true) == .needsAttention)
        #expect(AgentGroup(for: .finished, wantsEyes: true) == .needsAttention)
    }

    /// An agent that is not going anywhere is not waiting on you.
    @Test func aSettledAgentIsNotDraggedIntoNeedsAttention() {
        #expect(AgentGroup(for: .stopped, wantsEyes: true) == .stopped)
        #expect(AgentGroup(for: .archived, wantsEyes: true) == .archived)
    }

    /// The old initialiser still means what it meant.
    @Test func theOlderInitialiserIsTheNoEyesCase() {
        for state in AgentState.allCases {
            #expect(AgentGroup(for: state) == AgentGroup(for: state, wantsEyes: false))
        }
    }
}
