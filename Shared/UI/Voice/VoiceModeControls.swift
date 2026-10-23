import AgentsKitCore
import SwiftUI

/// The prompt bar's voice button (#2322), beside the dictate button under the prompt
/// (#2375), while Settings has voice mode on. It turns voice mode on in this chat, and off again.
struct VoiceModeButton: View {
    let agentID: UUID
    /// Words for the recogniser that a dictionary would not have: agent, file and runtime names.
    var vocabulary: [String] = []
    /// Sends the words to this chat as a voice prompt, and says whether the host took them.
    let send: (String) async -> Bool

    @AppStorage(VoiceSettings.onKey, store: WindowDefaults.store) private var isEnabled = VoiceSettings.onAtFirst
    private var voice: VoiceMode { VoiceMode.shared }

    var body: some View {
        if isEnabled {
            let isOn = voice.isOn(in: agentID)
            Button {
                if isOn {
                    voice.turnOff()
                } else {
                    voice.turnOn(in: agentID, vocabulary: vocabulary, send: send)
                }
            } label: {
                Image(systemName: isOn ? "xmark" : "waveform.circle")
                    .appText(.reading).fontWeight(.semibold)
                    .frame(width: 22, height: 22)
                    .symbolEffect(.variableColor, isActive: isOn && voice.phase == .speaking)
            }
            .buttonStyle(.paper)
            .buttonBorderShape(.circle)
            // On, it is × and Escape ends it (#2375).
            .keyboardShortcut(isOn ? .cancelAction : nil)
            .help(isOn ? "End voice mode (Esc)" : "Voice mode: say what you want and hear the reply")
            .accessibilityLabel(isOn ? "End voice mode" : "Voice mode")
            .alert("Voice mode", isPresented: Binding(get: { voice.problem != nil },
                                                      set: { if !$0 { voice.dismissProblem() } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(voice.problem ?? "")
            }
        }
    }
}

extension View {
    /// Voice mode writes what it hears into the prompt field itself (#2375): the bar keeps
    /// its layout, and the words go when the person pauses, as dictation's do. What was
    /// typed before voice mode is left until the first word is heard.
    func voiceModeWrites(into text: Binding<String>, in agentID: UUID?) -> some View {
        modifier(VoiceModeWriter(agentID: agentID, text: text))
    }
}

private struct VoiceModeWriter: ViewModifier {
    let agentID: UUID?
    @Binding var text: String

    func body(content: Content) -> some View {
        let voice = VoiceMode.shared
        let heard = agentID.map(voice.isOn(in:)) == true ? voice.heard : nil
        content.onChange(of: heard) { old, new in
            guard let new, !(old == nil && new.isEmpty) else { return }
            text = new
        }
    }
}

extension View {
    /// Tells voice mode what this chat shows, so it can speak a reply when a turn ends.
    /// Does nothing unless voice mode is on in this chat.
    /// `question` is the form the agent waits on, and `answer` sends an answer to it.
    func voiceModeObserves(_ agent: Agent, items: [TranscriptItem], question: ElicitationRequest?,
                           answer: @escaping VoiceMode.Answer) -> some View {
        modifier(VoiceModeObserver(agent: agent, items: items, question: question, answer: answer))
    }
}

private struct VoiceModeObserver: ViewModifier {
    let agent: Agent
    let items: [TranscriptItem]
    let question: ElicitationRequest?
    let answer: VoiceMode.Answer

    /// What changes when a turn moves on: cheap to compare, unlike the items.
    private struct Key: Equatable {
        /// So the chat is seen the moment voice mode turns on in it.
        var isOn: Bool
        var state: AgentState
        var count: Int
        var last: TranscriptItem?
        var question: UUID?
    }

    func body(content: Content) -> some View {
        let isOn = VoiceMode.shared.isOn(in: agent.id)
        content.onChange(of: Key(isOn: isOn, state: agent.state, count: items.count, last: items.last,
                                 question: question?.id), initial: true) {
            guard isOn else { return }
            VoiceMode.shared.observe(agent, items: items, question: question, answer: answer)
        }
    }
}
