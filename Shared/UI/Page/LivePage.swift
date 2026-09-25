import AgentsKitCore
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
/// One page on the Mac and the phone (034). What it decides is `PageFollower`'s, under
/// test; what it draws is here; where it saves and how it reads a picture come from
/// `PageActions`, which is the only thing the two apps give it differently.
///
/// What is real here is `PageMetrics`: the width comes from the pane, the measure and
/// the padding from the kit, and the page centres itself once the pane is wider than
/// it needs to be. FR-004 of 007 still holds: no sheet edge, no shadow, no drawn border
/// — the paper is the space and the type.
struct LivePage: View {
    @Environment(\.pageActions) private var actions

    let text: String
    /// Where the document is, so an image beside it can be found.
    let url: URL
    /// The line an agent named, or nil. Read once when it changes: the view goes to
    /// the passage holding it and marks it (FR-007), and then the line is spent.
    let line: Int?
    /// What the agent is called, for the name over its caret: its runtime's name.
    var agentName = "Agent"
    /// Bumped by the pane on every folder event, including the ones that leave the
    /// document's text alone. That is when a picture beside it may have changed, and
    /// a picture is not in the text (FR-020).
    var folderEvent = 0
    /// Bumped when the connection to the Mac comes back, so a draft that could not be
    /// saved is carried across whatever happened meanwhile and saved (034 FR-009).
    var reconnection = 0

    @State private var page = PageFollower()
    @State private var typist: Task<Void, Never>?
    /// Which passages are marked, and when each mark was set. A mark is not a flag
    /// but a moment, so a passage marked twice in a second fades from the second.
    ///
    /// Only the line an agent names is marked now (FR-007). A write is not: the caret
    /// typing it in is how the page says where it changed, and a tint flashing behind
    /// each block as well was one signal too many.
    @State private var marked: [Int: Date] = [:]
    /// The pictures on the page and when each file last changed.
    @State private var images = ImageStamps()
    /// Bumped for each save handed out, so an older answer landing late is not taken
    /// for the newer one's.
    @State private var saving = 0

    /// The caret's beat: `PageFollower.typingStep` characters every tick, fifty a
    /// second.
    private static let typingTick: Duration = .milliseconds(40)

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
                        ForEach(page.passages.indices, id: \.self) { index in
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
                    perform(page.follow(new), proxy: proxy)
                    startTyping()
                    Task { await retakeImages() }
                }
                .onChange(of: folderEvent) {
                    Task {
                        let (fresh, changed) = await images.refreshed(look: actions.stamp)
                        images = fresh
                        guard let first = changed.first, !page.isEditing else { return }
                        await go(to: first, proxy: proxy)
                    }
                }
                .onChange(of: reconnection) {
                    perform(page.reconnected(text), proxy: proxy)
                    startTyping()
                }
                // The view follows the caret from block to block, which is the whole
                // of what a reader has to do to read along with it. It stays put while
                // the person is typing, the same as every other move this page makes.
                .onChange(of: page.revealing?.index) { _, new in
                    guard let new, !page.isEditing else { return }
                    Task { await go(to: new, proxy: proxy) }
                }
                .onDisappear {
                    typist?.cancel()
                    page.complete()
                }
                .task(id: line) {
                    guard let line, let index = page.index(containing: line) else { return }
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
            if page.editing?.index == index {
                VStack(alignment: .leading, spacing: 4) {
                    PassageEditor(draft: draftBinding, onCommit: commit, onClose: {
                        // Only this passage's editor may close itself. Focus leaving it
                        // because another passage was opened arrives after that one is
                        // open, and must not close it.
                        if page.editing?.index == index { close() }
                    })
                    .disabled(!actions.canEdit)
                    if let saveProblem = page.saveProblem {
                        Text("Not saved: \(saveProblem)")
                            .appText(.fine)
                            .foregroundStyle(.secondary)
                    }
                    if let collision = page.collision {
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
                    MarkdownText(markdown: page.shown(index), base: url,
                                 caret: page.revealing?.index == index ? .agent(agentName) : nil)
                        // A new identity when a picture in it changed, which is what
                        // makes the file be read again rather than redrawn.
                        .id(images.token(for: index))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!actions.canEdit)
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
                    Button("Use theirs") { save(page.takeTheirs()) }
                }
                Button("Keep mine") { page.keepMine() }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(8)
        .paperWell(in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: Typing

    private var draftBinding: Binding<String> {
        Binding(get: { page.editing?.draft ?? "" },
                set: { page.edit($0) })
    }

    private func begin(_ index: Int) {
        save(page.begin(index))
    }

    private func commit() {
        save(page.commit())
    }

    private func close() {
        save(page.close())
    }

    /// Hand each document to the daemon and tell the page how it went.
    private func save(_ effects: [PageFollower.Effect]) {
        for effect in effects {
            guard case .save(let document) = effect else { continue }
            let draft = page.editing?.draft ?? ""
            saving += 1
            let mine = saving
            Task {
                let problem = await actions.save(url.path, document)
                // A later save has been handed out since: its answer is the one that
                // counts, and this one would only say something stale.
                guard mine == saving else { return }
                page.saved(problem: problem, draft: draft)
            }
        }
    }

    private func perform(_ effects: [PageFollower.Effect], proxy: ScrollViewProxy) {
        save(effects)
        for effect in effects {
            if case .scroll(let index) = effect { Task { await go(to: index, proxy: proxy) } }
        }
    }

    // MARK: Typing it out

    private func startTyping() {
        guard page.revealing != nil else { return }
        typist?.cancel()
        typist = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.typingTick)
                guard !Task.isCancelled, page.tick() else { return }
            }
        }
    }

    // MARK: Following

    private func load(_ text: String) {
        page.load(text)
        Task { await retakeImages() }
    }

    private func retakeImages() async {
        images = await ImageStamps.take(passages: page.passages, base: url, look: actions.stamp)
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
