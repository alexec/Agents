import CodeText
import SwiftUI

/// A fenced code block, coloured by its tag (041 FR-001, US4).
///
/// One `Text` for the whole block rather than a row a line, because a page's caret is drawn
/// after the block's last character (022), and only a single `Text` can carry it there. A
/// block with no tag, or one the app does not know, is plain, as it was.
struct CodeBlockText: View {
    let text: String
    let language: CodeLanguage?
    /// Somebody's caret, drawn after the last character (022).
    var caret: CursorFlag? = nil

    @State private var document: CodeDocument?

    var body: some View {
        Group {
            if let caret {
                Text("\(Text(styled))\(caret.caret)")
            } else {
                Text(styled)
            }
        }
        .onAppear {
            guard document == nil, let language else { return }
            let document = CodeDocument(text: text, language: language)
            // A block is short: ask for all of it.
            for line in stride(from: 0, to: document.lines.count, by: Limits.window) {
                document.appear(line: line)
            }
            self.document = document
        }
        // A message still arriving: the block grows as it streams.
        .onChange(of: text) {
            guard let document else { return }
            document.update(text: text)
            for line in stride(from: 0, to: document.lines.count, by: Limits.window) {
                document.appear(line: line)
            }
        }
    }

    private var styled: AttributedString {
        guard let document, document.plainBecause == nil else { return AttributedString(text) }
        var result = AttributedString()
        for (index, line) in document.lines.enumerated() {
            if index > 0 { result.append(AttributedString("\n")) }
            result.append(CodeText.attributed(line, spans: document.spans(line: index),
                                              style: CodeInk.attributes(for:)))
        }
        return result
    }
}
