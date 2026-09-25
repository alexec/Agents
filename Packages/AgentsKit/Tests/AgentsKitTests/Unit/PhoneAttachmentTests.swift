import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import AgentsKitCore

/// What a phone may attach to the first prompt, and how (029). A file on a phone is a
/// path the Mac cannot open, so everything goes by value, small enough to cross the
/// relayed link in one record.
@Suite("Attaching from a phone")
struct PhoneAttachmentTests {
    /// A picture the size a phone's camera takes, drawn here rather than kept as a
    /// fixture.
    private func photo(width: Int, height: Int) throws -> Data {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                             bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func size(of data: Data) throws -> (Int, Int) {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return (image.width, image.height)
    }

    @Test func aPictureIsShrunkToTheLongEdgeAndSentAsJPEG() throws {
        let attached = try PhoneAttachment.picture(photo(width: 4032, height: 3024), name: "IMG_0001.HEIC").get()
        guard case .image(let data, let mimeType, _) = attached.block else {
            Issue.record("not a picture: \(attached.block)"); return
        }
        #expect(mimeType == "image/jpeg")
        let (width, height) = try size(of: data)
        #expect(max(width, height) == PhoneAttachment.longestEdge)
        #expect(width > height, "the shape is kept")
        #expect(attached.displayName == "IMG_0001.HEIC")
    }

    @Test func aSmallPictureIsNotBlownUp() throws {
        let attached = try PhoneAttachment.picture(photo(width: 300, height: 200), name: "small.png").get()
        guard case .image(let data, _, _) = attached.block else { Issue.record("not a picture"); return }
        #expect(try size(of: data) == (300, 200))
    }

    @Test func somethingThatIsNotAPictureIsRefusedAsOne() {
        guard case .failure(let refusal) = PhoneAttachment.picture(Data("hello".utf8), name: "notes.png") else {
            Issue.record("read as a picture"); return
        }
        #expect(refusal.sentence.contains("notes.png"))
    }

    @Test func textGoesAsTheFilesContents() throws {
        let attached = try PhoneAttachment.file(Data("line one\nline two".utf8), name: "notes.md", type: .plainText).get()
        guard case .resource(_, let text, _, _, _) = attached.block else { Issue.record("not contents"); return }
        #expect(text == "line one\nline two")
        #expect(attached.block.requirement == .embeddedContext)
    }

    @Test func aPictureFromFilesGoesAsAPicture() throws {
        let attached = try PhoneAttachment.file(photo(width: 100, height: 100), name: "shot.png", type: .png).get()
        guard case .image = attached.block else { Issue.record("not a picture"); return }
    }

    @Test func anythingElseIsRefusedInOneSentence() {
        let bytes = Data([0x00, 0xFF, 0xFE, 0x00, 0x81])
        guard case .failure(let refusal) = PhoneAttachment.file(bytes, name: "archive.zip", type: .zip) else {
            Issue.record("accepted a binary file"); return
        }
        #expect(refusal.sentence.contains("archive.zip"))
        #expect(!refusal.sentence.contains("\n"))
    }

    @Test func overTheLimitInAllIsRefusedNamingTheLimit() {
        let big = Attachment.image(Data(count: 600_000), mimeType: "image/jpeg", name: "a.jpg")
        let other = Attachment.image(Data(count: 400_000), mimeType: "image/jpeg", name: "b.jpg")
        #expect(PhoneAttachment.totalRefusal([big]) == nil)
        let refusal = PhoneAttachment.totalRefusal([big, other])
        #expect(refusal?.contains("900 KB") == true)
    }

    @Test func aRuntimeThatTakesNeitherRefusesBothTheMacsWay() {
        let none = ACP.PromptCapabilities()
        let picture = Attachment.image(Data(count: 10), mimeType: "image/jpeg", name: "a.jpg")
        #expect(PhoneAttachment.refusal(for: picture, from: none) == picture.refusal(from: none))
        let text = Attachment(block: .resource(uri: "phone:notes.md", text: "x", blob: nil, mimeType: "text/plain"),
                              displayName: "notes.md")
        let said = PhoneAttachment.refusal(for: text, from: none)
        #expect(said?.hasPrefix("This runtime does not take file contents") == true)
        #expect(said?.contains("Attach the file itself") == false, "a phone has no file itself to attach")
    }
}
