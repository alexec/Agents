import Foundation
import Testing
@testable import AgentsKit

/// What may be attached to a prompt, and what the runtime has to have said first.
@Suite("Attachments")
struct AttachmentTests {
    private let takesEverything = ACP.PromptCapabilities(image: true, audio: true, embeddedContext: true)
    private let takesNothingExtra = ACP.PromptCapabilities()

    @Test func aFileReferenceNeedsNoCapabilityAtAll() throws {
        let file = URL(filePath: "/tmp/notes.txt")
        let attachment = Attachment.file(file)
        #expect(attachment.displayName == "notes.txt")
        #expect(attachment.refusal(from: takesNothingExtra) == nil,
                "resource links are baseline in the protocol")
    }

    @Test func aPictureIsRefusedBeforeSendingWhenTheRuntimeCannotTakeOne() {
        let attachment = Attachment.image(Data([1, 2, 3]), mimeType: "image/png", name: "Screenshot")
        #expect(attachment.refusal(from: takesEverything) == nil)
        let refusal = attachment.refusal(from: takesNothingExtra)
        #expect(refusal == "This runtime does not take pictures")
    }

    @Test func fileContentsNeedEmbeddedContext() throws {
        let file = URL(filePath: NSTemporaryDirectory()).appending(path: "attach-\(UUID()).txt")
        try "inside".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }

        let attachment = try Attachment.contents(of: file)
        #expect(attachment.block.text == "inside")
        #expect(attachment.refusal(from: takesEverything) == nil)
        #expect(attachment.refusal(from: takesNothingExtra)?.contains("file contents") == true)
    }

    @Test func aPromptIsTheWordsThenWhatWasAttached() {
        let request = DaemonAPI.PromptRequest(agentID: UUID(), text: "look at this",
                                              attachments: [.image(Data([1]), mimeType: "image/png",
                                                                   name: "shot")])
        #expect(request.blocks.count == 2)
        #expect(request.blocks.first == .text("look at this"))
        #expect(request.blocks.last?.requirement == .image)
    }

    @Test func anOlderAppSendingOnlyTextStillWorks() throws {
        // The daemon outlives a window, and a window may be older than it.
        let json = #"{"agentID":"\#(UUID().uuidString)","text":"hello"}"#
        let request = try JSONDecoder().decode(DaemonAPI.PromptRequest.self, from: Data(json.utf8))
        #expect(request.attachments.isEmpty)
        #expect(request.blocks == [.text("hello")])
    }

    @Test func attachmentsSurviveTheTripToTheDaemon() throws {
        let attachment = Attachment.image(Data([0xff, 0xd8]), mimeType: "image/jpeg", name: "photo.jpg")
        let request = DaemonAPI.StartRequest(runtimeID: "claude", cwd: URL(filePath: "/tmp"),
                                             prompt: "what is this", attachments: [attachment])
        let data = try JSONEncoder().encode(request)
        let back = try JSONDecoder().decode(DaemonAPI.StartRequest.self, from: data)
        #expect(back.attachments.first?.block == attachment.block)
        #expect(back.blocks.count == 2)
    }
}
