import Foundation

/// Which conversation a half-typed prompt belongs to (025 US5).
///
/// An agent that exists, or the one about to be started — per project when the bar is a
/// project's, since what you were about to ask of one folder is not what you were about
/// to ask of the next.
public enum DraftKey: Hashable, Sendable {
    case agent(UUID)
    case newAgent(folder: URL?)

    /// Its name within a store. Stable, and one of two shapes, so a store can sweep its
    /// drafts without an index to keep in step. `DraftStore.defaultsKey(for:)` is where it
    /// actually lives.
    public var name: String {
        switch self {
        case .agent(let id):
            return Self.agentPrefix + id.uuidString
        case .newAgent(let folder):
            return Self.newAgentPrefix + (folder.map { Project.standardize($0).path } ?? "")
        }
    }

    static let agentPrefix = "agent."
    static let newAgentPrefix = "new."

    public static func == (lhs: DraftKey, rhs: DraftKey) -> Bool { lhs.name == rhs.name }
    public func hash(into hasher: inout Hasher) { hasher.combine(name) }
}

/// What the prompt bar was holding for a conversation, and had not sent.
///
/// The words and the attachments beside them, and nothing else. File mentions are not a
/// separate thing to keep: taking one puts the file on `attachments`, and what is left in
/// the bar while typing an "@" is a list of matches, which is a popup and not a draft.
public struct Draft: Codable, Hashable, Sendable {
    public var text: String
    public var attachments: [Attachment]
    /// For the thirty-day sweep. Moved on every save.
    public var editedAt: Date
    /// Something sent by value — a pasted picture — was too large to keep, and was left
    /// out. The window says so rather than restoring the draft silently incomplete.
    public var droppedInlineData: Bool

    public init(text: String, attachments: [Attachment] = [], editedAt: Date = Date(),
                droppedInlineData: Bool = false) {
        self.text = text
        self.attachments = attachments
        self.editedAt = editedAt
        self.droppedInlineData = droppedInlineData
    }

    /// Nothing typed and nothing staged: not a draft at all.
    public var isEmpty: Bool { text.isEmpty && attachments.isEmpty }

    /// The bytes held by value, which is what the cap is about. A file sent by reference
    /// is a path and costs nothing to keep.
    var inlineBytes: Int {
        attachments.reduce(0) { total, attachment in
            switch attachment.block {
            case .image(let data, _, _), .audio(let data, _): return total + data.count
            case .resource(_, let text, let blob, _, _):
                return total + (text?.utf8.count ?? 0) + (blob?.count ?? 0)
            default: return total
            }
        }
    }

    /// This draft with everything held by value taken out, and saying so.
    func withoutInlineData() -> Draft {
        var kept = self
        kept.attachments = attachments.filter {
            if case .resourceLink = $0.block { return true }
            return false
        }
        kept.droppedInlineData = true
        return kept
    }
}

/// The choices on a start form that has not been started.
///
/// One set for the whole app, because that is how many the app holds: they live on the
/// window's model, shared by every bar that can start an agent.
public struct StartDraft: Codable, Hashable, Sendable {
    public var cwd: URL?
    public var runtimeID: String?
    public var folders: [URL]
    public var servers: [MCPServer]
    public var chosen: [String: JSONValue]

    public init(cwd: URL? = nil, runtimeID: String? = nil, folders: [URL] = [],
                servers: [MCPServer] = [], chosen: [String: JSONValue] = [:]) {
        self.cwd = cwd
        self.runtimeID = runtimeID
        self.folders = folders
        self.servers = servers
        self.chosen = chosen
    }
}
