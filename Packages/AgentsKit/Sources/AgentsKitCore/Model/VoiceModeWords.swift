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

    /// Said as a prompt goes, when it is the "Stops listening" sound (#3565).
    public static let letMeThink = "Let me think."

    /// Whether words heard are only the voice's own "Let me think." heard back, not a
    /// prompt (#3565).
    public static func isLetMeThink(_ heard: String) -> Bool {
        isEcho(heard, of: letMeThink)
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

    /// Whether words heard end a sentence: their last mark, after any closing quote or
    /// bracket, is a full stop, a question mark or an exclamation mark (#3340). The
    /// transcriber writes these marks itself. "Do we have" and "Rather than looking at
    /// milestones," do not end one, so voice mode waits longer before they go.
    public static func endsSentence(_ text: String) -> Bool {
        let closing: Set<Character> = ["\"", "'", "”", "’", ")", "]"]
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).reversed().drop { closing.contains($0) }
        guard let last = trimmed.first else { return false }
        return [".", "?", "!", "…"].contains(last)
    }

    /// What is said over the voice that is only listening, not talking.
    static let backchannel: Set<String> = [
        "mm", "mmm", "hmm", "mhm", "mm-hmm", "uh-huh", "uh", "um", "er", "ah", "oh",
        "yeah", "yep", "yes", "ok", "okay", "right", "sure", "huh", "cool", "nice",
    ]

    /// Whether words heard while the voice speaks are the person talking over it: two words
    /// that are not backchannel ("mm-hmm", "yeah", a cough heard as "uh"), or one while a
    /// question is read, as "two!". Words that are the voice's own sentences (`said`), heard
    /// back through the microphone, are not: also when the microphone mishears them ("I hear
    /// you: not by milestone." heard as "I hear you not my master", #3340), so a word that
    /// is one letter off one of the voice's words counts as the voice's, in the same order.
    public static func isBargeIn(_ heard: String, over said: [String], asking: Bool) -> Bool {
        let meant = spokenWords(heard).filter { !backchannel.contains($0) }
        guard meant.count >= (asking ? 1 : 2) else { return false }
        let own = said.flatMap(spokenWords)
        return Double(echoed(meant, in: own)) < Double(meant.count) * 0.6
    }

    /// Words as `isBargeIn` counts them: "mm-hmm" is one word.
    private static func spokenWords(_ text: String) -> [String] {
        text.lowercased()
            .split { !$0.isLetter && !$0.isNumber && $0 != "-" && $0 != "'" }
            .map(String.init)
    }

    /// How many of `heard`, in order, are near words of `own`, in order: the longest
    /// common run of near words.
    private static func echoed(_ heard: [String], in own: [String]) -> Int {
        guard !own.isEmpty else { return 0 }
        var row = [Int](repeating: 0, count: own.count + 1)
        for word in heard {
            var diagonal = 0
            for (j, ownWord) in own.enumerated() {
                let above = row[j + 1]
                row[j + 1] = isNear(word, ownWord) ? diagonal + 1 : max(above, row[j])
                diagonal = above
            }
        }
        return row[own.count]
    }

    /// The same word, or one a microphone could mishear as it: one letter off ("my" for
    /// "by"), or two in a long word.
    static func isNear(_ a: String, _ b: String) -> Bool {
        guard a != b else { return true }
        let allowed = min(a.count, b.count) >= 5 ? 2 : 1
        guard abs(a.count - b.count) <= allowed, min(a.count, b.count) >= 2 else { return false }
        return distance(Array(a), Array(b)) <= allowed
    }

    /// The edit distance between two words, neither of them empty.
    private static func distance(_ a: [Character], _ b: [Character]) -> Int {
        var row = Array(0...b.count)
        for i in 1...a.count {
            var previous = row[0]
            row[0] = i
            for j in 1...b.count {
                let current = row[j]
                row[j] = a[i - 1] == b[j - 1] ? previous : min(previous, row[j], row[j - 1]) + 1
                previous = current
            }
        }
        return row[b.count]
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
