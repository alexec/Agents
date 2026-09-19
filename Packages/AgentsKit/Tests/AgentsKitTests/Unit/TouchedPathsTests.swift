import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

@Suite("Which files the agent touched")
struct TouchedPathsTests {
    private func toolCall(locations: [String] = [], diffs: [String] = []) -> TranscriptEntry {
        TranscriptEntry(kind: .toolCall(ToolCall(
            title: "Edit",
            content: diffs.map { .diff(ToolCallContent.Diff(path: $0, oldText: "was", newText: "is")) },
            locations: locations.map { ToolCallLocation(path: $0) })))
    }

    @Test func locationsAndDiffPathsAreBothTaken() {
        let touched = TouchedPaths(entries: [
            toolCall(locations: ["/tmp/project/read.swift"]),
            toolCall(diffs: ["/tmp/project/written.swift"]),
        ])
        #expect(touched.contains(URL(filePath: "/tmp/project/read.swift")))
        #expect(touched.contains(URL(filePath: "/tmp/project/written.swift")))
        #expect(touched.count == 2)
    }

    @Test func oneToolCallCanCarryBoth() {
        let touched = TouchedPaths(entries: [
            toolCall(locations: ["/tmp/project/a.swift"], diffs: ["/tmp/project/b.swift"]),
        ])
        #expect(touched.count == 2)
    }

    @Test func aFileNobodyTouchedIsAbsent() {
        let touched = TouchedPaths(entries: [toolCall(locations: ["/tmp/project/a.swift"])])
        #expect(touched.contains(URL(filePath: "/tmp/project/untouched.swift")) == false)
    }

    @Test func theSameFileTwiceIsStillOneFile() {
        let touched = TouchedPaths(entries: [
            toolCall(locations: ["/tmp/project/a.swift"]),
            toolCall(diffs: ["/tmp/project/a.swift"]),
        ])
        #expect(touched.count == 1)
    }

    @Test func messagesAndThoughtsTouchNothing() {
        // The mark claims the agent changed a file. Talking about one is not that.
        let touched = TouchedPaths(entries: [
            TranscriptEntry(kind: .agentMessage(messageID: nil, text: "I edited /tmp/project/a.swift")),
            TranscriptEntry(kind: .agentThought(messageID: nil, text: "/tmp/project/b.swift next")),
            TranscriptEntry(kind: .userMessage("please edit /tmp/project/c.swift")),
        ])
        #expect(touched.isEmpty)
    }

    @Test func anUpdateCountsTheSameAsTheCall() {
        let touched = TouchedPaths(entries: [
            TranscriptEntry(kind: .toolCallUpdate(ToolCall(
                title: "Edit",
                content: [.diff(ToolCallContent.Diff(path: "/tmp/project/late.swift",
                                                     oldText: nil, newText: "new"))],
                locations: []))),
        ])
        #expect(touched.contains(URL(filePath: "/tmp/project/late.swift")))
    }

    @Test func aPathIsMatchedAfterItIsResolved() throws {
        // The agent says /tmp/x and the pane is listing /private/tmp/x, or the other
        // way about. Same file, so it must carry the mark either way.
        //
        // This only holds for a file that exists: `resolvingSymlinksInPath` walks the
        // real file system, and for a path that is not there it leaves /tmp alone.
        // That is the right trade. The pane marks entries it got from a directory
        // listing, so the file is there by construction, and a path the agent named
        // that has since gone is not in the listing to be marked.
        let url = URL(filePath: "/tmp/touched-\(UUID().uuidString).swift")
        try Data("x".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let viaPrivate = "/private/tmp/\(url.lastPathComponent)"
        let touched = TouchedPaths(entries: [toolCall(locations: [url.path])])
        #expect(touched.contains(URL(filePath: viaPrivate)))

        let other = TouchedPaths(entries: [toolCall(locations: [viaPrivate])])
        #expect(other.contains(url))
    }

    @Test func absorbingLaterEntriesAddsToTheSet() {
        // The pane folds once per agent and keeps folding as entries arrive (FR-013).
        var touched = TouchedPaths()
        #expect(touched.isEmpty)
        touched.absorb(toolCall(locations: ["/tmp/project/first.swift"]))
        touched.absorb(toolCall(diffs: ["/tmp/project/second.swift"]))
        #expect(touched.count == 2)
    }
}
