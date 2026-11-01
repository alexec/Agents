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

    /// What `transcript` heard after `sent`, the words that already went (#3163). The
    /// recognizer can revise what it heard while a prompt is sent ("fix the bug" becomes
    /// "Fix the bug."), so the two are compared on letters and numbers only, without case
    /// or accents. When the transcript does not start with the words sent even so, as many
    /// words as were sent are left out: the prompt is never sent a second time.
    public static func heard(after sent: String, in transcript: String) -> String {
        let key = { (c: Character) in
            String(c).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        }
        let counts = { (c: Character) in c.isLetter || c.isNumber }
        guard sent.contains(where: counts) else {
            return transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var rest = transcript[...]
        var matched = true
        for c in sent where counts(c) {
            guard let i = rest.firstIndex(where: counts), key(rest[i]) == key(c) else {
                matched = false
                break
            }
            rest = rest[rest.index(after: i)...]
        }
        if !matched {
            rest = transcript[...]
            for _ in words(sent) {
                rest = rest.drop { !counts($0) && $0 != "'" }
                rest = rest.drop { counts($0) || $0 == "'" }
            }
        }
        // A word the recognizer only made longer ("test" to "testing") is not new words.
        rest = rest.drop { counts($0) || $0 == "'" }
        return String(rest.drop { !counts($0) }).trimmingCharacters(in: .whitespacesAndNewlines)
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
