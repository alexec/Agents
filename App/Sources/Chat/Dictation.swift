import AVFoundation
import Foundation
import Observation
import Speech

/// Carries audio to the recogniser from the realtime thread that produces it.
///
/// `SFSpeechAudioBufferRecognitionRequest` is not Sendable and appending to it from
/// the audio thread is exactly what it is for, so the promise is made here in one
/// place rather than spread through the closure that needs it.
private final class BufferSink: @unchecked Sendable {
    private let request: SFSpeechAudioBufferRecognitionRequest
    init(_ request: SFSpeechAudioBufferRecognitionRequest) { self.request = request }
    func append(_ buffer: AVAudioPCMBuffer) { request.append(buffer) }
}

/// Talking into the prompt instead of typing it.
///
/// Apple's recogniser, running on the device where the device can. It asks for the
/// microphone and for speech recognition the first time and not again, and it is asked
/// for at the moment of use rather than at launch.
@MainActor
@Observable
final class Dictation {
    private(set) var isListening = false
    private(set) var problem: String?

    private let recogniser = SFSpeechRecognizer(locale: Locale.current)
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var onText: ((String) -> Void)?

    var isAvailable: Bool { recogniser?.isAvailable ?? false }

    /// Whether the system has been asked yet. Used to put our own words in front of
    /// the system's alert the first time.
    var hasBeenAsked: Bool {
        SFSpeechRecognizer.authorizationStatus() != .notDetermined
    }

    func start(onText: @escaping (String) -> Void) {
        guard !isListening else { return }
        self.onText = onText
        problem = nil
        Task { await requestAccessThenListen() }
    }

    /// Asking for speech recognition, off the main actor.
    ///
    /// The answer comes back on whatever queue the privacy service feels like. A
    /// continuation resumed from a closure that belongs to the main actor fails
    /// Swift's isolation check and takes the app with it, which is exactly what
    /// happened the first time the microphone button was pressed.
    private nonisolated static func askForSpeech() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    private nonisolated static func askForMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    private func requestAccessThenListen() async {
        let speech = await Self.askForSpeech()
        guard speech == .authorized else {
            problem = "Dictation needs permission to recognise speech. Turn it on in System Settings, under Privacy & Security."
            return
        }
        let microphone = await Self.askForMicrophone()
        guard microphone else {
            problem = "Dictation needs the microphone. Turn it on in System Settings, under Privacy & Security."
            return
        }
        listen()
    }

    private func listen() {
        guard let recogniser, recogniser.isAvailable else {
            problem = "Speech recognition is not available for \(Locale.current.identifier)."
            return
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // Keep it on the Mac where the Mac can do it. What is said to an agent is the
        // agent's business and nobody else's.
        request.requiresOnDeviceRecognition = recogniser.supportsOnDeviceRecognition
        self.request = request

        // Both of these are called by somebody else's thread: the tap by the audio
        // realtime thread, the results by the recogniser. A closure written inside a
        // main-actor method belongs to the main actor, and Swift checks that where it
        // runs and kills the app when it is wrong. Spelling them @Sendable is what
        // makes them nobody's.
        let sink = BufferSink(request)
        let tap: @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void = { buffer, _ in
            sink.append(buffer)
        }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1_024, format: format, block: tap)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            problem = "The microphone would not start: \(error.localizedDescription)"
            return
        }
        isListening = true

        let results: @Sendable (SFSpeechRecognitionResult?, (any Error)?) -> Void = { [weak self] result, error in
            let spoken = result?.bestTranscription.formattedString
            let finished = error != nil || (result?.isFinal ?? false)
            Task { @MainActor in
                guard let self else { return }
                if let spoken { self.onText?(spoken) }
                if finished { self.stop() }
            }
        }
        task = recogniser.recognitionTask(with: request, resultHandler: results)
    }

    func stop() {
        guard isListening || engine.isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        isListening = false
    }

    func toggle(onText: @escaping (String) -> Void) {
        if isListening { stop() } else { start(onText: onText) }
    }
}
