import Foundation

/// What voice mode says, and what its strip shows, when something does not go as asked
/// (the usability check of 2026-10-22b).
public enum VoiceModeWords {
    /// Said when the host did not take a prompt (#2441).
    public static let notSent = "Not sent. Say it again."

    /// Said when an answer by voice, to a question or a permission, did not go after
    /// "Sending: …" (#2442). The card is still on the screen.
    public static let answerNotSent = "The answer did not go. It is on the screen."

    /// Dictation's problem, in voice mode's alert, which is titled "Voice mode": "Voice mode
    /// needs the microphone.", not "Dictation needs the microphone." (#2444).
    public static func problem(dictation message: String) -> String {
        message.hasPrefix("Dictation ") ? "Voice mode " + message.dropFirst("Dictation ".count) : message
    }

    /// The strip, after a prompt did not go: the words stay on the screen until the next
    /// words are heard (#2441).
    public static func unsent(_ words: String) -> String {
        "Not sent: “\(words)”. Say it again."
    }
}
