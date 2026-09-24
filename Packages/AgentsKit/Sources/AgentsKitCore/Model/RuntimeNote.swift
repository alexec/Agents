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

    /// Whether this note is about the moment it was written and nothing after.
    public static func isPassing(_ text: String) -> Bool {
        if text == pickedBackUp || text == stoppedWithDaemon { return true }
        return text.hasPrefix(startingPrefix) && text.hasSuffix(startingSuffix)
            && text.count > startingPrefix.count + startingSuffix.count
    }

    private static let startingPrefix = "Starting "
    private static let startingSuffix = "…"
}
