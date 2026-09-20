import Foundation
import Testing
@testable import AgentsKitCore

/// The line a tool call is drawn as. A runtime's title is its machinery; a
/// `description` argument is a sentence written for a person, and where there is one it
/// is the whole line.
@Suite("The line a tool call is drawn as")
struct ToolCallLineTests {
    @Test func aDescriptionArgumentIsTheLine() {
        let call = ToolCall(title: #"find . -name "*.tmp" -delete"#, name: "Bash",
                            rawInput: ["command": #"find . -name "*.tmp" -delete"#,
                                       "description": "Find and delete all .tmp files recursively"])
        #expect(call.line == "Find and delete all .tmp files recursively")
    }

    @Test func withoutOneTheTitleStands() {
        let call = ToolCall(title: "Read File", name: "Read", rawInput: ["path": "/tmp/notes.txt"])
        #expect(call.line == "Read File")
    }

    @Test func anEmptyDescriptionIsNoDescription() {
        // A blank line is worse than the machinery it replaced.
        let call = ToolCall(title: "Read File", rawInput: ["description": "   "])
        #expect(call.line == "Read File")
    }

    @Test func aDescriptionThatIsNotTextIsIgnored() {
        // Nothing says a runtime's `description` is a string. One that is not cannot be
        // a line, and the title is still there.
        let call = ToolCall(title: "Fetch", rawInput: ["description": ["long": "form"]])
        #expect(call.line == "Fetch")
    }

    @Test func aRecordWrittenBeforeRawInputWasKeptApartStillFindsIt() {
        // Older entries hold only the whole update, `rawInput` nested inside it.
        let call = ToolCall(title: "Bash",
                            raw: ["rawInput": ["description": "Show working tree status"]])
        #expect(call.line == "Show working tree status")
    }

    @Test func anUpdateCarryingOnlyOutputKeepsTheLine() {
        let start = ToolCall(toolCallID: "1", title: "Bash", status: "pending",
                             rawInput: ["description": "Run the tests"])
        let finish = ToolCall(toolCallID: "1", title: "Tool call", status: "completed",
                              rawOutput: ["content": "ok"])
        #expect(TranscriptEntry.merge(finish, onto: start).line == "Run the tests")
    }
}
