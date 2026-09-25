import CodeText
import SwiftUI

/// One line of code, coloured by what each part of it is (041 FR-001).
///
/// Only the text is here. Line numbers and change marks are drawn beside it as views of
/// their own, so selecting and copying lines gives the code and nothing else (FR-006).
struct CodeLine: View {
    let text: Substring
    let spans: [CodeSpan]

    var body: some View {
        Text(text.isEmpty ? AttributedString(" ") : styled)
            .appText(.code)
            // Read as the code, not as its colours.
            .accessibilityLabel(String(text))
    }

    private var styled: AttributedString {
        CodeText.attributed(text, spans: spans, style: CodeInk.attributes(for:))
    }
}
