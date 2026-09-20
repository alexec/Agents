import Foundation

/// How an agent says the work went, at the end of it.
///
/// The protocol has one word for every turn that ends normally, and that word is
/// `endTurn`: *I am giving the turn back*. The app used to read that as *the work is
/// done*, which is a different sentence, and the gap between the two is where a
/// question written into the transcript and then abandoned used to hide under a tick.
///
/// So this is not derived — the agent is the only thing that knows, and it says. Five
/// values, and the set is total over *what does the person do next* rather than over
/// *what happened*. That is why there is no `failed` distinct from `stuck`, and no
/// `succeeded with warnings`: a warning is either something a person must act on, in
/// which case it is `partlyDone` or `stuck`, or it is not, in which case it belongs in
/// the agent's message and nowhere else.
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
    /// Some of it done; the rest needs a decision that is not the agent's.
    case partlyDone = "partly_done"
    /// Could not do it, and says why.
    case stuck

    /// Whether somebody has to do something about this, or whether it is settled.
    ///
    /// The whole of the grouping rule: the three that are true here earn the app's one
    /// colour and the one group a person actually reads. Named after
    /// `WorkflowRefusal.needsAPerson`, which answers the same question about a workflow
    /// and earns colour on the same page for the same reason.
    public var needsAPerson: Bool {
        switch self {
        case .needsAnswer, .partlyDone, .stuck: return true
        case .done, .nothingToDo: return false
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
        case .partlyDone: return "Partly done"
        case .stuck: return "Stuck"
        }
    }

    /// What an agent sent, if it is one of the five.
    ///
    /// An outcome this build does not know is a report that never arrived, not a
    /// report rounded to the nearest thing we recognise. A newer runtime sending a
    /// sixth word must not have it read as `done` — that is exactly the unearned tick
    /// this feature exists to remove.
    public init?(wire: String) {
        self.init(rawValue: wire.trimmingCharacters(in: .whitespacesAndNewlines))
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
    /// and cut rather than refused when it runs long.
    public var message: String
    public var at: Date

    /// The most of the agent's message the app keeps. Long enough for two sentences
    /// written for somebody who has not read the conversation, and short enough that
    /// the record does not become a second transcript.
    public static let messageLimit = 1_000

    public init(outcome: WorkOutcome, message: String, at: Date) {
        self.outcome = outcome
        self.message = message
        self.at = at
    }

    /// What an agent sent, made fit to keep.
    ///
    /// Empty after trimming is refused, because a status with no words is what the app
    /// already had. Too long is cut rather than refused, in the manner of
    /// `SuggestedPrompt.init(wire:)` — losing the outcome over one long sentence would
    /// be worse than trimming it.
    public init?(outcome: WorkOutcome, wire message: String, at: Date = Date()) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        self.init(outcome: outcome, message: String(trimmed.prefix(Self.messageLimit)), at: at)
    }
}
