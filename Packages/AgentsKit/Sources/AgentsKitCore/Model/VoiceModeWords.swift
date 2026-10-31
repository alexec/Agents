import Foundation

/// What voice mode says, and what its strip shows, when something does not go as asked
/// (the usability check of 2026-10-22b).
public enum VoiceModeWords {
    /// Said when the host did not take a prompt (#2441).
    public static let notSent = "Not sent. Say it again."

    /// Said when an answer by voice, to a question or a permission, did not go after
    /// "Sending: …" (#2442). The card is still on the screen.
    public static let answerNotSent = "The answer did not go. It is on the screen."

    /// The strip while an answer waits two seconds for a "no": "Sending File. Say no to
    /// stop." (#2443). `doing` is what was said, without its full stop.
    public static func sayNoToStop(_ doing: String) -> String {
        "\(doing). Say no to stop."
    }

    /// Told to VoiceOver as the strip comes and goes (#2446).
    public static let on = "Voice mode is on."
    public static let off = "Voice mode is off."
    /// Under the strip while VoiceOver is on: its speech is a voice the microphone can
    /// hear (#2446).
    public static let voiceOverNote = "VoiceOver is on, and the microphone can hear it. Headphones keep it out."

    /// Whether words heard are only VoiceOver saying `announced` again, through the
    /// microphone: every word heard is one of its words (#2446).
    public static func isEcho(_ heard: String, of announced: String) -> Bool {
        let heardWords = words(heard)
        guard !heardWords.isEmpty else { return false }
        let own = Set(words(announced))
        return heardWords.allSatisfy(own.contains)
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased()
            .split { !$0.isLetter && !$0.isNumber && $0 != "'" }
            .map(String.init)
    }

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
