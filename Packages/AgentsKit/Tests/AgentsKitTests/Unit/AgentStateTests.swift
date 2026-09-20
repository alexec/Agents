import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

@Suite("Agent state")
struct AgentStateTests {
    @Test func aPromptFromAnySettledStatePicksTheAgentUp() {
        for state in [AgentState.stopped, .finished, .archived, .waitingOnUser] {
            #expect(state.applying(.promptSent)?.next == .running, "from \(state)")
        }
    }

    @Test func aSecondPromptWhileATurnIsInFlightIsRefused() {
        #expect(AgentState.running.applying(.promptSent) == nil)
    }

    @Test func onlyEndTurnReachesFinished() {
        #expect(AgentState.running.applying(.turnEnded(.endTurn))?.next == .finished)
        for reason in EndedReason.allCases where reason != .endTurn {
            #expect(AgentState.running.applying(.turnEnded(reason))?.next == .stopped, "\(reason)")
        }
    }

    @Test func nothingReachesArchivedWithoutTheUser() {
        for state in AgentState.allCases {
            for event in [AgentEvent.promptSent, .permissionAsked, .permissionAnswered,
                          .turnEnded(.endTurn), .turnEnded(.refusal), .stoppedByUser,
                          .processDied, .foundDead] {
                #expect(state.applying(event)?.next != .archived, "\(state) + \(event)")
            }
        }
    }

    @Test func aLiveAgentIsStoppedBeforeItIsArchived() {
        #expect(AgentState.running.applying(.archivedByUser) == nil)
        #expect(AgentState.waitingOnUser.applying(.archivedByUser) == nil)
        #expect(AgentState.stopped.applying(.archivedByUser)?.next == .archived)
        #expect(AgentState.finished.applying(.archivedByUser)?.next == .archived)
    }

    @Test func unarchivingRemembersHowTheAgentEnded() {
        #expect(AgentState.archived.applying(.unarchivedByUser, endedReason: .endTurn)?.next == .finished)
        #expect(AgentState.archived.applying(.unarchivedByUser, endedReason: .refusal)?.next == .stopped)
        #expect(AgentState.archived.applying(.unarchivedByUser, endedReason: nil)?.next == .stopped)
        #expect(AgentState.stopped.applying(.unarchivedByUser) == nil)
    }

    /// The case that cannot happen yet and will.
    ///
    /// The only ways into `archived` are from `finished` and `stopped`, and both carry
    /// a reason — so an archived agent with none is unreachable until somebody edits a
    /// record by hand or another build writes one. Unarchiving it to `stopped` with no
    /// reason would break the record's second invariant, so the table gives it the one
    /// word that is true: nothing vouched for that ending.
    @Test func unarchivingAnAgentWithNoRecordedEndingGivesItOne() {
        let transition = AgentState.archived.applying(.unarchivedByUser, endedReason: nil)
        #expect(transition?.next == .stopped)
        #expect(transition?.endedReason == .set(.unrecognised))
    }

    @Test func permissionsOnlyHappenToARunningAgent() {
        #expect(AgentState.running.applying(.permissionAsked)?.next == .waitingOnUser)
        #expect(AgentState.waitingOnUser.applying(.permissionAnswered)?.next == .running)
        for state in AgentState.allCases where state != .running {
            #expect(state.applying(.permissionAsked) == nil, "\(state)")
        }
    }

    /// The four pairs a caller used to be able to contradict.
    ///
    /// `move` took an `endedReason:` alongside the event, so nothing stopped
    /// `.stoppedByUser` being handed `.maxTokens` — two things that had to agree, and
    /// nothing anywhere checked that they did. The reason now comes from the event, so
    /// there is nothing left to disagree with (FR-011).
    @Test func theReasonComesFromTheEventAndNotTheCaller() {
        #expect(AgentState.running.applying(.stoppedByUser)?.endedReason == .set(.cancelled))
        #expect(AgentState.running.applying(.processDied)?.endedReason == .set(.processDied))
        #expect(AgentState.running.applying(.foundDead)?.endedReason == .set(.daemonGone))
        for reason in EndedReason.allCases {
            #expect(AgentState.running.applying(.turnEnded(reason))?.endedReason == .set(reason),
                    "\(reason)")
        }
    }

    /// FR-015, exhausted rather than asserted in one case.
    ///
    /// This was an inline `if` in `DaemonCore.move`, defended by a comment saying
    /// `recover` wrote the state directly so it could never clear the count on its way
    /// past. Once `recover` goes through the funnel that defence is gone, so the rule
    /// has to hold on its own — and here it is cheap to exhaust.
    @Test func theDaemonGoingNeverClearsThePickUpCount() {
        var decided = 0
        for state in AgentState.allCases {
            for event in Self.everyEvent {
                guard let transition = state.applying(event, endedReason: .endTurn) else { continue }
                decided += 1
                let settled = transition.next == .finished || transition.next == .stopped
                let endsWithTheDaemonGoing = transition.endedReason == .set(.daemonGone)
                #expect(transition.clearsPickUpCount == (settled && !endsWithTheDaemonGoing),
                        "\(state) + \(event)")
            }
        }
        #expect(decided > 0, "the loop found no legal pairs at all, so it proved nothing")
    }

    @Test func anEndingDiscoveredOnRestartKeepsTheCount() {
        for state in [AgentState.running, .waitingOnUser] {
            let transition = state.applying(.foundDead)
            #expect(transition?.next == .stopped, "\(state)")
            #expect(transition?.endedReason == .set(.daemonGone), "\(state)")
            #expect(transition?.clearsPickUpCount == false, "\(state)")
        }
    }

    /// A refusal is not a quiet no-op waiting to be noticed: it is the whole of what
    /// stops a second ending overwriting the first when a turn ends while the person is
    /// stopping the agent.
    @Test func aSecondEndingIsRefusedRatherThanApplied() {
        #expect(AgentState.finished.applying(.stoppedByUser) == nil)
        #expect(AgentState.stopped.applying(.turnEnded(.endTurn)) == nil)
        #expect(AgentState.finished.applying(.processDied) == nil)
        #expect(AgentState.stopped.applying(.foundDead) == nil)
    }

    /// The pick-up suppression is about one event, and must not leak to another.
    ///
    /// An agent stopped by `daemonGone` and then archived comes back out of the
    /// archive as `stopped`/`daemonGone` with no pick-ups — so it answers true to
    /// `mayBePickedUpAfterRestart` even though nothing is about to pick it up.
    /// Suppressing its `agentStopped` trigger on the strength of that record alone
    /// would silently change what unarchiving does, which is why `move` gates on the
    /// event as well.
    @Test func anUnarchivedAgentLooksPickUpAbleAndIsNot() {
        var agent = Agent(runtimeID: "grok", cwd: URL(filePath: "/tmp"),
                          state: .archived, endedReason: .daemonGone,
                          archivedReason: .byUser)
        let transition = try? #require(agent.state.applying(.unarchivedByUser,
                                                            endedReason: agent.endedReason))
        #expect(transition?.next == .stopped)
        agent.state = transition!.next
        // The record alone cannot tell the two apart — which is the point.
        #expect(agent.mayBePickedUpAfterRestart)
    }

    @Test func onlyRunningAndWaitingHoldARuntime() {
        // A finished agent's process is let go, because the session comes back.
        #expect(AgentState.running.holdsRuntime)
        #expect(AgentState.waitingOnUser.holdsRuntime)
        #expect(!AgentState.finished.holdsRuntime)
        #expect(!AgentState.stopped.holdsRuntime)
        #expect(!AgentState.archived.holdsRuntime)
    }

    @Test func stopReasonsComeFromTheProtocolSpelling() {
        #expect(EndedReason(stopReason: "end_turn") == .endTurn)
        #expect(EndedReason(stopReason: "max_tokens") == .maxTokens)
        #expect(EndedReason(stopReason: "max_turn_requests") == .maxTurnRequests)
        #expect(EndedReason(stopReason: "refusal") == .refusal)
        #expect(EndedReason(stopReason: "cancelled") == .cancelled)
        #expect(EndedReason(stopReason: "something new") == nil)
    }

    /// Every event, for the loops that have to be total over them. `turnEnded` appears
    /// more than once because its branches are different answers, not one.
    static let everyEvent: [AgentEvent] = [
        .promptSent, .turnBegun, .permissionAsked, .permissionAnswered,
        .turnEnded(.endTurn), .turnEnded(.refusal), .turnEnded(.daemonGone),
        .stoppedByUser, .processDied, .foundDead,
        .archivedByUser, .unarchivedByUser,
    ]

    /// The ten events, once each, in the order [contracts/transitions.md](
    /// ../../../../specs/020-agent-lifecycle/contracts/transitions.md) lists them.
    /// `turnEnded` stands for its `endTurn` branch here; the other branch is exhausted
    /// by `onlyEndTurnReachesFinished`.
    static let tenEvents: [AgentEvent] = [
        .promptSent, .turnBegun, .permissionAsked, .permissionAnswered,
        .turnEnded(.endTurn), .stoppedByUser, .processDied, .foundDead,
        .archivedByUser, .unarchivedByUser,
    ]

    /// SC-003: all sixty pairs, each with exactly one answer.
    ///
    /// Written as a literal transcribed from the contract rather than as a rule,
    /// because a rule would be the implementation stated twice and would agree with a
    /// wrong table as readily as a right one. Six states by ten events; a pair missing
    /// from the literal fails just as loudly as a pair that disagrees, so a state added
    /// later cannot slip through undecided.
    @Test func everyPairingOfStateAndEventHasExactlyOneAnswer() {
        // nil means the event must not happen in that state and the agent is untouched.
        let table: [AgentState: [AgentState?]] = [
            //                promptSent turnBegun permAsked permAnswered turnEnded(endTurn) stopped processDied foundDead archived unarchived
            .starting:      [ nil,       .running, nil,      nil,         nil,               .stopped, .stopped, .stopped, nil,     nil      ],
            .running:       [ nil,       nil,      .waitingOnUser, nil,   .finished,         .stopped, .stopped, .stopped, nil,     nil      ],
            .waitingOnUser: [ .running,  nil,      nil,      .running,    .finished,         .stopped, .stopped, .stopped, nil,     nil      ],
            .finished:      [ .running,  nil,      nil,      nil,         nil,               nil,      nil,      nil,      .archived, nil    ],
            .stopped:       [ .running,  nil,      nil,      nil,         nil,               nil,      nil,      nil,      .archived, nil    ],
            .archived:      [ .running,  nil,      nil,      nil,         nil,               nil,      nil,      nil,      nil,     .finished],
        ]

        #expect(table.count == AgentState.allCases.count,
                "a state exists that the table says nothing about")
        var pairs = 0
        for state in AgentState.allCases {
            guard let expected = table[state] else {
                Issue.record("no row for \(state)")
                continue
            }
            #expect(expected.count == Self.tenEvents.count, "row for \(state) is the wrong length")
            for (event, want) in zip(Self.tenEvents, expected) {
                pairs += 1
                // `.endTurn` so the archived row's `unarchivedByUser` lands on
                // `finished`, which is what the contract's own table shows.
                #expect(state.applying(event, endedReason: .endTurn)?.next == want,
                        "\(state) + \(event)")
            }
        }
        #expect(pairs == 60, "sixty pairs, and the loop saw \(pairs)")
    }

    /// `waitingOnUser` accepting a prompt is not a typo in the table above.
    ///
    /// Only `running` refuses one, because only `running` has a turn nothing is
    /// blocking. A permission question holds the turn open but the person answering it
    /// by typing something else is them moving the work on.
    @Test func onlyARunningAgentRefusesAPrompt() {
        #expect(AgentState.running.applying(.promptSent) == nil)
        #expect(AgentState.starting.applying(.promptSent) == nil)
        for state in [AgentState.waitingOnUser, .finished, .stopped, .archived] {
            #expect(state.applying(.promptSent)?.next == .running, "\(state)")
        }
    }

    // MARK: A new agent

    @Test func aStartingAgentHoldsARuntimeAndOwnsItsTurn() {
        // Both load-bearing. The first keeps `runUntilIdle` from exiting out from
        // under an agent being born; the second is the whole of FR-004.
        #expect(AgentState.starting.holdsRuntime)
        #expect(AgentState.starting.hasTurnInFlight)
    }

    /// FR-004, in the table rather than only in the daemon.
    ///
    /// `enqueue` and `sendNextQueued` both gate on `hasTurnInFlight`, so a prompt
    /// arriving mid-start already queues. This is the same rule written where somebody
    /// reading the lifecycle can find it.
    @Test func aPromptArrivingDuringAStartJoinsTheQueue() {
        #expect(AgentState.starting.applying(.promptSent) == nil)
    }

    @Test func theOnlyWaysOutOfStartingAreATurnOrAnEnding() {
        #expect(AgentState.starting.applying(.turnBegun)?.next == .running)
        #expect(AgentState.starting.applying(.stoppedByUser)?.endedReason == .set(.cancelled))
        #expect(AgentState.starting.applying(.processDied)?.endedReason == .set(.processDied))
        #expect(AgentState.starting.applying(.foundDead)?.endedReason == .set(.daemonGone))
    }

    /// A turn only ever begins out of a start.
    @Test func aTurnBeginningFromAnywhereElseIsRefused() {
        for state in AgentState.allCases where state != .starting {
            #expect(state.applying(.turnBegun) == nil, "\(state)")
        }
    }

    /// Archiving something that has not begun is refused for the reason archiving
    /// something that is working is: stop it first.
    @Test func somethingStartingIsStoppedBeforeItIsArchived() {
        #expect(AgentState.starting.applying(.archivedByUser) == nil)
    }

    /// FR-002, as a property of the initialiser rather than of any call site.
    @Test func aNewAgentIsBornStartingAndCarriesNoEnding() {
        let agent = Agent(runtimeID: "grok", cwd: URL(filePath: "/tmp"))
        #expect(agent.state == .starting)
        #expect(agent.endedReason == nil)
        #expect(agent.archivedReason == nil)
        #expect(agent.isConsistent)
        #expect(agent.group == .running, "and never once under Stopped")
    }

    /// The fourth invariant. It is what makes `starting` worth having: the old code
    /// wrote `stopped`/`endTurn` because rule 2 demanded some reason, and now nothing
    /// does.
    @Test func aStartingAgentCarryingAnEndingIsNotAConsistentRecord() {
        var agent = Agent(runtimeID: "grok", cwd: URL(filePath: "/tmp"))
        agent.endedReason = .endTurn
        #expect(!agent.isConsistent)

        var archived = Agent(runtimeID: "grok", cwd: URL(filePath: "/tmp"))
        archived.archivedReason = .byUser
        #expect(!archived.isConsistent)
    }
}
