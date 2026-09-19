import Foundation

/// Something typed while the agent was still working, waiting its turn.
///
/// The queue is the daemon's, and deliberately not the runtime's. ACP has no way to
/// say "take this when you are done", and a `session/prompt` sent while a turn is in
/// flight is answered differently by each of them: one holds it, one refuses it, one
/// starts a second turn over the top of the first. Holding it here makes all three
/// behave the same way, and it is the only version that is still true after the
/// window closes: the queue is on the agent's record, so it survives the daemon
/// going idle and coming back.
public struct QueuedPrompt: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var text: String
    public var attachments: [Attachment]
    public var queuedAt: Date

    public init(id: UUID = UUID(), text: String, attachments: [Attachment] = [],
                queuedAt: Date = Date()) {
        self.id = id
        self.text = text
        self.attachments = attachments
        self.queuedAt = queuedAt
    }

    /// What goes to the runtime when its turn comes: the words, then what was
    /// attached. The same shape a prompt sent straight away takes.
    public var blocks: [ContentBlock] {
        [.text(text)] + attachments.map(\.block)
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        text = try c.decode(String.self, forKey: .text)
        attachments = try c.decodeIfPresent([Attachment].self, forKey: .attachments) ?? []
        queuedAt = try c.decodeIfPresent(Date.self, forKey: .queuedAt) ?? Date()
    }
}
