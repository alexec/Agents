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
            converter = AVAudioConverter(from: buffer.format, to: target)
        }
        guard let converter else { return }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1
        guard let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        let given = Given()
        var error: NSError?
        let status = converter.convert(to: converted, error: &error) { _, status in
            if given.done {
                status.pointee = .noDataNow
                return nil
            }
            given.done = true
            status.pointee = .haveData
            return buffer
        }
        if status != .error, converted.frameLength > 0 {
            continuation.yield(AnalyzerInput(buffer: converted))
        }
    }

    /// Whether the converter has had this buffer yet. It asks until told there is no
    /// more for now, and the same buffer twice would be heard twice.
    private final class Given { var done = false }
}

/// Talking into the prompt instead of typing it.
///
/// Apple's dictation transcriber, on the device, as one continuous session for as long
/// as the button is on: a pause is a pause, not the end of a request (#427). What it
/// hears goes in at the cursor, the words it is still unsure of are the only ones it
/// replaces, and the person can go on editing and typing while it listens. `DictationText`
/// keeps track of all that.
///
/// It asks for the microphone and for speech recognition the first time and not again,
/// and it asks at the moment of use rather than at launch.
@MainActor
@Observable
final class Dictation {
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
    private static let whereTheSwitchIs = "Turn it on in Settings, under this app."
    #else
    private static let whereTheSwitchIs = "Turn it on in System Settings, under Privacy & Security."
    #endif

    private(set) var isListening = false
    private(set) var problem: Problem?

    private let engine = AVAudioEngine()
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

    /// The words in the field still being heard, as character offsets, while dictation
    /// is on. The field underlines them until they settle (#448).
    var heardWords: Range<Int>? { isListening ? text.heardWords : nil }

    /// Whether the system has been asked yet. Used to put our own words in front of
    /// the system's alert the first time.
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
        await listen(for: thisRun, vocabulary: vocabulary)
    }

    private func listen(for thisRun: Int, vocabulary: [String]) async {
        guard let locale = await DictationTranscriber.supportedLocale(equivalentTo: Locale.current) else {
            guard thisRun == run else { return }
            problem = Problem(message: "Dictation is not available for \(Locale.current.identifier).")
            return
        }
        // Punctuation and capitals as system dictation writes them, and the words still
        // being heard as they are heard, so they can be shown and settled in place.
        let transcriber = DictationTranscriber(locale: locale, contentHints: [],
                                               transcriptionOptions: [.punctuation],
                                               reportingOptions: [.volatileResults, .frequentFinalization],
                                               attributeOptions: [])
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
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        let (input, feed) = AsyncStream<AnalyzerInput>.makeStream()
        do {
            if !vocabulary.isEmpty {
                let context = AnalysisContext()
                context.contextualStrings[.general] = vocabulary
                try await analyzer.setContext(context)
            }
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
                guard let self, thisRun == self.run else { return }
                self.problem = Problem(message: "Dictation stopped: \(error.localizedDescription)")
                self.stop()
            }
        }
    }

    private func heard(_ words: String, final: Bool, from start: Double) {
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
        guard !engine.isRunning else { return }
        #if os(iOS)
        // A phone shares one audio route between everything on it, and the microphone
        // is not the app's until the app says it is recording.
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true, options: .notifyOthersOnDeactivation)
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
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        sink.point(at: nil)
        #if os(iOS)
        // Give the route back, so whatever was playing before carries on.
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    private nonisolated func finish(_ analyzer: SpeechAnalyzer) async {
        await analyzer.cancelAndFinishNow()
    }

    /// The alert has been read. It is shown for as long as there is something to say,
    /// so saying nothing is what dismisses it — `stop()` will not, because by the time
    /// a problem is set there is nothing left running for it to stop.
    func dismissProblem() { problem = nil }

    /// Stops listening. What is in the field stays as it is, words still being heard
    /// and all: they were shown, so they are kept (#69).
    func stop() {
        // Retire pending permission and set-up work as well as results still on their
        // way. Results already queued carry the old run number.
        run += 1
        onChange = nil
        isListening = false
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
