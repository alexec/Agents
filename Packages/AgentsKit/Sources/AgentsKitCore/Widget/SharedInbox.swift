// Not on Linux: the server build of agentsd has no app groups and no share sheet (037).
#if canImport(Darwin)
import Foundation
import UniformTypeIdentifiers

/// What the share sheet handed to Agents (#4915), waiting for New session to take it.
///
/// Words (selected text, a link) go into the prompt; pictures and files go as attachments,
/// by the paperclip's rules (`PhoneAttachment`); what the paperclip would refuse is kept as
/// its refusal, so New session says it in the paperclip's words. Several shares before the
/// Remote opens all wait here, in the order they were shared.
public struct SharedItems: Codable, Equatable, Sendable {
    public var texts: [String]
    public var attachments: [Attachment]
    public var refusals: [String]

    public init(texts: [String] = [], attachments: [Attachment] = [], refusals: [String] = []) {
        self.texts = texts
        self.attachments = attachments
        self.refusals = refusals
    }

    public var isEmpty: Bool { texts.isEmpty && attachments.isEmpty && refusals.isEmpty }

    /// Words, or a link, shared. Blank ones are nothing.
    public mutating func add(text: String) {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return }
        texts.append(words)
    }

    /// A picture shared from Photos, a screenshot or a page, shrunk as the paperclip does.
    public mutating func add(picture data: Data, name: String) {
        take(PhoneAttachment.picture(data, name: name))
    }

    /// Why a file of this size is refused before it is read, kept as a refusal; or nil, when
    /// it may be read (#930).
    public mutating func refuse(name: String, size: Int, type: UTType?) -> Bool {
        guard let refused = PhoneAttachment.sizeRefusal(name: name, size: size, type: type) else { return false }
        refusals.append(refused.sentence)
        return true
    }

    /// A file shared: a picture as a picture, text as its contents, anything else refused.
    public mutating func add(file data: Data, name: String, type: UTType?) {
        take(PhoneAttachment.file(data, name: name, type: type))
    }

    /// Something shared that could not be read at all.
    public mutating func unreadable(_ name: String) {
        refusals.append("\(name) could not be read.")
    }

    /// These, after those already waiting.
    public mutating func append(_ other: SharedItems) {
        texts += other.texts
        attachments += other.attachments
        refusals += other.refusals
    }

    /// The prompt's words with what was shared after them, a blank line between each, as a
    /// quote is given back to a prompt.
    public func text(after typed: String) -> String {
        let kept = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        return ([kept].filter { !$0.isEmpty } + texts).joined(separator: "\n\n")
    }

    /// The paperclip's words for what was refused, one sentence each, or nil.
    public var note: String? { refusals.isEmpty ? nil : refusals.joined(separator: " ") }

    private mutating func take(_ result: Result<Attachment, PhoneAttachment.Refusal>) {
        switch result {
        case .success(let attachment): attachments.append(attachment)
        case .failure(let refused): refusals.append(refused.sentence)
        }
    }
}

/// Where the share extension leaves `SharedItems` for the Remote (#4915): one file in the
/// Remote's app group, which the extension adds to and the Remote takes whole.
///
/// The group's `Library/Application Support`, not `Caches`: what was shared waits there until
/// the person opens the Remote, which may be days, and the system may empty a cache.
/// Both sides go through a file coordinator, so a share that lands while the Remote takes
/// is either taken or left for the next time, never lost.
public enum SharedInbox {
    public static let fileName = "shared-inbox.json"

    /// The link the extension opens the Remote with. The Remote also looks each time it
    /// comes to the front, so the link is only a shortcut.
    public static var startURL: URL { AttentionLink.start.url }

    public static var container: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AttentionSnapshotStore.appGroup)?
            .appendingPathComponent("Library/Application Support", isDirectory: true)
    }

    public static func url(in container: URL? = nil) -> URL? {
        (container ?? SharedInbox.container)?.appendingPathComponent(fileName)
    }

    /// Put these after whatever is already waiting. Whether they were written.
    @discardableResult
    public static func add(_ items: SharedItems, into container: URL? = nil) -> Bool {
        guard !items.isEmpty, let url = url(in: container) else { return false }
        var written = false
        coordinate(url, merging: true) { url in
            var waiting = read(url) ?? SharedItems()
            waiting.append(items)
            guard let data = try? JSONEncoder().encode(waiting) else { return }
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
                written = true
            } catch {}
        }
        return written
    }

    /// Whether anything waits, without taking it. Cheap: asked each time the Remote comes to
    /// the front.
    public static func hasItems(in container: URL? = nil) -> Bool {
        guard let url = url(in: container) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// Everything waiting, in the order it was shared, and the file gone; nil when nothing
    /// waits.
    public static func take(from container: URL? = nil) -> SharedItems? {
        guard let url = url(in: container) else { return nil }
        var taken: SharedItems?
        coordinate(url, merging: false) { url in
            taken = read(url)
            try? FileManager.default.removeItem(at: url)
        }
        return taken.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The pairing was forgotten (#3670): nothing shared waits for the next one.
    public static func clear(in container: URL? = nil) {
        guard let url = url(in: container) else { return }
        coordinate(url, merging: false) { try? FileManager.default.removeItem(at: $0) }
    }

    private static func read(_ url: URL) -> SharedItems? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SharedItems.self, from: data)
    }

    private static func coordinate(_ url: URL, merging: Bool, _ body: (URL) -> Void) {
        var error: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: merging ? .forMerging : .forDeleting,
                                       error: &error, byAccessor: body)
    }
}
#endif
