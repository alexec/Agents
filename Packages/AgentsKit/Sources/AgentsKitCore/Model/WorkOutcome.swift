import Foundation

/// How an agent says the work went, at the end of it.
///
/// The protocol has one word for every turn that ends normally, and that word is
/// `endTurn`: *I am giving the turn back*. The app used to read that as *the work is
/// done*, which is a different sentence, and the gap between the two is where a
/// question written into the transcript and then abandoned used to hide under a tick.
///
/// Only a question needs the person (#1916): the app never assumes an agent needs them
/// unless it asks. An agent that waits on other agents or a time is `waiting`. So there
/// is no `stuck`, `partlyDone` or `blocked` any more; an old record's (finish_turn's,
/// before #494, or a wait before #1915) reads as `done`, as the wire's `x-fallback` does
/// (#2981).
///
/// The wording lives here and not in any view, for the reason `EndedReason.summary`
/// gives: the phone and the window have to say the same words about the same agent,
/// and two copies of a switch are two chances to drift.
public enum WorkOutcome: String, Codable, Hashable, Sendable, CaseIterable {
    /// Asked for, and done. Nothing is left for anyone.
    case done
    /// Looked, and there was nothing that needed doing.
    case nothingToDo = "nothing_to_do"
    /// Cannot go further until a person answers something.
    case needsAnswer = "needs_answer"
    /// Waiting on something other than the person: agents it started, another agent's
    /// change, a CI run (039, #1915). Nobody has to do anything — the app resumes it when
    /// what it named has finished, or at the time it asked — so it is not `needsAPerson`,
    /// and it has a group of its own rather than a place under Needs attention.
    case waiting

    /// Whether somebody has to do something about this, or whether it is settled.
    ///
    /// The whole of the grouping rule: the three that are true here earn the app's one
    /// colour and the one group a person actually reads. Named after
    /// `WorkflowRefusal.needsAPerson`, which answers the same question about a workflow
    /// and earns colour on the same page for the same reason.
    public var needsAPerson: Bool {
        switch self {
        case .needsAnswer: return true
        case .done, .nothingToDo, .waiting: return false
        }
    }

    /// What the app says when it has to speak for itself: the icon's accessibility
    /// label, the tooltip, the label above the agent's own sentence in the transcript.
    ///
    /// Never what a row shows in place of the message. The agent's words win there
    /// (FR-013) — this is the app's summary of them, for the places that have no room
    /// for a sentence.
    public var heading: String {
        switch self {
        case .done: return "Complete"
        case .nothingToDo: return "Nothing to do"
        case .needsAnswer: return "Waiting on your answer"
        case .waiting: return "Waiting"
        }
    }

    /// What an agent sent, if it is one of the six.
    ///
    /// An outcome this build does not know is a report that never arrived, not a
    /// report rounded to the nearest thing we recognise. A newer runtime sending a
    /// sixth word must not have it read as `done` — that is exactly the unearned tick
    /// this feature exists to remove.
    public init?(wire: String) {
        self.init(rawValue: wire.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The words an old record may hold that read as `done` (#1916, #2981): finish_turn's,
    /// and a wait recorded before #1915.
    static let readAsDone: Set<String> = ["stuck", "partly_done", "blocked"]

    public init(from decoder: Decoder) throws {
        let word = try decoder.singleValueContainer().decode(String.self)
        if let known = WorkOutcome(rawValue: word) {
            self = known
        } else if Self.readAsDone.contains(word) {
            self = .done
        } else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "unknown outcome \(word)"))
        }
    }
}

/// One agent's account of how a turn's work went: the outcome, the words, and when.
///
/// Held against the agent rather than the turn, and replaced in place by a later report
/// in the same turn — an agent that reports twice has changed its mind, and the earlier
/// one is not history worth keeping. Cleared when the person's next prompt goes, in the
/// same way and for the same reason as a suggested prompt: it is an account of the turn
/// it came from, and a stale one is worse than none.
public struct WorkReport: Codable, Hashable, Sendable {
    public var outcome: WorkOutcome
    /// The agent's own sentence, which is what the row shows. Trimmed, never empty,
    /// and refused rather than cut when it runs long. A record written before the
    /// limit came down keeps its longer words: the limit is on what arrives.
    public var message: String
    public var at: Date
    /// What a `waiting` report waits on, and whether that has cleared (039). Nil on
    /// every other outcome, and on a waiting report that named nothing and gave no time.
    public var block: Block?

    /// The most an agent's message may be (#184). The row it is read on gives it one
    /// line, so the guidance asks for under about 100 characters; this is the room
    /// around that, and a message past it is sent back to be rewritten rather than
    /// cut, which teaches the agent where cutting only hides it.
    public static let messageLimit = 200

    /// Whether these words, as an agent sent them, are too long to keep.
    public static func isTooLong(_ message: String) -> Bool {
        message.trimmingCharacters(in: .whitespacesAndNewlines).count > messageLimit
    }

    /// What an agent is told when its message is too long, by either door. For
    /// needs_answer the message is the question, and a longer one belongs on the
    /// question card, which can carry as much as it needs to.
    public static func tooLong(_ outcome: WorkOutcome?) -> String {
        guard outcome == .needsAnswer else {
            return """
                Nothing was recorded: keep it to one sentence under \(messageLimit) characters — \
                what happened and what it means for the person, with no mechanism or file \
                names. The detail belongs in your reply. Call this again with a shorter one.
                """
        }
        return """
            Nothing was recorded: keep the question to one sentence under \(messageLimit) \
            characters. If it needs more than that, ask it with ask_question, which shows the \
            person a question card and waits for the answer; otherwise call this again \
            with a shorter one.
            """
    }

    public init(outcome: WorkOutcome, message: String, at: Date, block: Block? = nil) {
        self.outcome = outcome
        self.message = message
        self.at = at
        self.block = block
    }

    private enum CodingKeys: String, CodingKey { case outcome, message, at, block }

    /// Thrown for an outcome this build does not know, so the record around the report
    /// can drop the report and keep everything else (039, research R8). The synthesized
    /// decoder threw a plain `dataCorrupted` here, which took the whole agent with it.
    public struct UnknownOutcome: Error {
        public let word: String
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let word = try c.decode(String.self, forKey: .outcome)
        // An old record's stuck, partly_done or blocked reads as done (#1916, #2981).
        guard let outcome = WorkOutcome(rawValue: word)
                ?? (WorkOutcome.readAsDone.contains(word) ? .done : nil)
        else { throw UnknownOutcome(word: word) }
        self.outcome = outcome
        message = try c.decode(String.self, forKey: .message)
        at = try c.decode(Date.self, forKey: .at)
        block = try c.decodeIfPresent(Block.self, forKey: .block)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(outcome, forKey: .outcome)
        try c.encode(message, forKey: .message)
        try c.encode(at, forKey: .at)
        try c.encodeIfPresent(block, forKey: .block)
    }

    /// What an agent sent, made fit to keep.
    ///
    /// Empty after trimming is refused, because a status with no words is what the app
    /// already had. Too long is refused too (#184), never cut: a message cut mid-word
    /// says less than the agent meant, and the agent never learns to say less. Callers
    /// check `isTooLong` first, to tell the agent which of the two it was.
    public init?(outcome: WorkOutcome, wire message: String, at: Date = Date(), block: Block? = nil) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= Self.messageLimit else { return nil }
        self.init(outcome: outcome, message: trimmed, at: at, block: block)
    }

    /// A waiting report whose block has not yet cleared: under Waiting when the app will
    /// resume it (`resumesByItself`); one that will not (an old record's) is done (#1916).
    public var isOpenBlock: Bool {
        outcome == .waiting && block?.isOpen != false
    }

    /// An open block the app will clear by itself: it names agents to wait for, or a
    /// time to check again. The rest — a block that named nothing and gave no time, which
    /// only an old record has — is done (#1916).
    public var resumesByItself: Bool {
        guard isOpenBlock, let block else { return false }
        return !block.waits.isEmpty || block.checkAgainAt != nil
    }
}
