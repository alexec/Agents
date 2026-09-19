import Foundation
import Testing
@testable import AgentsKitCore

/// Whether a restarting daemon may bring a chat back by itself.
///
/// Exhausted rather than sampled, in the style of `AgentGroupTests`: the rule is three
/// conditions and one threshold, and every combination of them is cheap to state. The
/// value of writing it out is that a fourth condition added later has nowhere to hide.
@Suite("May a chat be picked back up")
struct AgentPickUpTests {
    private func agent(_ state: AgentState, _ reason: EndedReason?, _ pickUps: Int) -> Agent {
        Agent(runtimeID: "grok",
              cwd: URL(fileURLWithPath: "/tmp"),
              state: state,
              endedReason: reason,
              archivedReason: state == .archived ? .byUser : nil,
              restartPickUps: pickUps)
    }

    @Test func onlyAStoppedChatTheDaemonTookAndHasNotTakenBeforeComesBack() {
        let reasons: [EndedReason?] = [nil] + EndedReason.allCases.map { $0 }
        for state in AgentState.allCases {
            for reason in reasons {
                for pickUps in 0...2 {
                    let expected = state == .stopped && reason == .daemonGone && pickUps == 0
                    #expect(agent(state, reason, pickUps).mayBePickedUpAfterRestart == expected,
                            "\(state) / \(String(describing: reason)) / \(pickUps)")
                }
            }
        }
    }

    /// The threshold is one, because a chat is not picked back up a second time in a
    /// row. Spelled out on its own so moving it is a deliberate act.
    @Test func theThresholdIsOne() {
        #expect(agent(.stopped, .daemonGone, 0).mayBePickedUpAfterRestart)
        #expect(agent(.stopped, .daemonGone, 1).mayBePickedUpAfterRestart == false)
    }
}

/// A count that has to survive a record written before it existed, and a record
/// written by a version that knows more than this one.
@Suite("The restart count on the record")
struct AgentRestartPickUpsCodingTests {
    private func decode(_ json: String) throws -> Agent {
        try JSONDecoder().decode(Agent.self, from: Data(json.utf8))
    }

    private var withoutTheKey: String {
        """
        {"id":"\(UUID().uuidString)","runtimeID":"grok","cwd":"file:///tmp/",
         "state":"stopped","endedReason":"daemonGone","startOptions":{"values":{}},
         "advertisedOptions":[],"availableCommands":[],
         "createdAt":0,"lastActivityAt":0}
        """
    }

    @Test func aRecordWrittenBeforeTheCountExistedReadsAsNeverPickedUp() throws {
        let agent = try decode(withoutTheKey)
        #expect(agent.restartPickUps == 0)
        #expect(agent.mayBePickedUpAfterRestart, "which is what lets it come back at all")
    }

    @Test func andTheMissingKeyIsNotSweptIntoWhatWeDoNotKnow() throws {
        let agent = try decode(withoutTheKey)
        #expect(agent.unknownFields["restartPickUps"] == nil,
                "it is ours; a newer version's fields are the only thing kept aside")
    }

    @Test func aCountOfNothingIsNotWrittenBackOut() throws {
        let agent = try decode(withoutTheKey)
        let written = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(agent))
        #expect((written as? [String: Any])?["restartPickUps"] == nil,
                "records that have never been picked up do not grow a key saying so")
    }

    @Test func aCountThatIsSomethingSurvivesTheRoundTrip() throws {
        var agent = try decode(withoutTheKey)
        agent.restartPickUps = 1
        let again = try JSONDecoder().decode(Agent.self, from: try JSONEncoder().encode(agent))
        #expect(again.restartPickUps == 1)
    }
}
