import AgentsKitCore
import Foundation
import Testing

/// The open Prompts list works its prompts out again only when the chat changes (#1850).
@MainActor
struct SessionPromptsMemoTests {
    private func ask(_ text: String) -> TranscriptEntry {
        TranscriptEntry(kind: .userMessage(text))
    }

    @Test func anUnchangedChatIsNotWorkedOutAgain() {
        let memo = SessionPrompts.Memo()
        let entries = [ask("Fix the build"), ask("Now the tests")]
        let first = memo.of(turns: [], entries: entries, isRunning: false)
        let again = memo.of(turns: [], entries: entries, isRunning: false)
        #expect(first.map(\.title) == ["Fix the build", "Now the tests"])
        #expect(again == first)
        #expect(memo.worked == 1)
    }

    @Test func aNewEntryOrStateIsWorkedOutAgain() {
        let memo = SessionPrompts.Memo()
        var entries = [ask("Fix the build")]
        _ = memo.of(turns: [], entries: entries, isRunning: true)
        entries.append(ask("Now the tests"))
        #expect(memo.of(turns: [], entries: entries, isRunning: true).count == 2)
        _ = memo.of(turns: [], entries: entries, isRunning: false)
        _ = memo.of(turns: [], entries: entries, isRunning: false, earlier: 3)
        #expect(memo.worked == 4)
    }
}
