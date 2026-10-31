import Foundation

/// A question card, read out and answered by voice (#2322, Alex's notes on #1792).
///
/// Only a question with one set of choices can be answered by voice: "Two choices. One:
/// Keychain. Two: File. One is recommended." The person says a number ("two", "the
/// second", "option 2") or the choice's own words. Anything else (several questions, free
/// text, numbers, a page to open) needs the screen, and voice mode says so.
public struct SpokenQuestion: Hashable, Sendable {
    /// The property the answer goes in.
    public var property: String
    public var choices: [ElicitationSchema.Property.Choice]
    /// What is said: the question, then the choices with their numbers.
    public var sentences: [String]

    /// What is said for a question voice cannot answer.
    public static let needsTheScreen = "This one needs your screen."
    /// What is said when the words matched no choice.
    public static let notCaught = "I did not catch a choice. Say its number."

    /// Nil when the request is not one question with choices.
    public init?(_ request: ElicitationRequest) {
        guard case .form(let schema) = request.mode, schema.pages.count == 1,
              let first = schema.pages.first?.first,
              case .string(_, _, _, let choices) = first.kind, let choices, !choices.isEmpty,
              choices.count <= Self.ordinals.count
        else { return nil }
        property = first.name
        self.choices = choices
        let question = request.message ?? first.title ?? first.description ?? schema.title ?? "The agent asks."
        var said = Speakable.sentences(question)
        said.append(choices.count == 1 ? "One choice." : "\(Self.number(choices.count).capitalized) choices.")
        for (index, choice) in choices.enumerated() {
            said.append("\(Self.number(index + 1).capitalized): \(Self.spokenTitle(choice.title)).")
        }
        if let recommended = choices.firstIndex(where: Self.isRecommended) {
            said.append("\(Self.number(recommended + 1).capitalized) is recommended.")
        }
        sentences = said
    }

    /// The choice the words mean, or nil. A number first, then the choice whose words
    /// they hold.
    public func choice(for heard: String) -> ElicitationSchema.Property.Choice? {
        let words = Self.words(heard)
        guard !words.isEmpty else { return nil }
        for word in words {
            if let index = Self.index(of: word), index < choices.count { return choices[index] }
        }
        // What a recogniser hears for a number said on its own; inside a sentence these
        // are only words.
        if words.count == 1, let index = Self.heardAlone[words[0]], index < choices.count { return choices[index] }
        let said = " " + words.joined(separator: " ") + " "
        let matches = choices.filter { choice in
            let title = Self.words(Self.spokenTitle(choice.title)).joined(separator: " ")
            return !title.isEmpty && said.contains(" " + title + " ")
        }
        return matches.count == 1 ? matches[0] : nil
    }

    /// Whether the words take back an answer about to go: "no", "wait", "stop".
    public static func isNo(_ heard: String) -> Bool {
        !Set(words(heard)).isDisjoint(with: ["no", "nope", "wait", "stop", "cancel", "don't"])
    }

    // MARK: - Words

    static let ordinals: [(cardinal: String, ordinal: String)] = [
        ("one", "first"), ("two", "second"), ("three", "third"), ("four", "fourth"),
        ("five", "fifth"), ("six", "sixth"), ("seven", "seventh"), ("eight", "eighth"),
        ("nine", "ninth"),
    ]

    static func number(_ n: Int) -> String { ordinals[n - 1].cardinal }

    /// "two", "2", "second", "2nd" → 1.
    static func index(of word: String) -> Int? {
        if let n = Int(word.trimmingCharacters(in: .letters)), (1...ordinals.count).contains(n) { return n - 1 }
        return ordinals.firstIndex { $0.cardinal == word || $0.ordinal == word }
    }

    static let heardAlone = ["won": 0, "to": 1, "too": 1, "for": 3]

    static func words(_ s: String) -> [String] {
        s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" }).map(String.init)
    }

    static func isRecommended(_ choice: ElicitationSchema.Property.Choice) -> Bool {
        choice.title.range(of: "(recommended)", options: .caseInsensitive) != nil
    }

    /// The title without "(Recommended)", which is said once, after the choices.
    public static func spokenTitle(_ title: String) -> String {
        Speakable.text(title.replacing(#/\s*\((?i:recommended)\)/#, with: ""))
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
    }
}
