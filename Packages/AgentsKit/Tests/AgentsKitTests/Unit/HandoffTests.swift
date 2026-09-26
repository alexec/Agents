import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// What the next runtime is handed (052, R4).
@Suite("The handoff")
struct HandoffTests {
    private func entry(_ kind: TranscriptEntry.Kind) -> TranscriptEntry {
        TranscriptEntry(id: UUID(), at: .now, kind: kind)
    }

    @Test func itIsTheConversationInOrder() {
        let doc = Handoff.document(entries: [
            entry(.userMessage("Fix the login redirect.")),
            entry(.agentMessage(messageID: nil, text: "Changing the callback.")),
            entry(.runtimeNote("Claude’s allowance ran out.")),
            entry(.userMessage("Run the tests.")),
        ], fromRuntime: "Claude", why: "its allowance ran out")
        #expect(doc.markdown.hasPrefix("# Conversation so far"))
        #expect(doc.markdown.contains("**You:** Fix the login redirect."))
        #expect(doc.markdown.contains("**Claude:** Changing the callback."))
        #expect(!doc.markdown.contains("Claude’s allowance"), "the app's own notes are not the conversation")
        #expect(doc.leftOut == nil)
        let first = doc.markdown.range(of: "Fix the login")!.lowerBound
        let last = doc.markdown.range(of: "Run the tests")!.lowerBound
        #expect(first < last)
    }

    @Test func overBudgetKeepsTheFirstAndTheLatest() {
        var entries = [entry(.userMessage("THE FIRST REQUEST"))]
        for i in 0..<50 {
            entries.append(entry(.userMessage("turn \(i)")))
            entries.append(entry(.agentMessage(messageID: nil, text: String(repeating: "x", count: 200))))
        }
        let doc = Handoff.document(entries: entries, fromRuntime: "Claude", why: "it ran out", budget: 2_000)
        #expect(doc.markdown.contains("THE FIRST REQUEST"))
        #expect(doc.markdown.contains("turn 49"))
        #expect(!doc.markdown.contains("turn 1\n"))
        #expect((doc.leftOut ?? 0) > 0)
        #expect(doc.markdown.contains("earlier turns left out"))
        #expect(doc.markdown.count <= 2_200)
    }
}
