import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// A tool call and its updates are the same call. What the updates carry is only what
/// changed, which is why merging replaces field by field.
@Suite("Merging a tool call with its updates")
struct ToolCallMergeTests {
    private func entry(_ call: ToolCall, update: Bool = false) -> TranscriptEntry {
        TranscriptEntry(kind: update ? .toolCallUpdate(call) : .toolCall(call))
    }

    @Test func anUpdateWithNoTitleKeepsTheOneItStartedWith() {
        // Watched happening against the Claude adapter: a completion update carries a
        // status and nothing else.
        let start = ToolCall(toolCallID: "1", title: "Read File", kind: "read", status: "pending")
        let finish = ToolCall(toolCallID: "1", title: "Tool call", status: "completed")
        let items = TranscriptEntry.display([entry(start), entry(finish, update: true)])
        #expect(items.count == 1)
        #expect(items.first?.latestToolCall?.title == "Read File")
        #expect(items.first?.latestToolCall?.status == "completed")
    }

    @Test func whatItWasCalledWithSurvivesWhatItReturned() {
        // The bug this feature exists to fix: the input was lost the moment the output
        // arrived, because the whole raw blob was replaced.
        let start = ToolCall(toolCallID: "1", title: "Read File", status: "pending",
                             rawInput: ["path": "/tmp/notes.txt"])
        let finish = ToolCall(toolCallID: "1", title: "Tool call", status: "completed",
                              rawOutput: ["content": "inside"])
        let merged = TranscriptEntry.merge(finish, onto: start)
        #expect(merged.rawInput?["path"]?.stringValue == "/tmp/notes.txt")
        #expect(merged.rawOutput?["content"]?.stringValue == "inside")
    }

    @Test func contentIsAppendedRatherThanReplaced() {
        // Output arrives in pieces and the last piece is not the whole story.
        let start = ToolCall(toolCallID: "1", title: "Run",
                             content: [.content(.text("first "))])
        let more = ToolCall(toolCallID: "1", title: "Tool call",
                            content: [.content(.text("second"))])
        let merged = TranscriptEntry.merge(more, onto: start)
        #expect(merged.content.count == 2)
    }

    @Test func locationsSurviveAndAreReplacedWhenSentAgain() {
        let start = ToolCall(toolCallID: "1", title: "Edit",
                             locations: [ToolCallLocation(path: "/a", line: 1)])
        let quiet = ToolCall(toolCallID: "1", title: "Tool call", status: "completed")
        #expect(TranscriptEntry.merge(quiet, onto: start).locations.count == 1)

        let moved = ToolCall(toolCallID: "1", title: "Tool call",
                             locations: [ToolCallLocation(path: "/b", line: 9)])
        #expect(TranscriptEntry.merge(moved, onto: start).locations.map(\.path) == ["/b"])
    }

    @Test func aCallWithNoContentStillDraws() {
        let only = ToolCall(toolCallID: "1", title: "Thinking")
        let items = TranscriptEntry.display([entry(only)])
        #expect(items.first?.latestToolCall?.title == "Thinking")
        #expect(items.first?.latestToolCall?.content.isEmpty == true)
    }

    @Test func theDiffsAreEasyToFind() {
        let call = ToolCall(toolCallID: "1", title: "Edit",
                            content: [.content(.text("note")),
                                      .diff(.init(path: "/tmp/a.txt", oldText: "old", newText: "new"))])
        #expect(call.diffs.count == 1)
        #expect(call.diffs.first?.fileName == "a.txt")
    }
}
