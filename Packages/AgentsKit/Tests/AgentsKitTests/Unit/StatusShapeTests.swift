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
        #expect(StatusShape(state: .running, outcome: nil, isWaiting: false, isComingBack: false) == .working)
        #expect(StatusShape(state: .starting, outcome: nil, isWaiting: false, isComingBack: false) == .working)
        // The record still reads stopped while the daemon brings it back.
        #expect(StatusShape(state: .stopped, outcome: nil, isWaiting: false, isComingBack: true) == .working)
        #expect(StatusShape.working.symbol == nil)
    }

    @Test("Anything waiting on a person is needs-you, and only that gets colour")
    func needsYou() {
        #expect(StatusShape(state: .waitingOnUser, outcome: nil, isWaiting: false, isComingBack: false) == .needsYou)
        for outcome in [WorkOutcome.needsAnswer] {
            #expect(StatusShape(state: .finished, outcome: outcome, isWaiting: false, isComingBack: false) == .needsYou,
                    "\(outcome) should want a person")
        }
        for shape in [StatusShape.working, .needsYou, .done, .stopped] {
            #expect(shape.wantsAPerson == (shape == .needsYou))
        }
    }

    @Test("A finished turn nobody is waiting on is done, vouched for or not")
    func done() {
        #expect(StatusShape(state: .finished, outcome: .done, isWaiting: false, isComingBack: false) == .done)
        #expect(StatusShape(state: .finished, outcome: .nothingToDo, isWaiting: false, isComingBack: false) == .done)
        // Finished and never said how it went. The words say so; the shape does not.
        #expect(StatusShape(state: .finished, outcome: nil, isWaiting: false, isComingBack: false) == .done)
    }

    @Test("Stopped and archived are stopped, whatever was last claimed")
    func stopped() {
        #expect(StatusShape(state: .stopped, outcome: nil, isWaiting: false, isComingBack: false,
                            endedReason: .cancelled) == .stopped)
        #expect(StatusShape(state: .archived, outcome: nil, isWaiting: false, isComingBack: false) == .stopped)
        // An outcome from an earlier turn does not dress a stopped agent up as done.
        #expect(StatusShape(state: .stopped, outcome: .done, isWaiting: false, isComingBack: false,
                            endedReason: .cancelled) == .stopped)
        #expect(StatusShape(state: .stopped, outcome: nil, isWaiting: false, isComingBack: false,
                            endedReason: .processDied) == .needsYou)
    }

    /// A block the app will not clear (an old record's) is done: only a question needs the
    /// person (#1916).
    @Test("A turn that ended waiting on nothing is done, and wants nobody")
    func blocked() {
        let shape = StatusShape(state: .finished, outcome: .waiting, isWaiting: false, isComingBack: false)
        #expect(shape == .done)
        #expect(!shape.wantsAPerson)
        #expect(StatusShape(state: .stopped, outcome: .waiting, isWaiting: false, isComingBack: false,
                            endedReason: .cancelled) == .stopped)
        #expect(StatusShape(state: .running, outcome: .waiting, isWaiting: false, isComingBack: false) == .working)
    }

    /// Something the app watches will carry it on: its own shape, apart from Blocked,
    /// and no colour. Wanting a person still outranks it.
    @Test("A turn the app will carry on is waiting, and wants nobody")
    func waiting() {
        let shape = StatusShape(state: .finished, outcome: .waiting, isWaiting: true, isComingBack: false)
        #expect(shape == .waiting)
        #expect(!shape.wantsAPerson)
        // Drawn as the waiting card's beacon, which breathes (#2456, #2657).
        #expect(shape.symbol == "dot.radiowaves.left.and.right")
        #expect(StatusShape(state: .finished, outcome: .done, isWaiting: true, isComingBack: false) == .waiting)
        #expect(StatusShape(state: .finished, outcome: .needsAnswer, isWaiting: true, isComingBack: false) == .needsYou)
        #expect(StatusShape(state: .stopped, outcome: .waiting, isWaiting: true, isComingBack: false,
                            endedReason: .cancelled) == .stopped)
    }

    @Test("Every state lands on exactly one of the four")
    func total() {
        // Queued waits by itself for a place (#362); every other state lands on the four.
        let shapes = Set(AgentState.allCases.filter { $0 != .queued }.map {
            StatusShape(state: $0, outcome: nil, isWaiting: false, isComingBack: false)
        })
        #expect(shapes.isSubset(of: [.working, .needsYou, .done, .stopped]))
        #expect(StatusShape(state: .queued, outcome: nil, isWaiting: false, isComingBack: false) == .waiting)
        // One is motion (the ring); the other four are symbols, each its own.
        #expect(Set([StatusShape.needsYou, .waiting, .done, .stopped].compactMap(\.symbol)).count == 4)
        #expect(StatusShape.waiting.symbol == StatusShape.waitingSymbol)
    }

    @Test("A Needs You row says its question or why it stopped")
    func needsYouLine() {
        var asking = Agent(runtimeID: "test", cwd: URL(fileURLWithPath: "/tmp"), state: .waitingOnUser)
        #expect(StatusShape.needsYouLine(row: asking, question: "May I run this?\nMore detail") == "May I run this?")
        #expect(StatusShape.needsYouLine(row: asking) == nil)

        asking.state = .stopped
        asking.endedReason = .daemonGone
        #expect(StatusShape.needsYouLine(row: asking, question: "Old question") == "Stopped with the daemon")

        asking.state = .finished
        asking.endedReason = .endTurn
        asking.outcomeAsked = true
        #expect(StatusShape.needsYouLine(row: asking) == "Finished without saying how it went")

        asking.outcomeAsked = false
        asking.report = WorkReport(outcome: .done, message: "The report", at: Date())
        #expect(StatusShape.needsYouLine(row: asking) == nil)
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

    /// An older record says who named it. The key is read and dropped, not carried on
    /// as an unknown field, since the runtime names the conversation now.
    @Test("An older record's titledByAgent is dropped")
    func titledByAgentIsDropped() throws {
        let agent = Agent(runtimeID: "claude", cwd: URL(fileURLWithPath: "/tmp"), title: "Login redirect fixed")
        var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(agent)) as? [String: Any])
        object["titledByAgent"] = true
        let older = try JSONSerialization.data(withJSONObject: object)
        let read = try JSONDecoder().decode(Agent.self, from: older)
        #expect(read.title == "Login redirect fixed")
        #expect(read.unknownFields["titledByAgent"] == nil)
        let written = String(decoding: try JSONEncoder().encode(read), as: UTF8.self)
        #expect(!written.contains("titledByAgent"))
    }
}
