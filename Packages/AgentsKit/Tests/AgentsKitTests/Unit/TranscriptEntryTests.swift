import Foundation
import Testing
@testable import AgentsKitCore

@Suite("What a transcript keeps")
struct TranscriptEntryTests {
    @Test func onlyZeroWidthAgentTextIsInvisible() {
        func kind(_ text: String) -> TranscriptEntry.Kind { .agentMessage(messageID: "m", text: text) }
        #expect(kind("\u{200B}").isInvisibleAgentText)
        #expect(kind(String(repeating: "\u{200B}", count: 8)).isInvisibleAgentText)
        #expect(kind("\u{200C}\u{200D}\u{2060}\u{FEFF}").isInvisibleAgentText)
        // A paragraph break inside a real reply, and words with one in them, stay.
        #expect(!kind("\n\n").isInvisibleAgentText)
        #expect(!kind(" ").isInvisibleAgentText)
        #expect(!kind("ok\u{200B}").isInvisibleAgentText)
        #expect(!kind("").isInvisibleAgentText)
        // Only the agent's reply: the person's own message is never dropped.
        #expect(!TranscriptEntry.Kind.userMessage("\u{200B}").isInvisibleAgentText)
    }

    @Test func aNoticeIsKeptInTheRecord() throws {
        let entry = TranscriptEntry(kind: .notice(SessionNotice(severity: "error", title: "Model unavailable",
                                                                detail: "Fell back to a smaller one.")))
        let read = try JSONDecoder().decode(TranscriptEntry.self, from: JSONEncoder().encode(entry))
        #expect(read.kind == entry.kind)
    }
}
