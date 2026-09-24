import Foundation

/// One run of source lines in a Markdown document, separated from the next by blank
/// lines, with a fenced block always kept whole.
///
/// This is the page's unit of everything. What is marked as changed is a passage; what
/// the view scrolls to is a passage; what the person clicks into and types in is a
/// passage; what the merge moves is a passage; what the agent is told about is a
/// passage. One unit for all five, so they cannot disagree about where a thing is.
///
/// It is split from the *source*, not from `MarkdownBlock`, and that is the whole
/// reason it exists. `MarkdownBlock.parse` is built on Foundation's CommonMark parser,
/// which returns intents and text and no source ranges — a block cannot be mapped back
/// to the lines it came from, so it cannot be edited in place or named in a note. A
/// passage carries its lines, and each passage is rendered on its own by the same
/// `MarkdownText` that draws a whole document (022 research §2).
///
/// What this costs: a list whose items are separated by blank lines becomes several
/// one-item lists on the page. The source is untouched, so the file is unharmed; it is
/// a rendering wrinkle, and one of the things the proof of concept is for.
public struct Passage: Hashable, Sendable {
    /// The lines, joined with newlines, without the newline that ends the last one.
    /// Leading blank lines of a document belong to its first passage, so that there is
    /// somewhere for them to be: `split` then `join` must give back the exact text.
    public var source: String
    /// Where it sits in the document, counted from one. The separator's blank lines
    /// are not in this range; `index(containing:in:)` gives them to the passage before.
    public var lines: ClosedRange<Int>
    /// The newlines that followed: the one ending the last line, plus one per blank
    /// line before the next passage. Empty for a passage the document ends on without
    /// a newline. Kept exactly, because the daemon writes back whatever the page
    /// hands it, and a page that normalised blank lines would rewrite the file on
    /// every keystroke.
    public var separator: String
    /// The first non-blank line is an ATX heading, or the passage is a setext heading.
    /// Used for nothing but how the page spaces it.
    public var isHeading: Bool

    public init(source: String, lines: ClosedRange<Int>, separator: String, isHeading: Bool) {
        self.source = source
        self.lines = lines
        self.separator = separator
        self.isHeading = isHeading
    }

    // MARK: Splitting

    /// The document, as passages. Empty for an empty or all-blank document.
    public static func split(_ text: String) -> [Passage] {
        guard !text.isEmpty else { return [] }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        // A text ending in a newline yields a final empty "line" that is not a line.
        // It is the newline that ends the last real line, and lands in its separator.
        let endsWithNewline = text.hasSuffix("\n")
        let count = endsWithNewline ? lines.count - 1 : lines.count

        var passages: [Passage] = []
        var current: [Substring] = []
        var start = 1
        var fence: (character: Character, length: Int)? = nil

        func close(at last: Int, blankAfter: Int, endsDocument: Bool) {
            // Newlines that follow: one ending the last line (unless the document
            // simply stops there), plus one per blank line.
            let ending = endsDocument && !endsWithNewline ? 0 : 1
            let separator = String(repeating: "\n", count: ending + blankAfter)
            let source = current.joined(separator: "\n")
            passages.append(Passage(source: source, lines: start...last,
                                    separator: separator, isHeading: isHeading(current)))
            current = []
        }

        var index = 0
        while index < count {
            let line = lines[index]
            let number = index + 1
            if fence == nil, current.isEmpty, isBlank(line), passages.isEmpty {
                // Leading blank lines: kept in the first passage's source so that the
                // round trip holds. If the document is nothing but blank lines there
                // is no first passage, and they are dropped with it.
                current.append(line)
                if start == number { /* start stays where it is */ }
                index += 1
                continue
            }
            if let open = fence {
                current.append(line)
                if closesFence(line, open) { fence = nil }
                index += 1
                continue
            }
            if isBlank(line), !current.isEmpty, !current.allSatisfy(isBlank) {
                // The passage ends on the line before; count the blank run.
                var blank = 0
                var cursor = index
                while cursor < count, isBlank(lines[cursor]) { blank += 1; cursor += 1 }
                close(at: number - 1, blankAfter: blank, endsDocument: cursor >= count)
                start = cursor + 1
                index = cursor
                continue
            }
            if isBlank(line) {
                // Only blank lines so far, and the first passage not yet begun.
                current.append(line)
                index += 1
                continue
            }
            if current.isEmpty { start = number }
            if let opened = opensFence(line) { fence = opened }
            current.append(line)
            index += 1
        }
        if !current.isEmpty, !current.allSatisfy(isBlank) {
            close(at: count, blankAfter: 0, endsDocument: true)
        }
        return passages
    }

    /// The document, back from its passages. `join(split(x)) == x` for every `x`.
    public static func join(_ passages: [Passage]) -> String {
        passages.map { $0.source + $0.separator }.joined()
    }

    /// The passage that holds a line, counted from one.
    ///
    /// A line inside the blank run after a passage belongs to that passage; a line
    /// past the end is the last passage, because an agent naming a line the file has
    /// not reached is still pointing at the end of the document rather than at
    /// nothing. Zero, a negative, and an empty document are nowhere.
    public static func index(containing line: Int, in passages: [Passage]) -> Int? {
        guard line >= 1, !passages.isEmpty else { return nil }
        if let exact = passages.firstIndex(where: { $0.lines.contains(line) }) { return exact }
        if let before = passages.lastIndex(where: { $0.lines.upperBound < line }) { return before }
        return 0
    }

    // MARK: What a line is

    private static func isBlank(_ line: Substring) -> Bool {
        line.allSatisfy { $0 == " " || $0 == "\t" }
    }

    /// Up to three spaces of indent, then three or more backticks or tildes.
    private static func opensFence(_ line: Substring) -> (Character, Int)? {
        let trimmed = line.drop(while: { $0 == " " })
        guard line.count - trimmed.count <= 3, let first = trimmed.first,
              first == "`" || first == "~" else { return nil }
        let run = trimmed.prefix(while: { $0 == first }).count
        guard run >= 3 else { return nil }
        // A backtick fence's info string may not itself contain a backtick.
        if first == "`", trimmed.dropFirst(run).contains("`") { return nil }
        return (first, run)
    }

    /// The same character, at least as many, and nothing else on the line.
    private static func closesFence(_ line: Substring, _ open: (character: Character, length: Int)) -> Bool {
        let trimmed = line.drop(while: { $0 == " " })
        guard line.count - trimmed.count <= 3 else { return false }
        let run = trimmed.prefix(while: { $0 == open.character }).count
        guard run >= open.length else { return false }
        return trimmed.dropFirst(run).allSatisfy { $0 == " " || $0 == "\t" }
    }

    private static func isHeading(_ lines: [Substring]) -> Bool {
        let content = lines.drop(while: isBlank)
        guard let first = content.first else { return false }
        // Front matter: `---` on the first line is a document's preamble, and the
        // `---` that closes it under `title: x` is not a setext underline.
        if first == "---" { return false }
        let hashes = first.prefix(while: { $0 == "#" }).count
        if hashes >= 1, hashes <= 6,
           first.count == hashes || first.dropFirst(hashes).first == " " {
            return true
        }
        guard content.count >= 2 else { return false }
        let second = content[content.index(after: content.startIndex)]
        let underline = second.drop(while: { $0 == " " })
        guard let mark = underline.first, mark == "=" || mark == "-" else { return false }
        return underline.allSatisfy { $0 == mark || $0 == " " }
            && underline.contains(mark) && !isBlank(first)
    }
}

/// What differs between two versions of a document, said in passages of the new one.
///
/// The agent's edit and write tools rewrite the file, so the disk only ever shows
/// before and after; ACP's `diff` blocks arrive on the transcript, out of step with the
/// file, and Grok's writes carry none. A diff of the two texts works for every writer
/// and needs nothing from the runtime (022 research §3).
///
/// Marked lines are individual, not a hull: two passages changed with three untouched
/// between them mark two passages, not five. `changedLines` is the hull, for anyone who
/// wants the extent.
public struct PassageChange: Hashable, Sendable {
    /// First to last changed line in the new text, or nil when nothing changed.
    public var changedLines: ClosedRange<Int>?
    /// Indices of the new text's passages that hold a changed line.
    public var changed: IndexSet
    /// The passage to scroll to: the first that changed.
    public var first: Int?

    public init(changedLines: ClosedRange<Int>?, changed: IndexSet, first: Int?) {
        self.changedLines = changedLines
        self.changed = changed
        self.first = first
    }

    public static func between(old: String, new: String) -> PassageChange {
        let oldLines = old.isEmpty ? [] : old.split(separator: "\n", omittingEmptySubsequences: false)
        let newLines = new.isEmpty ? [] : new.split(separator: "\n", omittingEmptySubsequences: false)
        let difference = newLines.difference(from: oldLines)
        guard !difference.isEmpty, !newLines.isEmpty else {
            return PassageChange(changedLines: nil, changed: [], first: nil)
        }

        // Lines of the new text, counted from one, that are new or that now sit where
        // something was removed.
        //
        // Inserted blank lines are not marks on their own: an appended paragraph
        // arrives with the blank line before it, and that blank belongs to the passage
        // above, which did not change. They count only when nothing else does — a
        // blank line inserted into the middle of a paragraph splits it, and that is a
        // change worth marking somewhere.
        var inserted = Set<Int>()
        var insertedBlank = Set<Int>()
        for case .insert(let offset, let line, _) in difference {
            if line.allSatisfy({ $0 == " " || $0 == "\t" }) {
                insertedBlank.insert(offset + 1)
            } else {
                inserted.insert(offset + 1)
            }
        }
        // A removal has an offset in the old text. What now sits where it was is the
        // next old line that survived, at its new position; if none did, the end.
        let removedOffsets = Set(difference.removals.compactMap { change -> Int? in
            if case .remove(let offset, _, _) = change { return offset }
            return nil
        })
        let insertedOffsets = Set(difference.insertions.compactMap { change -> Int? in
            if case .insert(let offset, _, _) = change { return offset }
            return nil
        })
        // Retained old lines and retained new lines are the same lines in the same
        // order, so pairing them gives the old-to-new map.
        let retainedOld = oldLines.indices.filter { !removedOffsets.contains($0) }
        let retainedNew = newLines.indices.filter { !insertedOffsets.contains($0) }
        var newPosition: [Int: Int] = [:]
        for (oldIndex, newIndex) in zip(retainedOld, retainedNew) { newPosition[oldIndex] = newIndex }
        // Only a removal with nothing put in its place marks the line now there. A
        // changed line is a removal and an insertion at the same spot, and the
        // insertion is already the mark; marking the next line too would spill into
        // the passage below.
        var removedNow = Set<Int>()
        for offset in removedOffsets {
            let previous = retainedOld.last { $0 < offset }.flatMap { newPosition[$0] } ?? -1
            let next = retainedOld.first { $0 > offset }.flatMap { newPosition[$0] } ?? newLines.count
            guard next == previous + 1 else { continue }
            removedNow.insert(min(next, newLines.count - 1) + 1)
        }

        var marked = inserted.union(removedNow)
        if marked.isEmpty { marked = insertedBlank }

        let passages = Passage.split(new)
        var changed = IndexSet()
        for line in marked {
            if let index = Passage.index(containing: line, in: passages) {
                changed.insert(index)
            }
        }
        return PassageChange(changedLines: marked.min().map { $0...marked.max()! },
                             changed: changed,
                             first: changed.first)
    }
}

/// The person is typing in one passage and somebody else wrote the file.
///
/// One moving part. The person can only have one passage open, so the general
/// three-way problem collapses to a single question: did the other side touch my
/// lines? If not, the edit is spliced in where those lines now are. If so, the
/// person's text is kept and put where the other side's replacement sits, and that
/// replacement is handed back for the page to show beside it — nothing typed vanishes
/// without the page saying so (022 FR-014, FR-015).
///
/// Line-exact matching, deliberately. A CRDT solves a problem this page does not
/// have: one person, one passage, whole-file writes at second granularity.
public enum PassageMerge {
    public enum Result: Hashable, Sendable {
        /// The edit is in `text` at `passageIndex`, and nothing of theirs was lost.
        case merged(text: String, passageIndex: Int)
        /// The edit is in `text` at `passageIndex`, in place of what they wrote there,
        /// which is `theirs` — empty if they had deleted the passage outright.
        case collided(text: String, passageIndex: Int, theirs: String)
    }

    /// - Parameters:
    ///   - base: the document as it was when the editor opened, which `mine` is a
    ///     passage of.
    ///   - theirs: the document as it is on disk now.
    ///   - mine: the passage the person is editing, as it was in `base`.
    ///   - edited: what the person has typed for it.
    public static func apply(base: String, theirs: String, mine: Passage, edited: String) -> Result {
        let theirPassages = Passage.split(theirs)

        // Untouched: my passage's exact source still occurs as a passage of theirs.
        // The one nearest its old place, in case the same paragraph appears twice.
        let candidates = theirPassages.indices.filter { theirPassages[$0].source == mine.source }
        if let index = candidates.min(by: {
            abs(theirPassages[$0].lines.lowerBound - mine.lines.lowerBound)
                < abs(theirPassages[$1].lines.lowerBound - mine.lines.lowerBound)
        }) {
            var merged = theirPassages
            merged[index].source = edited
            return .merged(text: Passage.join(merged), passageIndex: index)
        }

        // Touched. Where my lines were is where the person's text goes: the passage
        // of theirs that now holds my first line, or the end if the document has
        // grown shorter than that.
        guard !theirPassages.isEmpty else {
            return .collided(text: edited, passageIndex: 0, theirs: "")
        }
        let index = Passage.index(containing: mine.lines.lowerBound, in: theirPassages) ?? theirPassages.count - 1
        var merged = theirPassages
        let replaced = merged[index]
        // A deletion: what sits at my old line is a passage that was already there in
        // base, after mine. Mine goes in before it rather than over it.
        if let basePassages = Optional(Passage.split(base)),
           basePassages.contains(where: { $0.source == replaced.source && $0.lines.lowerBound > mine.lines.lowerBound }) {
            // With a blank line of its own after it; the passage it goes in front
            // of keeps whatever followed it, which may be the document's end.
            merged.insert(Passage(source: edited, lines: mine.lines, separator: "\n\n", isHeading: false), at: index)
            return .collided(text: Passage.join(merged), passageIndex: index, theirs: "")
        }
        merged[index].source = edited
        return .collided(text: Passage.join(merged), passageIndex: index, theirs: replaced.source)
    }
}

extension Passage {
    /// The destinations of the images this passage references, in order, outside any
    /// fence. Listed as written — relative, absolute or remote — because which of
    /// them to load is the page's decision (FR-019), and which of them to watch is
    /// why this exists at all (FR-020): a redrawn picture changes no text, so the
    /// line diff cannot see it, and the page has to know which files to keep an eye on.
    ///
    /// One regular expression over the source. The alt text is not parsed and a
    /// title after the destination is dropped; the destination is what is wanted.
    public var imageSources: [String] {
        var sources: [String] = []
        var inFence = false
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.drop(while: { $0 == " " })
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
                continue
            }
            guard !inFence else { continue }
            for match in line.matches(of: image) {
                sources.append(String(match.output.1))
            }
        }
        return sources
    }

    /// `![anything](destination "optional title")`. The destination runs to the first
    /// space or closing bracket; a title in quotes after it is not the destination.
    /// Built per call rather than held in a static: a `Regex` is not `Sendable`, and
    /// a passage is a few lines.
    private var image: Regex<(Substring, Substring)> { /!\[[^\]]*\]\(\s*([^\s)]+)[^)]*\)/ }
}
