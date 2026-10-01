import Foundation

/// What dictation has put in the prompt box: the words already settled, and the
/// utterance the recogniser is still hearing (#69).
///
/// The recogniser hands back the whole of the current utterance each time, so a result
/// replaces the last one. But after a pause it can begin a fresh utterance without
/// first marking the old one final, and the next result then holds only the words said
/// since the pause. Taken at its word, that wipes out everything said before it. So a
/// result that does not carry on from the last one settles the last one first: words
/// already shown are only ever taken away by the person.
public struct DictationText: Sendable, Equatable {
    /// What was in the box when dictation started, and every utterance settled since.
    public private(set) var settled: String
    /// The utterance being heard now, as the recogniser last had it.
    public private(set) var hearing = ""
    /// What goes between `settled` and the next utterance: a space to begin with, since
    /// what was typed and what is said after it are one thought.
    private var separator = " "

    public init(startingWith text: String) {
        settled = text
    }

    /// Everything to show in the box.
    public var shown: String { joined(settled, hearing) }

    /// A result from the recogniser. `final` is true when it has ended the utterance.
    /// Returns what the box should now hold.
    @discardableResult
    public mutating func heard(_ said: String, final: Bool) -> String {
        if !said.isEmpty {
            if Self.startsAfresh(said, after: hearing) { settle(separator: " ") }
            hearing = said
        }
        // A pause long enough for the recogniser to call the utterance over is a new
        // paragraph; a breath in the middle of one is not.
        if final { settle(separator: "\n\n") }
        return shown
    }

    private mutating func settle(separator next: String) {
        guard !hearing.isEmpty else { return }
        settled = joined(settled, hearing)
        hearing = ""
        separator = next
    }

    private func joined(_ head: String, _ tail: String) -> String {
        if tail.isEmpty { return head }
        if head.isEmpty { return tail }
        return head + separator + tail
    }

    /// Whether `said` is a new utterance rather than a revision of `previous`.
    ///
    /// The recogniser revises its guesses as it hears more, so the words at the start
    /// can change while an utterance is short. Once there are a few words, a result
    /// whose opening words differ is a fresh start. With only a word or two, a revision
    /// still keeps one of them, so a result sharing none of them is a fresh start too.
    static func startsAfresh(_ said: String, after previous: String) -> Bool {
        let before = words(previous), now = words(said)
        guard !before.isEmpty, !now.isEmpty else { return false }
        if before.count < 3 { return Set(before).isDisjoint(with: now) }
        let shared = min(2, now.count)
        return Array(before.prefix(shared)) != Array(now.prefix(shared))
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" })
            .map(String.init)
    }
}
