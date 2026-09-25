import SwiftUI

/// A file's text, a row to a line, numbered.
///
/// Numbered because of `show_file`: an agent that says "line 412" is naming something
/// the reader has to be able to find, and a wall of unnumbered text does not let them
/// check that what they are looking at is what was meant.
///
/// Long lines wrap rather than running off to the right. The column is 380 points by
/// default, and scrolling sideways through code in a strip that narrow is worse than
/// reading it folded.
struct FileLines: View {
    let text: String
    /// The line to put the reader on, counted from one, or nil for the top.
    let line: Int?

    /// Split once, when the view is made, rather than on every pass of `body` and
    /// once more for every row drawn.
    private let lines: [Substring]
    private let gutter: Double

    init(text: String, line: Int?) {
        self.text = text
        self.line = line
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
                        Text("Line \(line) is past what is shown here.")
                            .appText(.fine)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.bottom, 6)
                    }
                    ForEach(Array(lines.enumerated()), id: \.offset) { number, content in
                        row(number: number + 1, content: content)
                    }
                }
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
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
    }

    private func row(number: Int, content: Substring) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number)")
                .foregroundStyle(.tertiary)
                .frame(width: gutter, alignment: .trailing)
            Text(content.isEmpty ? " " : String(content))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .appText(.code)
        .padding(.horizontal, 10)
        .padding(.vertical, 1)
        .background(number == line ? AnyShapeStyle(.tint.opacity(0.18)) : AnyShapeStyle(.clear))
    }

    /// `task(id:)` wants one equatable thing, and both halves matter: the same line in
    /// a different file, or a different line in the same file, are both a new place.
    private struct TaskKey: Equatable {
        let text: String
        let line: Int?
    }
}
