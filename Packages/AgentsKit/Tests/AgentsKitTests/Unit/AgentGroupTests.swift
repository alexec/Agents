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
        #expect(AgentGroup.live.map(\.title) == ["Needs you", "Waiting", "Working", "Done", "Paused"])
        #expect(AgentGroup.archived.title == "Archived")
        #expect(!AgentGroup.live.contains(.blocked))
    }

    /// #70: unread is a mark on the row, not a reason for a group, so reading a chat
    /// never moves it.
    @Test func finishedAndUnreadIsDone() {
        var completed = agent(.finished, report: .done, endedReason: .endTurn, unread: true)
        #expect(completed.group() == .finished)
        #expect(completed.showsUnread)
        completed.isUnread = false
        #expect(completed.group() == .finished)
    }

    /// #584: a request to archive is a mark on the row too, never a group.
    @Test func askingToBeArchivedStaysInDone() {
        var asking = agent(.finished, report: .done, endedReason: .endTurn, unread: true)
        asking.archiveRequest = .requested(at: Date())
        #expect(asking.group() == .finished)
        #expect(asking.asksToArchive)
        #expect(asking.showsUnread)
    }

    /// #1323: the row is bold only for an unread session in Done. One that asks, waits
    /// or needs the person is never bold, though it still counts as unread.
    @Test func onlyDoneDrawsUnread() {
        var completed = agent(.finished, report: .done, endedReason: .endTurn, unread: true)
        #expect(completed.drawsUnread)
        completed.archiveRequest = .requested(at: Date())
        #expect(completed.drawsUnread, "asking to be archived is still done")
        let asking = agent(.finished, report: .needsAnswer, endedReason: .endTurn, unread: true)
        #expect(asking.group() == .needsAttention)
        #expect(asking.showsUnread)
        #expect(!asking.drawsUnread)
        #expect(!agent(.finished, report: .done, endedReason: .endTurn, unread: false).drawsUnread)
    }

    /// What truly needs the person stays under Needs you, read or not.
    @Test func whatNeedsYouStaysWhetherReadOrNot() {
        for unread in [false, true] {
            var asked = agent(.finished, report: .needsAnswer, endedReason: .endTurn, unread: unread)
            #expect(asked.group() == .needsAttention)
            asked.report = nil
            asked.outcomeAsked = true
            #expect(asked.group() == .needsAttention, "an unaccounted ending")
            #expect(agent(.waitingOnUser, unread: unread).group() == .needsAttention)
        }
    }

    /// The icon no longer turns orange for unread alone: the dot carries it.
    @Test func unreadAloneIsNotTheAttentionShape() {
        #expect(StatusShape(state: .finished, outcome: .done, isWaiting: false, isComingBack: false) == .done)
        #expect(StatusShape(state: .finished, outcome: nil, isWaiting: false, isComingBack: false,
                            outcomeUnknown: true) == .needsYou)
    }

    @Test func unaccountedOutcomesNeedReview() {
        var unknown = agent(.finished, endedReason: .endTurn)
        unknown.outcomeAsked = true
        #expect(unknown.group() == .needsAttention)
    }

    /// Only a question needs the person (#1916): a block on nothing the app watches is done.
    @Test func manualBlocksAreDoneAndAutomaticWaitsWait() {
        var blocked = agent(.finished, report: .waiting, endedReason: .endTurn)
        #expect(blocked.group() == .finished)
        blocked.report = WorkReport(outcome: .waiting, message: "Waiting", at: Date(),
                                    block: Block(checkAgainAt: Date().addingTimeInterval(600)))
        #expect(blocked.group() == .waiting)
        blocked.isUnread = true
        #expect(blocked.group() == .waiting, "an unread wait still carries on by itself")
    }

    @Test func stoppedSessionsFollowWhoActsNext() {
        #expect(agent(.stopped, endedReason: .cancelled).group() == .stopped)
        #expect(agent(.stopped, endedReason: .stoppedByAgent).group() == .stopped)
        #expect(agent(.stopped, endedReason: .processDied).group() == .needsAttention)
    }

    @Test func aRequestNeverMovesTheGroupAndAnArchivedOneShowsNoMark() {
        var finished = agent(.finished, report: .done, endedReason: .endTurn, unread: true)
        finished.archiveRequest = .requested(at: Date())
        finished.state = .waitingOnUser
        #expect(finished.group() == .needsAttention)
        finished.state = .archived
        #expect(finished.group() == .archived)
        #expect(!finished.asksToArchive)
    }

    @Test func everyStateAndOutcomeMapsToOneVisibleGroup() {
        for state in AgentState.allCases {
            for outcome in [nil] + WorkOutcome.allCases.map(Optional.some) {
                for unread in [false, true] {
                    let group = agent(state, report: outcome, unread: unread).group()
                    #expect(AgentGroup.live.contains(group) || group == .archived)
                }
            }
        }
    }
}
