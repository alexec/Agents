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

    // MARK: And what the agent said about the work

    private static func report(_ outcome: WorkOutcome) -> WorkReport {
        WorkReport(outcome: outcome, message: "words", at: Date())
    }

    /// The same property again, widened to the third input rather than relaxed:
    /// exactly one group per agent, never none and never two.
    @Test func everyStateAndReportPairIsStillExactlyOneGroup() {
        let reports: [WorkReport?] = [nil] + WorkOutcome.allCases.map(Self.report)
        for state in AgentState.allCases {
            for wantsEyes in [true, false] {
                for report in reports {
                    let group = AgentGroup(for: state, wantsEyes: wantsEyes, report: report)
                    #expect(AgentGroup.allCases.contains(group))
                }
            }
        }
    }

    /// The one rule this feature adds: an agent that said it cannot get further
    /// without a person is where the person actually looks.
    @Test func aFinishedAgentThatNeedsAPersonIsInNeedsAttention() {
        for outcome in WorkOutcome.allCases where outcome.needsAPerson {
            #expect(AgentGroup(for: .finished, report: Self.report(outcome)) == .needsAttention)
        }
        for outcome in WorkOutcome.allCases where !outcome.needsAPerson {
            #expect(AgentGroup(for: .finished, report: Self.report(outcome)) == .finished)
        }
    }

    /// How a turn *ended* outranks what the agent said about the work. An agent
    /// somebody stopped, or put away, is not waiting on them whatever it last claimed.
    @Test func aStoppedOrArchivedAgentIsUnmovedByAnyReport() {
        for outcome in WorkOutcome.allCases {
            #expect(AgentGroup(for: .stopped, report: Self.report(outcome)) == .stopped)
            #expect(AgentGroup(for: .archived, report: Self.report(outcome)) == .archived)
        }
    }

    /// A report is about a turn that is over, so it says nothing about one in flight.
    @Test func aRunningAgentIsGroupedByWhatItIsDoing() {
        for outcome in WorkOutcome.allCases {
            #expect(AgentGroup(for: .running, report: Self.report(outcome)) == .running)
            #expect(AgentGroup(for: .waitingOnUser, report: Self.report(outcome)) == .needsAttention)
        }
    }

    /// The old initialiser still means what it meant.
    @Test func theOlderInitialiserIsTheNoEyesCase() {
        for state in AgentState.allCases {
            #expect(AgentGroup(for: state) == AgentGroup(for: state, wantsEyes: false))
        }
    }
}
