import Foundation

/// Something the user put on a prompt before sending it.
///
/// A picture, a reference to a file, or the contents of one. The block is what goes to
/// the runtime; the rest is what the composer needs to draw it.
public struct Attachment: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var block: ContentBlock
    public var displayName: String
    public var byteCount: Int?

    public init(id: UUID = UUID(), block: ContentBlock, displayName: String, byteCount: Int? = nil) {
        self.id = id
        self.block = block
        self.displayName = displayName
        self.byteCount = byteCount
    }

    /// A file on disk, sent by reference. Baseline in the protocol, so this is the one
    /// attachment every runtime takes.
    public static func file(_ url: URL) -> Attachment {
        let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        return Attachment(block: .resourceLink(uri: url.absoluteString,
                                               name: url.lastPathComponent,
                                               mimeType: nil,
                                               size: size ?? nil),
                          displayName: url.lastPathComponent,
                          byteCount: size ?? nil)
    }

    /// A picture, sent by value.
    public static func image(_ data: Data, mimeType: String, name: String) -> Attachment {
        Attachment(block: .image(data: data, mimeType: mimeType, uri: nil),
                   displayName: name,
                   byteCount: data.count)
    }

    /// A file's contents, sent inline, for a runtime that takes embedded context.
    public static func contents(of url: URL) throws -> Attachment {
        let text = try String(contentsOf: url, encoding: .utf8)
        return Attachment(block: .resource(uri: url.absoluteString,
                                           text: text,
                                           blob: nil,
                                           mimeType: "text/plain"),
                          displayName: url.lastPathComponent,
                          byteCount: text.utf8.count)
    }

    /// Why this runtime will not take it, said before the prompt is sent rather than
    /// after. Nil means it will.
    public func refusal(from capabilities: ACP.PromptCapabilities) -> String? {
        guard !capabilities.allows(block.requirement) else { return nil }
        switch block.requirement {
        case .image: return "This runtime does not take pictures"
        case .audio: return "This runtime does not take audio"
        case .embeddedContext: return "This runtime does not take file contents. Attach the file itself"
        case nil: return nil
        }
    }
}
