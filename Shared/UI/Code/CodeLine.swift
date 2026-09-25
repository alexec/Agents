import CodeText
import SwiftUI

/// One line of code, coloured by what each part of it is (041 FR-001).
///
/// Only the text is here. Line numbers and change marks are drawn beside it as views of
/// their own, so selecting and copying lines gives the code and nothing else (FR-006).
///
/// In a diff, `changed` ranges sit on a neutral wash, stronger than the line's own, over
/// the syntax colour rather than instead of it (FR-009, FR-011).
struct CodeLine: View {
    let text: Substring
    let spans: [CodeSpan]
    var changed: [Range<Int>] = []

    var body: some View {
        Text(text.isEmpty ? AttributedString(" ") : styled)
            .appText(.code)
            // Read as the code, not as its colours.
            .accessibilityLabel(String(text))
    }

    private var styled: AttributedString {
        var mark = AttributeContainer()
        mark.backgroundColor = CodeInk.changedWash
        return CodeText.attributed(text, spans: spans, style: CodeInk.attributes(for:),
                                   marks: changed, mark: mark)
    }
}
