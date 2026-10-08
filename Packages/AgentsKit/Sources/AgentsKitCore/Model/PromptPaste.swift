// Not on Linux: the server build of agentsd has no pasteboard and no UniformTypeIdentifiers (037).
#if canImport(UniformTypeIdentifiers)
import Foundation
import UniformTypeIdentifiers

/// What one thing on the clipboard is, pasted into the prompt (#396).
///
/// A pasteboard item comes in several representations of the same thing. A file copied
/// in Finder is a file, whatever icon comes with it. Words copied from a document often
/// come with a picture of themselves, so an item with words is words, and goes into the
/// field as any paste's would. Only an item that is a picture and nothing else attaches
/// as a picture: a screenshot, or a picture copied from a page or Preview.
public enum PromptPaste: Equatable, Sendable {
    case file
    case picture(UTType)
    case words
    case nothing

    /// The pictures the paperclip and a drag attach, most specific first; a picture of any
    /// other kind after them.
    public static let pictureTypes: [UTType] = [.png, .jpeg, .gif, .heic, .webP, .tiff]

    /// What an item with these type identifiers is.
    public static func kind(of identifiers: [String]) -> PromptPaste {
        let types = identifiers.compactMap { UTType($0) }
        if types.contains(where: { $0.conforms(to: .fileURL) }) { return .file }
        if types.contains(where: { $0.conforms(to: .plainText) }) { return .words }
        if let known = pictureTypes.first(where: types.contains) { return .picture(known) }
        if let other = types.first(where: { $0.conforms(to: .image) }) { return .picture(other) }
        return .nothing
    }

    /// The MIME type a picture of this kind goes as.
    public static func mimeType(for picture: UTType) -> String {
        picture.preferredMIMEType ?? "application/octet-stream"
    }
}
#endif
