import Foundation

/// One line of an agent's life, appended and never rewritten.
///
/// Entries are appended as they arrive rather than at the end of a turn, so a daemon
/// that dies mid-turn still leaves a record that matches what happened.
public struct TranscriptEntry: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var at: Date
    public var kind: Kind

    public init(id: UUID = UUID(), at: Date = Date(), kind: Kind) {
        self.id = id
        self.at = at
        self.kind = kind
    }

    public enum Kind: Codable, Hashable, Sendable {
        case userMessage(String)
        case agentMessage(messageID: String?, text: String)
        case agentThought(messageID: String?, text: String)
        case toolCall(ToolCall)
        case toolCallUpdate(ToolCall)
        case plan(JSONValue)
        case permissionAsked(PermissionRequest)
        case permissionAnswered(optionID: String, optionName: String?)
        case optionChanged(id: String, value: JSONValue)
        case stateChanged(AgentState, reason: EndedReason?)

        /// Ours, not the agent's: "runtime starting", "session resumed", "the runtime
        /// could not give the session back". This is how the record stays honest
        /// across the gaps where there is no agent process at all.
        case runtimeNote(String)
    }
}

extension TranscriptEntry {
    /// The text an agent produced, for the places that want to read rather than render.
    public var text: String? {
        switch kind {
        case .userMessage(let t): return t
        case .agentMessage(_, let t): return t
        case .agentThought(_, let t): return t
        case .runtimeNote(let t): return t
        default: return nil
        }
    }

    /// Chunks of one message join up by the runtime's own message id.
    public var messageID: String? {
        switch kind {
        case .agentMessage(let id, _), .agentThought(let id, _): return id
        default: return nil
        }
    }
}

extension TranscriptEntry {
    /// Join the chunks of one message back into one message.
    ///
    /// A runtime streams a sentence as a dozen updates, and the record keeps every one
    /// of them because the record is what happened. What a person reads is the
    /// sentence, so chunks that share the runtime's message id are joined here, and
    /// consecutive chunks with no id are treated as one message for the same reason.
    public static func coalesced(_ entries: [TranscriptEntry]) -> [TranscriptEntry] {
        var result: [TranscriptEntry] = []
        for entry in entries {
            guard let joined = join(entry, onto: result.last) else {
                result.append(entry)
                continue
            }
            result[result.count - 1] = joined
        }
        return result
    }

    private static func join(_ entry: TranscriptEntry, onto previous: TranscriptEntry?) -> TranscriptEntry? {
        guard let previous else { return nil }
        switch (previous.kind, entry.kind) {
        case (.agentMessage(let firstID, let text), .agentMessage(let nextID, let more))
            where firstID == nextID:
            var joined = previous
            joined.kind = .agentMessage(messageID: firstID, text: text + more)
            return joined
        case (.agentThought(let firstID, let text), .agentThought(let nextID, let more))
            where firstID == nextID:
            var joined = previous
            joined.kind = .agentThought(messageID: firstID, text: text + more)
            return joined
        default:
            return nil
        }
    }
}
