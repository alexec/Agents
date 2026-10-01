import CodeText
import SwiftUI

/// One line of code, coloured by what each part of it is (041 FR-001).
///
/// Only the text is here. Line numbers and change marks are drawn beside it as views of
/// their own, so selecting and copying lines gives the code and nothing else (FR-006).
///
/// In a diff, `changed` ranges sit on a neutral wash, stronger than the line's own, over
/// the syntax colour rather than instead of it (FR-009, FR-011).
///
/// No accessibility label of its own: the row it sits in is the one element, and says
/// what the line is. A label here, on a `Text` that selectable text backs with an AppKit
/// view, sent the first accessibility query round between the two until the stack ran
/// out (#71, and the diff rows before it).
struct CodeLine: View {
    let text: Substring
    let spans: [CodeSpan]
    var changed: [Range<Int>] = []

    var body: some View {
        Text(text.isEmpty ? AttributedString(" ") : styled)
            .appText(.code)
    }

    private var styled: AttributedString {
        var mark = AttributeContainer()
        mark.backgroundColor = CodeInk.changedWash
        return CodeText.attributed(text, spans: spans, style: CodeInk.attributes(for:),
                                   marks: changed, mark: mark)
    }
}
