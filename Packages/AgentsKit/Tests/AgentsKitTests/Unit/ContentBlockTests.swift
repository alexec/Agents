import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

@Suite("Content blocks")
struct ContentBlockTests {
    @Test func textIsTheSimpleCase() {
        let block = ContentBlock(wire: ["type": "text", "text": "hello"])
        #expect(block == .text("hello"))
        #expect(block.wire["text"]?.stringValue == "hello")
        #expect(block.requirement == nil)
    }

    @Test func anImageKeepsItsBytes() {
        let bytes = Data([0x89, 0x50, 0x4e, 0x47])
        let block = ContentBlock.image(data: bytes, mimeType: "image/png", uri: nil)
        let back = ContentBlock(wire: block.wire)
        #expect(back == block)
        #expect(block.requirement == .image)
        // An image has no text. This is what used to draw as an empty line.
        #expect(block.text == nil)
    }

    @Test func aResourceLinkNeedsNoCapability() {
        let block = ContentBlock(wire: ["type": "resource_link", "uri": "file:///tmp/notes.txt"])
        #expect(block == .resourceLink(uri: "file:///tmp/notes.txt", name: "notes.txt",
                                       mimeType: nil, size: nil))
        #expect(block.requirement == nil)
    }

    @Test func embeddedContentCarriesItsText() {
        let block = ContentBlock(wire: ["type": "resource",
                                        "resource": ["uri": "file:///tmp/a.txt", "text": "inside"]])
        #expect(block.text == "inside")
        #expect(block.requirement == .embeddedContext)
    }

    @Test func aKindWeDoNotKnowIsKeptWhole() {
        let odd: JSONValue = ["type": "hologram", "spin": 3]
        let block = ContentBlock(wire: odd)
        #expect(block == .unknown(odd))
        // Sent back out exactly as it arrived, rather than as something else.
        #expect(block.wire == odd)
    }

    @Test func aMalformedBlockIsUnknownRatherThanEmpty() {
        // A resource link with no uri is not a resource link.
        let block = ContentBlock(wire: ["type": "resource_link", "name": "notes.txt"])
        if case .unknown = block {} else { Issue.record("expected unknown, got \(block)") }
    }

    @Test func plainTextJoinsOnlyTheTextBlocks() {
        let blocks: [ContentBlock] = [.text("one "),
                                      .image(data: Data([1]), mimeType: "image/png", uri: nil),
                                      .text("two")]
        #expect(blocks.plainText == "one two")
    }

    @Test func oneBlockOrAListOfThem() {
        // Runtimes send both shapes for the same thing.
        let single = [ContentBlock](wire: ["type": "text", "text": "solo"])
        let many = [ContentBlock](wire: [["type": "text", "text": "a"], ["type": "text", "text": "b"]])
        #expect(single == [.text("solo")])
        #expect(many.plainText == "ab")
    }

    @Test func storedAsTheProtocolSentIt() throws {
        let blocks: [ContentBlock] = [.text("hi"),
                                      .resourceLink(uri: "file:///a", name: "a", mimeType: "text/plain", size: 12)]
        let data = try JSONEncoder().encode(blocks)
        let back = try JSONDecoder().decode([ContentBlock].self, from: data)
        #expect(back == blocks)
        let asJSON = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        #expect(asJSON?.first?["type"] as? String == "text")
    }
}
