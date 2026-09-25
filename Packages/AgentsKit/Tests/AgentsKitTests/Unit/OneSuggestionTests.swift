import Foundation
import Testing
@testable import AgentsKitCore

/// A conversation holds at most one suggestion (031).
///
/// Records written when a turn could offer four are still on disk, and a daemon from
/// before 031 still sends four to a phone from after it. Both open holding the first.
@Suite("One suggestion")
struct OneSuggestionTests {
    @Test func aRecordWithSeveralOpensHoldingTheFirst() throws {
        let several = Agent(runtimeID: "grok",
                            cwd: URL(fileURLWithPath: "/tmp"),
                            suggestedPrompts: ["Run the tests", "Commit it", "Push"].map {
                                SuggestedPrompt(label: $0, prompt: "Please: \($0)")
                            })
        // Written as an older daemon would have written it: the initialiser does not
        // cut, so all three reach the encoder.
        #expect(several.suggestedPrompts.count == 3)

        let opened = try JSONDecoder().decode(Agent.self, from: try JSONEncoder().encode(several))
        #expect(opened.suggestedPrompts.map(\.label) == ["Run the tests"])
    }

    @Test func aRecordWithNoneOpensWithNone() throws {
        let none = Agent(runtimeID: "grok", cwd: URL(fileURLWithPath: "/tmp"))
        let opened = try JSONDecoder().decode(Agent.self, from: try JSONEncoder().encode(none))
        #expect(opened.suggestedPrompts.isEmpty)
    }
}
