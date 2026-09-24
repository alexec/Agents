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
    let text: String
    /// Where the document is, so an image beside it can be found.
    let url: URL
    /// The line an agent named, or nil. Read once when it changes: the view goes to
    /// the passage holding it and marks it (FR-007), and then the line is spent.
    let line: Int?
    /// True while the person has a passage open for typing. Marks still land; the
    /// view does not move.
    let isEditing: Bool

    @State private var passages: [Passage] = []
    /// Which passages are marked, and when each mark was set. A mark is not a flag
    /// but a moment, so a passage marked twice in a second fades from the second.
    @State private var marked: [Int: Date] = [:]
    /// The text `passages` came from: the base for the next diff.
    @State private var lastLoaded = ""

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
                .font(.system(.callout, design: .serif))
                .textSelection(.enabled)
                .onAppear { load(text) }
                .onChange(of: text) { _, new in
                    follow(new, proxy: proxy)
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
        return MarkdownText(markdown: passages[index].source, base: url)
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

    // MARK: Following

    private func load(_ text: String) {
        passages = Passage.split(text)
        lastLoaded = text
    }

    /// New text on disk: what changed is marked, and the view goes to the first of it
    /// unless the person is typing.
    private func follow(_ new: String, proxy: ScrollViewProxy) {
        let change = PassageChange.between(old: lastLoaded, new: new)
        passages = Passage.split(new)
        lastLoaded = new
        guard let first = change.first else { return }
        mark(Array(change.changed))
        guard !isEditing else { return }
        Task { await go(to: first, proxy: proxy) }
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
