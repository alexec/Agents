import SwiftUI

/// A prompt bar's dictate button (#427), with our own words before the system's first ask
/// and the alert when it cannot listen. The chat's bar and the new agent's bar use this one
/// (#2300), so the button cannot be in one and not in the other again. The bar keeps the
/// `Dictation`, as it alone knows its field, its cursor and when it sends; `begin` starts it.
struct DictateButton: View {
    let dictation: Dictation
    /// Starts listening at the bar's cursor, after the primer the first time.
    let begin: () -> Void
    /// Sends the prompt after a held press ends.
    let send: () -> Void

    @State private var isPriming = false

    var body: some View {
        PushToTalkButton(tap: toggle, begin: beginPushToTalk, end: finishPushToTalk, cancel: dictation.stop) {
            // The microphone, blue while it listens: the waveform is voice mode's (Alex, 2026-10-29).
            Image(systemName: "microphone")
                .appText(.reading).fontWeight(.semibold)
                .foregroundStyle(dictation.isListening ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                .frame(width: 22, height: 22)
                .symbolEffect(.variableColor.iterative, isActive: dictation.isListening)
        }
        .buttonStyle(.paper)
        .buttonBorderShape(.circle)
        .accessibilityLabel(dictation.isListening ? "Stop dictating" : "Dictate")
        // Voice mode listens already: one listener at a time (#2445).
        .disabled(VoiceMode.shared.isOn && !dictation.isListening)
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

    private func beginPushToTalk() {
        guard !VoiceMode.shared.isOn, !dictation.isListening else { return }
        if dictation.hasBeenAsked { begin() }
        else { isPriming = true }
    }

    /// Sends once the last words said are in the field (#2753).
    private func finishPushToTalk() {
        guard dictation.isListening else { return }
        Task {
            await dictation.finish()
            send()
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
