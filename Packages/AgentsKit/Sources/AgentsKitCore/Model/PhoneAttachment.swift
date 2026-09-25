// Not on Linux: the server build of agentsd has no CoreGraphics and no use for this (037).
#if canImport(CoreGraphics)
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// What a phone may attach to a prompt, and in what form (029).
///
/// On the Mac anything that is not a picture goes as a reference to the file, which every
/// runtime takes. From a phone a reference is a path on the phone, which means nothing on
/// the Mac, so everything goes by value: a picture as a picture, shrunk; text as the
/// file's contents; anything else is refused, in one sentence, before it is sent.
///
/// Small enough, in all, to cross the relayed link in one record (005's mailbox, 1 MB),
/// and held to the same size on the direct link, so what can be attached does not change
/// with where the phone is.
public enum PhoneAttachment {
    /// A picture's longest side, once shrunk. Enough to read a screenshot by.
    public static let longestEdge = 2048
    /// Everything attached by value to one prompt, under the relayed link's record.
    public static let limit = 900_000

    public struct Refusal: Error, Equatable, Sendable {
        public var sentence: String
        public init(_ sentence: String) { self.sentence = sentence }
    }

    /// A picture from the library or the camera, shrunk and sent as a JPEG.
    public static func picture(_ data: Data, name: String) -> Result<Attachment, Refusal> {
        guard let jpeg = shrunk(data) else {
            return .failure(Refusal("\(name) could not be read as a picture."))
        }
        return .success(.image(jpeg, mimeType: "image/jpeg", name: name))
    }

    /// A file from Files. A picture goes as a picture, text as its contents, and
    /// anything else is refused.
    public static func file(_ data: Data, name: String, type: UTType?) -> Result<Attachment, Refusal> {
        if let type, type.conforms(to: .image) { return picture(data, name: name) }
        guard let text = String(data: data, encoding: .utf8), !text.contains("\u{0}") else {
            return .failure(Refusal("\(name) is not a picture or text, so it would have to be on the Mac to attach."))
        }
        // Not a path: the file is on the phone, and a `file://` here would name a place
        // on the Mac that does not exist. The name is what the agent reads it by.
        return .success(Attachment(block: .resource(uri: "phone:\(name)", text: text, blob: nil,
                                                    mimeType: type?.preferredMIMEType ?? "text/plain"),
                                   displayName: name, byteCount: text.utf8.count))
    }

    /// Why these cannot go together, or nil when they can.
    public static func totalRefusal(_ attachments: [Attachment]) -> String? {
        let total = attachments.reduce(0) { $0 + inlineBytes($1) }
        guard total > limit else { return nil }
        let size = ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file)
        return "From a phone, attachments can be 900 KB in all, and these are \(size). Remove one to send."
    }

    /// The Mac's reason, with a way out that exists on a phone. The Mac tells you to
    /// attach the file itself; a phone has no file itself to attach.
    public static func refusal(for attachment: Attachment, from capabilities: ACP.PromptCapabilities) -> String? {
        guard let said = attachment.refusal(from: capabilities) else { return nil }
        if attachment.block.requirement == .embeddedContext {
            return "This runtime does not take file contents, so this can only be attached on the Mac"
        }
        return said
    }

    private static func inlineBytes(_ attachment: Attachment) -> Int {
        switch attachment.block {
        case .image(let data, _, _), .audio(let data, _): return data.count
        case .resource(_, let text, let blob, _, _): return (text?.utf8.count ?? 0) + (blob?.count ?? 0)
        default: return 0
        }
    }

    /// No bigger than `longestEdge` on its longest side, the right way up, as a JPEG. A
    /// picture already smaller keeps its size.
    private static func shrunk(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: longestEdge,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return out as Data
    }
}
#endif
