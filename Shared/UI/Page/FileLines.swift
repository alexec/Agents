import CodeText
import SwiftUI

/// A file's text, a row to a line, numbered, and coloured when its language is known (041).
///
/// Numbered because of `show_file`: an agent that says "line 412" is naming something
/// the reader has to be able to find, and a wall of unnumbered text does not let them
/// check that what they are looking at is what was meant.
///
/// Long lines wrap rather than running off to the right. The column is 380 points by
/// default, and scrolling sideways through code in a strip that narrow is worse than
/// reading it folded.
///
/// The text is drawn at once and plain; colour follows a window of lines at a time, so a
/// large file is never held back by its colouring (041 FR-017).
struct FileLines: View {
    let text: String
    /// The line to put the reader on, counted from one, or nil for the top.
    let line: Int?
    /// Where the reader was, kept by a pane that is drawn afresh on a phone (034).
    var place: Binding<Int?>? = nil
    /// The file's path, which says what language it is (041). Nil draws it plain.
    var path: String? = nil

    /// Split once, when the view is made, rather than on every pass of `body` and
    /// once more for every row drawn.
    private let lines: [Substring]
    private let gutter: Double

    /// Made when the view first appears rather than in `init`, which runs on every redraw
    /// of whatever holds this view, and would start a parse each time.
    @State private var document: CodeDocument?

    init(text: String, line: Int?, place: Binding<Int?>? = nil, path: String? = nil) {
        self.text = text
        self.line = line
        self.place = place
        self.path = path
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        self.lines = lines
        // Wide enough for the biggest number this will draw. The pane shows the first
        // 128 KB of a file, so that is five digits at the very most.
        self.gutter = lines.count < 1_000 ? 24 : 40
    }

    var body: some View {
        ScrollViewReader { reader in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    // Only the first 128 KB of a file is read, so an agent naming a
                    // line deep in a big one is naming a place this cannot go. Said,
                    // rather than left as a view that quietly did not move.
                    if let line, line > lines.count {
                        note("Line \(line) is past what is shown here.")
                    }
                    // A file too big or too long-lined to colour says so (FR-018), rather
                    // than looking like a language the app does not know.
                    if let reason = document?.plainBecause {
                        note(reason.message)
                    }
                    ForEach(Array(lines.enumerated()), id: \.offset) { number, content in
                        FileLineRow(number: number + 1, content: content, gutter: gutter,
                                    named: number + 1 == line, document: document)
                    }
                }
                .scrollTargetLayout()
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .keepsPlace(place)
            // Runs again when the agent names a different line in the same file, which
            // is the case a plain `onAppear` would sleep through.
            .task(id: TaskKey(text: text, line: line)) {
                guard let line, line <= lines.count else { return }
                // A beat, so the scroll happens after the rows it is scrolling to
                // exist. Without it the reader is asked to find a row the lazy stack
                // has not built.
                try? await Task.sleep(for: .milliseconds(50))
                withAnimation(.easeOut(duration: 0.2)) {
                    reader.scrollTo(line - 1, anchor: .center)
                }
            }
        }
        .textSelection(.enabled)
        .onAppear {
            if document == nil { document = makeDocument() }
        }
        .onChange(of: path) {
            document = makeDocument()
        }
        // The same file, changed: an agent still writing it. Reparsed around the change,
        // keeping the colour of everything above it (R7).
        .onChange(of: text) {
            document?.update(text: text)
        }
    }

    private func note(_ message: String) -> some View {
        Text(message)
            .appText(.fine)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
    }

    private func makeDocument() -> CodeDocument? {
        guard let path else { return nil }
        let language = CodeLanguage.detect(path: path, firstLine: lines.first)
        let document = CodeDocument(text: text, language: language)
        // The rows on screen may have appeared before this existed; ask for where the
        // reader is, and rows appearing from here on ask for their own.
        document.appear(line: max((line ?? 1) - 1, 0))
        return document
    }

    /// `task(id:)` wants one equatable thing, and both halves matter: the same line in
    /// a different file, or a different line in the same file, are both a new place.
    private struct TaskKey: Equatable {
        let text: String
        let line: Int?
    }
}

/// One numbered line. A view of its own so that colour arriving for a window of lines
/// redraws those rows, not the whole file.
private struct FileLineRow: View {
    let number: Int
    let content: Substring
    let gutter: Double
    let named: Bool
    let document: CodeDocument?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number)")
                .foregroundStyle(.tertiary)
                .frame(width: gutter, alignment: .trailing)
            CodeLine(text: content, spans: document?.spans(line: number - 1) ?? [])
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .appText(.code)
        .padding(.horizontal, 10)
        .padding(.vertical, 1)
        .background(named ? AnyShapeStyle(.tint.opacity(0.18)) : AnyShapeStyle(.clear))
        // On appearing, and again when the document arrives after the row did.
        .task(id: document.map(ObjectIdentifier.init)) { document?.appear(line: number - 1) }
    }
}
