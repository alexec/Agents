import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

@Suite("Agent grouping")
struct AgentGroupTests {
    private func agent(_ state: AgentState, report outcome: WorkOutcome? = nil,
                       endedReason: EndedReason? = nil, unread: Bool = false) -> Agent {
        var agent = Agent(runtimeID: "claude", cwd: URL(fileURLWithPath: "/tmp/work"),
                          state: state, endedReason: endedReason)
        agent.report = outcome.map { WorkReport(outcome: $0, message: "Status", at: Date()) }
        agent.isUnread = unread
        return agent
    }

    @Test func groupsAppearInActionOrder() {
        #expect(AgentGroup.live.map(\.title) == ["Needs you", "Waiting", "Working", "Done", "Paused", "Parked"])
        #expect(AgentGroup.archived.title == "Archived")
        #expect(!AgentGroup.live.contains(.blocked))
    }

    @Test func unreadFinishedSessionsNeedYouUntilOpened() {
        var completed = agent(.finished, report: .done, endedReason: .endTurn, unread: true)
        #expect(completed.group(wantsEyes: false) == .needsAttention)
        completed.isUnread = false
        #expect(completed.group(wantsEyes: false) == .finished)
        completed.report = WorkReport(outcome: .needsAnswer, message: "Choose", at: Date())
        #expect(completed.group(wantsEyes: false) == .needsAttention)
    }

    @Test func unaccountedOutcomesNeedReview() {
        var unknown = agent(.finished, endedReason: .endTurn)
        unknown.outcomeAsked = true
        #expect(unknown.group(wantsEyes: false) == .needsAttention)
    }

    @Test func manualBlocksNeedYouAndAutomaticWaitsDoNot() {
        var blocked = agent(.finished, report: .blocked, endedReason: .endTurn)
        #expect(blocked.group(wantsEyes: false) == .needsAttention)
        blocked.report = WorkReport(outcome: .blocked, message: "Waiting", at: Date(),
                                    block: Block(checkAgainAt: Date().addingTimeInterval(600)))
        #expect(blocked.group(wantsEyes: false) == .waiting)
        blocked.isUnread = true
        #expect(blocked.group(wantsEyes: false) == .needsAttention)
    }

    @Test func stoppedSessionsFollowWhoActsNext() {
        #expect(agent(.stopped, endedReason: .cancelled).group(wantsEyes: false) == .stopped)
        #expect(agent(.stopped, endedReason: .stoppedByAgent).group(wantsEyes: false) == .stopped)
        #expect(agent(.stopped, endedReason: .processDied).group(wantsEyes: false) == .needsAttention)
    }

    @Test func explicitParkingAndLiveQuestionsKeepTheirPriority() {
        var finished = agent(.finished, report: .done, endedReason: .endTurn, unread: true)
        finished.parking = .parked(at: Date())
        #expect(finished.group(wantsEyes: false) == .parked)
        finished.state = .waitingOnUser
        #expect(finished.group(wantsEyes: false) == .needsAttention)
        finished.state = .archived
        #expect(finished.group(wantsEyes: false) == .archived)
    }

    @Test func everyStateAndOutcomeMapsToOneVisibleGroup() {
        for state in AgentState.allCases {
            for outcome in [nil] + WorkOutcome.allCases.map(Optional.some) {
                for unread in [false, true] {
                    let group = agent(state, report: outcome, unread: unread).group(wantsEyes: false)
                    #expect(AgentGroup.live.contains(group) || group == .archived)
                }
            }
        }
    }
}
