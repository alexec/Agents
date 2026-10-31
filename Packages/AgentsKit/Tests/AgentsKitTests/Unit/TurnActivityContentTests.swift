import Foundation
import Testing
@testable import AgentsKitCore

/// What a turn's Live Activity says (#1657). The activity is drawn by the widget extension
/// on a phone, so these are the words it is handed.
@Suite("What a turn's Live Activity says")
struct TurnActivityContentTests {

    private let folder = URL(filePath: "/tmp/work/api")
    private let sent = Date(timeIntervalSince1970: 1_000_000)

    private func agent(_ state: AgentState, title: String? = "Fix the widget") -> Agent {
        Agent(runtimeID: "claude", cwd: folder, title: title, state: state,
              lastActivityAt: sent.addingTimeInterval(90))
    }

    private func need(for agent: Agent, kind: Need.Kind, h3: String = "which branch to use",
                      at: Date = Date()) -> Need {
        Need(id: .elicitation(UUID()), agentID: agent.id, folder: folder, kind: kind, raisedAt: at,
             headline: Headline(h1: "api", h2: "Fix the widget", h3: h3))
    }

    @Test func aWorkingTurnSaysTheStepItIsOn() throws {
        var working = agent(.running)
        working.plans = [Plan(entries: [PlanEntry(content: "Read the code", status: .completed),
                                        PlanEntry(content: "Write the view", status: .inProgress)])]
        let content = try #require(TurnActivityContent.make(agent: working, needs: [], startedAt: sent))
        #expect(content.phase == .working)
        #expect(content.line == "Write the view")
        #expect(content.startedAt == sent, "the timer counts from the send")
        #expect(content.endedAt == nil)
    }

    @Test func aQuestionAndAPermissionSayWhatTheyAsk() throws {
        let asking = agent(.waitingOnUser)
        let question = try #require(TurnActivityContent.make(
            agent: asking, needs: [need(for: asking, kind: .elicitation)], startedAt: sent))
        #expect(question.phase == .question)
        #expect(question.word == "Question waiting")
        #expect(question.line == "which branch to use")
        let approval = try #require(TurnActivityContent.make(
            agent: asking, needs: [need(for: asking, kind: .permission, h3: "run swift test")], startedAt: sent))
        #expect(approval.phase == .approval)
        #expect(approval.word == "Needs approval")
        #expect(approval.line == "run swift test")
    }

    @Test func anotherSessionsNeedIsNotThisOnes() throws {
        let working = agent(.running)
        let other = agent(.waitingOnUser)
        let content = try #require(TurnActivityContent.make(
            agent: working, needs: [need(for: other, kind: .permission)], startedAt: sent))
        #expect(content.phase == .working)
    }

    @Test func theNewestNeedWins() throws {
        let asking = agent(.waitingOnUser)
        let content = try #require(TurnActivityContent.make(
            agent: asking,
            needs: [need(for: asking, kind: .permission, at: sent),
                    need(for: asking, kind: .elicitation, h3: "newer", at: sent.addingTimeInterval(10))],
            startedAt: sent))
        #expect(content.phase == .question)
        #expect(content.line == "newer")
    }

    @Test func aCleanEndIsDoneWithItsReport() throws {
        var done = agent(.finished)
        done.endedReason = .endTurn
        done.report = WorkReport(outcome: .done, message: "Added the view.\nAnd its tests.", at: Date())
        let content = try #require(TurnActivityContent.make(agent: done, needs: [], startedAt: sent))
        #expect(content.phase == .done)
        #expect(content.isOver)
        #expect(content.line == "Added the view.", "one line")
        #expect(content.endedAt == sent.addingTimeInterval(90), "the timer stops where the turn ended")
    }

    /// A clean end that still wants the person is Needs you, as the sidebars say (#1861).
    private func endedNeedingYou(_ outcome: WorkOutcome?, block: Block? = nil) throws -> TurnActivityContent {
        var ended = agent(.finished)
        ended.endedReason = .endTurn
        ended.outcomeAsked = true
        ended.report = outcome.map { WorkReport(outcome: $0, message: "The rest is yours.", at: Date(), block: block) }
        let content = try #require(TurnActivityContent.make(agent: ended, needs: [], startedAt: sent))
        #expect(content.phase == .needsYou)
        #expect(content.word == "Needs you")
        #expect(content.isOver && !content.asks)
        #expect(content.endedAt == sent.addingTimeInterval(90))
        return content
    }

    @Test func aQuestionNeedsYou() throws {
        #expect(try endedNeedingYou(.needsAnswer).line == "Waiting on your answer: The rest is yours.")
    }


    @Test func outcomeUnknownNeedsYou() throws {
        #expect(try endedNeedingYou(nil).line == "Outcome unknown")
    }

    @Test func aQuestionInTheReportNeedsYou() throws {
        #expect(try endedNeedingYou(.needsAnswer).line == "Waiting on your answer: The rest is yours.")
    }

    @Test func aPushedNeedsYouSaysToOpenTheApp() throws {
        let json = #"{"phase":"needs_you","startedAt":800000000,"endedAt":800000300}"#
        let pushed = try JSONDecoder().decode(TurnActivityContent.self, from: Data(json.utf8))
        #expect(pushed.phase == .needsYou && pushed.isOver)
        #expect(pushed.line(isStale: false) == "Open Agents to see what it needs")
    }

    @Test func anEndForAReasonIsAFailureThatSaysIt() throws {
        var died = agent(.finished)
        died.endedReason = .processDied
        let content = try #require(TurnActivityContent.make(agent: died, needs: [], startedAt: sent))
        #expect(content.phase == .failed)
        #expect(content.line == "The runtime crashed")
        #expect(content.word == "Unexpected stop")
        let stopped = try #require(TurnActivityContent.make(agent: agent(.stopped), needs: [], startedAt: sent))
        #expect(stopped.phase == .failed)
        #expect(stopped.word == "Unexpected stop" && stopped.line == nil)
    }

    /// Stops someone chose use Paused: a neutral word, and the reason once, not "Stopped" twice.
    @Test func aStopSomeoneChoseIsPausedNotAFailure() throws {
        for (reason, line) in [(EndedReason.cancelled, "Stopped by you"),
                               (.stoppedByAgent, "Stopped by the agent that started it")] {
            var stopped = agent(.stopped)
            stopped.endedReason = reason
            let content = try #require(TurnActivityContent.make(agent: stopped, needs: [], startedAt: sent))
            #expect(content.phase == .paused && content.isOver)
            #expect(content.word == "Paused" && content.line == line)
            #expect(content.endedAt != nil)
        }
        var exhausted = agent(.stopped)
        exhausted.endedReason = .allowanceSpent
        let failed = try #require(TurnActivityContent.make(agent: exhausted, needs: [], startedAt: sent))
        #expect(failed.phase == .failed && failed.isOver)
        #expect(failed.word == "Unexpected stop" && failed.line == "Its allowance ran out")
        let json = #"{"phase":"paused","startedAt":800000000,"endedAt":800000300}"#
        let pushed = try JSONDecoder().decode(TurnActivityContent.self, from: Data(json.utf8))
        #expect(pushed.phase == .paused && pushed.line(isStale: false) == nil)
    }

    @Test func anArchivedOrMissingSessionEndsTheActivity() {
        #expect(TurnActivityContent.make(agent: agent(.archived), needs: [], startedAt: sent) == nil)
        #expect(TurnActivityContent.make(agent: nil, needs: [Need](), startedAt: sent) == nil)
    }

    @Test func anUntitledSessionHasAName() throws {
        let content = try #require(TurnActivityContent.make(agent: agent(.running, title: nil), needs: [], startedAt: sent))
        #expect(content.title == TurnActivityContent.untitled)
        #expect(TurnActivityContent.sent(title: nil, at: sent).phase == .working)
    }

    @Test func aLongLineIsCut() {
        let long = String(repeating: "a", count: 1000)
        let content = TurnActivityContent(phase: .done, title: "t", line: long, startedAt: sent)
        #expect(content.line?.count == TurnActivityContent.lineLimit)
        #expect(content.line?.hasSuffix("…") == true)
        #expect(TurnActivityContent(phase: .done, title: "t", line: "  \n", startedAt: sent).line == nil)
    }

    @Test func theStateStaysSmall() throws {
        let content = TurnActivityContent(phase: .working, title: String(repeating: "t", count: 200),
                                          line: String(repeating: "a", count: 4000), startedAt: sent)
        #expect(try JSONEncoder().encode(content).count < 1024, "ActivityKit refuses 4 KB")
    }

    /// What the control plane pushes (#1744, #2991), as Go writes it: the phase, the
    /// session, the counts and the times, no words. ActivityKit decodes it with a plain
    /// JSONDecoder.
    @Test func aPushedStateHasNoWordsAndSaysHowManySessions() throws {
        let json = #"{"phase":"approval","agentID":"A0000000-0000-4000-8000-000000000001","startedAt":800000000,"othersWorking":2}"#
        let pushed = try JSONDecoder().decode(TurnActivityContent.self, from: Data(json.utf8))
        #expect(pushed.phase == .approval)
        #expect(pushed.agentID == UUID(uuidString: "A0000000-0000-4000-8000-000000000001"))
        #expect(pushed.startedAt == Date(timeIntervalSinceReferenceDate: 800_000_000))
        #expect(pushed.title == nil && pushed.place == nil && pushed.line == nil && pushed.endedAt == nil)
        #expect(pushed.shownTitle == "3 sessions")
        #expect(pushed.others == "+2 working")
        #expect(pushed.line(isStale: false) == "Open Agents to decide")

        let before = try JSONDecoder().decode(TurnActivityContent.self,
                                              from: Data(#"{"phase":"working","startedAt":800000000}"#.utf8))
        #expect(before.agentID == nil && before.sessions == 1 && before.others == nil, "a push from before #2991")
        #expect(before.shownTitle == "Your session")

        let ended = try JSONDecoder().decode(TurnActivityContent.self,
                                             from: Data(#"{"phase":"done","startedAt":800000000,"endedAt":800000300}"#.utf8))
        #expect(ended.isOver && ended.endedAt == Date(timeIntervalSinceReferenceDate: 800_000_300))
        #expect(ended.line(isStale: true) == nil)
    }

    /// The app's own state keeps its title and its line; a stale one says to open the app.
    @Test func theAppsOwnStateSaysItsOwnWords() {
        let asking = TurnActivityContent(phase: .question, title: "Fix the widget", line: nil, startedAt: sent,
                                         othersWorking: 4)
        #expect(asking.shownTitle == "Fix the widget")
        #expect(asking.line(isStale: false) == nil)
        let working = TurnActivityContent(phase: .working, title: "t", line: "Write the view", startedAt: sent)
        #expect(working.line(isStale: false) == "Write the view")
        #expect(working.line(isStale: true) == "Open Agents to see where it is")
    }

    // MARK: One activity in total (#2991)

    private func turn(_ phase: TurnActivityContent.Phase, _ title: String, startedAt offset: TimeInterval,
                      endedAt end: TimeInterval? = nil) -> TurnActivityContent {
        TurnActivityContent(phase: phase, agentID: UUID(), title: title, place: "Claude · api", line: nil,
                            startedAt: sent.addingTimeInterval(offset), endedAt: end.map { sent.addingTimeInterval($0) })
    }

    @Test func theSummaryShowsTheSessionThatAsksWithACountOfTheRest() throws {
        let summary = try #require(TurnActivityContent.summary(of: [
            turn(.working, "Oldest", startedAt: 0),
            turn(.approval, "Asks", startedAt: 10),
            turn(.working, "Newest", startedAt: 20),
            turn(.question, "Asks too", startedAt: 5),
            turn(.done, "Over", startedAt: -50, endedAt: 30),
        ]))
        #expect(summary.title == "Asks", "one that asks wins, the newest of them")
        #expect(summary.phase == .approval && summary.place == "Claude · api")
        #expect(summary.startedAt == sent, "the timer counts from the oldest turn still running")
        #expect(summary.othersAsking == 1 && summary.othersWorking == 2, "an ended turn is not counted")
        #expect(summary.others == "+1 needs you · +2 working")
        #expect(summary.sessions == 4)
    }

    @Test func withNoneAskingTheNewestWorkingOneIsShown() throws {
        let summary = try #require(TurnActivityContent.summary(of: [
            turn(.working, "Old", startedAt: 0), turn(.working, "New", startedAt: 20)]))
        #expect(summary.title == "New" && summary.startedAt == sent && summary.others == "+1 working")
    }

    @Test func onceEveryTurnHasEndedTheLastToEndIsShown() throws {
        let summary = try #require(TurnActivityContent.summary(of: [
            turn(.done, "First", startedAt: 0, endedAt: 50), turn(.failed, "Last", startedAt: 10, endedAt: 60)]))
        #expect(summary.title == "Last" && summary.isOver && summary.others == nil)
        #expect(TurnActivityContent.summary(of: [TurnActivityContent]()) == nil)
    }

    @Test func oneTurnIsItsOwnSummary() throws {
        let one = turn(.working, "Only", startedAt: 0)
        #expect(TurnActivityContent.summary(of: [one]) == one)
    }

    @Test func aSessionIsNamedWithItsPlace() throws {
        let working = agent(.running)
        let content = try #require(TurnActivityContent.make(agent: working, needs: [], startedAt: sent,
                                                            place: "Claude · api"))
        #expect(content.agentID == working.id && content.place == "Claude · api")
    }
}
