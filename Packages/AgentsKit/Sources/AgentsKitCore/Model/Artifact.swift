import Foundation

/// Something named in the conversation rather than merely said: a file attached to a
/// prompt, or one an agent handed back.
///
/// FR-046, answered narrow: an artifact is a `resource_link` block or an embedded
/// `resource` block, and nothing else. A file a tool call merely touched is not one.
/// That question has a better home in the files pane, which marks what the agent
/// changed, and putting it in both would make the sidebar say the same thing twice.
///
/// Both directions count. No runtime installed here hands anything over yet, so an
/// attachment is in practice the only artifact there is, and a file is worth finding
/// again whichever way it went. The pane is named for the exchange, not for the
/// agent's half of it.
public struct Artifact: Sendable, Hashable, Identifiable {
    public var id: String
    public var uri: String
    public var name: String
    public var mimeType: String?
    public var size: Int?
    public var arrivedAt: Date
    /// The message it came from, so the pane can get back to it (FR-042).
    public var entryID: UUID
    /// True for an embedded `resource`, which carries its own text or bytes and can be
    /// read without going anywhere.
    public var embedded: Bool
    /// The text of an embedded resource, when it brought any.
    public var text: String?

    public init(id: String, uri: String, name: String, mimeType: String? = nil,
                size: Int? = nil, arrivedAt: Date, entryID: UUID,
                embedded: Bool = false, text: String? = nil) {
        self.id = id
        self.uri = uri
        self.name = name
        self.mimeType = mimeType
        self.size = size
        self.arrivedAt = arrivedAt
        self.entryID = entryID
        self.embedded = embedded
        self.text = text
    }

    /// Where it opens: the files pane, the browser, or in place.
    public enum Destination: Sendable, Equatable {
        case file(URL)
        case web(URL)
        case inPlace
        case nowhere
    }

    public var destination: Destination {
        if embedded, text != nil { return .inPlace }
        guard let url = URL(string: uri) else { return .nowhere }
        switch url.scheme?.lowercased() {
        case "file": return .file(url)
        case "http", "https": return .web(url)
        default: return .nowhere
        }
    }

    /// Whether the thing it points at is still there. Only answerable for a file; a
    /// web address is not something to check by fetching it.
    public var isMissing: Bool {
        guard case .file(let url) = destination else { return false }
        return !FileManager.default.fileExists(atPath: url.path)
    }
}

extension Artifact {
    /// Everything exchanged, newest first: sent and handed back alike.
    ///
    /// A pure function over transcript entries, so it is derived on read and never
    /// stored. That is what makes FR-044 free: artifacts last exactly as long as the
    /// transcript does, across restarts and for a stopped or archived agent, because
    /// there is nothing separate to keep in step.
    public static func all(in entries: some Sequence<TranscriptEntry>) -> [Artifact] {
        var found: [Artifact] = []
        for entry in entries {
            guard let blocks = entry.blocks else { continue }
            for (index, block) in blocks.enumerated() {
                guard let artifact = Artifact(block: block,
                                              index: index,
                                              at: entry.at,
                                              entryID: entry.id) else { continue }
                found.append(artifact)
            }
        }
        return found.sorted { $0.arrivedAt > $1.arrivedAt }
    }

    init?(block: ContentBlock, index: Int, at: Date, entryID: UUID) {
        // A block marked for someone other than the person at the screen is not the
        // user's artifact. No annotations at all means it is.
        if let annotations = block.annotations, !annotations.isForUser { return nil }

        switch block {
        case .resourceLink(let uri, let name, let mimeType, let size, _):
            self.init(id: "\(entryID.uuidString):\(index)",
                      uri: uri,
                      name: name,
                      mimeType: mimeType,
                      size: size,
                      arrivedAt: at,
                      entryID: entryID)
        case .resource(let uri, let text, let blob, let mimeType, _):
            self.init(id: "\(entryID.uuidString):\(index)",
                      uri: uri,
                      name: URL(string: uri)?.lastPathComponent ?? uri,
                      mimeType: mimeType,
                      size: blob?.count ?? text?.utf8.count,
                      arrivedAt: at,
                      entryID: entryID,
                      embedded: true,
                      text: text)
        default:
            // Everything else, including a tool call's locations and diffs, which are
            // the files pane's business and not this pane's (FR-046).
            return nil
        }
    }
}
