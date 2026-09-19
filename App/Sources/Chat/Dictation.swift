import AVFoundation
import Foundation
import Observation
import Speech

/// Carries audio to the recogniser from the realtime thread that produces it.
///
/// `SFSpeechAudioBufferRecognitionRequest` is not Sendable and appending to it from
/// the audio thread is exactly what it is for, so the promise is made here in one
/// place rather than spread through the closure that needs it.
///
/// It is pointed at a request rather than given one, because the tap on the microphone
/// is installed once and outlives any single request: a pause ends the recogniser's
/// request, not the listening, and the next one takes the same audio.
private final class BufferSink: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?

    func point(at request: SFSpeechAudioBufferRecognitionRequest?) {
        lock.lock()
        defer { lock.unlock() }
        self.request = request
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let request = self.request
        lock.unlock()
        request?.append(buffer)
    }
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
    private let sink = BufferSink()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var onText: ((String) -> Void)?

    /// The words that are already settled: what was in the field when this run of
    /// dictation started, and every utterance finished since. What the recogniser is
    /// hearing now is added to this rather than put in its place.
    private var base = ""

    /// What goes between `base` and what is being said now. A space to begin with,
    /// because what was typed and the sentence being spoken after it are one thought;
    /// a blank line afterwards, because stopping to draw breath and carrying on is a
    /// new one.
    private var separator = " "

    /// Which run of dictation we are on. The recogniser can deliver a last result
    /// after it has been stopped, and that result belongs to the run that is over: it
    /// must not be written over what has been said since.
    private var run = 0

    /// Utterances that ended with nothing to show, one after another. The recogniser
    /// reports an error when it has heard nothing for long enough, and beginning again
    /// for ever would be a spin rather than dictation, so a run of empty ones ends it.
    private var emptyUtterances = 0
    private let emptyUtteranceLimit = 3

    var isAvailable: Bool { recogniser?.isAvailable ?? false }

    /// Whether the system has been asked yet. Used to put our own words in front of
    /// the system's alert the first time.
    var hasBeenAsked: Bool {
        SFSpeechRecognizer.authorizationStatus() != .notDetermined
    }

    func start(appendingTo base: String, onText: @escaping (String) -> Void) {
        guard !isListening else { return }
        self.base = base
        self.onText = onText
        separator = " "
        emptyUtterances = 0
        run += 1
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
        do {
            try openMicrophone()
        } catch {
            problem = "The microphone would not start: \(error.localizedDescription)"
            return
        }
        isListening = true
        listenForAnUtterance(with: recogniser)
    }

    /// The microphone, opened once and left open for as long as dictation is on.
    private func openMicrophone() throws {
        guard !engine.isRunning else { return }

        // The tap is called by the audio realtime thread. A closure written inside a
        // main-actor method belongs to the main actor, and Swift checks that where it
        // runs and kills the app when it is wrong. Spelling it @Sendable is what makes
        // it nobody's.
        let sink = self.sink
        let tap: @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void = { buffer, _ in
            sink.append(buffer)
        }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1_024, format: format, block: tap)
        engine.prepare()
        try engine.start()
    }

    /// One utterance: everything said between two pauses.
    ///
    /// The recogniser hands back the whole of what it has heard each time, so a result
    /// replaces what the last one said rather than adding to it — which is right within
    /// an utterance and wrong between two. When it decides an utterance is over it
    /// stops, and anything said afterwards belongs to a request that has not been made
    /// yet, so a new one is made here and what was heard is settled into `base` first.
    private func listenForAnUtterance(with recogniser: SFSpeechRecognizer) {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // Keep it on the Mac where the Mac can do it. What is said to an agent is the
        // agent's business and nobody else's.
        request.requiresOnDeviceRecognition = recogniser.supportsOnDeviceRecognition
        self.request = request
        sink.point(at: request)

        // Called by the recogniser, on its own thread: @Sendable for the same reason as
        // the tap above.
        let thisRun = run
        let results: @Sendable (SFSpeechRecognitionResult?, (any Error)?) -> Void = { [weak self] result, error in
            let spoken = result?.bestTranscription.formattedString
            let over = error != nil || (result?.isFinal ?? false)
            Task { @MainActor in
                guard let self, thisRun == self.run else { return }
                self.heard(spoken, endsTheUtterance: over)
            }
        }
        task = recogniser.recognitionTask(with: request, resultHandler: results)
    }

    private func heard(_ spoken: String?, endsTheUtterance over: Bool) {
        let said = spoken ?? ""
        if !said.isEmpty { onText?(base + (base.isEmpty ? "" : separator) + said) }
        guard over else { return }

        if said.isEmpty {
            emptyUtterances += 1
        } else {
            emptyUtterances = 0
            base += (base.isEmpty ? "" : separator) + said
            // From here on, a pause is a paragraph.
            separator = "\n\n"
        }

        task = nil
        request = nil
        sink.point(at: nil)

        // Still on? Then listen for the next one. The microphone never closed.
        guard isListening, emptyUtterances < emptyUtteranceLimit, let recogniser, engine.isRunning else {
            stop()
            return
        }
        listenForAnUtterance(with: recogniser)
    }

    /// The alert has been read. It is shown for as long as there is something to say,
    /// so saying nothing is what dismisses it — `stop()` will not, because by the time
    /// a problem is set there is nothing left running for it to stop.
    func dismissProblem() { problem = nil }

    func stop() {
        guard isListening || engine.isRunning else { return }
        isListening = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        sink.point(at: nil)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
    }

    func toggle(appendingTo base: String, onText: @escaping (String) -> Void) {
        if isListening { stop() } else { start(appendingTo: base, onText: onText) }
    }
}
