import AgentsKitCore
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
    /// On the Mac, voice processing is set up once and kept between uses: switching it on
    /// takes about a second, nearly all of turning voice mode on, and Alex wants it to
    /// listen within 100 ms of the press (2026-10-29). Set up, it opens no microphone: the
    /// microphone is on only while the engine runs.
    private var isPrepared = false
    #if os(macOS)
    /// That set-up, off the main thread: on it, the window stopped for that second as the
    /// first prompt bar drew, at every launch (P20261029-1). The engine is the set-up's
    /// until it ends: `open` waits for it, and nothing else touches the engine while voice
    /// mode is off.
    private lazy var ahead = ReadyAhead { [engine = EngineHandle(self.engine)] in
        try Self.prepareVoiceProcessing(engine.engine)
    }
    private var routeChanges: (any NSObjectProtocol)?
    #endif

    init() {
        #if os(macOS)
        // A set-up that failed is tried again on another route (or at a press), not by
        // every new prompt bar.
        routeChanges = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.ahead.retry() }
        }
        #endif
    }

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

    /// Voice processing switched on ahead of the press, on the Mac (`isPrepared`), off the
    /// main thread. Does nothing in a walk, or when it is set up or being set up already;
    /// a failure is left for `open`.
    func prepare() {
        #if os(macOS)
        guard listens, !isPrepared, !isOpen, ahead.state == .idle else { return }
        // What it costs the window (P20261029-1): every millisecond here, it does not draw.
        let started = ContinuousClock.now
        ahead.start()
        note("voice: prepare held the main thread \(Int((ContinuousClock.now - started) / .milliseconds(1))) ms")
        Task { await takePrepared() }
        #endif
    }

    #if os(macOS)
    /// Waits for a set-up that has not ended, and takes it when it worked.
    private func takePrepared() async {
        let wasRunning = ahead.state == .running
        guard await ahead.wait() else {
            if wasRunning { note("voice: echo cancellation was not set up ahead: \(ahead.error.map { "\($0)" } ?? "")") }
            return
        }
        guard !isPrepared else { return }
        isPrepared = true
        cancelsEcho = true
        if wasRunning, let took = ahead.took {
            note("voice: echo cancellation set up ahead, off the main thread, in \(Int(took / .milliseconds(1))) ms")
        }
    }

    /// The set-up itself, on the set-up's thread.
    nonisolated private static func prepareVoiceProcessing(_ engine: AVAudioEngine) throws {
        do {
            try engine.inputNode.setVoiceProcessingEnabled(true)
            engine.inputNode.voiceProcessingOtherAudioDuckingConfiguration =
                AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
            try joinOutput(engine, cancelsEcho: true)
            // Its resources ahead too: that is the rest of the wait, at the first start.
            engine.prepare()
        } catch {
            try? engine.inputNode.setVoiceProcessingEnabled(false)
            throw error
        }
    }
    #endif

    /// Opens the audio route for talking and listening. Throws when there is none.
    func open() async throws {
        guard !isOpen else { return }
        #if os(macOS)
        if listens, !isPrepared {
            // A press tries a failed set-up again; one still running is waited for.
            ahead.retry()
            ahead.start()
            await takePrepared()
            guard !isOpen else { return }
        }
        if isPrepared, listens {
            isOpen = true
            return
        }
        #endif
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
        #if os(macOS)
        isPrepared = cancelsEcho
        #endif
        isOpen = true
    }

    /// The mixer joined to the output before the engine starts, as voice processing needs.
    /// With it on, at the microphone's rate: voice processing will not start when the
    /// output runs at another one (-10875 on a MacBook Air's speakers, 44.1 against 48 kHz).
    private func joinOutput() throws {
        try Self.joinOutput(engine, cancelsEcho: cancelsEcho)
    }

    nonisolated private static func joinOutput(_ engine: AVAudioEngine, cancelsEcho: Bool) throws {
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
        // Paused keeps what the engine prepared, so the next start is quick; stopped lets it go.
        if engine.isRunning { if isPrepared { engine.pause() } else { engine.stop() } }
        isOpen = false
        // Kept on the Mac for the next time (`isPrepared`): stopped, it hears nothing.
        guard !isPrepared else { return }
        if cancelsEcho { try? engine.inputNode.setVoiceProcessingEnabled(false) }
        cancelsEcho = false
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }
}

#if os(macOS)
/// The engine, handed to the set-up's thread: `VoiceAudio` touches it on the main thread
/// only once the set-up has ended (`ReadyAhead.wait`).
private struct EngineHandle: @unchecked Sendable {
    let engine: AVAudioEngine
    init(_ engine: AVAudioEngine) { self.engine = engine }
}
#endif
