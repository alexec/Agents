import AgentsKitCore
import SwiftUI

/// The prompt bar's voice button (#2322), beside the dictate button, while Settings has
/// voice mode on. It turns voice mode on in this chat, and off again.
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

/// What voice mode is doing in this chat, over the prompt bar: listening (and the words
/// heard), sending, working, or speaking (and the sentence said), with Stop and End.
struct VoiceModeStrip: View {
    let agentID: UUID
    private var voice: VoiceMode { VoiceMode.shared }

    var body: some View {
        if voice.isOn(in: agentID) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .foregroundStyle(.tint)
                    .symbolEffect(.variableColor, isActive: voice.phase == .listening || voice.phase == .speaking)
                    .accessibilityHidden(true)
                Text(words)
                    .appText(.supporting)
                    .foregroundStyle(voice.phase == .listening && !voice.heard.isEmpty ? .primary : .secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if voice.phase == .speaking {
                    Button("Stop") { voice.stopSpeaking() }
                        .buttonStyle(.paper)
                        .help("Stop the voice. The reply stays on the screen.")
                }
                Button {
                    voice.turnOff()
                } label: {
                    Image(systemName: "xmark")
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.paper)
                .buttonBorderShape(.circle)
                .help("End voice mode")
                .accessibilityLabel("End voice mode")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Voice mode")
        }
    }

    private var icon: String {
        switch voice.phase {
        case .speaking: "speaker.wave.2"
        case .listening: "waveform"
        default: "ellipsis"
        }
    }

    private var words: String {
        switch voice.phase {
        case .off: ""
        case .loading: "Getting the voice ready…"
        case .sending: "Sending…"
        case .speaking: voice.saying ?? "Speaking…"
        case .listening:
            if !voice.heard.isEmpty { voice.heard }
            else if voice.isWaitingForReply { "Working on it. You can say more." }
            else { "Listening. Say what you want." }
        }
    }
}

extension View {
    /// Tells voice mode what this chat shows, so it can speak a reply when a turn ends.
    /// Does nothing unless voice mode is on in this chat.
    func voiceModeObserves(_ agent: Agent, items: [TranscriptItem]) -> some View {
        modifier(VoiceModeObserver(agent: agent, items: items))
    }
}

private struct VoiceModeObserver: ViewModifier {
    let agent: Agent
    let items: [TranscriptItem]

    /// What changes when a turn moves on: cheap to compare, unlike the items.
    private struct Key: Equatable {
        /// So the chat is seen the moment voice mode turns on in it.
        var isOn: Bool
        var state: AgentState
        var count: Int
        var last: TranscriptItem?
    }

    func body(content: Content) -> some View {
        let isOn = VoiceMode.shared.isOn(in: agent.id)
        content.onChange(of: Key(isOn: isOn, state: agent.state, count: items.count, last: items.last), initial: true) {
            guard isOn else { return }
            VoiceMode.shared.observe(agent, items: items)
        }
    }
}
