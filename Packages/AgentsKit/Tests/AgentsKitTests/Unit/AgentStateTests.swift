import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

@Suite("Agent state")
struct AgentStateTests {
    @Test func aPromptFromAnySettledStatePicksTheAgentUp() {
        for state in [AgentState.stopped, .finished, .archived, .waitingOnUser] {
            #expect(state.applying(.promptSent) == .running, "from \(state)")
        }
    }

    @Test func aSecondPromptWhileATurnIsInFlightIsRefused() {
        #expect(AgentState.running.applying(.promptSent) == nil)
    }

    @Test func onlyEndTurnReachesFinished() {
        #expect(AgentState.running.applying(.turnEnded(.endTurn)) == .finished)
        for reason in EndedReason.allCases where reason != .endTurn {
            #expect(AgentState.running.applying(.turnEnded(reason)) == .stopped, "\(reason)")
        }
    }

    @Test func nothingReachesArchivedWithoutTheUser() {
        for state in AgentState.allCases {
            for event in [AgentEvent.promptSent, .permissionAsked, .permissionAnswered,
                          .turnEnded(.endTurn), .turnEnded(.refusal), .stoppedByUser,
                          .processDied, .foundDead] {
                #expect(state.applying(event) != .archived, "\(state) + \(event)")
            }
        }
    }

    @Test func aLiveAgentIsStoppedBeforeItIsArchived() {
        #expect(AgentState.running.applying(.archivedByUser) == nil)
        #expect(AgentState.waitingOnUser.applying(.archivedByUser) == nil)
        #expect(AgentState.stopped.applying(.archivedByUser) == .archived)
        #expect(AgentState.finished.applying(.archivedByUser) == .archived)
    }

    @Test func unarchivingRemembersHowTheAgentEnded() {
        #expect(AgentState.archived.applying(.unarchivedByUser, endedReason: .endTurn) == .finished)
        #expect(AgentState.archived.applying(.unarchivedByUser, endedReason: .refusal) == .stopped)
        #expect(AgentState.archived.applying(.unarchivedByUser, endedReason: nil) == .stopped)
        #expect(AgentState.stopped.applying(.unarchivedByUser) == nil)
    }

    @Test func permissionsOnlyHappenToARunningAgent() {
        #expect(AgentState.running.applying(.permissionAsked) == .waitingOnUser)
        #expect(AgentState.waitingOnUser.applying(.permissionAnswered) == .running)
        for state in AgentState.allCases where state != .running {
            #expect(state.applying(.permissionAsked) == nil, "\(state)")
        }
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
}
