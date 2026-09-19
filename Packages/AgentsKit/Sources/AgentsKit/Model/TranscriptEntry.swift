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
