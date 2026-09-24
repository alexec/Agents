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
/// It follows the agent. When `text` changes, the passages that changed are tinted for
/// a moment and the first of them is scrolled into view — unless the person is typing
/// (FR-013), in which case the marks land and the view stays put. That the view always
/// follows otherwise, even when the reader has scrolled off to read something else, is
/// the proof of concept's rule, and whether it should be softer is one of the things
/// it exists to find out (spec, US1 scenario 6).
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
    @State private var marked: [Int: Date] = [:]
    /// The text `passages` came from: the base for the next diff.
    @State private var lastLoaded = ""
    /// The pictures on the page and when each file last changed.
    @State private var images = ImageStamps()

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
                // Prose in New York, the system serif, at 12pt. Measured for 007: 13pt
                // gives 57 characters at the default pane width and misses the floor
                // of 60. A relative style rather than a fixed size, so Dynamic Type
                // still moves it. Headings, code and chrome stay on the sans and mono
                // faces the rest of the app uses.
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
                    mark(Array(changed).filter { $0 != editing?.index })
                    guard !isEditing else { return }
                    Task { await go(to: first, proxy: proxy) }
                }
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
                    PassageEditor(draft: draftBinding, onCommit: commit, onClose: close)
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
                MarkdownText(markdown: passages[index].source, base: url)
                    // A new identity when a picture in it changed on disk, which is
                    // what makes the file be read again rather than redrawn.
                    .id(images.token(for: index))
                    // The whole passage is the click target, gaps included, so a
                    // click beside a short line still opens it. A `Button` would eat
                    // the drag that selects text; a tap gesture does not.
                    .contentShape(Rectangle())
                    .onTapGesture { begin(index) }
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
        guard let current = editing, passages.indices.contains(current.index) else {
            passages = Passage.split(new)
            lastLoaded = new
            images = ImageStamps.take(passages: passages, base: url)
            guard let first = change.first else { return }
            mark(Array(change.changed))
            Task { await go(to: first, proxy: proxy) }
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
        mark(Array(change.changed).filter { $0 != index })
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
