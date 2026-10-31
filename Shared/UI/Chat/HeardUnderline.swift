import SwiftUI

/// The words dictation is still hearing, underlined until they settle (#448).
///
/// A plain-text field cannot style part of its text, so this is the same text laid
/// over the field, invisible but for the underline. The field itself is left as it is.
/// Once the text is taller than the field, the field scrolls and the copy could not
/// follow it, so then nothing is drawn.
///
/// When the first volatile words arrive late, `Dictation.heardWords` is nil and this
/// draws nothing. The button's pulse is the listening mark instead (#2515).
struct HeardUnderline: View {
    let dictation: Dictation
    let text: String

    var body: some View {
        if let heard = dictation.heardWords, heard.upperBound <= text.count {
            ViewThatFits(in: .vertical) {
                Text(Self.underlining(heard, of: text))
                    .appText(.reading)
                    .fixedSize(horizontal: false, vertical: true)
                Color.clear
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private static func underlining(_ heard: Range<Int>, of text: String) -> AttributedString {
        var styled = AttributedString(text)
        styled.foregroundColor = .clear
        let lower = styled.index(styled.startIndex, offsetByCharacters: heard.lowerBound)
        let upper = styled.index(lower, offsetByCharacters: heard.count)
        styled[lower..<upper].underlineStyle = Text.LineStyle(pattern: .solid, color: .secondary)
        return styled
    }
}
