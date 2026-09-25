import Foundation
import Testing
@testable import AgentsKitCore

/// The table, exhausted. Every outcome has a group and a heading, no two outcomes read
/// the same, and only the one an agent chose for itself is allowed the word Complete.
@Suite("What an agent says about its work")
struct WorkOutcomeTests {
    @Test("every outcome answers both questions the app asks of it")
    func theTableIsTotal() {
        // Neither is optional and neither has a `default`, so a sixth case added later
        // fails to compile rather than quietly landing nowhere.
        for outcome in WorkOutcome.allCases {
            #expect(!outcome.heading.isEmpty)
            _ = outcome.needsAPerson
        }
        #expect(WorkOutcome.allCases.count == 6)
    }

    @Test("the three that want a person are the three the spec names")
    func whichOnesWantAPerson() {
        #expect(WorkOutcome.allCases.filter(\.needsAPerson) == [.needsAnswer, .partlyDone, .stuck])
        #expect(WorkOutcome.allCases.filter { !$0.needsAPerson } == [.done, .nothingToDo, .blocked])
    }

    /// Two outcomes that read the same are two outcomes a person cannot tell apart,
    /// which is the whole of what this feature is for.
    @Test("no two outcomes read the same")
    func headingsAreDistinct() {
        let headings = WorkOutcome.allCases.map(\.heading)
        #expect(Set(headings).count == headings.count)
    }

    /// SC-001, directly. The word is a claim, and only one thing may make it.
    @Test("only a reported done is called Complete")
    func completeIsReserved() {
        #expect(WorkOutcome.done.heading == "Complete")
        for outcome in WorkOutcome.allCases where outcome != .done {
            #expect(outcome.heading != "Complete")
        }
    }

    @Test("the wire spellings are the ones the tool offers")
    func wireSpellings() {
        #expect(WorkOutcome.allCases.map(\.rawValue)
            == ["done", "nothing_to_do", "needs_answer", "partly_done", "stuck", "blocked"])
        for outcome in WorkOutcome.allCases {
            #expect(WorkOutcome(wire: outcome.rawValue) == outcome)
        }
    }

    /// FR-027. A newer runtime's sixth word is a report that never arrived, never a
    /// report rounded to the nearest one we happen to know.
    @Test("an outcome we do not know is not rounded to one we do")
    func unknownOutcomesAreNotRounded() {
        #expect(WorkOutcome(wire: "succeeded") == nil)
        #expect(WorkOutcome(wire: "done_ish") == nil)
        #expect(WorkOutcome(wire: "") == nil)
        #expect(WorkOutcome(wire: "DONE") == nil)
    }

    @Test("a report with no words is refused")
    func anEmptyMessageIsRefused() {
        #expect(WorkReport(outcome: .done, wire: "") == nil)
        #expect(WorkReport(outcome: .done, wire: "   \n\t ") == nil)
    }

    /// Cut rather than refused: losing the outcome over one long sentence would be
    /// worse than trimming it, which is the rule `SuggestedPrompt` already follows.
    @Test("a message that runs long is cut, not refused")
    func aLongMessageIsCut() {
        let report = WorkReport(outcome: .stuck, wire: String(repeating: "a", count: 2_000))
        #expect(report?.message.count == WorkReport.messageLimit)
        #expect(WorkReport.messageLimit == 1_000)
    }

    @Test("the words are trimmed of what surrounds them")
    func theMessageIsTrimmed() {
        #expect(WorkReport(outcome: .done, wire: "  it is done.\n")?.message == "it is done.")
    }

    // MARK: Blocked (039)

    @Test("a blocked report keeps its block through the record")
    func aBlockRoundTrips() throws {
        let block = Block(waits: [Wait(agentID: UUID(), nameAtReport: "helper",
                                       ending: WaitEnding(at: Date(timeIntervalSince1970: 5),
                                                          how: .finished(outcome: .done, message: "ok")))],
                          checkAgainAt: Date(timeIntervalSince1970: 100))
        let report = WorkReport(outcome: .blocked, message: "waiting", at: Date(timeIntervalSince1970: 1),
                                block: block)
        let back = try JSONDecoder().decode(WorkReport.self, from: JSONEncoder().encode(report))
        #expect(back == report)
    }

    /// A word from a newer build is a report that never arrived, and the rest of the
    /// agent is untouched (research R8).
    @Test("an outcome this build does not know drops the report, not the agent")
    func anUnknownOutcomeDropsOnlyTheReport() throws {
        let agent = Agent(runtimeID: "claude", cwd: URL(filePath: "/tmp"), title: "Kept")
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(agent)) as! [String: Any]
        object["report"] = ["outcome": "someday", "message": "words", "at": 0]
        let data = try JSONSerialization.data(withJSONObject: object)
        let back = try JSONDecoder().decode(Agent.self, from: data)
        #expect(back.report == nil)
        #expect(back.title == "Kept")
    }
}
