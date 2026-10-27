import AgentsKitCore
import SwiftUI

/// The prompt bar's voice button (#2322), beside the dictate button, while Settings has
/// voice mode on. It turns voice mode on in this chat, or in a new session (#2375), whose
/// first words start it. On, `VoiceModeBar` takes the bar's place.
struct VoiceModeButton: View {
    /// Nil for a new session, not started yet.
    let agentID: UUID?
    /// Words for the recogniser that a dictionary would not have: agent, file and runtime names.
    /// Run when voice mode starts, not in `body`, which then does not read every agent (#2732).
    var vocabulary: () -> [String] = { [] }
    /// Whether "Hey Agents" (#2420) turns voice mode on here, as a press does, with the words
    /// said after the phrase. One bar of a chat takes it: the main window's.
    var takesWake = false
    /// Sends the words as a voice prompt, and says which chat took them.
    let send: VoiceMode.Send

    @AppStorage(VoiceSettings.onKey, store: WindowDefaults.store) private var isEnabled = VoiceSettings.onAtFirst
    @Environment(\.openURL) private var openURL
    @State private var isPriming = false
    private var voice: VoiceMode { VoiceMode.shared }

    var body: some View {
        if isEnabled {
            Button {
                #if os(iOS)
                // Our own words before the system asks, the first time, as Dictate has (#2444).
                guard voice.dictation.hasBeenAsked else {
                    isPriming = true
                    return
                }
                #endif
                voice.turnOn(in: agentID, vocabulary: vocabulary(), send: send)
            } label: {
                Image(systemName: "waveform.circle")
                    .appText(.reading).fontWeight(.semibold)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.paper)
            .buttonBorderShape(.circle)
            .help("Voice mode: say what you want and hear the reply")
            .accessibilityLabel("Voice mode")
            .onChange(of: voice.wake, initial: true) {
                guard takesWake, let wake = voice.takeWake(for: agentID) else { return }
                voice.turnOn(in: agentID, vocabulary: vocabulary(), words: wake.words, send: send)
            }
            #if os(iOS)
            .sheet(isPresented: $isPriming) {
                DictationPrimer(title: PromptWords.voicePrimerTitle, what: PromptWords.voicePrimer,
                                notNow: { isPriming = false },
                                continue: {
                                    isPriming = false
                                    voice.turnOn(in: agentID, vocabulary: vocabulary(), send: send)
                                })
                .paperSheet()
            }
            #endif
            .alert("Voice mode", isPresented: Binding(get: { voice.problem != nil },
                                                      set: { if !$0 { voice.dismissProblem() } })) {
                // Where a switch would fix it, offer to open the switch, as Dictate does (#2444).
                if let permission = voice.problemPermission {
                    Button("Open Settings") { openURL(permission.settings) }
                }
                Button("OK", role: .cancel) {}
            } message: {
                Text(voice.problem ?? "")
            }
        }
    }
}

/// Voice mode in place of the whole prompt bar (#2375), field and pills: the blue waveform,
/// moving while it listens or speaks, the words heard or said, never cut, and Stop (or
/// Escape) to end it (#2517).
struct VoiceModeBar: View {
    private var voice: VoiceMode { VoiceMode.shared }
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverIsOn

    /// VoiceOver, or a walk that says it is on (#2446).
    private var tellsVoiceOver: Bool { voiceOverIsOn || voice.walkVoiceOver }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            strip
            // Its speech is a voice the microphone hears (#2446).
            if tellsVoiceOver {
                Text(VoiceModeWords.voiceOverNote)
                    .appText(.supporting)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
            }
        }
        // VoiceOver is told what only the strip says: on, off, and what it waits for. The
        // voice and the sounds say the rest (#2446).
        .onAppear {
            if tellsVoiceOver { voice.announce(VoiceModeWords.on) }
        }
        .onDisappear {
            if tellsVoiceOver { voice.announce(VoiceModeWords.off) }
        }
        .onChange(of: voice.phase == .listening ? voice.hint : "") { _, hint in
            if tellsVoiceOver { voice.announce(hint) }
        }
    }

    private var strip: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "waveform")
                .appText(.reading)
                .foregroundStyle(.tint)
                .frame(width: 22, height: 22)
                .symbolEffect(.variableColor.iterative, isActive: voice.phase == .listening || voice.phase == .speaking)
                .accessibilityHidden(true)
            Text(words)
                .appText(.reading)
                .foregroundStyle(voice.heard.isEmpty || voice.phase == .speaking ? .secondary : .primary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            // While an answer waits two seconds for a "no", a touch can stop it too (#2443).
            if voice.confirmLine != nil {
                Button("Don't Send") { voice.dontSend() }
                    .buttonStyle(.paper)
                    .help("Don't send this answer; the question is asked again")
            }
            Button {
                voice.turnOff()
            } label: {
                Image(systemName: PromptWords.stopSymbol)
                    .appText(.reading).fontWeight(.semibold)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.paper)
            .buttonBorderShape(.circle)
            .keyboardShortcut(.cancelAction)
            .help("Stop voice mode (Esc)")
            .accessibilityLabel("Stop voice mode")
        }
        .padding(14)
        .paperRaised(in: RoundedRectangle(cornerRadius: 18))
        .background {
            Button("Send") { voice.sendNow() }
                .keyboardShortcut(.defaultAction)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Voice mode")
    }

    /// The words heard, or the sentence being said, or what it waits for.
    private var words: String {
        switch voice.phase {
        case .listening, .sending: voice.heard.isEmpty || voice.confirmLine != nil ? voice.hint : voice.heard
        default: voice.hint
        }
    }
}

extension View {
    /// Tells voice mode what this chat shows, so it can speak a reply when a turn ends.
    /// Does nothing unless voice mode is on in this chat.
    /// `question` is the form the agent waits on, and `answer` sends an answer to it;
    /// `permission` the request it waits on, and `approve` answers it (#2358).
    func voiceModeObserves(_ agent: Agent, items: [TranscriptItem], question: ElicitationRequest?,
                           permission: PermissionRequest?, approve: @escaping VoiceMode.Approve,
                           answer: @escaping VoiceMode.Answer) -> some View {
        modifier(VoiceModeObserver(agent: agent, items: items, question: question, permission: permission,
                                   approve: approve, answer: answer))
    }
}

private struct VoiceModeObserver: ViewModifier {
    let agent: Agent
    let items: [TranscriptItem]
    let question: ElicitationRequest?
    let permission: PermissionRequest?
    let approve: VoiceMode.Approve
    let answer: VoiceMode.Answer

    /// What changes when a turn moves on: cheap to compare, unlike the items.
    private struct Key: Equatable {
        /// So the chat is seen the moment voice mode turns on in it.
        var isOn: Bool
        var state: AgentState
        var count: Int
        var last: TranscriptItem?
        var question: UUID?
        var permission: UUID?
    }

    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        let isOn = VoiceMode.shared.isOn(in: agent.id)
        content.onChange(of: Key(isOn: isOn, state: agent.state, count: items.count, last: items.last,
                                 question: question?.id, permission: permission?.id), initial: true) {
            guard isOn else { return }
            VoiceMode.shared.observe(agent, items: items, question: question, answer: answer,
                                     permission: permission, approve: approve)
        }
        // Another chat opened in this place, or this one closed: voice mode ends (#2388).
        .onChange(of: agent.id) { old, _ in VoiceMode.shared.leave(old) }
        .onDisappear { VoiceMode.shared.leave(agent.id) }
        #if os(iOS)
        // The phone put away: voice mode ends (Alex, U20261022-49).
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { VoiceMode.shared.leave(agent.id) }
        }
        #endif
    }
}
