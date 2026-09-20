import Foundation

/// Whose prompt a `userMessage` was.
///
/// The app speaks in the person's turn exactly once — the single question it asks an
/// agent that ended without accounting for itself — and a person reading the
/// conversation has to be able to tell that apart from something they typed.
public enum PromptOrigin: String, Codable, Hashable, Sendable {
    case person
    /// The app asking on its own behalf. Today: the one question after a silent ending.
    case app
}

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
        /// The text is kept alongside the blocks so a record written by 001 still
        /// reads, and so the places that search rather than draw stay simple.
        ///
        /// `from` says whose prompt it was. Almost always the person's; the app sends
        /// one of its own after a turn that ended without saying how it went, and that
        /// one must never be drawn as though they typed it.
        case userMessage(String, blocks: [ContentBlock] = [], from: PromptOrigin = .person)
        case agentMessage(messageID: String?, text: String, blocks: [ContentBlock] = [])
        case agentThought(messageID: String?, text: String)
        case toolCall(ToolCall)
        case toolCallUpdate(ToolCall)
        case plan(JSONValue)
        case planUpdated(Plan)
        case usageRecorded(TurnUsage)
        case servedRequest(ServedRequest)
        case elicitationAsked(ElicitationRequest)
        case elicitationAnswered(id: UUID, summary: String)
        case compaction(status: String, summary: [ContentBlock])
        case permissionAsked(PermissionRequest)
        case permissionAnswered(optionID: String, optionName: String?)
        case optionChanged(id: String, value: JSONValue)
        case stateChanged(AgentState, reason: EndedReason?)

        /// The agent saying how the work went, at the end of it. Drawn at the foot of
        /// the conversation so the list and the transcript agree about the same turn.
        case workReported(WorkReport)

        /// Ours, not the agent's: "runtime starting", "session resumed", "the runtime
        /// could not give the session back". This is how the record stays honest
        /// across the gaps where there is no agent process at all.
        case runtimeNote(String)

        /// Something a newer version of this app wrote down, read by an older one.
        /// Kept whole and skipped when drawing, so a transcript is never lost to a
        /// kind that did not exist when this build was made.
        case unrecognised(JSONValue)
    }
}

extension TranscriptEntry {
    /// The blocks of a message, for the places that draw rather than read. A record
    /// written before 003 has only text, so it becomes one text block.
    public var blocks: [ContentBlock]? {
        switch kind {
        case .userMessage(let text, let blocks, _), .agentMessage(_, let text, let blocks):
            return blocks.isEmpty ? (text.isEmpty ? [] : [.text(text)]) : blocks
        case .compaction(_, let summary):
            return summary
        default:
            return nil
        }
    }

    /// The text an agent produced, for the places that want to read rather than render.
    public var text: String? {
        switch kind {
        case .userMessage(let t, _, _): return t
        case .agentMessage(_, let t, _): return t
        case .agentThought(_, let t): return t
        case .runtimeNote(let t): return t
        default: return nil
        }
    }

    /// Chunks of one message join up by the runtime's own message id.
    public var messageID: String? {
        switch kind {
        case .agentMessage(let id, _, _), .agentThought(let id, _): return id
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
        case (.agentMessage(let firstID, let text, let blocks),
              .agentMessage(let nextID, let more, let moreBlocks))
            where firstID == nextID:
            var joined = previous
            joined.kind = .agentMessage(messageID: firstID, text: text + more,
                                        blocks: blocks + moreBlocks)
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
