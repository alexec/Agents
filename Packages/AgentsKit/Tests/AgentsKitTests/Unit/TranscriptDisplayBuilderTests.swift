import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// The fold kept up a chunk at a time says exactly what the fold from the top says,
/// and keeps a run's identity while the run is going.
@Suite("Folding the page as it grows")
struct TranscriptDisplayBuilderTests {
    private static func message(_ text: String, _ id: String? = "m") -> TranscriptEntry {
        TranscriptEntry(kind: .agentMessage(messageID: id, text: text))
    }

    private static func call(_ id: String, _ title: String, status: String? = nil) -> TranscriptEntry {
        TranscriptEntry(kind: .toolCall(ToolCall(toolCallID: id, title: title, status: status)))
    }

    private static func update(_ id: String, status: String) -> TranscriptEntry {
        TranscriptEntry(kind: .toolCallUpdate(ToolCall(toolCallID: id, title: "Tool call", status: status)))
    }

    private static func suggestion(_ id: String) -> TranscriptEntry {
        TranscriptEntry(kind: .toolCall(ToolCall(toolCallID: id, title: "Suggest", name: AppTool.suggestPrompts)))
    }

    private func message(_ text: String, _ id: String? = "m") -> TranscriptEntry { Self.message(text, id) }
    private func call(_ id: String, _ title: String) -> TranscriptEntry { Self.call(id, title) }
    private func update(_ id: String, status: String) -> TranscriptEntry { Self.update(id, status: status) }

    /// Everything the chat can be handed, in an order that exercises every branch:
    /// chunks joining, a run interrupted by a message, an update to an earlier call,
    /// a suppressed call and its later update, and passing lines superseded.
    ///
    /// Stored, not computed: every entry is made once, or the ids would differ
    /// between the page fed to the builder and the page folded from the top.
    private let story: [TranscriptEntry] = {
        [
            TranscriptEntry(kind: .userMessage("do it")),
            TranscriptEntry(kind: .stateChanged(.running, reason: nil)),
            message("On "), message("it"),
            call("t1", "Read the file", status: "pending"),
            suggestion("s1"),
            call("t2", "Patch the file"),
            update("s1", status: "completed"),
            update("t1", status: "completed"),
            message("Patched", "m2"),
            TranscriptEntry(kind: .optionChanged(id: "mode", value: .string("auto"))),
            call("t3", "Run the tests"),
            TranscriptEntry(kind: .agentThought(messageID: "th", text: "Hm")),
            TranscriptEntry(kind: .agentThought(messageID: "th", text: "m.")),
            TranscriptEntry(kind: .stateChanged(.finished, reason: .endTurn)),
        ]
    }()

    @Test func aChunkAtATimeIsTheSameAsTheWholePage() {
        var builder = TranscriptDisplayBuilder()
        var stepwise: [[TranscriptItem]] = []
        for (index, entry) in story.enumerated() {
            builder.add(entry)
            stepwise.append(builder.items)
            #expect(builder.items == TranscriptEntry.display(Array(story.prefix(index + 1))),
                    "after entry \(index)")
        }
        #expect(stepwise.last == TranscriptEntry.display(story))
    }

    @Test func aRunKeepsItsIdentityWhileItGrows() {
        var builder = TranscriptDisplayBuilder()
        builder.add(call("t1", "Read"))
        let opened = builder.items.last?.id
        builder.add(call("t2", "Patch"))
        builder.add(update("t1", status: "completed"))
        #expect(builder.items.last?.id == opened, "the row for a run is the same row as calls join it")
        #expect(builder.items.last?.hiddenToolCallCount == 1)
    }

    @Test func aRunIsIdentifiedByTheEntryThatOpenedIt() {
        let first = call("t1", "Read")
        let items = TranscriptEntry.display([first, call("t2", "Patch")])
        #expect(items.first?.id == first.id, "stable across folds, so two folds of one page agree")
        #expect(TranscriptEntry.display([first, call("t2", "Patch")]) == items)
    }

    @Test func aChunkReplacesTheMessageItContinues() {
        var builder = TranscriptDisplayBuilder()
        builder.add(message("Hel"))
        let id = builder.items.first?.id
        builder.add(message("lo"))
        #expect(builder.items.count == 1)
        #expect(builder.items.first?.id == id)
        if case .entry(let entry) = builder.items[0] { #expect(entry.text == "Hello") }
    }
}
