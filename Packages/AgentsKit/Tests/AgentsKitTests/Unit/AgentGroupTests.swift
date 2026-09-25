import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// The one property that stops an agent disappearing: every combination of the facts
/// the grouping consults lands in exactly one group. A fact added later and not thought
/// about fails to compile here rather than quietly becoming an agent nobody can see.
///
/// Every call spells out all four facts, because the initialiser has no defaults — the
/// default was the bug 019 removed. The helper below is this file's shorthand only.
@Suite("Agent grouping")
struct AgentGroupTests {
    private static func group(_ state: AgentState, eyes: Bool = false,
                              _ outcome: WorkOutcome? = nil, asked: Bool = false,
                              parked: Bool = false) -> AgentGroup {
        AgentGroup(for: state, wantsEyes: eyes, report: outcome.map(report), outcomeAsked: asked,
                   parked: parked)
    }

    private static func report(_ outcome: WorkOutcome) -> WorkReport {
        WorkReport(outcome: outcome, message: "words", at: Date())
    }

    private static let reports: [WorkOutcome?] = [nil] + WorkOutcome.allCases

    @Test("each state maps to the group the spec names")
    func mappingIsTheSpecs() {
        // Under Working, so a new agent never appears among the settled ones — and no
        // heading is added, renamed or removed for it (020 FR-006, FR-023).
        #expect(Self.group(.starting) == .running)
        #expect(Self.group(.waitingOnUser) == .needsAttention)
        #expect(Self.group(.running) == .running)
        #expect(Self.group(.finished) == .finished)
        #expect(Self.group(.stopped) == .stopped)
        #expect(Self.group(.archived) == .archived)
    }

    @Test("every group is reachable from some state")
    func everyGroupReachable() {
        let reached = Set(AgentState.allCases.flatMap { [Self.group($0), Self.group($0, parked: true)] })
        #expect(reached == Set(AgentGroup.allCases))
        #expect(AgentGroup.allCases.count == 6)
        #expect(AgentState.allCases.count == 6)
    }

    @Test("the live groups are in the order the panel draws them")
    func liveOrder() {
        #expect(AgentGroup.live == [.needsAttention, .running, .finished, .stopped, .parked])
        #expect(!AgentGroup.live.contains(.archived))
    }

    /// FR-022 of 019 and FR-023 of 020, stated as a test so it cannot be lost quietly.
    /// 040 added one heading, last, and renamed and removed none.
    @Test func noHeadingWasRenamedOrRemoved() {
        #expect(AgentGroup.live.map(\.title) == ["Needs attention", "Working", "Complete", "Stopped", "Parked"])
        #expect(AgentGroup.archived.title == "Archived")
    }

    /// SC-006 of 019. Every combination of the four facts the grouping consults lands
    /// in exactly one group. A fact added to the initialiser without a loop added here
    /// fails to compile, which is the point (FR-002, FR-019).
    @Test func everyCombinationOfTheFourFactsIsExactlyOneGroup() {
        var seen = 0
        for state in AgentState.allCases {
            for eyes in [false, true] {
                for outcome in Self.reports {
                    for asked in [false, true] {
                        for parked in [false, true] {
                            let group = Self.group(state, eyes: eyes, outcome, asked: asked, parked: parked)
                            #expect(AgentGroup.allCases.contains(group))
                            seen += 1
                        }
                    }
                }
            }
        }
        #expect(seen == 6 * 2 * (1 + WorkOutcome.allCases.count) * 2 * 2)
    }

    /// An agent whose conversation has not begun has not asked anybody to look at
    /// anything, so it does not take `running`'s `wantsEyes` arm.
    @Test func aStartingAgentIsWorkingWhateverElseIsTrueOfIt() {
        for eyes in [true, false] {
            for outcome in Self.reports {
                for asked in [false, true] {
                    #expect(Self.group(.starting, eyes: eyes, outcome, asked: asked) == .running)
                }
            }
        }
    }

    /// A working agent that has asked for a file goes where the person will see it.
    @Test func aWorkingAgentThatAskedToBeLookedAtNeedsAttention() {
        #expect(Self.group(.running, eyes: true) == .needsAttention)
        #expect(Self.group(.finished, eyes: true) == .needsAttention)
    }

    /// An agent that is not going anywhere is not waiting on you.
    @Test func aSettledAgentIsNotDraggedIntoNeedsAttention() {
        #expect(Self.group(.stopped, eyes: true) == .stopped)
        #expect(Self.group(.archived, eyes: true) == .archived)
    }

    // MARK: And what the agent said about the work

    /// The one rule 014 added: an agent that said it cannot get further without a
    /// person is where the person actually looks.
    @Test func aFinishedAgentThatNeedsAPersonIsInNeedsAttention() {
        for outcome in WorkOutcome.allCases where outcome.needsAPerson {
            #expect(Self.group(.finished, outcome) == .needsAttention)
        }
        for outcome in WorkOutcome.allCases where !outcome.needsAPerson {
            #expect(Self.group(.finished, outcome) == .finished)
        }
    }

    /// How a turn *ended* outranks what the agent said about the work. An agent
    /// somebody stopped, or put away, is not waiting on them whatever it last claimed.
    @Test func aStoppedOrArchivedAgentIsUnmovedByAnyReport() {
        for outcome in WorkOutcome.allCases {
            #expect(Self.group(.stopped, outcome) == .stopped)
            #expect(Self.group(.archived, outcome) == .archived)
        }
    }

    /// A report is about a turn that is over, so it says nothing about one in flight.
    @Test func aRunningAgentIsGroupedByWhatItIsDoing() {
        for outcome in WorkOutcome.allCases {
            #expect(Self.group(.running, outcome) == .running)
            #expect(Self.group(.waitingOnUser, outcome) == .needsAttention)
        }
    }

    // MARK: And whether the app is the one asking

    /// US3 of 019. An agent running the app's own question is grouped exactly as the
    /// finished agent it was a moment ago — same eyes, same report — and not Working.
    @Test func anAgentAnsweringTheAppStaysWhereItWas() {
        for eyes in [false, true] {
            for outcome in Self.reports {
                #expect(Self.group(.running, eyes: eyes, outcome, asked: true)
                        == Self.group(.finished, eyes: eyes, outcome, asked: true))
            }
        }
    }

    /// A person's prompt clears the flag, and the same agent is then Working — or
    /// Needs attention on the strength of eyes alone, as any working agent is.
    @Test func aPersonsPromptMakesItWorkAgain() {
        for outcome in Self.reports {
            #expect(Self.group(.running, outcome, asked: false) == .running)
            #expect(Self.group(.running, eyes: true, outcome, asked: false) == .needsAttention)
        }
    }

    /// The flag says nothing about any other state: an agent that never answered ends
    /// `finished` with it still up and is grouped as finished; a stopped one is stopped.
    @Test func theFlagMovesNothingButARunningAgent() {
        for state in AgentState.allCases where state != .running {
            for eyes in [false, true] {
                for outcome in Self.reports {
                    #expect(Self.group(state, eyes: eyes, outcome, asked: true)
                            == Self.group(state, eyes: eyes, outcome, asked: false))
                }
            }
        }
    }

    // MARK: And whether the person parked it (040)

    /// Parked outranks every ending and every arm: the person has seen it and chosen
    /// later, including a report that wants them and a workflow's turn that wakes it.
    @Test func aParkedChatIsParkedWhateverItsEndingOrReport() {
        for state in [AgentState.starting, .running, .finished, .stopped] {
            for eyes in [false, true] {
                for outcome in Self.reports {
                    for asked in [false, true] {
                        #expect(Self.group(state, eyes: eyes, outcome, asked: asked, parked: true) == .parked)
                    }
                }
            }
        }
    }

    /// A question asked mid-turn blocks the agent on the person, and archiving is a
    /// firmer word than parking. Both outrank it.
    @Test func aQuestionAndArchivingOutrankParking() {
        #expect(Self.group(.waitingOnUser, parked: true) == .needsAttention)
        #expect(Self.group(.archived, parked: true) == .archived)
    }

    /// Only the parked mark moves a chat. One marked to park when its turn ends is
    /// grouped as it would be without the mark until the turn does end.
    @Test func aChatMarkedToParkIsNotParkedYet() {
        let dir = URL(fileURLWithPath: "/tmp/work")
        var agent = Agent(runtimeID: "claude", cwd: dir, state: .running)
        agent.parking = .whenTurnEnds(since: Date())
        #expect(agent.group(wantsEyes: false) == .running)
        agent.parking = .parked(at: Date())
        #expect(agent.group(wantsEyes: false) == .parked)
    }

    /// The one place that says which button a chat shows (FR-012).
    @Test func theParkActionIsDecidedOnce() {
        let dir = URL(fileURLWithPath: "/tmp/work")
        var agent = Agent(runtimeID: "claude", cwd: dir, state: .finished, endedReason: .endTurn)
        #expect(agent.parkAction == .park)
        agent.state = .running
        #expect(agent.parkAction == .park)
        agent.parking = .whenTurnEnds(since: Date())
        #expect(agent.parkAction == .unpark)
        agent.state = .finished
        agent.parking = .parked(at: Date())
        #expect(agent.parkAction == .unpark)
        agent.parking = nil
        agent.state = .archived
        #expect(agent.parkAction == nil)
    }
}
