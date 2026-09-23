import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

@Suite("What was exchanged")
struct ArtifactTests {
    private func message(_ blocks: [ContentBlock], at: Date = Date()) -> TranscriptEntry {
        TranscriptEntry(at: at, kind: .agentMessage(messageID: nil, text: "", blocks: blocks))
    }

    private func prompt(_ blocks: [ContentBlock], at: Date = Date()) -> TranscriptEntry {
        TranscriptEntry(at: at, kind: .userMessage("", blocks: blocks))
    }

    private let link = ContentBlock.resourceLink(uri: "file:///tmp/report.md", name: "report.md",
                                                 mimeType: "text/markdown", size: 400)

    /// Both directions, on purpose. A file you attached is the one artifact the list is
    /// sure to have while no runtime hands anything over, and it is worth finding again
    /// whichever way it went.
    @Test func aFileAttachedToAPromptIsAnArtifactToo() {
        let sent = Attachment.file(URL(fileURLWithPath: "/tmp/brief.md")).block
        let artifacts = Artifact.all(in: [prompt([.text("have a look"), sent])])
        #expect(artifacts.count == 1)
        #expect(artifacts[0].name == "brief.md")
    }

    @Test func aResourceLinkIsAnArtifact() {
        let artifacts = Artifact.all(in: [message([link])])
        #expect(artifacts.count == 1)
        #expect(artifacts[0].name == "report.md")
        #expect(artifacts[0].mimeType == "text/markdown")
        #expect(artifacts[0].size == 400)
    }

    @Test func anEmbeddedResourceIsAnArtifact() {
        let block = ContentBlock.resource(uri: "file:///tmp/notes.txt", text: "hello",
                                          blob: nil, mimeType: "text/plain")
        let artifacts = Artifact.all(in: [message([block])])
        #expect(artifacts.count == 1)
        #expect(artifacts[0].embedded)
        #expect(artifacts[0].text == "hello")
        #expect(artifacts[0].destination == .inPlace)
    }

    @Test func aFileAToolCallTouchedIsNotAnArtifact() {
        // The whole of FR-046. A tool call that read and edited six files adds nothing
        // to this list; that belongs to the files pane's marks.
        let entry = TranscriptEntry(kind: .toolCall(ToolCall(
            title: "Edit",
            content: [.diff(ToolCallContent.Diff(path: "/tmp/a.swift", oldText: "a", newText: "b"))],
            locations: [ToolCallLocation(path: "/tmp/b.swift"), ToolCallLocation(path: "/tmp/c.swift")])))
        #expect(Artifact.all(in: [entry]).isEmpty)
    }

    @Test func plainMessagesAndThoughtsAreNotArtifacts() {
        let entries = [
            message([.text("here is your report")]),
            TranscriptEntry(kind: .agentThought(messageID: nil, text: "thinking")),
            TranscriptEntry(kind: .userMessage("write me a report")),
        ]
        #expect(Artifact.all(in: entries).isEmpty)
    }

    @Test func imagesAndAudioAreNotArtifactsEither() {
        // They are message content, drawn in the conversation. Only the two blocks that
        // hand something over count.
        let entries = [message([
            .image(data: Data([1, 2, 3]), mimeType: "image/png", uri: nil),
            .audio(data: Data([1]), mimeType: "audio/wav"),
        ])]
        #expect(Artifact.all(in: entries).isEmpty)
    }

    @Test func theNewestComesFirst() {
        let old = Date(timeIntervalSince1970: 1_000)
        let new = Date(timeIntervalSince1970: 2_000)
        let entries = [
            message([.resourceLink(uri: "file:///tmp/old.md", name: "old.md", mimeType: nil, size: nil)], at: old),
            message([.resourceLink(uri: "file:///tmp/new.md", name: "new.md", mimeType: nil, size: nil)], at: new),
        ]
        #expect(Artifact.all(in: entries).map(\.name) == ["new.md", "old.md"])
    }

    @Test func anAudienceThatIsNotTheUserIsLeftOut() {
        let forAssistant = ContentBlock.resourceLink(
            uri: "file:///tmp/scratch.json", name: "scratch.json", mimeType: nil, size: nil,
            annotations: .init(audience: ["assistant"]))
        #expect(Artifact.all(in: [message([forAssistant])]).isEmpty)
    }

    @Test func anAudienceThatIncludesTheUserIsKept() {
        let forBoth = ContentBlock.resourceLink(
            uri: "file:///tmp/report.md", name: "report.md", mimeType: nil, size: nil,
            annotations: .init(audience: ["user", "assistant"]))
        #expect(Artifact.all(in: [message([forBoth])]).count == 1)
    }

    @Test func noAnnotationsMeansItIsForTheUser() {
        // An agent that bothered to send a resource link meant it, and the protocol
        // does not make it say so twice.
        #expect(Artifact.all(in: [message([link])]).count == 1)
    }

    @Test func eachArtifactKnowsTheMessageItCameFrom() {
        let entry = message([link])
        let artifact = Artifact.all(in: [entry])[0]
        #expect(artifact.entryID == entry.id)
    }

    @Test func twoArtifactsInOneMessageGetDifferentIdentities() {
        let entry = message([
            link,
            .resourceLink(uri: "file:///tmp/second.md", name: "second.md", mimeType: nil, size: nil),
        ])
        let artifacts = Artifact.all(in: [entry])
        #expect(artifacts.count == 2)
        #expect(artifacts[0].id != artifacts[1].id)
    }

    @Test func aFileUriOpensInTheFilesPaneAndHttpInTheBrowser() {
        #expect(Artifact.all(in: [message([link])])[0].destination == .file(URL(string: "file:///tmp/report.md")!))
        let web = ContentBlock.resourceLink(uri: "https://example.com/report", name: "report",
                                            mimeType: nil, size: nil)
        #expect(Artifact.all(in: [message([web])])[0].destination == .web(URL(string: "https://example.com/report")!))
    }

    @Test func anAddressWeCannotOpenGoesNowhereRatherThanCrashing() {
        let odd = ContentBlock.resourceLink(uri: "gopher://example.com/x", name: "x", mimeType: nil, size: nil)
        #expect(Artifact.all(in: [message([odd])])[0].destination == .nowhere)
    }

    @Test func oneThatPointsAtSomethingGoneSaysSoRatherThanDisappearing() throws {
        // It stays in the list. The record that it arrived is still true (FR-045).
        let url = URL.temporaryDirectory.appending(path: "artifact-\(UUID().uuidString).txt")
        try Data("x".utf8).write(to: url)
        let block = ContentBlock.resourceLink(uri: url.absoluteString, name: url.lastPathComponent,
                                              mimeType: nil, size: nil)
        var artifact = Artifact.all(in: [message([block])])[0]
        #expect(artifact.isMissing == false)

        try FileManager.default.removeItem(at: url)
        artifact = Artifact.all(in: [message([block])])[0]
        #expect(artifact.isMissing)
    }

    @Test func annotationsSurviveBeingWrittenAndReadBack() throws {
        // They cross the socket and land in the transcript, so they have to round trip.
        let block = ContentBlock.resourceLink(uri: "file:///tmp/a.md", name: "a.md",
                                              mimeType: "text/markdown", size: 7,
                                              annotations: .init(audience: ["user"], priority: 0.8))
        let data = try JSONEncoder().encode(block)
        let back = try JSONDecoder().decode(ContentBlock.self, from: data)
        #expect(back == block)
        #expect(back.annotations?.audience == ["user"])
        #expect(back.annotations?.priority == 0.8)
    }

    @Test func aBlockWithoutAnnotationsStillDecodes() throws {
        let data = try JSONEncoder().encode(link)
        let back = try JSONDecoder().decode(ContentBlock.self, from: data)
        #expect(back == link)
        #expect(back.annotations == nil)
    }
}
