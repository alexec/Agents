import Foundation
import Testing
@testable import AgentsKit

/// What a card says an agent is doing.
///
/// A title is what it was asked an hour ago. This is the line that answers the question
/// somebody actually opened the window to ask, so it has to be the agent's own words or
/// nothing at all.
@Suite("What an agent is working on")
struct AgentActivityTests {
    private func agent(plans: [Plan], state: AgentState = .running) -> Agent {
        Agent(runtimeID: "claude", cwd: URL(filePath: "/work/api"), title: "Fix the parser",
              state: state, endedReason: .endTurn, plans: plans)
    }

    private func plan(_ entries: [(String, PlanEntry.Status)],
                      state: Plan.State = .current) -> Plan {
        Plan(entries: entries.map { PlanEntry(content: $0.0, status: $0.1) }, state: state)
    }

    @Test func theStepInProgressIsWhatItIsWorkingOn() {
        let one = agent(plans: [plan([("Read the tests", .completed),
                                      ("Rewrite the lexer", .inProgress),
                                      ("Run the suite", .pending)])])
        #expect(one.currentStep == "Rewrite the lexer")
    }

    @Test func noPlanMeansNothingToSay() {
        #expect(agent(plans: []).currentStep == nil)
    }

    @Test func aPlanWithNothingInProgressSaysNothing() {
        // Between steps it is not working on any of them, and picking one would be
        // inventing something the agent did not say.
        let between = agent(plans: [plan([("One", .completed), ("Two", .pending)])])
        #expect(between.currentStep == nil)
    }

    @Test func aWithdrawnPlanIsNotTheCurrentOne() {
        let withdrawn = agent(plans: [plan([("Abandoned", .inProgress)], state: .withdrawn)])
        #expect(withdrawn.currentStep == nil)
        #expect(withdrawn.currentPlan == nil)
    }

    @Test func theNewestCurrentPlanWins() {
        let older = plan([("Old idea", .inProgress)])
        let newer = plan([("New idea", .inProgress)])
        #expect(agent(plans: [older, newer]).currentStep == "New idea")
    }

    @Test func aStepOfNothingButSpacesSaysNothing() {
        #expect(agent(plans: [plan([("   ", .inProgress)])]).currentStep == nil)
    }

    @Test func progressCountsWhatIsDone() {
        let working = agent(plans: [plan([("One", .completed), ("Two", .completed),
                                          ("Three", .inProgress), ("Four", .pending)])])
        let progress = try? #require(working.planProgress)
        #expect(progress?.done == 2)
        #expect(progress?.total == 4)
    }

    @Test func anEmptyPlanHasNoProgress() {
        #expect(agent(plans: [plan([])]).planProgress == nil)
    }
}
