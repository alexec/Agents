#if canImport(Darwin)
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import AgentsKitCore

/// Share ▸ Agents (#4915): what another app shares waits in the app group, by the
/// paperclip's rules, until New session takes it.
@Suite("Shared to Agents")
struct SharedInboxTests {
    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("shared-inbox-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func picture() throws -> Data {
        let context = try #require(CGContext(data: nil, width: 40, height: 30, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    @Test func itemsGoAsThePaperclipWouldPutThem() throws {
        var items = SharedItems()
        items.add(text: "  https://example.com/page \n")
        items.add(text: "   ")
        items.add(picture: try picture(), name: "Screenshot")
        items.add(file: Data("notes".utf8), name: "notes.txt", type: .plainText)
        items.add(file: Data([0, 1, 2]), name: "film.mov", type: .movie)
        #expect(items.texts == ["https://example.com/page"])
        #expect(items.attachments.map(\.displayName) == ["Screenshot", "notes.txt"])
        if case .image(_, let mime, _) = items.attachments.first?.block { #expect(mime == "image/jpeg") } else {
            Issue.record("the picture is not a picture")
        }
        #expect(items.refusals == [PhoneAttachment.file(Data([0, 1, 2]), name: "film.mov", type: .movie)
            .failureSentence])
    }

    @Test func aFileTooBigIsRefusedInThePaperclipsWords() {
        var items = SharedItems()
        let big = items.refuse(name: "big.log", size: 2_000_000, type: .plainText)
        let small = items.refuse(name: "small.log", size: 10, type: .plainText)
        #expect(big)
        #expect(!small)
        #expect(items.refusals == [PhoneAttachment.sizeRefusal(name: "big.log", size: 2_000_000, type: .plainText)?.sentence])
        #expect(items.note == items.refusals.first)
    }

    @Test func sharedWordsComeAfterWhatIsTyped() {
        let items = SharedItems(texts: ["one", "two"])
        #expect(items.text(after: "") == "one\n\ntwo")
        #expect(items.text(after: "Look at this:  ") == "Look at this:\n\none\n\ntwo")
    }

    @Test func severalSharesWaitInOrderAndAreTakenOnce() throws {
        let container = try scratch()
        defer { try? FileManager.default.removeItem(at: container) }
        #expect(!SharedInbox.hasItems(in: container))
        #expect(!SharedInbox.add(SharedItems(), into: container))
        #expect(SharedInbox.add(SharedItems(texts: ["first"]), into: container))
        #expect(SharedInbox.add(SharedItems(texts: ["second"], refusals: ["no"]), into: container))
        #expect(SharedInbox.hasItems(in: container))
        let taken = try #require(SharedInbox.take(from: container))
        #expect(taken.texts == ["first", "second"])
        #expect(taken.refusals == ["no"])
        #expect(!SharedInbox.hasItems(in: container))
        #expect(SharedInbox.take(from: container) == nil)
    }

    @Test func forgettingThePairingClearsWhatWaits() throws {
        let container = try scratch()
        defer { try? FileManager.default.removeItem(at: container) }
        SharedInbox.add(SharedItems(texts: ["x"]), into: container)
        SharedInbox.clear(in: container)
        #expect(SharedInbox.take(from: container) == nil)
    }

    @Test func theStartLinkGoesBothWays() {
        #expect(SharedInbox.startURL.absoluteString == "agents://start")
        #expect(AttentionLink.parse(SharedInbox.startURL) == .start)
    }
}

private extension Result where Failure == PhoneAttachment.Refusal {
    var failureSentence: String? {
        if case .failure(let refused) = self { return refused.sentence }
        return nil
    }
}
#endif
