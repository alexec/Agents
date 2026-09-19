import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

@Suite("What the chat draws")
struct TranscriptDisplayTests {
    private func message(_ text: String, _ id: String? = nil) -> TranscriptEntry {
        TranscriptEntry(kind: .agentMessage(messageID: id, text: text))
    }

    private func call(_ id: String, _ title: String, status: String? = nil) -> TranscriptEntry {
        TranscriptEntry(kind: .toolCall(ToolCall(toolCallID: id, title: title, status: status)))
    }

    private func update(_ id: String, status: String, title: String = "Tool call") -> TranscriptEntry {
        TranscriptEntry(kind: .toolCallUpdate(ToolCall(toolCallID: id, title: title, status: status)))
    }

    @Test func oneToolCallIsOneLine() {
        let items = TranscriptEntry.display([call("t1", "Write hello.txt")])
        #expect(items.count == 1)
        #expect(items[0].latestToolCall?.title == "Write hello.txt")
        #expect(items[0].hiddenToolCallCount == 0)
    }

    @Test func aCallAndItsUpdatesAreStillOneCall() {
        let items = TranscriptEntry.display([
            call("t1", "Write hello.txt", status: "pending"),
            update("t1", status: "in_progress"),
            update("t1", status: "completed"),
        ])
        #expect(items.count == 1)
        #expect(items[0].hiddenToolCallCount == 0, "an update is the same call further along")
        #expect(items[0].latestToolCall?.status == "completed")
        #expect(items[0].latestToolCall?.title == "Write hello.txt", "the update does not lose the title")
    }

    @Test func aRunOfCallsShowsTheLatestAndKeepsTheRest() {
        let items = TranscriptEntry.display([
            call("t1", "Read the file"),
            call("t2", "Patch the file"),
            call("t3", "Run the tests"),
        ])
        #expect(items.count == 1)
        #expect(items[0].latestToolCall?.title == "Run the tests")
        #expect(items[0].hiddenToolCallCount == 2)
        if case .toolRun(_, let calls) = items[0] {
            #expect(calls.map(\.title) == ["Read the file", "Patch the file", "Run the tests"])
        }
    }

    @Test func anythingSaidBetweenThemStartsANewRun() {
        let items = TranscriptEntry.display([
            call("t1", "Read the file"),
            message("Here is what I found"),
            call("t2", "Patch the file"),
            call("t3", "Run the tests"),
        ])
        #expect(items.count == 3)
        #expect(items[0].hiddenToolCallCount == 0)
        if case .entry(let entry) = items[1] { #expect(entry.text == "Here is what I found") }
        #expect(items[2].hiddenToolCallCount == 1)
    }

    @Test func messageChunksAreStillJoined() {
        let items = TranscriptEntry.display([
            message("Created ", "m1"), message("hello.txt", "m1"),
        ])
        #expect(items.count == 1)
        if case .entry(let entry) = items[0] { #expect(entry.text == "Created hello.txt") }
    }

    @Test func everythingElseKeepsItsOwnLine() {
        let items = TranscriptEntry.display([
            TranscriptEntry(kind: .userMessage("do it")),
            call("t1", "Write a file"),
            TranscriptEntry(kind: .stateChanged(.finished, reason: .endTurn)),
        ])
        #expect(items.count == 3)
    }
}
