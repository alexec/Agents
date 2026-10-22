#if os(macOS)
import AppKit
#else
import AudioToolbox
#endif

/// The moments of voice mode, each a sound the system already has (#1792, Alex's design
/// notes): no recordings of our own and nothing looping in the background.
enum VoiceSound {
    /// The microphone opens for the next prompt.
    case listening
    /// The prompt went.
    case sent
    /// A question or a form waits on the person.
    case question
    /// Something went wrong.
    case problem

    func play() {
        #if os(macOS)
        let name = switch self {
        case .listening: "Pop"
        case .sent: "Tink"
        case .question: "Purr"
        case .problem: "Basso"
        }
        NSSound(named: NSSound.Name(name))?.play()
        #else
        // The system's own: begin recording, sent, the "tock" of a key, and the error.
        let id: SystemSoundID = switch self {
        case .listening: 1113
        case .sent: 1001
        case .question: 1104
        case .problem: 1073
        }
        AudioServicesPlaySystemSound(id)
        #endif
    }
}
