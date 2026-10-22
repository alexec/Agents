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

    var body: some View {
        Section {
            Toggle("Voice mode", isOn: $isOn)
        } header: {
            if let header { Text(header) }
        } footer: {
            Text("On, each chat has a voice button beside the prompt. Say what you want and hear the reply. The voice runs on this device. Off, no voice is loaded.")
                .appText(.fine)
                .foregroundStyle(.secondary)
        }
        .paperListRow()
        .onChange(of: isOn) { _, on in
            if !on { VoiceMode.shared.turnOff() }
        }
    }
}
