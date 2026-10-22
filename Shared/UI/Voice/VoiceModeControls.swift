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
                Image(systemName: isOn ? "waveform.circle.fill" : "waveform.circle")
                    .appText(.reading).fontWeight(.semibold)
                    .frame(width: 22, height: 22)
                    .symbolEffect(.variableColor, isActive: isOn && voice.phase == .speaking)
            }
            .buttonStyle(.paper)
            .buttonBorderShape(.circle)
            .help(isOn ? "End voice mode" : "Voice mode: say what you want and hear the reply")
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

/// Voice mode's talking area (#2375), in place of the prompt field while voice mode is on in
/// this chat: every word heard for the next prompt as it is heard, or the sentence being
/// said, with Stop, and × to end it.
struct VoiceModeField: View {
    let agentID: UUID
    private var voice: VoiceMode { VoiceMode.shared }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .appText(.reading)
                .foregroundStyle(.tint)
                .frame(width: 22, height: 22)
                .symbolEffect(.variableColor, isActive: voice.phase == .listening || voice.phase == .speaking)
                .accessibilityHidden(true)
            // All of it, never cut: the person sees each word before it goes. No heading
            // over it (Alex, #2375): the mark beside it says what it is doing.
            Text(words)
                .appText(.reading)
                .foregroundStyle(voice.phase == .speaking || voice.heard.isEmpty ? .secondary : .primary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if voice.phase == .speaking {
                Button("Stop") { voice.stopSpeaking() }
                    .buttonStyle(.paper)
                    .help("Stop the voice. The reply stays on the screen. Or talk over it.")
            }
            // The way back to typing, and the only other control while it is on (#2375).
            Button {
                voice.turnOff()
            } label: {
                Image(systemName: "xmark")
                    .appText(.reading).fontWeight(.semibold)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.paper)
            .buttonBorderShape(.circle)
            .help("End voice mode and type instead")
            .accessibilityLabel("End voice mode")
        }
        .padding(14)
        .frame(minHeight: 70, alignment: .top)
        .paperRaised(in: RoundedRectangle(cornerRadius: 18))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Voice mode")
    }

    private var icon: String {
        switch voice.phase {
        case .speaking: "speaker.wave.2"
        case .listening: "waveform"
        default: "ellipsis"
        }
    }

    /// The words heard, or the sentence being said, or what it waits for.
    private var words: String {
        switch voice.phase {
        case .off: ""
        case .loading: "Getting the voice ready…"
        case .sending: voice.heard.isEmpty ? "Sending…" : voice.heard
        case .speaking: voice.saying ?? "Speaking…"
        case .listening:
            if !voice.heard.isEmpty { voice.heard }
            else if voice.isAsking { "Say your answer." }
            else if voice.isWaitingForReply { "Working on it. You can say more." }
            else { "Say what you want." }
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
