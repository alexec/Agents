import Foundation

/// Auto on the start form (#4559): the persona the first prompt's words name, as it is
/// typed. Ported by hand to the web as `autoPersona` (`Web/src/model/personas.ts`).
///
/// A keyword counts once it is a whole word: the word and then a space or punctuation, so
/// a half-typed word never matches and the pick does not flicker. Case does not matter.
/// The persona with the most matches wins; the earliest match breaks a tie, and then the
/// list's order. `#<n>` matches an issue number, such as `#123`.
extension Persona {
    public struct AutoPick: Hashable, Sendable {
        public var persona: Persona
        /// The word that picked it, the earliest of its matches, for the line under the control.
        public var word: String

        public init(persona: Persona, word: String) {
            self.persona = persona
            self.word = word
        }
    }

    /// A segment of the persona control: Auto, no persona, or one by id.
    public enum Segment: Hashable, Sendable {
        case auto
        case none
        case persona(String)

        public init(auto: Bool, picked: String?) {
            self = auto ? .auto : picked.map(Segment.persona) ?? Segment.none
        }
    }

    /// The grey line under the control while Auto is on: what it picked, and the word.
    public static func autoLine(_ pick: AutoPick?) -> String {
        guard let pick else { return "Auto picks a persona from the words you type" }
        return "Auto picked \(pick.persona.name): \"\(pick.word)\""
    }

    /// The keyword that stands for any issue number.
    public static let issueNumberKeyword = "#<n>"

    /// The words that pick this persona: its `keywords:`, else the longer words of its name
    /// and description.
    public var autoWords: [String] {
        if let keywords, !keywords.isEmpty { return keywords }
        let words = ([name] + (description.map { [$0] } ?? []))
            .flatMap { $0.split { !$0.isLetter && !$0.isNumber } }
            .map(String.init)
            .filter { $0.count >= 5 && !Self.commonWords.contains($0.lowercased()) }
        var seen = Set<String>()
        return words.filter { seen.insert($0.lowercased()).inserted }
    }

    /// Words too common in a description to say anything about the persona.
    static let commonWords: Set<String> = ["about", "after", "before", "every", "other", "their", "there",
                                           "these", "those", "until", "where", "which", "while", "would"]

    /// The persona `prompt` names, or nil when none of `personas` matches.
    public static func autoPick(_ prompt: String, among personas: [Persona]) -> AutoPick? {
        let text = Array(prompt.lowercased())
        var best: (pick: AutoPick, count: Int, first: Int)?
        for persona in personas where persona.problem == nil {
            var count = 0
            var first: (at: Int, word: String)?
            for keyword in persona.autoWords {
                for match in matches(of: keyword, in: text) {
                    count += 1
                    if first == nil || match.at < first!.at { first = match }
                }
            }
            guard let first, count > 0 else { continue }
            if best == nil || count > best!.count || count == best!.count && first.at < best!.first {
                best = (AutoPick(persona: persona, word: first.word), count, first.at)
            }
        }
        return best?.pick
    }

    /// Where `keyword` is a whole word in `text` (already lower case), and the word to show.
    static func matches(of keyword: String, in text: [Character]) -> [(at: Int, word: String)] {
        let wanted = keyword.trimmingCharacters(in: .whitespaces)
        let isWord = { (c: Character) in c.isLetter || c.isNumber }
        var found: [(at: Int, word: String)] = []
        if wanted == issueNumberKeyword {
            for i in text.indices where text[i] == "#" && (i == 0 || !isWord(text[i - 1])) {
                var end = i + 1
                while end < text.count, text[end].isASCII, text[end].isNumber { end += 1 }
                if end > i + 1, end < text.count, !isWord(text[end]) {
                    found.append((i, String(text[i..<end])))
                }
            }
            return found
        }
        let word = Array(wanted.lowercased())
        guard !word.isEmpty, word.count < text.count else { return [] }
        for i in 0...(text.count - word.count - 1) where Array(text[i..<(i + word.count)]) == word {
            let after = text[i + word.count]
            if (i == 0 || !isWord(text[i - 1])) && !isWord(after) { found.append((i, wanted)) }
        }
        return found
    }
}
