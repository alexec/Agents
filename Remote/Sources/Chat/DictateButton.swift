import SwiftUI

/// A prompt bar's dictate button (#427), with our own words before the system's first ask
/// and the alert when it cannot listen. The chat's bar and the new agent's bar use this one
/// (#2300), so the button cannot be in one and not in the other again. The bar keeps the
/// `Dictation`, as it alone knows its field, its cursor and when it sends; `begin` starts it.
struct DictateButton: View {
    let dictation: Dictation
    /// Starts listening at the bar's cursor, after the primer the first time.
    let begin: () -> Void

    @State private var isPriming = false

    var body: some View {
        Button(action: toggle) {
            Image(systemName: dictation.isListening ? "waveform" : "microphone")
                .appText(.reading).fontWeight(.semibold)
                .frame(width: 22, height: 22)
                .symbolEffect(.variableColor, isActive: dictation.isListening)
        }
        .buttonStyle(.paper)
        .buttonBorderShape(.circle)
        .accessibilityLabel(dictation.isListening ? "Stop dictating" : "Dictate")
        .sheet(isPresented: $isPriming) { primer.paperSheet() }
        .alert("Dictation", isPresented: Binding(get: { dictation.problem != nil },
                                                 set: { if !$0 { dictation.dismissProblem() } })) {
            // Where a switch would fix it, offer to open the switch.
            if let permission = dictation.problem?.permission {
                Button("Open Settings") { UIApplication.shared.open(permission.settings) }
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text(dictation.problem?.message ?? "")
        }
    }

    private func toggle() {
        if dictation.isListening {
            dictation.stop()
        } else if dictation.hasBeenAsked {
            begin()
        } else {
            isPriming = true
        }
    }

    /// Our own words before the system's alert, the first time only.
    private var primer: some View {
        DictationPrimer(title: PromptWords.dictationPrimerTitle,
                        what: PromptWords.dictationPrimer,
                        notNow: { isPriming = false },
                        continue: {
                            isPriming = false
                            begin()
                        })
    }
}

/// The words dictation is still hearing, underlined as system dictation does until they
/// settle (#448). A plain-text field cannot style part of its text, so this is the same
/// text laid over the field, invisible but for the underline. The field itself is left
/// exactly as it is: its keys, paste, focus and height. Once the text is taller than the
/// field, the field scrolls and the copy could not follow it, so then nothing is drawn.
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
