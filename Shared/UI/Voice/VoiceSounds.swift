#if os(macOS)
import AppKit
#else
import AudioToolbox
#endif

/// The moments of voice mode, each a sound the system already has (#1792, Alex's design
/// notes): no recordings of our own. The tick is one short sound every few seconds, not a
/// loop (#2520).
@MainActor
enum VoiceSound {
    /// The microphone opens for the next prompt.
    case listening
    /// Still listening, and nothing has been heard (#2520). Quieter than the open sound.
    case tick
    /// The prompt went.
    case sent
    /// A question or a form waits on the person.
    case question
    /// Something went wrong.
    case problem
    /// Voice mode ends (#2520): a short falling sound, the opposite of the one that opened.
    case ended

    func play() {
        #if os(macOS)
        switch self {
        case .tick:
            Self.playTick()
        case .listening:
            NSSound(named: NSSound.Name("Pop"))?.play()
        case .sent:
            NSSound(named: NSSound.Name("Tink"))?.play()
        case .question:
            NSSound(named: NSSound.Name("Purr"))?.play()
        case .problem:
            NSSound(named: NSSound.Name("Basso"))?.play()
        case .ended:
            NSSound(named: NSSound.Name("Blow"))?.play()
        }
        #else
        // begin recording, a quiet tock, sent, the key tock, the error, end recording.
        let id: SystemSoundID = switch self {
        case .listening: 1113
        case .tick: 1105
        case .sent: 1001
        case .question: 1104
        case .problem: 1073
        case .ended: 1114
        }
        AudioServicesPlaySystemSound(id)
        #endif
    }

    #if os(macOS)
    /// Tink at low volume. The Mac has no Tock. A copy, so the named Tink (the sent
    /// sound) stays at full volume, and this stays quieter than Pop. Kept, so playback
    /// is not cut off when the call returns.
    private static var tickSound: NSSound?

    private static func playTick() {
        if tickSound == nil {
            let named = NSSound(named: NSSound.Name("Tink"))
            // A real copy: the named Tink is the sent sound, and its volume must stay full.
            guard let copy = named?.copy() as? NSSound, copy !== named else { return }
            copy.volume = 0.35
            tickSound = copy
        }
        guard let sound = tickSound else { return }
        sound.stop()
        sound.play()
    }
    #endif
}
