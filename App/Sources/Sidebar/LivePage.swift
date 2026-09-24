import AgentsKit
import SwiftUI

/// A Markdown file as a page that is alive: what is on disk, drawn as a document, with
/// what just changed marked and the view taken to it.
///
/// This is the paper surface `DocumentView` was, grown one step: the document is drawn
/// passage by passage rather than whole, so that a change can be said to have happened
/// *somewhere*. Each passage goes through the same `MarkdownText` the conversation
/// uses and inherits that renderer's shape; the split is `Passage`'s, in the kit, where
/// the tests can reach it.
///
/// It follows the agent. When `text` changes, a caret with the agent's name over it
/// appears at the first block that changed and types it in, then moves to the next,
/// with the view going along with it — unless the person is typing (FR-013), in which
/// case the agent's caret carries on and the view stays put. The person's own caret,
/// in the passage they have open, carries their name, so the two are never confused.
/// That the view always follows otherwise, even when the reader has scrolled off to
/// read something else, is the proof of concept's rule, and whether it should be
/// softer is one of the things it exists to find out (spec, US1 scenario 6).
///
/// What is real here is `PageMetrics`: the width comes from the pane, the measure and
/// the padding from the kit, and the page centres itself once the pane is wider than
/// it needs to be. FR-004 of 007 still holds: no sheet edge, no shadow, no drawn border
/// — the paper is the space and the type.
struct LivePage: View {
    @Environment(AppModel.self) private var model

    let text: String
    /// Where the document is, so an image beside it can be found.
    let url: URL
    /// The line an agent named, or nil. Read once when it changes: the view goes to
    /// the passage holding it and marks it (FR-007), and then the line is spent.
    let line: Int?
    /// Whose page this is: the daemon writes the person's typing inside this agent's
    /// folders and remembers it for this agent's next turn.
    let agentID: UUID
    /// What the agent is called, for the name over its caret: its runtime's name.
    var agentName = "Agent"
    /// Bumped by the pane on every folder event, including the ones that leave the
    /// document's text alone. That is when a picture beside it may have changed, and
    /// a picture is not in the text (FR-020).
    var folderEvent = 0

    /// The one passage open for typing, if any. It holds only its own source, so an
    /// agent's write elsewhere in the file re-renders around it and never replaces
    /// what is under the caret (FR-012).
    private struct Editing {
        var index: Int
        /// The passage as it was when the editor opened, or as last saved: what
        /// `draft` is compared against to know whether there is anything to write.
        var base: String
        var draft: String
    }

    @State private var editing: Editing?
    /// The whole document as last handed to the daemon, so its own echo through the
    /// folder watch is recognised and not treated as news.
    @State private var lastWritten: String?
    @State private var saveProblem: String?
    /// The agent rewrote the very passage the person was typing in. Theirs is shown
    /// under the editor until the person takes it or dismisses it (FR-014).
    @State private var collision: String?

    private var isEditing: Bool { editing != nil }

    @State private var passages: [Passage] = []
    /// Which passages are marked, and when each mark was set. A mark is not a flag
    /// but a moment, so a passage marked twice in a second fades from the second.
    ///
    /// Only the line an agent names is marked now (FR-007). A write is not: the caret
    /// typing it in is how the page says where it changed, and a tint flashing behind
    /// each block as well was one signal too many.
    @State private var marked: [Int: Date] = [:]
    /// The text `passages` came from: the base for the next diff.
    @State private var lastLoaded = ""
    /// The one passage the caret is in, and the ones waiting their turn.
    ///
    /// There is exactly one caret on a page. A write that changes six passages does
    /// not start six of them typing at once, which is what this used to do and what
    /// read as six hands on one document. They queue in document order, the caret
    /// goes to each in turn, and until its turn comes a passage shows what was there
    /// before the write — nothing at all, for a passage that is new. So the document
    /// grows a block at a time instead of arriving whole and being typed over.
    @State private var revealing: Reveal?
    @State private var pending: [Reveal] = []
    @State private var typist: Task<Void, Never>?
    /// The pictures on the page and when each file last changed.
    @State private var images = ImageStamps()

    /// A passage being typed, or waiting to be: where the caret began and how far it
    /// has got. It begins where the passage stopped agreeing with what was there
    /// before, so a rewritten sentence types from the sentence rather than from the
    /// top of the paragraph.
    private struct Reveal {
        var index: Int
        /// The agreed prefix: what was already on the page when this began.
        var from: Int
        /// How many characters are drawn now.
        var shown: Int
        /// What this block said before the write. Drawn while it waits its turn, so
        /// the page goes on looking like the page until the caret reaches it — an
        /// appended block has nothing here and shows nothing, and a rewritten one
        /// keeps its old words rather than being cut back to the few characters the
        /// two versions happen to share.
        var before: String
    }

    /// The caret's pace: `typingStep` characters every `typingTick`, fifty a second —
    /// a quick read. 240 words a minute was tried first and was too slow to sit
    /// through. Nothing hurries a long block along; what keeps a long document from
    /// taking a long time is the agent's next write, which completes whatever is still
    /// on its way rather than racing it.
    private static let typingTick: Duration = .milliseconds(40)
    private static let typingStep = 2

    /// How long a mark stays before it starts to fade, and how long the fade takes.
    /// Long enough to be found by an eye that was elsewhere; short enough that a
    /// document written in twenty steps is not twenty tints deep.
    private static let markHold: Duration = .seconds(2)
    private static let markFade: Double = 1.2

    var body: some View {
        GeometryReader { geometry in
            let metrics = PageMetrics.forPane(width: geometry.size.width)
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(passages.indices, id: \.self) { index in
                            passage(index, metrics: metrics)
                                .id(index)
                        }
                    }
                    .padding(.vertical, 24)
                    .frame(maxWidth: .infinity)
                }
                // Prose on the app's reading step: the same face and the same size as
                // everything else, because a document is a thing you read and that is
                // what the step is for. It was New York at 12pt for 007, which read as
                // paper but as a different app's paper. The pane widened to 460 rather
                // than the text shrinking back, so the 60-character floor still holds;
                // `PageMetrics` carries that arithmetic.
                .appText(.reading)
                .textSelection(.enabled)
                .onAppear { load(text) }
                .onChange(of: text) { _, new in
                    follow(new, proxy: proxy)
                }
                .onChange(of: folderEvent) {
                    let (fresh, changed) = images.refreshed()
                    images = fresh
                    guard let first = changed.first else { return }
                    guard !isEditing else { return }
                    Task { await go(to: first, proxy: proxy) }
                }
                // The view follows the caret from block to block, which is the whole
                // of what a reader has to do to read along with it. It stays put while
                // the person is typing, the same as every other move this page makes.
                .onChange(of: revealing?.index) { _, new in
                    guard let new, !isEditing else { return }
                    Task { await go(to: new, proxy: proxy) }
                }
                .onDisappear { complete() }
                .task(id: line) {
                    guard let line, let index = Passage.index(containing: line, in: passages) else { return }
                    await go(to: index, proxy: proxy)
                    mark([index])
                }
            }
        }
    }

    // MARK: One passage

    private func passage(_ index: Int, metrics: PageMetrics) -> some View {
        let isMarked = marked[index] != nil
        return Group {
            if editing?.index == index {
                VStack(alignment: .leading, spacing: 4) {
                    PassageEditor(draft: draftBinding, onCommit: commit, onClose: {
                        // Only this passage's editor may close itself. Focus leaving it
                        // because another passage was opened arrives after that one is
                        // open, and must not close it.
                        if editing?.index == index { close() }
                    })
                    if let saveProblem {
                        Text(saveProblem)
                            .appText(.fine)
                            .foregroundStyle(.secondary)
                    }
                    if let collision {
                        collisionCard(collision)
                    }
                }
            } else {
                // The passage is the button. A tap gesture under the page's text
                // selection never fired — selection takes the click — which the
                // 2026-09-24 walk saw: a click, no caret, keystrokes gone. So the
                // rendered passage is a plain `Button` whose label is the text, the
                // shape that keeps its clicks (see the SwiftUI card memory), and
                // copying from the page is done from the editor it opens.
                Button {
                    begin(index)
                } label: {
                    MarkdownText(markdown: shown(index), base: url,
                                 caret: revealing?.index == index ? .agent(agentName) : nil)
                        // A new identity when a picture in it changed on disk,
                        // which is what makes the file be read again rather than
                        // redrawn.
                        .id(images.token(for: index))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
            .frame(maxWidth: metrics.measure, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            // The tint the app already uses for "the agent did this" — the dot on a
            // touched file in the listing — at the strength `FileLines` gives the line
            // an agent named. One meaning, one colour.
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(.tint.opacity(isMarked ? 0.18 : 0))
            )
            .animation(.easeOut(duration: Self.markFade), value: isMarked)
            .padding(.horizontal, metrics.padding - 8)
            .frame(maxWidth: .infinity)
    }

    // MARK: When the agent wrote the same passage

    /// Said in a line, with theirs rendered under it and one way to take it. The
    /// person's text is already on disk by the time this shows; the card is what
    /// keeps the agent's version from vanishing without a word (FR-014, FR-015).
    private func collisionCard(_ theirs: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("The agent changed this passage while you were typing. Yours is kept; theirs is below.")
                .appText(.fine)
                .foregroundStyle(.secondary)
            if !theirs.isEmpty {
                MarkdownText(markdown: theirs, base: url)
                    .foregroundStyle(.secondary)
            } else {
                Text("They had removed it.")
                    .appText(.fine)
                    .foregroundStyle(.tertiary)
            }
            HStack(spacing: 8) {
                if !theirs.isEmpty {
                    Button("Use theirs") {
                        editing?.draft = theirs
                        collision = nil
                        commit()
                    }
                }
                Button("Keep mine") { collision = nil }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(8)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: Typing

    private var draftBinding: Binding<String> {
        Binding(get: { editing?.draft ?? "" },
                set: { editing?.draft = $0 })
    }

    private func begin(_ index: Int) {
        // Opening another passage closes this one, writing it first.
        if editing != nil { close() }
        guard passages.indices.contains(index) else { return }
        // Opened while the agent's caret is in it, or waiting for it: the person gets
        // the whole of it at once, and the agent's caret moves on to the next block.
        pending.removeAll { $0.index == index }
        if revealing?.index == index { next() }
        editing = Editing(index: index, base: passages[index].source, draft: passages[index].source)
        saveProblem = nil
    }

    /// The draft is due on disk: the document with this passage's draft in place of
    /// its source, whole, handed to the daemon (FR-011).
    private func commit() {
        guard let current = editing, current.draft != current.base,
              passages.indices.contains(current.index) else { return }
        var edited = passages
        edited[current.index].source = current.draft
        let document = Passage.join(edited)
        lastWritten = document
        Task {
            let problem = await model.writeArtifact(agentID: agentID, path: url.path, text: document)
            saveProblem = problem
            if problem == nil { editing?.base = current.draft }
        }
    }

    private func close() {
        commit()
        editing = nil
    }

    // MARK: Typing it out

    /// What the passage shows right now: all of it; or, when the caret is in it, as
    /// much as has been typed (the caret itself is drawn by `MarkdownText`, with the
    /// agent's name over it); or, when it is still waiting its turn, only what was
    /// there before the write.
    private func shown(_ index: Int) -> String {
        if let current = revealing, current.index == index {
            return String(passages[index].source.prefix(current.shown))
        }
        if let waiting = pending.first(where: { $0.index == index }) {
            return waiting.before
        }
        return passages[index].source
    }

    /// Queue these passages to be typed, in document order, and put the caret in the
    /// first of them. Returns the ones it took, so the caller knows whether the caret
    /// will take the view there or it has to go by hand.
    @discardableResult
    private func reveal(_ indices: [Int], previous: [Passage]) -> Set<Int> {
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
        start()
        return Set([first.index] + queue.map(\.index))
    }

    /// Everything on its way is shown whole, now: the caret goes, and every queued
    /// passage draws in full.
    private func complete() {
        typist?.cancel()
        typist = nil
        revealing = nil
        pending = []
    }

    private func start() {
        typist?.cancel()
        typist = Task {
            while !Task.isCancelled, revealing != nil {
                try? await Task.sleep(for: Self.typingTick)
                guard !Task.isCancelled, var current = revealing else { return }
                guard passages.indices.contains(current.index) else { next(); continue }
                current.shown += Self.typingStep
                if current.shown >= passages[current.index].source.count {
                    next()
                } else {
                    revealing = current
                }
            }
        }
    }

    /// The caret has finished a block: on to the next one, or off the page.
    private func next() {
        revealing = pending.isEmpty ? nil : pending.removeFirst()
    }

    // MARK: Following

    private func load(_ text: String) {
        passages = Passage.split(text)
        lastLoaded = text
        images = ImageStamps.take(passages: passages, base: url)
    }

    /// New text on disk: what changed is marked, and the view goes to the first of it
    /// unless the person is typing.
    private func follow(_ new: String, proxy: ScrollViewProxy) {
        if new == lastWritten {
            // The person's own save, back through the folder watch. Not news: no
            // mark, no scroll. The passages are re-split because the draft may have
            // gained or lost a blank line; if it did, the editor's index no longer
            // names one passage and it closes rather than guess.
            let fresh = Passage.split(new)
            if let current = editing,
               fresh.indices.contains(current.index), fresh[current.index].source == current.draft {
                passages = fresh
            } else {
                passages = fresh
                editing = nil
            }
            lastLoaded = new
            images = ImageStamps.take(passages: passages, base: url)
            return
        }
        let change = PassageChange.between(old: lastLoaded, new: new)
        let previous = passages
        guard let current = editing, passages.indices.contains(current.index) else {
            passages = Passage.split(new)
            lastLoaded = new
            images = ImageStamps.take(passages: passages, base: url)
            guard let first = change.first else { return }
            let typed = reveal(Array(change.changed), previous: previous)
            // A block being typed is taken to by the caret, which moves the view to
            // each one as it reaches it. Only a change with nothing to type — a
            // deletion — needs the view moved by hand.
            if typed.isEmpty { Task { await go(to: first, proxy: proxy) } }
            return
        }
        // Somebody else wrote while a passage is open. The draft is carried across:
        // spliced in where its lines now are, or kept in place of what they wrote
        // there with theirs shown beside it. Either way the result goes to disk, so
        // the file holds both (FR-012), and the view does not move (FR-013).
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
        images = ImageStamps.take(passages: passages, base: url)
        editing = Editing(index: index, base: current.draft, draft: current.draft)
        reveal(Array(change.changed).filter { $0 != index }, previous: previous)
        if merged != new {
            lastWritten = merged
            Task {
                saveProblem = await model.writeArtifact(agentID: agentID, path: url.path, text: merged)
            }
        }
    }

    private func mark(_ indices: [Int]) {
        let now = Date()
        for index in indices { marked[index] = now }
        Task {
            try? await Task.sleep(for: Self.markHold)
            // Only the mark set now. A passage marked again since keeps its newer one.
            for index in indices where marked[index] == now {
                marked[index] = nil
            }
        }
    }

    /// A beat, so the scroll happens after the rows it is scrolling to exist. Without
    /// it the reader is asked to find a row the lazy stack has not built — the same
    /// beat `FileLines` takes, for the same reason.
    private func go(to index: Int, proxy: ScrollViewProxy) async {
        try? await Task.sleep(for: .milliseconds(50))
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(index, anchor: .center)
        }
    }
}
