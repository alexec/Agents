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
    /// The subagent this was said or done by, when it was not the agent itself (057).
    ///
    /// A field rather than a kind of its own, so a subagent's edit is still an edit to
    /// every place that reads edits (Changes, the files it touched). The chat leaves
    /// these out, and the subagent's own page shows only these. Absent on everything
    /// written before, which is the agent's.
    public var subagentID: String?

    public init(id: UUID = UUID(), at: Date = Date(), kind: Kind, subagentID: String? = nil) {
        self.id = id
        self.at = at
        self.kind = kind
        self.subagentID = subagentID
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
        case planUpdated(Plan)
        case usageRecorded(TurnUsage)
        case servedRequest(ServedRequest)
        case elicitationAsked(ElicitationRequest)
        /// `answers` is what was said, question by question, when the form was
        /// answered; empty for a decline, a withdrawal, and every record written before.
        case elicitationAnswered(id: UUID, summary: String, answers: [ElicitationAnswer] = [])
        case compaction(status: String, summary: [ContentBlock])
        /// The runtime telling the person something beside the reply (ACP `notice`).
        case notice(SessionNotice)
        case permissionAsked(PermissionRequest)
        case permissionAnswered(optionID: String, optionName: String?)
        case optionChanged(id: String, value: JSONValue)
        case stateChanged(AgentState, reason: EndedReason?)

        /// Something started running in the background, or stopped running there
        /// (057). Written when it starts and when it ends, as it stood then; the list
        /// over the prompt is `Agent.background`, which is always current.
        case background(BackgroundItem)

        /// The agent saying how the work went, at the end of it. Drawn at the foot of
        /// the conversation so the list and the transcript agree about the same turn.
        case workReported(WorkReport)

        /// Ours, not the agent's: "runtime starting", "session resumed", "the runtime
        /// could not give the session back". This is how the record stays honest
        /// across the gaps where there is no agent process at all.
        case runtimeNote(String)

        /// A chat carried on with another runtime (052): drawn as the tinted note, with
        /// what it carried and what it did not. An older build reads it as unrecognised.
        /// Nothing writes it since 065; read because 052 is after the #58 cut-off (051).
        case poolSwitch(SwitchRecord)
        /// A runtime's sandbox could not be set up (064). The card, until answered.
        case sandboxFailure(SandboxFailureRecord)

        /// What the new runtime was handed, built from this record (052, R4). Drawn
        /// folded under the switch note, never as the person's words.
        case handoff(markdown: String, characters: Int)

        /// The settings a switch chose, changed afterwards from its note (052, FR-029).
        case settingsChanged(SwitchRecord)

        /// A call of a tool that has a view (#187): drawn as the view, where the call began.
        /// Written by the daemon as the call arrives and again as it ends, under one id.
        case appView(AppViewCall)

        /// Something a newer version of this app wrote down, read by an older one.
        /// Kept whole and skipped when drawing, so a transcript is never lost to a
        /// kind that did not exist when this build was made.
        case unrecognised(JSONValue)
    }
}

extension TranscriptEntry.Kind {
    /// A piece of an agent's reply that shows nothing at all: every character in it is
    /// a zero-width format character, like U+200B.
    ///
    /// Opus 5.5 answers "say nothing" this way. Asked to report a silent turn and say
    /// nothing else, it calls finish_turn and then writes a zero-width space — once in
    /// a while not one but tens of thousands, streamed as one chunk each, which filled
    /// a transcript with 2,800 entries in two minutes and drew as an empty bubble.
    ///
    /// Only format characters, and not whitespace: a chunk of `\n\n` inside a real
    /// reply is the break between two paragraphs, and dropping it would glue them.
    public var isInvisibleAgentText: Bool {
        guard case .agentMessage(_, let text, let blocks) = self, blocks.isEmpty, !text.isEmpty else {
            return false
        }
        return text.unicodeScalars.allSatisfy { $0.properties.generalCategory == .format }
    }
}

extension TranscriptEntry {
    /// The blocks of a message, for the places that draw rather than read. A message of
    /// plain text is kept as text alone, with no blocks, so it becomes one text block.
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

    static func join(_ entry: TranscriptEntry, onto previous: TranscriptEntry?) -> TranscriptEntry? {
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
