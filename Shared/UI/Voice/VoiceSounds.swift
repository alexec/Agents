#if os(macOS)
import AppKit
#else
import AudioToolbox
#endif

/// The moments of voice mode, each a sound the system already has (#1792, Alex's design
/// notes): no recordings of our own. The tick is one short sound every few seconds, not a
/// loop (#2520).
@MainActor
enum VoiceSound: CaseIterable {
    /// The microphone opens for the next prompt.
    case listening
    /// The microphone stopped listening: the prompt went (Alex, 2026-10-29).
    case sent
    /// The agent works on the prompt, and nothing is being said: a quiet sound every few
    /// seconds (Alex, 2026-10-29).
    case working
    /// Still listening, and nothing has been heard (#2520). Quieter than the open sound.
    case tick
    /// A question or a form waits on the person.
    case question
    /// Something went wrong.
    case problem
    /// Voice mode ends (#2520): a short falling sound, the opposite of the one that opened.
    case ended

    /// Its name in Settings.
    var title: String {
        switch self {
        case .listening: "Starts listening"
        case .sent: "Stops listening"
        case .working: "Working"
        case .tick: "Still listening"
        case .question: "A question waits"
        case .problem: "Something went wrong"
        case .ended: "Voice mode ends"
        }
    }

    /// The sound it has until Settings chooses another.
    var soundAtFirst: String {
        switch self {
        case .listening: "Pop"
        case .sent: "Bottle"
        case .working: "Morse"
        case .tick: "Tink"
        case .question: "Purr"
        case .problem: "Basso"
        case .ended: "Blow"
        }
    }

    func play() {
        #if os(macOS)
        Self.play(VoiceSettings.soundName(self), volume: volume)
        #else
        // begin recording, a quiet tock, sent, the key tock, the error, end recording.
        let id: SystemSoundID = switch self {
        case .listening: 1113
        case .tick: 1105
        case .sent: 1001
        case .working: 1105
        case .question: 1104
        case .problem: 1073
        case .ended: 1114
        }
        AudioServicesPlaySystemSound(id)
        #endif
    }

    #if os(macOS)
    /// The tick and the working sound are quieter than the rest.
    private var volume: Float {
        switch self {
        case .tick: 0.35
        case .working: 0.3
        default: 1
        }
    }

    /// Copies by name and volume, so a quiet one never turns the named sound down, kept so
    /// playback is not cut off when the call returns.
    private static var copies: [String: NSSound] = [:]

    private static func play(_ name: String, volume: Float) {
        guard !name.isEmpty else { return }
        let key = "\(name)@\(volume)"
        if copies[key] == nil {
            guard let copy = NSSound(named: NSSound.Name(name))?.copy() as? NSSound else { return }
            copy.volume = volume
            copies[key] = copy
        }
        guard let sound = copies[key] else { return }
        sound.stop()
        sound.play()
    }
    #endif
}
