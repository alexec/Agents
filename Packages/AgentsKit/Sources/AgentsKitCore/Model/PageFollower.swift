import Foundation

/// What a live page knows and decides, without the page (034).
///
/// This was `LivePage`'s `@State`, and the rules lived in the view where no test could
/// reach them. It is here now for two reasons: the phone draws the same page and must
/// decide the same way, and a page that is typed on from two devices over a connection
/// that drops has more ways to lose somebody's words than one on a Mac did.
///
/// It holds no clock and draws nothing. The view calls `tick()` on the caret's beat,
/// performs the effects it is handed (go somewhere, save this document), and tells it
/// how a save went. The marks, which are moments rather than facts, and the pictures,
/// which are the platform's, stay in the view.
public struct PageFollower: Sendable, Equatable {
    /// The one passage open for typing, if any. It holds only its own source, so an
    /// agent's write elsewhere in the file re-renders around it and never replaces
    /// what is under the caret (022 FR-012).
    public struct Editing: Sendable, Equatable {
        public var index: Int
        /// The passage as it was when the editor opened, or as last saved: what
        /// `draft` is compared against to know whether there is anything to write.
        public var base: String
        public var draft: String
        /// False while what is typed has not reached the disk: a save that failed, or
        /// one the connection dropped. A commit then writes it again even when the
        /// draft already equals `base` (034 FR-009).
        public var isSaved = true
    }

    /// A passage being typed, or waiting to be: where the caret began and how far it
    /// has got. It begins where the passage stopped agreeing with what was there
    /// before, so a rewritten sentence types from the sentence rather than from the
    /// top of the paragraph.
    public struct Reveal: Sendable, Equatable {
        public var index: Int
        /// The agreed prefix: what was already on the page when this began.
        public var from: Int
        /// How many characters are drawn now.
        public var shown: Int
        /// What this block said before the write. Drawn while it waits its turn, so
        /// the page goes on looking like the page until the caret reaches it — an
        /// appended block has nothing here and shows nothing, and a rewritten one
        /// keeps its old words rather than being cut back to the few characters the
        /// two versions happen to share.
        public var before: String
    }

    /// What the view should do after a change.
    public enum Effect: Sendable, Equatable {
        /// Take the view to this passage.
        case scroll(to: Int)
        /// Hand this whole document to the daemon to write.
        case save(String)
    }

    /// The caret's pace: `typingStep` characters every tick, fifty a second at the
    /// view's 40 ms — a quick read. 240 words a minute was tried first and was too slow
    /// to sit through. Nothing hurries a long block along; what keeps a long document
    /// from taking a long time is the agent's next write, which completes whatever is
    /// still on its way rather than racing it.
    public static let typingStep = 2

    public private(set) var passages: [Passage] = []
    /// The text `passages` came from: the base for the next diff.
    public private(set) var lastLoaded = ""
    /// The whole document as last handed to the daemon, so its own echo through the
    /// folder watch is recognised and not treated as news.
    public private(set) var lastWritten: String?
    public private(set) var editing: Editing?
    /// The one passage the caret is in, and the ones waiting their turn.
    ///
    /// There is exactly one caret on a page. A write that changes six passages does
    /// not start six of them typing at once, which is what this used to do and what
    /// read as six hands on one document. They queue in document order, the caret
    /// goes to each in turn, and until its turn comes a passage shows what was there
    /// before the write — nothing at all, for a passage that is new. So the document
    /// grows a block at a time instead of arriving whole and being typed over.
    public private(set) var revealing: Reveal?
    public private(set) var pending: [Reveal] = []
    /// The agent rewrote the very passage the person was typing in. Theirs is shown
    /// under the editor until the person takes it or dismisses it (022 FR-014).
    public private(set) var collision: String?
    /// Why the last save did not land. The draft stays open, and stays unsaved, until
    /// one does (034 FR-009).
    public private(set) var saveProblem: String?

    public init() {}

    public var isEditing: Bool { editing != nil }

    // MARK: What is on the page

    /// What the passage shows right now: all of it; or, when the caret is in it, as
    /// much as has been typed; or, when it is still waiting its turn, only what was
    /// there before the write.
    public func shown(_ index: Int) -> String {
        guard passages.indices.contains(index) else { return "" }
        if let current = revealing, current.index == index {
            return String(passages[index].source.prefix(current.shown))
        }
        if let waiting = pending.first(where: { $0.index == index }) {
            return waiting.before
        }
        return passages[index].source
    }

    /// The passage holding a line an agent named, counted from one.
    public func index(containing line: Int) -> Int? {
        Passage.index(containing: line, in: passages)
    }

    // MARK: Following

    public mutating func load(_ text: String) {
        passages = Passage.split(text)
        lastLoaded = text
    }

    /// New text on disk: what changed is queued for the caret, and the view goes to
    /// the first of it unless the person is typing.
    public mutating func follow(_ new: String) -> [Effect] {
        if new == lastWritten {
            // The person's own save, back through the folder watch. Not news: no
            // reveal, no scroll. The passages are re-split because the draft may have
            // gained or lost a blank line; if it did, the editor's index no longer
            // names one passage and it closes rather than guess.
            let fresh = Passage.split(new)
            if let current = editing,
               !(fresh.indices.contains(current.index) && fresh[current.index].source == current.draft) {
                editing = nil
            }
            passages = fresh
            lastLoaded = new
            return []
        }
        let change = PassageChange.between(old: lastLoaded, new: new)
        let previous = passages
        guard let current = editing, passages.indices.contains(current.index) else {
            passages = Passage.split(new)
            lastLoaded = new
            guard let first = change.first else { return [] }
            let typed = reveal(Array(change.changed), previous: previous)
            // A block being typed is taken to by the caret, which moves the view to
            // each one as it reaches it. Only a change with nothing to type — a
            // deletion — needs the view moved by hand.
            return typed.isEmpty ? [.scroll(to: first)] : []
        }
        // Somebody else wrote while a passage is open. The draft is carried across:
        // spliced in where its lines now are, or kept in place of what they wrote
        // there with theirs shown beside it. Either way the result goes to disk, so
        // the file holds both (022 FR-012), and the view does not move (FR-013).
        let result = PassageMerge.apply(base: lastLoaded, theirs: new,
                                        mine: passages[current.index], edited: current.draft)
        let merged: String
        let index: Int
        switch result {
        case .merged(let text, let at):
            merged = text; index = at
        case .collided(let text, let at, let theirs):
            merged = text; index = at
            collision = theirs
        }
        passages = Passage.split(merged)
        lastLoaded = merged
        editing = Editing(index: index, base: current.draft, draft: current.draft,
                          isSaved: merged == new ? current.isSaved : false)
        reveal(Array(change.changed).filter { $0 != index }, previous: previous)
        guard merged != new else { return [] }
        lastWritten = merged
        return [.save(merged)]
    }

    /// The connection came back and the file was read again (034 FR-009). The same as
    /// any other read, with the draft carried across by the same merge, so nothing new
    /// decides a collision. A draft whose save never landed is written now.
    public mutating func reconnected(_ fresh: String) -> [Effect] {
        var effects = follow(fresh)
        if effects.isEmpty, let current = editing, !current.isSaved {
            effects = commit(force: true)
        }
        return effects
    }

    // MARK: Typing

    public mutating func begin(_ index: Int) -> [Effect] {
        // Opening another passage closes this one, writing it first.
        var effects: [Effect] = []
        if editing != nil { effects = close() }
        guard passages.indices.contains(index) else { return effects }
        // Opened while the agent's caret is in it, or waiting for it: the person gets
        // the whole of it at once, and the agent's caret moves on to the next block.
        pending.removeAll { $0.index == index }
        if revealing?.index == index { next() }
        editing = Editing(index: index, base: passages[index].source, draft: passages[index].source)
        saveProblem = nil
        return effects
    }

    public mutating func edit(_ draft: String) {
        editing?.draft = draft
    }

    /// The draft is due on disk: the document with this passage's draft in place of
    /// its source, whole, handed to the daemon (022 FR-011).
    public mutating func commit() -> [Effect] {
        commit(force: false)
    }

    private mutating func commit(force: Bool) -> [Effect] {
        guard let current = editing, current.draft != current.base || !current.isSaved || force,
              passages.indices.contains(current.index) else { return [] }
        var edited = passages
        edited[current.index].source = current.draft
        let document = Passage.join(edited)
        lastWritten = document
        editing?.isSaved = false
        return [.save(document)]
    }

    /// How the save of `draft` went. A save that failed leaves the draft unsaved, so
    /// the next commit, or the next reconnect, writes it again.
    public mutating func saved(problem: String?, draft: String) {
        saveProblem = problem
        guard problem == nil, editing?.draft == draft || editing?.base == draft else { return }
        editing?.base = draft
        if editing?.draft == draft { editing?.isSaved = true }
    }

    public mutating func close() -> [Effect] {
        let effects = commit()
        // A draft that has not reached the disk is not given up: it stays open, so it
        // is still on screen and can be copied (034 FR-009).
        if editing?.isSaved == false, saveProblem != nil { return effects }
        editing = nil
        return effects
    }

    /// "Use theirs": the agent's version of the passage replaces the draft, and is
    /// written.
    public mutating func takeTheirs() -> [Effect] {
        guard let theirs = collision else { return [] }
        editing?.draft = theirs
        collision = nil
        return commit()
    }

    /// "Keep mine": the card goes. Theirs is already gone from the file.
    public mutating func keepMine() {
        collision = nil
    }

    // MARK: The caret

    /// One beat of the caret. Returns whether anything is still being typed.
    @discardableResult
    public mutating func tick() -> Bool {
        guard var current = revealing else { return false }
        guard passages.indices.contains(current.index) else { next(); return revealing != nil }
        current.shown += Self.typingStep
        if current.shown >= passages[current.index].source.count {
            next()
        } else {
            revealing = current
        }
        return revealing != nil
    }

    /// Everything on its way is shown whole, now: the caret goes, and every queued
    /// passage draws in full.
    public mutating func complete() {
        revealing = nil
        pending = []
    }

    /// Queue these passages to be typed, in document order, and put the caret in the
    /// first of them. Returns the ones it took, so the caller knows whether the caret
    /// will take the view there or it has to go by hand.
    @discardableResult
    private mutating func reveal(_ indices: [Int], previous: [Passage]) -> Set<Int> {
        // Whatever is still on its way is completed rather than raced. This is the
        // rule that keeps one caret on the page: the agent writing again is what
        // finishes the block being typed, so text never types over text that is
        // itself still typing.
        complete()
        var queue: [Reveal] = []
        for index in indices.sorted() where passages.indices.contains(index) {
            let new = passages[index].source
            let old = previous.indices.contains(index) ? previous[index].source : ""
            let agreed = zip(old, new).prefix { $0 == $1 }.count
            guard agreed < new.count else { continue }
            queue.append(Reveal(index: index, from: agreed, shown: agreed, before: old))
        }
        guard !queue.isEmpty else { return [] }
        let first = queue.removeFirst()
        revealing = first
        pending = queue
        return Set([first.index] + queue.map(\.index))
    }

    /// The caret has finished a block: on to the next one, or off the page.
    private mutating func next() {
        revealing = pending.isEmpty ? nil : pending.removeFirst()
    }
}
