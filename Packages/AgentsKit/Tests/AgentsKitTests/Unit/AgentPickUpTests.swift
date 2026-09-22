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

    @Test func onlyAStoppedChatTheDaemonTookComesBack() {
        let reasons: [EndedReason?] = [nil] + EndedReason.allCases.map { $0 }
        for state in AgentState.allCases {
            for reason in reasons {
                for pickUps in 0...2 {
                    let expected = state == .stopped && reason == .daemonGone
                    #expect(agent(state, reason, pickUps).mayBePickedUpAfterRestart == expected,
                            "\(state) / \(String(describing: reason)) / \(pickUps)")
                }
            }
        }
    }

    /// There is no threshold: a chat is picked back up however many restarts it has
    /// been through. Spelled out on its own so putting one back is a deliberate act.
    @Test func thereIsNoThreshold() {
        #expect(agent(.stopped, .daemonGone, 0).mayBePickedUpAfterRestart)
        #expect(agent(.stopped, .daemonGone, 1).mayBePickedUpAfterRestart)
        #expect(agent(.stopped, .daemonGone, 5).mayBePickedUpAfterRestart)
    }


    // MARK: The count the ending must not clear (020)

    /// FR-015, from every state the ending can be reached from.
    ///
    /// The count is the only evidence that a chat can reach the end of a turn without
    /// taking the daemon with it, so an ending that *is* the daemon going says nothing
    /// about it and must leave it alone. This used to be an inline `if` in
    /// `DaemonCore.move`, held up by a comment saying `recover` wrote the reason
    /// directly and so could never clear the count on its way past — a defence that
    /// disappeared the moment recovery started going through the funnel.
    @Test func anEndingDiscoveredOnRestartDoesNotClearThePickUpCount() {
        for state in AgentState.allCases where state.holdsRuntime {
            let transition = state.applying(.foundDead)
            #expect(transition?.next == .stopped, "\(state)")
            #expect(transition?.endedReason == .set(.daemonGone), "\(state)")
            #expect(transition?.clearsPickUpCount == false,
                    "\(state) cleared the count on the one ending that must not")
        }
    }

    /// And the contrast, so the test above cannot pass by the rule being "never clear".
    @Test func anEndingOfAnyOtherKindDoesClearIt() {
        #expect(AgentState.running.applying(.stoppedByUser)?.clearsPickUpCount == true)
        #expect(AgentState.running.applying(.processDied)?.clearsPickUpCount == true)
        #expect(AgentState.running.applying(.turnEnded(.endTurn))?.clearsPickUpCount == true)
        // Including one that ended *with* `daemonGone` reported by the runtime rather
        // than discovered on a restart: it is the reason that decides, not the event.
        #expect(AgentState.running.applying(.turnEnded(.daemonGone))?.clearsPickUpCount == false)
    }

    /// A `starting` agent is picked back up like any other, which is FR-007: its
    /// process died with the last daemon exactly as a working one's did.
    @Test func anAgentCutOffBeforeItsFirstTurnIsStillBroughtBack() {
        let transition = AgentState.starting.applying(.foundDead)
        #expect(transition?.next == .stopped)
        var agent = self.agent(.starting, nil, 0)
        agent.state = transition!.next
        if case .set(let reason) = transition!.endedReason { agent.endedReason = reason }
        #expect(agent.mayBePickedUpAfterRestart)
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
