import Foundation

/// What voice mode says, and what its strip shows, when something does not go as asked
/// (the usability check of 2026-10-22b).
public enum VoiceModeWords {
    /// Said when the host did not take a prompt (#2441).
    public static let notSent = "Not sent. Say it again."

    /// The strip, after a prompt did not go: the words stay on the screen until the next
    /// words are heard (#2441).
    public static func unsent(_ words: String) -> String {
        "Not sent: “\(words)”. Say it again."
    }
}
