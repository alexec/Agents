import AgentsKitCore
import AVFoundation
import CoreMedia
import Foundation
#if os(iOS)
import UIKit
#endif
import Observation
import Speech
import SwiftUI

/// Carries audio to the analyser from the realtime thread that produces it, converted
/// to the format the analyser wants.
///
/// A converter and a stream's continuation are not things Swift will let a realtime
/// closure hold on its own, and using them from that thread is exactly what they are
/// for. So the promise is made here, in one place, rather than spread through the
/// closure that needs it.
private final class BufferSink: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var converter: AVAudioConverter?
    private var target: AVAudioFormat?
    /// For the log: the tap's format, and buffers given and passed on, since `point`.
    private var given: (format: String, count: Int, passed: Int) = ("none", 0, 0)

    var counts: String {
        lock.lock()
        defer { lock.unlock() }
        return "tap \(given.format), \(given.count) buffers, \(given.passed) passed on"
    }

    func point(at continuation: AsyncStream<AnalyzerInput>.Continuation?, in target: AVAudioFormat? = nil) {
        lock.lock()
        defer { lock.unlock() }
        self.continuation?.finish()
        self.continuation = continuation
        self.target = target
        converter = nil
        given = ("none", 0, 0)
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard let continuation else { return }
        if given.count == 0 {
            let format = buffer.format
            given.format = "\(format.sampleRate) Hz × \(format.channelCount) \(format.commonFormat.rawValue)"
                + (format.isInterleaved ? " interleaved" : "")
        }
        given.count += 1
        guard let target, buffer.format != target else {
            given.passed += 1
            continuation.yield(AnalyzerInput(buffer: buffer))
            return
        }
        if converter?.inputFormat != buffer.format {
            converter = DictationAudio.converter(from: buffer.format, to: target)
        }
        guard let converter, let converted = DictationAudio.convert(buffer, with: converter) else { return }
        given.passed += 1
        continuation.yield(AnalyzerInput(buffer: converted))
    }
}

/// The text and timing fields both transcribers expose to dictation.
private protocol DictationResult: SpeechModuleResult {
    var text: AttributedString { get }
}

extension DictationTranscriber.Result: DictationResult {}
extension SpeechTranscriber.Result: DictationResult {}

/// Talking into the prompt instead of typing it.
///
/// Apple's on-device transcriber, as one continuous session for as long as the button
/// is on: a pause is a pause, not the end of a request (#427, #2515, #2575).
/// What it hears goes in at the cursor, the words it is still unsure of are the only
/// ones it replaces, and the person can go on editing and typing while it listens.
/// `DictationText` keeps track of all that. No cloud transcription.
///
/// It asks for the microphone and for speech recognition the first time and not again,
/// and it asks at the moment of use rather than at launch.
@MainActor
@Observable
final class Dictation {
    enum Model {
        case speech
        case systemDictation
    }

    /// Something to tell the person, and where to send them about it.
    struct Problem {
        var message: String
        /// Set only when a switch somewhere would fix it.
        var permission: Permission?
    }

    /// The two the app asks for, and the list each one is on.
    enum Permission {
        case microphone
        case speechRecognition

        /// Privacy & Security, already scrolled to the list this permission is on. The
        /// switch is somewhere most people have never been, so it is worth opening for
        /// them rather than describing the way and wishing them luck.
        var settings: URL {
            #if os(iOS)
            // A phone has one place for an app's switches, and this app's page is it.
            return URL(string: UIApplication.openSettingsURLString)!
            #else
            switch self {
            case .microphone:
                return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
            case .speechRecognition:
                return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition")!
            }
            #endif
        }
    }

    /// Where the switches are, in each system's own words.
    #if os(iOS)
    static let whereTheSwitchIs = "Turn it on in Settings, under this app."
    #else
    static let whereTheSwitchIs = "Turn it on in System Settings, under Privacy & Security."
    #endif

    private(set) var isListening = false
    /// The first volatile words of this run trailed the audio. The underline stays off
    /// and the button's pulse is the listening mark (#2515).
    private(set) var volatileIsLate = false
    private(set) var problem: Problem?
    /// `finish()` is waiting for the last words.
    private var isFinishing = false

    private let engine: AVAudioEngine
    private let model: Model
    /// Voice mode's engine and audio route, when this is voice mode's dictation (#2375):
    /// they are opened and closed by voice mode, and this only adds its tap.
    private let shared: VoiceAudio?
    private let sink = BufferSink()
    private var analyzer: SpeechAnalyzer?
    private var results: Task<Void, Never>?
    private var onChange: ((String, Range<Int>) -> Void)?

    /// What is in the field, as far as dictation knows: where the next words go, and
    /// which words are still being heard.
    private var text = DictationText("")

    /// Which run of dictation we are on. The analyser can deliver a last result after
    /// it has been stopped, and that result belongs to the run that is over: it must not
    /// be written over what has been typed since.
    private var run = 0
    private let clock = ContinuousClock()
    /// When the microphone opened for this run. Compared with a result's audio time.
    private var listeningSince: ContinuousClock.Instant?
    /// The first volatile result is the one that says whether the words are late.
    /// A later revision of the same words is expected to arrive after it.
    private var judgedVolatile = false
    /// A first volatile result that trails its audio by more than this is late.
    static let lateVolatile: Duration = .milliseconds(1_200)

    /// The words in the field still being heard, as character offsets, while dictation
    /// is on. The field underlines them until they settle (#448). Nil when those words
    /// came late: the pulse shows instead (#2515).
    var heardWords: Range<Int>? {
        guard isListening, !volatileIsLate else { return nil }
        return text.heardWords
    }

    /// Whether the system has been asked yet. Used to put our own words in front of
    /// the system's alert the first time.
    init(shared: VoiceAudio? = nil, model: Model = .speech) {
        self.shared = shared
        engine = shared?.engine ?? AVAudioEngine()
        self.model = model
    }

    var hasBeenAsked: Bool {
        SFSpeechRecognizer.authorizationStatus() != .notDetermined
    }

    /// Starts listening into `field`, at `selection` (the end, with none). Each time
    /// what is heard changes the field, `onChange` gets the whole of it and where the
    /// cursor now belongs. `vocabulary` is words this prompt is likely to hold that a
    /// dictionary would not: agent, file and runtime names.
    func start(in field: String, selection: Range<Int>?, vocabulary: [String] = [],
               onChange: @escaping (String, Range<Int>) -> Void) {
        guard !isListening else { return }
        text = DictationText(field, selection: selection)
        self.onChange = onChange
        run += 1
        problem = nil
        let thisRun = run
        Task { await requestAccessThenListen(for: thisRun, vocabulary: vocabulary) }
    }

    /// The person changed the field while dictation was on. What they wrote is theirs:
    /// the next result goes around it, never over it.
    func edited(_ field: String) {
        guard isListening else { return }
        let wasDropping = text.isDroppingAdoptedSpeech
        text.edited(to: field)
        // They took over words still being heard. Ask for those to be settled now, so
        // that what they say next starts afresh rather than waiting out the old speech.
        if text.isDroppingAdoptedSpeech, !wasDropping, let analyzer {
            Task { try? await analyzer.finalize(through: nil) }
        }
    }

    /// The person moved the cursor or selected some words while dictation was on. The
    /// next words go there.
    func selected(_ range: Range<Int>) {
        guard isListening else { return }
        let wasDropping = text.isDroppingAdoptedSpeech
        text.selected(range)
        if text.isDroppingAdoptedSpeech, !wasDropping, let analyzer {
            Task { try? await analyzer.finalize(through: nil) }
        }
    }

    /// Asking for speech recognition, off the main actor.
    ///
    /// The answer comes back on whatever queue the privacy service feels like. A
    /// continuation resumed from a closure that belongs to the main actor fails
    /// Swift's isolation check and takes the app with it, which is exactly what
    /// happened the first time the microphone button was pressed (#48).
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

    private func requestAccessThenListen(for thisRun: Int, vocabulary: [String]) async {
        let speech = await Self.askForSpeech()
        guard thisRun == run else { return }
        guard speech == .authorized else {
            problem = Problem(message: "Dictation needs permission to recognise speech. " + Self.whereTheSwitchIs,
                              permission: .speechRecognition)
            return
        }
        let microphone = await Self.askForMicrophone()
        guard thisRun == run else { return }
        guard microphone else {
            problem = Problem(message: "Dictation needs the microphone. " + Self.whereTheSwitchIs,
                              permission: .microphone)
            return
        }
        await listen(as: model, for: thisRun, vocabulary: vocabulary)
    }

    private func listen(as model: Model, for thisRun: Int, vocabulary: [String]) async {
        switch model {
        case .systemDictation:
            guard let locale = await DictationTranscriber.supportedLocale(equivalentTo: Locale.current) else {
                guard thisRun == run else { return }
                problem = Problem(message: "Dictation is not available for \(Locale.current.identifier).")
                return
            }
            let transcriber = DictationTranscriber(locale: locale, contentHints: [],
                                                   transcriptionOptions: [.punctuation],
                                                   reportingOptions: [.volatileResults, .frequentFinalization],
                                                   attributeOptions: [])
            await listen(with: transcriber, locale: locale, for: thisRun, vocabulary: vocabulary)
        case .speech:
            // Not on every device, nor in the simulator: the older model there, rather than
            // no dictation at all (#2532).
            guard SpeechTranscriber.isAvailable,
                  let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) else {
                guard thisRun == run else { return }
                note("dictation: SpeechTranscriber not available (\(SpeechTranscriber.isAvailable)), the older model")
                await listen(as: .systemDictation, for: thisRun, vocabulary: vocabulary)
                return
            }
            // The newer on-device model (#2515). Volatile results are the live words. It
            // has no punctuation switch: the model writes the punctuation.
            let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                                reportingOptions: [.volatileResults],
                                                attributeOptions: [])
            await listen(with: transcriber, locale: locale, for: thisRun, vocabulary: vocabulary)
        }
    }

    private func listen<T: LocaleDependentSpeechModule>(with transcriber: T, locale: Locale,
                                                        for thisRun: Int, vocabulary: [String]) async
    where T.Result: DictationResult {
        do {
            // The model for this language, the first time: a download the system shares
            // with every app, and a no-op once it is there.
            if let install = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await install.downloadAndInstall()
            }
        } catch {
            guard thisRun == run else { return }
            problem = Problem(message: "Dictation could not get the speech model for \(locale.identifier): \(error.localizedDescription)")
            return
        }
        guard thisRun == run else { return }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        // Nil when the model is not on the device after all (the simulator's case). The
        // microphone's own buffers would then reach the analyser, which traps on them on the
        // audio thread, and the app is gone (#2532): a problem to show instead.
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            let status = await AssetInventory.status(forModules: [transcriber])
            guard thisRun == run else { return }
            note("dictation: no audio format for \(T.self), assets \(status)")
            problem = Problem(message: "Dictation is not available on this device for \(locale.identifier).")
            return
        }
        let (input, feed) = AsyncStream<AnalyzerInput>.makeStream()
        do {
            let context = AnalysisContext()
            context.contextualStrings[.general] = DictationVocabulary.merging(vocabulary)
            try await analyzer.setContext(context)
            try await analyzer.start(inputSequence: input)
        } catch {
            feed.finish()
            guard thisRun == run else { return }
            problem = Problem(message: "Dictation would not start: \(error.localizedDescription)")
            return
        }
        sink.point(at: feed, in: format)

        do {
            try await openMicrophone()
        } catch let noInput as NoAudioInput {
            await finish(analyzer)
            guard thisRun == run else { return }
            problem = Problem(message: noInput.message)
            return
        } catch {
            await finish(analyzer)
            guard thisRun == run else { return }
            problem = Problem(message: "The microphone would not start: \(error.localizedDescription)")
            return
        }
        // `stop()` may have been called while all that was being set up. None of it can
        // be cancelled midway, so retire this start before it can listen.
        guard thisRun == run else {
            closeMicrophone()
            await finish(analyzer)
            return
        }
        self.analyzer = analyzer
        listeningSince = clock.now
        note("dictation: listening, \(T.self), analyzer \(format.sampleRate) Hz × \(format.channelCount)")
        judgedVolatile = false
        volatileIsLate = false
        isListening = true

        // Called with every result, on the analyser's own schedule. Each is the words for
        // one stretch of speech, final once the transcriber will not change them again.
        results = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    let words = String(result.text.characters)
                    let start = result.range.start.seconds
                    let final = result.isFinal
                    guard let self, thisRun == self.run else { return }
                    self.heard(words, final: final, from: start.isFinite ? start : 0)
                }
            } catch {
                note("dictation: results ended: \(error)")
                guard let self, thisRun == self.run else { return }
                self.problem = Problem(message: "Dictation stopped: \(error.localizedDescription)")
                self.stop()
            }
        }
    }

    private func heard(_ words: String, final: Bool, from start: Double) {
        if !judgedVolatile, listeningSince != nil { note("dictation: first result, final \(final), \(sink.counts)") }
        if !final, !judgedVolatile, let listeningSince {
            judgedVolatile = true
            let lag = clock.now - listeningSince - Duration.seconds(start)
            if lag > Self.lateVolatile { volatileIsLate = true }
        }
        guard text.heard(words, final: final, from: start) else { return }
        onChange?(text.text, text.selection)
    }

    /// The input node would not say what it was listening to, so there was nothing to
    /// hang a tap on. It carries its own sentence: everything else AVFoundation refuses
    /// is caught below and described from the error it arrived with.
    private struct NoAudioInput: Error {
        var message: String { "The microphone would not start: there was no audio input to read." }
    }

    /// The microphone, opened once and left open for as long as dictation is on.
    private func openMicrophone() async throws {
        guard shared != nil || !engine.isRunning else { return }
        #if os(iOS)
        if shared == nil {
        // A phone shares one audio route between everything on it, and the microphone
        // is not the app's until the app says it is recording.
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        }
        #endif

        // The tap is called by the audio realtime thread. A closure written inside a
        // main-actor method belongs to the main actor, and Swift checks that where it
        // runs and kills the app when it is wrong. Spelling it @Sendable is what makes
        // it nobody's.
        let sink = self.sink
        let tap: @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void = { buffer, _ in
            sink.append(buffer)
        }

        let input = engine.inputNode
        guard let format = await Self.aFormatToListenIn(from: input) else { throw NoAudioInput() }
        input.removeTap(onBus: 0)
        // The throwing tap that replaced the old one in 27 reaches Swift only by its refined name.
        try input.__installTap(onBus: 0, bufferSize: 1_024, format: format, error: (), block: tap)
        if let shared {
            try shared.start()
            return
        }
        engine.prepare()
        try engine.start()
    }

    /// A format the input node will really produce, waited for.
    ///
    /// A node that has just been woken — a session only now made active, or an engine
    /// started a second time in this app's life — can report zero hertz and no channels
    /// for a moment. A tap installed with that is an Objective-C exception rather than a
    /// Swift error, so nothing in this file can catch it and the app is gone. Waiting a
    /// moment for the route to settle costs nothing when the format is already good,
    /// which is the case every other time.
    private nonisolated static func aFormatToListenIn(from input: AVAudioNode) async -> AVAudioFormat? {
        for _ in 0..<20 {
            let format = input.outputFormat(forBus: 0)
            if format.sampleRate > 0, format.channelCount > 0 { return format }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }

    private func closeMicrophone() {
        // Voice mode's engine goes on playing the voice: only the tap comes off.
        if shared != nil {
            engine.inputNode.removeTap(onBus: 0)
            sink.point(at: nil)
            return
        }
        let wasListening = engine.isRunning
        if wasListening {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        sink.point(at: nil)
        #if os(iOS)
        // Give the route back, so whatever was playing before carries on: only a route this
        // took, and never voice mode's, which a field's stop as its page goes would end
        // (Alex's iPhone, 2026-10-29).
        if wasListening, !VoiceMode.shared.isOn {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        #endif
    }

    private nonisolated func finish(_ analyzer: SpeechAnalyzer) async {
        await analyzer.cancelAndFinishNow()
    }

    /// The alert has been read. It is shown for as long as there is something to say,
    /// so saying nothing is what dismisses it — `stop()` will not, because by the time
    /// a problem is set there is nothing left running for it to stop.
    func dismissProblem() { problem = nil }

    /// How long `finish()` waits for the last words before it stops anyway.
    static let lastWordsWait: Duration = .seconds(2)

    /// Stops listening once the last words said are in the field, so a prompt sent next
    /// holds all of them (#2753). The microphone closes at once; the analyser then turns
    /// the audio it still has into final words, for up to `lastWordsWait`.
    func finish() async {
        guard isListening, !isFinishing, let analyzer, let results else {
            stop()
            return
        }
        isFinishing = true
        defer { isFinishing = false }
        note("dictation: finish, \(sink.counts)")
        // Closing the microphone ends the analyser's input.
        closeMicrophone()
        let inTime = await waitAtMost(Self.lastWordsWait) {
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
            await results.value
        }
        if !inTime { note("dictation: last words not in after \(Self.lastWordsWait)") }
        stop()
    }

    /// Stops listening. What is in the field stays as it is, words still being heard
    /// and all: they were shown, so they are kept (#69).
    func stop() {
        // Retire pending permission and set-up work as well as results still on their
        // way. Results already queued carry the old run number.
        if isListening { note("dictation: stop, \(sink.counts)") }
        run += 1
        onChange = nil
        isListening = false
        volatileIsLate = false
        listeningSince = nil
        judgedVolatile = false
        closeMicrophone()
        results?.cancel()
        results = nil
        if let analyzer {
            self.analyzer = nil
            Task { await finish(analyzer) }
        }
    }
}

/// A field's selection, as the character offsets `DictationText` counts in, and back.
enum DictationCursor {
    static func range(of selection: TextSelection?, in text: String) -> Range<Int>? {
        guard let selection, case .selection(let range) = selection.indices,
              range.lowerBound >= text.startIndex, range.upperBound <= text.endIndex else { return nil }
        let lower = text.distance(from: text.startIndex, to: range.lowerBound)
        return lower..<(lower + text.distance(from: range.lowerBound, to: range.upperBound))
    }

    static func selection(_ range: Range<Int>, in text: String) -> TextSelection {
        let lower = text.index(text.startIndex, offsetBy: min(range.lowerBound, text.count))
        let upper = text.index(lower, offsetBy: min(range.count, text.distance(from: lower, to: text.endIndex)))
        return range.isEmpty ? TextSelection(insertionPoint: lower) : TextSelection(range: lower..<upper)
    }
}
