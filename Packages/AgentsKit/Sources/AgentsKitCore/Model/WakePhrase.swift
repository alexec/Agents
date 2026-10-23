import Foundation

/// "Hey Agents" in what the recogniser wrote (#2420), and the words said after it.
///
/// The recogniser writes text, so the wake is a match of words: the case and the
/// punctuation do not count ("Hey, Agents!" is the phrase). The spike (#1800) heard the
/// phrase best as "Hey Agents"; "Hey agent" and "Hay agents" are how it wrote it the other
/// times. A phrase inside a longer word does not count ("they agents" is not it).
public struct WakePhrase: Sendable, Equatable {
    /// The phrase as the person says it, for the recogniser's context and the Settings footer.
    public let phrase: String
    /// Each way of writing it, in words, lowercased.
    private let spellings: [[String]]

    public static let heyAgents = WakePhrase("Hey Agents", soundsLike: ["Hey agent", "Hay agents", "Hay agent"])

    public init(_ phrase: String, soundsLike: [String] = []) {
        self.phrase = phrase
        spellings = ([phrase] + soundsLike).map { Self.words(in: $0).map(\.word) }.filter { !$0.isEmpty }
    }

    /// The words said after the phrase, with the punctuation between them left out ("" when
    /// nothing came after it), or nil when the phrase is not in `text`.
    public func wordsAfter(in text: String) -> String? {
        let heard = Self.words(in: text)
        for start in heard.indices {
            for spelling in spellings where start + spelling.count <= heard.count {
                guard heard[start..<(start + spelling.count)].map(\.word) == spelling else { continue }
                let end = heard[start + spelling.count - 1].range.upperBound
                return String(text[end...]).trimmingCharacters(in: Self.notWords)
            }
        }
        return nil
    }

    private static let notWords = CharacterSet.alphanumerics.inverted

    /// The words of `text`, lowercased, with where each one is.
    private static func words(in text: String) -> [(word: String, range: Range<String.Index>)] {
        var words: [(String, Range<String.Index>)] = []
        var start: String.Index?
        var index = text.startIndex
        while index < text.endIndex {
            let isWord = text[index].isLetter || text[index].isNumber || text[index] == "'"
            if isWord, start == nil { start = index }
            if !isWord, let begun = start {
                words.append((text[begun..<index].lowercased(), begun..<index))
                start = nil
            }
            index = text.index(after: index)
        }
        if let begun = start { words.append((text[begun...].lowercased(), begun..<text.endIndex)) }
        return words
    }
}
