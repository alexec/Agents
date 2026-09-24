import Foundation
import Testing
@testable import AgentsKitCore

/// Four shapes, and which of them every state and outcome lands on.
///
/// Worth walking in full because the old icon had ten, and a state that quietly fell
/// into the wrong one of four would be the one row nobody could read.
@Suite("The four shapes beside a title")
struct StatusShapeTests {
    @Test("A turn going, or a chat coming back, is working")
    func working() {
        #expect(StatusShape(state: .running, outcome: nil, isComingBack: false) == .working)
        #expect(StatusShape(state: .starting, outcome: nil, isComingBack: false) == .working)
        // The record still reads stopped while the daemon brings it back.
        #expect(StatusShape(state: .stopped, outcome: nil, isComingBack: true) == .working)
        #expect(StatusShape.working.symbol == nil)
    }

    @Test("Anything waiting on a person is needs-you, and only that gets colour")
    func needsYou() {
        #expect(StatusShape(state: .waitingOnUser, outcome: nil, isComingBack: false) == .needsYou)
        for outcome in [WorkOutcome.needsAnswer, .partlyDone, .stuck] {
            #expect(StatusShape(state: .finished, outcome: outcome, isComingBack: false) == .needsYou,
                    "\(outcome) should want a person")
        }
        for shape in [StatusShape.working, .needsYou, .done, .stopped] {
            #expect(shape.wantsAPerson == (shape == .needsYou))
        }
    }

    @Test("A finished turn nobody is waiting on is done, vouched for or not")
    func done() {
        #expect(StatusShape(state: .finished, outcome: .done, isComingBack: false) == .done)
        #expect(StatusShape(state: .finished, outcome: .nothingToDo, isComingBack: false) == .done)
        // Finished and never said how it went. The words say so; the shape does not.
        #expect(StatusShape(state: .finished, outcome: nil, isComingBack: false) == .done)
    }

    @Test("Stopped and archived are stopped, whatever was last claimed")
    func stopped() {
        #expect(StatusShape(state: .stopped, outcome: nil, isComingBack: false) == .stopped)
        #expect(StatusShape(state: .archived, outcome: nil, isComingBack: false) == .stopped)
        // An outcome from an earlier turn does not dress a stopped agent up as done.
        #expect(StatusShape(state: .stopped, outcome: .done, isComingBack: false) == .stopped)
        #expect(StatusShape(state: .stopped, outcome: .stuck, isComingBack: false) == .stopped)
    }

    @Test("Every state lands on exactly one of the four")
    func total() {
        let shapes = Set(AgentState.allCases.map {
            StatusShape(state: $0, outcome: nil, isComingBack: false)
        })
        #expect(shapes.isSubset(of: [.working, .needsYou, .done, .stopped]))
        #expect(Set([StatusShape.needsYou, .done, .stopped].compactMap(\.symbol)).count == 3)
    }
}

@Suite("An agent's own title")
struct AgentTitleTests {
    @Test("Cleaned to one line and a row's length")
    func cleaned() {
        #expect(Agent.cleanedTitle("  Login redirect\n  fixed  ") == "Login redirect fixed")
        #expect(Agent.cleanedTitle("") == nil)
        #expect(Agent.cleanedTitle(" \n\t ") == nil)
        let long = Agent.cleanedTitle(String(repeating: "a ", count: 100))
        #expect(long?.count == 80)
        #expect(long?.hasSuffix("…") == true)
    }

    @Test("Who named it is kept on the record, and an older record says nobody did")
    func roundTrip() throws {
        let agent = Agent(runtimeID: "claude", cwd: URL(fileURLWithPath: "/tmp"),
                          title: "Login redirect fixed", titledByAgent: true)
        let data = try JSONEncoder().encode(agent)
        #expect(try JSONDecoder().decode(Agent.self, from: data).titledByAgent)

        // Written only when true, so an older build's record is unchanged by this one.
        let plain = Agent(runtimeID: "claude", cwd: URL(fileURLWithPath: "/tmp"))
        let written = String(decoding: try JSONEncoder().encode(plain), as: UTF8.self)
        #expect(!written.contains("titledByAgent"))
        #expect(try JSONDecoder().decode(Agent.self, from: Data(written.utf8)).titledByAgent == false)
    }
}
