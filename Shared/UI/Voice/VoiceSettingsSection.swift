import SwiftUI

/// Whether this device has voice mode (#2322). Off at first: voice mode uses the microphone
/// and loads a voice, and the person turns it on to try it. Kept on this device only, as
/// Show thoughts is (#1725). Off, the chat has no voice button and no voice is loaded.
enum VoiceSettings {
    static let onKey = "voiceMode"
    static let onAtFirst = false
}

/// The Voice mode switch, in Settings on the Mac and the Remote.
struct VoiceSettingsSection: View {
    /// The Remote's Settings page has no title of its own for it, so the section says it.
    var header: String? = nil
    @AppStorage(VoiceSettings.onKey, store: WindowDefaults.store) private var isOn = VoiceSettings.onAtFirst
    #if os(macOS)
    @AppStorage(WakeListener.onKey, store: WindowDefaults.store) private var listensForWake = WakeListener.onAtFirst
    #endif

    var body: some View {
        Section {
            Toggle("Voice mode", isOn: $isOn)
            #if os(macOS)
            // "Hey Agents" (#2420): a way into voice mode, so beside its switch. This Mac only.
            Toggle("Listen for “Hey Agents”", isOn: $listensForWake)
                .disabled(!isOn)
            if let problem = WakeListener.shared.problem, isOn, listensForWake {
                Text(problem)
                    .appText(.fine)
                    .foregroundStyle(.red)
            }
            #endif
        } header: {
            if let header { Text(header) }
        } footer: {
            Text(footer)
                .appText(.fine)
                .foregroundStyle(.secondary)
        }
        .paperListRow()
        .onChange(of: isOn) { _, on in
            if !on { VoiceMode.shared.turnOff() }
            #if os(macOS)
            WakeListener.shared.update()
            #endif
        }
        #if os(macOS)
        .onChange(of: listensForWake) { WakeListener.shared.update() }
        #endif
    }

    private var footer: String {
        let voice = "On, each chat has a voice button beside the prompt. Say what you want and hear the reply. The voice runs on this device. Voice mode ends when you leave the chat, or the app goes to the background or is interrupted by a call. Off, no voice is loaded."
        #if os(macOS)
        return voice + " With “Hey Agents” on, this Mac listens for those words while voice mode is off, and they open voice mode in the chat in front. Words said after them are your first prompt. The words are recognised on this Mac and no audio is kept. The window shows an ear while it listens."
        #else
        return voice
        #endif
    }
}
