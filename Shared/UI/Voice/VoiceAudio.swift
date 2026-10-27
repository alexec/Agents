@preconcurrency import AVFoundation
import Foundation

/// The one audio engine of voice mode (#2375): the microphone and the voice together.
///
/// The person can talk over the voice, so the microphone stays open while the voice
/// speaks. For the microphone not to hear the voice, the voice plays through the same
/// engine, with the system's voice processing (echo cancellation) on its input. Voice mode
/// opens it when it turns on and closes it when it turns off; `Dictation` and
/// `VoiceSpeaker` only add and take away their own parts.
@MainActor
final class VoiceAudio {
    let engine = AVAudioEngine()
    private(set) var isOpen = false
    /// Whether the microphone leaves out what the voice says. Without it, the microphone
    /// closes while the voice speaks, as before #2375.
    private(set) var cancelsEcho = false
    /// Off in a walk: no microphone, so nothing to ask for and nothing to cancel.
    var listens = true

    /// The route and the microphone's format, for the log: no words.
    var route: String {
        var parts = ["echo cancelled \(cancelsEcho)"]
        if listens {
            let format = engine.inputNode.outputFormat(forBus: 0)
            parts.append("input \(format.sampleRate) Hz × \(format.channelCount)")
        }
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        parts.append("category \(session.category.rawValue) mode \(session.mode.rawValue)")
        parts.append("inputs \(session.currentRoute.inputs.map(\.portType.rawValue))")
        parts.append("outputs \(session.currentRoute.outputs.map(\.portType.rawValue))")
        #endif
        return parts.joined(separator: ", ")
    }

    /// Opens the audio route for talking and listening. Throws when there is none.
    func open() throws {
        guard !isOpen else { return }
        #if os(iOS)
        // Speaker and microphone at once. The silent switch does not mute it, since the
        // person asked to hear the reply, and other sound ducks under it.
        let session = AVAudioSession.sharedInstance()
        if listens {
            try session.setCategory(.playAndRecord, mode: .voiceChat,
                                    options: [.defaultToSpeaker, .allowBluetoothHFP, .duckOthers])
        } else {
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        }
        try session.setActive(true)
        #endif
        cancelsEcho = false
        if listens {
            do {
                try engine.inputNode.setVoiceProcessingEnabled(true)
                // Other apps' sound stays as loud as it can: the voice is not a phone call.
                engine.inputNode.voiceProcessingOtherAudioDuckingConfiguration =
                    AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
                cancelsEcho = true
            } catch {
                // No echo cancellation on this route: the microphone closes while it speaks.
            }
        }
        try joinOutput()
        // Voice processing can still refuse to start: then without it, rather than no voice.
        if cancelsEcho {
            do {
                engine.prepare()
                try engine.start()
                engine.stop()
            } catch {
                try? engine.inputNode.setVoiceProcessingEnabled(false)
                cancelsEcho = false
                try joinOutput()
            }
        }
        isOpen = true
    }

    /// The mixer joined to the output before the engine starts, as voice processing needs.
    /// With it on, at the microphone's rate: voice processing will not start when the
    /// output runs at another one (-10875 on a MacBook Air's speakers, 44.1 against 48 kHz).
    private func joinOutput() throws {
        // Not the input node without voice processing: a walk has no microphone to ask for.
        let rate = cancelsEcho ? engine.inputNode.outputFormat(forBus: 0).sampleRate : 0
        let format = rate > 0 ? AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1) : nil
        try engine.connectNode(engine.mainMixerNode, to: engine.outputNode, format: format)
    }

    /// Stops the engine and joins the mixer to the output again, for a part that found the
    /// graph changed under it (#2472). The part joins itself again and starts it.
    func rejoin() throws {
        if engine.isRunning { engine.stop() }
        try joinOutput()
    }

    /// Starts the engine, once something is joined to it.
    func start() throws {
        guard !engine.isRunning else { return }
        engine.prepare()
        try engine.start()
    }

    func close() {
        guard isOpen else { return }
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        if cancelsEcho { try? engine.inputNode.setVoiceProcessingEnabled(false) }
        cancelsEcho = false
        isOpen = false
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }
}
