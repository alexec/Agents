import Foundation

/// The runtime notes that are about a moment rather than about what happened.
///
/// Most of what the daemon writes as a `runtimeNote` is history: the conversation was
/// branched from another, the runtime lost its copy, what you queued could not be
/// sent. Those stay on the page because they explain the page. These three do not:
/// each says only where things stand right now, and the next line makes it untrue.
/// "Starting Claude…" is over once Claude has started; "picked the conversation back
/// up" is old news once the conversation has moved on. They are built here, once, so
/// the chat can tell them from the notes that are worth keeping without guessing at
/// the wording.
public enum RuntimeNote {
    /// The daemon is bringing a runtime process up behind an existing agent.
    public static func starting(_ runtimeName: String) -> String {
        "\(startingPrefix)\(runtimeName)\(startingSuffix)"
    }

    /// The runtime took the conversation back after a restart.
    public static let pickedBackUp = "Picked the conversation back up."

    /// Why an agent stopped when the daemon did. Followed by the ending it explains,
    /// and then by the agent being picked back up, which is when it stops mattering.
    public static let stoppedWithDaemon = "This agent was working when the daemon stopped, so it stopped too."

    /// A question the agent asked that ended without an answer, because its runtime
    /// exited, the person stopped it, or the daemon went.
    ///
    /// **Not passing, and must never be added to `isPassing`.** Every note above is true
    /// of the moment it was written and false a line later, which is what earns them
    /// being dropped once something follows. This one is permanent: it is the difference,
    /// for somebody reading back in six months, between a question that was answered and
    /// one that was never going to be. It is always followed immediately by the ending it
    /// belongs to, so a passing note here would be a note that is never once drawn.
    ///
    /// Written after the `permissionAsked` or `elicitationAsked` entry it closes and
    /// before the `stateChanged` entry recording the ending. Position is what says which
    /// question; the line does not name one, because the three places that write it do
    /// not all know (after a restart the pending questions died with the last daemon —
    /// what is left is the agent's state).
    public static let questionWentUnanswered = "Nobody answered this question before the agent ended."

    /// Whether this note is about the moment it was written and nothing after.
    ///
    /// `questionWentUnanswered` is deliberately absent. See the note on it.
    public static func isPassing(_ text: String) -> Bool {
        if text == pickedBackUp || text == stoppedWithDaemon { return true }
        return text.hasPrefix(startingPrefix) && text.hasSuffix(startingSuffix)
            && text.count > startingPrefix.count + startingSuffix.count
    }

    private static let startingPrefix = "Starting "
    private static let startingSuffix = "…"
}
