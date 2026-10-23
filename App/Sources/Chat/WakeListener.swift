import AgentsKitCore
import AppKit
@preconcurrency import AVFoundation
import Observation
import Speech

/// "Hey Agents" opens voice mode (#2420), as spike #1800 recommends: Apple's on-device
/// `SpeechAnalyzer`, a `SpeechDetector` in front of a `SpeechTranscriber` with the phrase as
/// context, and a match of words (`WakePhrase`). No model of our own, no audio kept.
///
/// Off at first, and only on the Mac. It listens while its switch and voice mode's are on,
/// voice mode is off (voice mode has the microphone then), and the Mac is awake and not
/// locked. The window shows a mark while it listens, and macOS its orange dot.
@MainActor
@Observable
final class WakeListener {
    static let shared = WakeListener()

    static let onKey = "heyAgents"
    static let onAtFirst = false
    static let phrase = WakePhrase.heyAgents
    /// How long a phrase heard in words not yet final waits for more on the same breath.
    static let breath: Duration = .milliseconds(800)

    private(set) var isListening = false
    /// Why it does not listen, when it cannot: no permission, no speech model.
    private(set) var problem: String?

    /// The phrase was heard, with the words said after it. The main window sets it.
    @ObservationIgnored var onWake: ((String) -> Void)?

    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var analyzer: SpeechAnalyzer?
    @ObservationIgnored private var results: Task<Void, Never>?
    @ObservationIgnored private var breathing: Task<Void, Never>?
    @ObservationIgnored private let sink = WakeSink()
    /// Which start this is: a result or a set-up from one before it is let go.
    @ObservationIgnored private var run = 0
    @ObservationIgnored private var isStarting = false
    @ObservationIgnored private var isAsleep = false
    @ObservationIgnored private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    private var isWanted: Bool {
        let defaults = WindowDefaults.store
        return defaults.bool(forKey: Self.onKey) && defaults.bool(forKey: VoiceSettings.onKey)
            && VoiceMode.shared.phase == .off && !isAsleep && !Self.isWalk
    }

    /// A scratch walk has no microphone to ask for.
    private static var isWalk: Bool { CommandLine.arguments.contains("--walk") }

    /// Watches the Mac and voice mode from now on, and listens when it should.
    func start() {
        guard observers.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        for (center, name, asleep) in [
            (workspace, NSWorkspace.willSleepNotification, true),
            (workspace, NSWorkspace.screensDidSleepNotification, true),
            (workspace, NSWorkspace.didWakeNotification, false),
            (workspace, NSWorkspace.screensDidWakeNotification, false),
            (distributed, Notification.Name("com.apple.screenIsLocked"), true),
            (distributed, Notification.Name("com.apple.screenIsUnlocked"), false),
        ] as [(NotificationCenter, Notification.Name, Bool)] {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    WakeListener.shared.isAsleep = asleep
                    WakeListener.shared.update()
                }
            }
            observers.append((center, token))
        }
        watchVoiceMode()
        update()
    }

    /// Listens or stops, as the switches, voice mode and the Mac now say.
    func update() {
        if isWanted {
            guard !isListening, !isStarting else { return }
            run += 1
            let thisRun = run
            isStarting = true
            Task { await begin(thisRun) }
        } else {
            end()
        }
    }

    private func watchVoiceMode() {
        withObservationTracking {
            _ = VoiceMode.shared.phase
        } onChange: {
            Task { @MainActor in
                WakeListener.shared.watchVoiceMode()
                WakeListener.shared.update()
            }
        }
    }

    // MARK: Listening

    private func begin(_ thisRun: Int) async {
        defer { if thisRun == run { isStarting = false } }
        guard await Self.askForSpeech() == .authorized else {
            fail("“Hey Agents” needs permission to recognise speech. Turn it on in System Settings, under Privacy & Security.", thisRun)
            return
        }
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            fail("“Hey Agents” needs the microphone. Turn it on in System Settings, under Privacy & Security.", thisRun)
            return
        }
        // The phrase is English: an English recogniser hears it, whatever the Mac's language.
        let english = Locale.current.language.languageCode == .english ? Locale.current : Locale(identifier: "en_US")
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: english) else {
            fail("“Hey Agents” is not available on this Mac.", thisRun)
            return
        }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                            reportingOptions: [.volatileResults, .fastResults], attributeOptions: [])
        do {
            if let install = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await install.downloadAndInstall()
            }
        } catch {
            fail("“Hey Agents” could not get the speech model: \(error.localizedDescription)", thisRun)
            return
        }
        guard thisRun == run, isWanted else { return }
        // The detector leaves silence out, which halves what listening costs (#1800).
        let detector = SpeechDetector(detectionOptions: .init(sensitivityLevel: .medium), reportResults: false)
        let analyzer = SpeechAnalyzer(modules: [detector, transcriber])
        let context = AnalysisContext()
        context.contextualStrings[.general] = [Self.phrase.phrase]
        try? await analyzer.setContext(context)
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        let (input, feed) = AsyncStream<AnalyzerInput>.makeStream()
        let engine = AVAudioEngine()
        do {
            try await analyzer.start(inputSequence: input)
            sink.point(at: feed, in: format)
            let microphone = engine.inputNode
            let heard = microphone.outputFormat(forBus: 0)
            guard heard.sampleRate > 0, heard.channelCount > 0 else { throw NoInput() }
            let sink = self.sink
            let tap: @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void = { buffer, _ in sink.append(buffer) }
            try microphone.__installTap(onBus: 0, bufferSize: 4_096, format: heard, error: (), block: tap)
            engine.prepare()
            try engine.start()
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            sink.point(at: nil)
            await analyzer.cancelAndFinishNow()
            fail("“Hey Agents” could not open the microphone: \(error.localizedDescription)", thisRun)
            return
        }
        guard thisRun == run, isWanted else {
            stop(engine, analyzer)
            return
        }
        self.engine = engine
        self.analyzer = analyzer
        problem = nil
        isListening = true
        results = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self, thisRun == self.run else { return }
                    self.heard(String(result.text.characters), final: result.isFinal, in: thisRun)
                }
            } catch {}
        }
    }

    private struct NoInput: LocalizedError {
        var errorDescription: String? { "there was no audio input to read." }
    }

    /// Words from the recogniser. The phrase in final words wakes at once; in words still
    /// being heard, it waits a breath for what is said after it.
    private func heard(_ text: String, final: Bool, in thisRun: Int) {
        guard let words = Self.phrase.wordsAfter(in: text) else { return }
        breathing?.cancel()
        if final {
            wake(words)
            return
        }
        breathing = Task { [weak self] in
            try? await Task.sleep(for: Self.breath)
            guard !Task.isCancelled, let self, thisRun == self.run else { return }
            self.wake(words)
        }
    }

    #if DEBUG
    /// The walk's `wake` (#2420): `text` as if heard, with no microphone. Says whether it woke.
    func walkHeard(_ text: String) -> Bool {
        guard let words = Self.phrase.wordsAfter(in: text) else { return false }
        wake(words)
        return true
    }
    #endif

    private func wake(_ words: String) {
        // Voice mode takes the microphone: this stops first, and starts again when it ends.
        end()
        onWake?(words)
    }

    private func end() {
        run += 1
        isStarting = false
        breathing?.cancel()
        breathing = nil
        results?.cancel()
        results = nil
        if let engine, let analyzer { stop(engine, analyzer) }
        engine = nil
        analyzer = nil
        isListening = false
    }

    private func stop(_ engine: AVAudioEngine, _ analyzer: SpeechAnalyzer) {
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        sink.point(at: nil)
        Task { await analyzer.cancelAndFinishNow() }
    }

    private func fail(_ message: String, _ thisRun: Int) {
        guard thisRun == run else { return }
        problem = message
    }

    /// Off the main actor: the answer comes back on a queue of the system's (#48).
    private nonisolated static func askForSpeech() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
    }
}

/// Carries the microphone's audio to the analyser from the realtime thread, converted to
/// the analyser's format (`DictationAudio`, which keeps the first channel of many).
private final class WakeSink: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var converter: AVAudioConverter?
    private var target: AVAudioFormat?

    func point(at continuation: AsyncStream<AnalyzerInput>.Continuation?, in target: AVAudioFormat? = nil) {
        lock.lock()
        defer { lock.unlock() }
        self.continuation?.finish()
        self.continuation = continuation
        self.target = target
        converter = nil
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard let continuation else { return }
        guard let target, buffer.format != target else {
            continuation.yield(AnalyzerInput(buffer: buffer))
            return
        }
        if converter?.inputFormat != buffer.format {
            converter = DictationAudio.converter(from: buffer.format, to: target)
        }
        guard let converter, let converted = DictationAudio.convert(buffer, with: converter) else { return }
        continuation.yield(AnalyzerInput(buffer: converted))
    }
}
