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

    @Test func copyTakesTheWholeMessageAsWritten() throws {
        // Streamed chunks, joined the way the chat joins them: one message, every word.
        let chunks = TranscriptEntry.coalesced([
            TranscriptEntry(kind: .agentMessage(messageID: "m", text: "## Done\n\n")),
            TranscriptEntry(kind: .agentMessage(messageID: "m", text: "- one\n- `two`")),
        ])
        #expect(chunks.count == 1)
        #expect(try #require(chunks.first).copiedText == "## Done\n\n- one\n- `two`")
        #expect(TranscriptEntry(kind: .userMessage("Fix it", blocks: [.text("Fix it")])).copiedText == "Fix it")
        // Blocks alone give the text in them.
        #expect(TranscriptEntry(kind: .agentMessage(messageID: nil, text: "",
                                                    blocks: [.text("a"), .text("b")])).copiedText == "ab")
        // Nothing to copy is nothing offered.
        #expect(TranscriptEntry(kind: .agentMessage(messageID: nil, text: "")).copiedText == nil)
        #expect(TranscriptEntry(kind: .runtimeNote("note")).copiedText == nil)
    }
}
