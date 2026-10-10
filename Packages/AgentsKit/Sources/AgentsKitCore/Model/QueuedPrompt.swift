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
    /// Whose prompt this is. The app queues one of its own after a turn that ended
    /// without saying how it went; everything else here is the person's.
    public var from: PromptOrigin
    /// Words for the runtime only, sent before `text` and never recorded as said: what
    /// the app owes the agent about this prompt, such as the wait it just cancelled
    /// (042 FR-013). The person's bubble stays their own words.
    public var preface: String?
    /// The agent that sent it, when `from` is `.agent` (#560).
    public var sender: MessageSender?
    /// How many messages between agents led here with no prompt from the person (#560):
    /// 1 for an agent's message sent in a turn the person started. The loop guard.
    public var hops: Int?

    public init(id: UUID = UUID(), text: String, attachments: [Attachment] = [],
                queuedAt: Date = Date(), from: PromptOrigin = .person, preface: String? = nil,
                sender: MessageSender? = nil, hops: Int? = nil) {
        self.id = id
        self.text = text
        self.attachments = attachments
        self.queuedAt = queuedAt
        self.from = from
        self.preface = preface
        self.sender = sender
        self.hops = hops
    }

    /// What goes to the runtime when its turn comes: the words, then what was
    /// attached. The same shape a prompt sent straight away takes.
    public var blocks: [ContentBlock] {
        [.text(text)] + attachments.map(\.block)
    }

    /// Several waiting prompts as the one that goes when the turn ends (#346): the
    /// words in the order they were queued, a blank line between them, with every
    /// attachment and every preface. Later words often correct earlier ones, and a turn
    /// each would answer each half-thought on its own, at a turn's cost each time.
    ///
    /// Keeps the first one's id, so a turn that fails puts back one prompt, not three.
    public static func merging(_ prompts: [QueuedPrompt]) -> QueuedPrompt? {
        guard var merged = prompts.first else { return nil }
        guard prompts.count > 1 else { return merged }
        merged.text = prompts.map(\.text).joined(separator: "\n\n")
        merged.attachments = prompts.flatMap(\.attachments)
        let prefaces = prompts.compactMap(\.preface)
        merged.preface = prefaces.isEmpty ? nil : prefaces.joined(separator: "\n\n")
        return merged
    }

}

extension Array where Element == QueuedPrompt {
    /// What the next turn takes from the head of the queue (#346): every prompt of the
    /// person's waiting there in a row, or the app's own prompt alone. The app's words
    /// are a turn of their own and are never folded into what somebody typed.
    public var nextTurn: [QueuedPrompt] {
        guard let first else { return [] }
        guard first.from == .person else { return [first] }
        return Array(prefix { $0.from == .person })
    }
}
