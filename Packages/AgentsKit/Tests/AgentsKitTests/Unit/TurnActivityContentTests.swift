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

    /// The docs' Paused endings (#1869): a neutral word, and the reason once, not "Stopped" twice.
    @Test func aStopSomeoneChoseIsPausedNotAFailure() throws {
        for (reason, line) in [(EndedReason.cancelled, "Stopped by you"),
                               (.stoppedByAgent, "Stopped by the agent that started it"),
                               (.allowanceSpent, "Its allowance ran out")] {
            var stopped = agent(.stopped)
            stopped.endedReason = reason
            let content = try #require(TurnActivityContent.make(agent: stopped, needs: [], startedAt: sent))
            #expect(content.phase == .paused && content.isOver)
            #expect(content.word == "Paused" && content.line == line)
            #expect(content.endedAt != nil)
        }
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

    /// What the control plane pushes (#1744), as Go writes it: the phase and the times, no
    /// words. ActivityKit decodes it with a plain JSONDecoder.
    @Test func aPushedStateHasNoWordsAndKeepsTheTitleItStartedWith() throws {
        let json = #"{"phase":"approval","startedAt":800000000}"#
        let pushed = try JSONDecoder().decode(TurnActivityContent.self, from: Data(json.utf8))
        #expect(pushed.phase == .approval)
        #expect(pushed.startedAt == Date(timeIntervalSinceReferenceDate: 800_000_000))
        #expect(pushed.title == nil && pushed.line == nil && pushed.endedAt == nil)
        #expect(pushed.title(startedWith: "Fix the widget") == "Fix the widget")
        #expect(pushed.title(startedWith: nil) == TurnActivityContent.untitled)
        #expect(pushed.line(isStale: false) == "Open Agents to decide")

        let ended = try JSONDecoder().decode(TurnActivityContent.self,
                                             from: Data(#"{"phase":"done","startedAt":800000000,"endedAt":800000300}"#.utf8))
        #expect(ended.isOver && ended.endedAt == Date(timeIntervalSinceReferenceDate: 800_000_300))
        #expect(ended.line(isStale: true) == nil)
    }

    /// The app's own state keeps its title and its line; a stale one says to open the app.
    @Test func theAppsOwnStateSaysItsOwnWords() {
        let asking = TurnActivityContent(phase: .question, title: "Fix the widget", line: nil, startedAt: sent)
        #expect(asking.title(startedWith: "Old name") == "Fix the widget")
        #expect(asking.line(isStale: false) == nil)
        let working = TurnActivityContent(phase: .working, title: "t", line: "Write the view", startedAt: sent)
        #expect(working.line(isStale: false) == "Write the view")
        #expect(working.line(isStale: true) == "Open Agents to see where it is")
    }
}
