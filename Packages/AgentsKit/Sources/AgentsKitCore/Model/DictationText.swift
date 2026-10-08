import Foundation

/// What dictation does to the prompt box: it writes at the cursor, and the words it is
/// still hearing are the only ones it ever replaces (#427).
///
/// The person can go on editing while it listens. They can click back, delete a word,
/// type over a selection or type a word of their own between two sentences. Whatever
/// they do is theirs: the recogniser's next result never writes over it. The words
/// still being heard sit in `provisional`. A result that is not final replaces them,
/// and a final one settles them and moves on. Everything outside that span belongs to
/// the person.
///
/// The recogniser is one continuous session, so there is no guessing after a pause
/// whether a result revises the last one or starts afresh (#69). A final result
/// settles its words, and the next result starts a new span after them.
///
/// Positions are counted in characters, as the field shows them.
public struct DictationText: Sendable, Equatable {
    /// Everything in the box.
    public private(set) var text: String
    /// Where the next words go. While words are being heard, it is the span they occupy,
    /// with any space put around them. Otherwise it is the cursor or the selection, and
    /// the first words heard replace a selection the way typing would.
    public private(set) var provisional: Range<Int>
    /// Whether `provisional` holds heard words, rather than the person's cursor or
    /// selection waiting for some.
    public private(set) var isHearing = false
    /// Where the person put the cursor while words were still being heard. Those words
    /// settle where they are, and the next ones go here.
    private var nextTarget: Range<Int>?
    /// The person edited the words still being heard, so those words are theirs now.
    /// Later revisions of the same speech would bring the old words back, so they are
    /// dropped. This is where that speech began, in seconds of audio.
    private var adoptedFrom: Double?
    /// When the words in `provisional` began, in seconds of audio.
    private var hearingFrom: Double?
    /// Whether a space was put after the heard words, so the cursor can sit before it.
    private var spacedAfter = false

    /// Starting with what is in the box, and the cursor or selection in it. With no
    /// cursor, the words go at the end.
    public init(_ text: String, selection: Range<Int>? = nil) {
        self.text = text
        let end = text.count
        let chosen = selection ?? end..<end
        provisional = min(max(chosen.lowerBound, 0), end)..<min(max(chosen.upperBound, 0), end)
    }

    /// Where the field's cursor or selection belongs now: just after the words being
    /// heard, or wherever the person has put it since.
    public var selection: Range<Int> {
        if let nextTarget { return nextTarget }
        if !isHearing { return provisional }
        let end = provisional.upperBound - (spacedAfter ? 1 : 0)
        return end..<end
    }

    /// Whether the person has edited words that were still being heard, so the rest of
    /// that speech is being dropped. The recogniser should be asked to finalise what it
    /// has, so that the next words start a new span soon.
    public var isDroppingAdoptedSpeech: Bool { adoptedFrom != nil }

    // MARK: Heard

    /// A result from the recogniser: `words` for the speech that began at `start` seconds,
    /// final once the recogniser will not revise them. Returns whether the text changed.
    @discardableResult
    public mutating func heard(_ words: String, final: Bool, from start: Double) -> Bool {
        if let adoptedFrom {
            // The rest of the speech the person took over: theirs already.
            if start <= adoptedFrom { return false }
            self.adoptedFrom = nil
        }
        let words = words.trimmingCharacters(in: .whitespacesAndNewlines)
        // Nothing to say is no reason to remove the person's selection, only to take back
        // words that were being heard.
        guard !words.isEmpty || isHearing else { return false }

        var characters = Array(text)
        let lower = provisional.lowerBound, upper = provisional.upperBound
        var piece = words
        spacedAfter = false
        if !words.isEmpty {
            if lower > 0, Self.wantsSpace(between: characters[lower - 1], and: words.first!) {
                piece = " " + piece
            }
            if upper < characters.count, Self.wantsSpace(between: words.last!, and: characters[upper]) {
                piece += " "
                spacedAfter = true
            }
        }
        let pieceCount = piece.count
        characters.replaceSubrange(lower..<upper, with: Array(piece))
        let changed = String(characters) != text
        text = String(characters)
        let delta = pieceCount - (upper - lower)
        if let target = nextTarget, target.lowerBound >= upper {
            nextTarget = (target.lowerBound + delta)..<(target.upperBound + delta)
        }

        provisional = lower..<(lower + pieceCount)
        isHearing = !words.isEmpty
        hearingFrom = start
        if final { settle(at: lower + pieceCount - (spacedAfter ? 1 : 0)) }
        return changed
    }

    /// The heard words are settled: they are the person's now, and the next words go
    /// after them, or wherever the person has put the cursor since.
    private mutating func settle(at end: Int) {
        provisional = nextTarget ?? end..<end
        nextTarget = nil
        isHearing = false
        hearingFrom = nil
        spacedAfter = false
    }

    /// Whether a space belongs between two characters dictation put side by side. Not
    /// after one already there, and not before punctuation that hangs on a word.
    private static func wantsSpace(between left: Character, and right: Character) -> Bool {
        if left.isWhitespace || right.isWhitespace { return false }
        if "([{\"'“‘/".contains(left) { return false }
        if ".,;:!?)]}\"'”’…%/".contains(right) { return false }
        return true
    }

    // MARK: Edited

    /// The person changed the box: typed, deleted, pasted. Words they touched are
    /// theirs, and everything dictation is keeping track of moves with their edit.
    public mutating func edited(to new: String) {
        guard new != text else { return }
        let old = Array(text), now = Array(new)
        var prefix = 0
        while prefix < old.count, prefix < now.count, old[prefix] == now[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < old.count - prefix, suffix < now.count - prefix,
              old[old.count - 1 - suffix] == now[now.count - 1 - suffix] { suffix += 1 }
        // The span of the old text that changed, and how much the text grew.
        let changed = prefix..<(old.count - suffix)
        let editEnd = now.count - suffix
        let delta = now.count - old.count
        text = new

        provisional = moved(provisional, by: changed, editEnd: editEnd, delta: delta)
        if isHearing, provisional.isEmpty { adoptHeardWords() }
        nextTarget = nextTarget.map { moved($0, by: changed, editEnd: editEnd, delta: delta) }
    }

    /// Where a span ends up after an edit. An edit wholly before it moves it along, and
    /// so does typing right at its start: the words that follow come after what was
    /// typed, never over it. An edit wholly after it leaves it alone. One that reaches
    /// into it collapses it to the end of the edit, since the person has taken that text
    /// over.
    private func moved(_ span: Range<Int>, by changed: Range<Int>, editEnd: Int, delta: Int) -> Range<Int> {
        let shifted = (span.lowerBound + delta)..<(span.upperBound + delta)
        if changed.isEmpty {
            if changed.lowerBound <= span.lowerBound { return shifted }
            if changed.lowerBound >= span.upperBound { return span }
        } else {
            if changed.upperBound <= span.lowerBound { return shifted }
            if changed.lowerBound >= span.upperBound { return span }
        }
        return editEnd..<editEnd
    }

    /// The words being heard are the person's now: they stay as the person left them,
    /// and the recogniser's later takes on the same speech are dropped.
    private mutating func adoptHeardWords() {
        adoptedFrom = hearingFrom ?? 0
        isHearing = false
        hearingFrom = nil
        spacedAfter = false
    }

    // MARK: Moved

    /// The person put the cursor somewhere, or selected some words. If words are being
    /// heard, they settle where they are and the next ones go here. Otherwise the next
    /// ones go here at once.
    public mutating func selected(_ range: Range<Int>) {
        let end = text.count
        let range = min(max(range.lowerBound, 0), end)..<min(max(range.upperBound, 0), end)
        guard range != selection else { return }
        if isHearing, range.upperBound > provisional.lowerBound, range.lowerBound < provisional.upperBound,
           !(range.isEmpty && range.lowerBound == provisional.upperBound) {
            // Into the words being heard, to change them: they stop changing first.
            adoptHeardWords()
            provisional = range
            nextTarget = nil
        } else if isHearing {
            nextTarget = range
        } else {
            provisional = range
        }
    }
}
