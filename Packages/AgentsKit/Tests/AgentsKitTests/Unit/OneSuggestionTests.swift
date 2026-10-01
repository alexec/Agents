import Foundation
import Testing
@testable import AgentsKitCore

/// A conversation holds at most one suggestion (031).
@Suite("One suggestion")
struct OneSuggestionTests {
    @Test func aRecordWithNoneOpensWithNone() throws {
        let none = Agent(runtimeID: "grok", cwd: URL(fileURLWithPath: "/tmp"))
        let opened = try JSONDecoder().decode(Agent.self, from: try JSONEncoder().encode(none))
        #expect(opened.suggestedPrompts.isEmpty)
    }
}
