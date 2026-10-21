import AppKit
@preconcurrency import AVFoundation
import CoreMedia
import Darwin
import Foundation
import Speech

// The #1800 demo: a wake phrase heard on this Mac with no extra model.
//
//   wake-demo clips  out/                                 test speech in 8 voices, by `say`
//   wake-demo detect "hey loops" file.wav [--realtime] [--no-detector] [--also "hey loose,…"] [--truth truth.json]
//   wake-demo listen "hey loops"                          the microphone, until Control-C
//
// The detector is Apple's on-device SpeechAnalyzer: a SpeechDetector (voice activity)
// in front of a SpeechTranscriber, with the phrase given as context. Each result's text
// is checked for the phrase; a match is a wake. No audio is kept or sent anywhere.

func note(_ message: String) { FileHandle.standardError.write(Data((message + "\n").utf8)) }
func fail(_ message: String) -> Never { note(message); exit(2) }

// MARK: - Test speech

// Apple's voices make the test speech only; voice mode's own voice is Paradee (#1792).
// Kokoro was the first choice here, but with eight voices loaded it crashed in libBNNS on
// macOS 27.0.1, three runs of three (see the report).
let voices = ["Ava (Premium)", "Noelle (Enhanced)", "Karen", "Moira", "Aman",
              "Eddy (English (US))", "Flo (English (UK))", "Daniel (English (UK))"]
/// Words a minute; `say`'s normal is 175.
let speeds: [Int] = [160, 185, 215]
let phrases = ["Hey Loops", "Okay Agents", "Hey Agents"]

/// Developer talk with the near misses a wake phrase meets at a desk.
let negatives = [
    "Can you look at the for loops in the parser?",
    "The agents finished the build an hour ago.",
    "Hey, look at this graph, it went up again.",
    "Okay, a gent from the other team called.",
    "Two nested loops make it quadratic.",
    "Hey, how was the weekend?",
    "The loop never ends because the index never moves.",
    "Okay, agents can run in parallel now.",
    "Hello, can you hear me? You are on mute.",
    "Let's loop in Sam on the next call.",
    "Hey Lou, pass me the charger.",
    "Okay, that's enough for today.",
    "Fruit Loops are not a breakfast.",
    "The agent asked for permission to run the tests.",
    "Hey, loopy idea, but it might work.",
    "Run the event loop on the main thread.",
    "Okay, a Jens or a Jenny, I forget the name.",
    "Hey there, are the agents still running?",
    "We go around in loops on this design.",
    "Okay, I'll merge it after lunch.",
]

func writeWav(_ samples: [Float], to url: URL) throws {
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 24_000.0, AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
    ]
    let file = try AVAudioFile(forWriting: url, settings: settings)
    let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
    buffer.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
    try file.write(from: buffer)
}

struct Truth: Codable { var phrase: String; var wakes: [[Double]] }

func clips(_ out: String) async throws {
    let dir = URL(fileURLWithPath: out)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("wake-say.caf")
    func say(_ text: String, _ voice: String, _ rate: Int) async throws -> [Float] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-v", voice, "-r", String(rate), "--data-format=LEF32@24000", "-o", scratch.path, text]
        let status = try await withCheckedThrowingContinuation { (done: CheckedContinuation<Int32, Error>) in
            process.terminationHandler = { done.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch { done.resume(throwing: error) }
        }
        guard status == 0 else { fail("say failed for \(voice)") }
        let file = try AVAudioFile(forReading: scratch)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }
    let gap = [Float](repeating: 0, count: 24_000 * 6 / 10)
    var generator = SystemRandomNumberGenerator()

    // The near misses alone: every wake here is a false one.
    var negative: [Float] = []
    for (index, sentence) in negatives.enumerated() {
        negative += try await say(sentence, voices[index % voices.count], 185) + gap
    }
    try writeWav(negative, to: dir.appendingPathComponent("negatives.wav"))
    note("negatives written")

    // Each phrase: 24 tries (8 voices × 3 speeds) among the near misses, with a little noise.
    for phrase in phrases {
        var stream: [Float] = []
        var truth = Truth(phrase: phrase, wakes: [])
        var tries: [(String, Int)] = voices.flatMap { v in speeds.map { (v, $0) } }
        tries.shuffle(using: &generator)
        for (index, (voice, speed)) in tries.enumerated() {
            let start = Double(stream.count) / 24_000
            stream += try await say(phrase + ".", voice, speed)
            truth.wakes.append([start, Double(stream.count) / 24_000])
            stream += gap
            stream += try await say(negatives[index % negatives.count], voices[(index + 3) % voices.count], 185) + gap
        }
        for i in stream.indices { stream[i] += Float.random(in: -0.004...0.004, using: &generator) }
        let name = phrase.lowercased().replacing(" ", with: "-")
        try writeWav(stream, to: dir.appendingPathComponent("stream-\(name).wav"))
        try JSONEncoder().encode(truth).write(to: dir.appendingPathComponent("truth-\(name).json"))
    }
    // A minute of a quiet room, for the cost of listening when nobody talks.
    let quiet = (0..<(24_000 * 60)).map { _ in Float.random(in: -0.002...0.002, using: &generator) }
    try writeWav(quiet, to: dir.appendingPathComponent("quiet.wav"))
    print("clips in \(dir.path)")
}

// MARK: - The detector

func normalized(_ s: String) -> String {
    s.lowercased().unicodeScalars.map { CharacterSet.letters.contains($0) ? String($0) : " " }.joined()
        .split(separator: " ").joined(separator: " ")
}

func cpuSeconds() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
        + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
}

final class Detector: @unchecked Sendable {
    let phrase: String
    /// Spellings the recogniser writes for the phrase, as heard in the test speech.
    let alternates: [String]
    /// The last word of the phrase and of each alternate, to find the phrase's time.
    let lastWords: [String]
    let firstWords: [String]
    let transcriber: SpeechTranscriber
    let analyzer: SpeechAnalyzer
    let format: AVAudioFormat
    var wakes: [(segment: Double, audio: Double, wall: Double)] = []
    var heard: [String] = []

    init(phrase: String, alternates: [String] = [], useDetector: Bool) async throws {
        self.phrase = normalized(phrase)
        self.alternates = alternates.map(normalized)
        lastWords = ([self.phrase] + self.alternates).compactMap { $0.split(separator: " ").last.map(String.init) }
        firstWords = ([self.phrase] + self.alternates).compactMap { $0.split(separator: " ").first.map(String.init) }
        guard SpeechTranscriber.isAvailable else { fail("no on-device speech transcription here") }
        let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en_US")) ?? Locale(identifier: "en_US")
        transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                        reportingOptions: [.volatileResults, .fastResults],
                                        attributeOptions: [.audioTimeRange])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        var modules: [any SpeechModule] = [transcriber]
        if useDetector {
            modules.insert(SpeechDetector(detectionOptions: .init(sensitivityLevel: .medium), reportResults: false), at: 0)
        }
        analyzer = SpeechAnalyzer(modules: modules)
        let context = AnalysisContext()
        context.contextualStrings[.general] = [phrase]
        try? await analyzer.setContext(context)
        guard let best = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            fail("no audio format for the transcriber")
        }
        format = best
    }

    /// Reads results until the stream ends; a result whose text holds the phrase is a wake,
    /// once per segment of speech.
    func watch(onWake: @escaping @Sendable (Double) -> Void) -> Task<Void, Error> {
        Task {
            for try await result in transcriber.results {
                let text = String(result.text.characters)
                if result.isFinal { heard.append(text) }
                let said = normalized(text)
                guard ([phrase] + alternates).contains(where: { said.contains($0) }) else { continue }
                // A result is one segment of speech; its start says which. A volatile result
                // and the final one of the same segment start within a second of each other.
                // A final result also carries each word's time: the phrase's own time, once known,
                // replaces the segment's start, which can be a sentence earlier.
                let segment = result.range.start.seconds
                // The phrase's last word, where the word before it is the phrase's first.
                var word: Double?
                var previous = ""
                for run in result.text.runs {
                    let piece = normalized(String(result.text[run.range].characters))
                    if piece.isEmpty { continue }
                    if word == nil, lastWords.contains(where: { piece.contains($0) }),
                       firstWords.contains(where: { previous.hasSuffix($0) }), let range = run.audioTimeRange {
                        word = range.start.seconds
                    }
                    previous = piece
                }
                if ProcessInfo.processInfo.environment["WAKE_DEBUG"] != nil {
                    note(String(format: "candidate final=%@ range=%.2f–%.2f word=%.2f %@", result.isFinal ? "y" : "n",
                                segment, result.range.end.seconds, word ?? -1, text))
                }
                if let i = wakes.firstIndex(where: { wake in
                    abs(wake.segment - segment) < 1.5 || word.map { abs(wake.audio - $0) < 1.5 } == true
                }) {
                    if let word { wakes[i].audio = word }
                    continue
                }
                wakes.append((segment, word ?? segment, Date().timeIntervalSinceReferenceDate))
                onWake(segment)
            }
        }
    }
}

/// The file in 100 ms buffers in the transcriber's format, paced like a microphone if asked.
func feed(_ url: URL, to detector: Detector, realtime: Bool,
          started: @escaping @Sendable () -> Void) async throws -> Double {
    let file = try AVAudioFile(forReading: url)
    let source = file.processingFormat
    let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: input)
    let converter = AVAudioConverter(from: source, to: detector.format)!
    let ratio = detector.format.sampleRate / source.sampleRate
    let output = AVAudioPCMBuffer(pcmFormat: detector.format,
                                  frameCapacity: AVAudioFrameCount(Double(input.frameLength) * ratio) + 1024)!
    var given = false
    var error: NSError?
    converter.convert(to: output, error: &error) { _, status in
        if given { status.pointee = .endOfStream; return nil }
        given = true
        status.pointee = .haveData
        return input
    }
    if let error { throw error }

    let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
    try await detector.analyzer.start(inputSequence: stream)
    started()
    let chunk = AVAudioFrameCount(detector.format.sampleRate / 10)
    let begin = Date()
    var offset: AVAudioFrameCount = 0
    let bytesPerFrame = Int(detector.format.streamDescription.pointee.mBytesPerFrame)
    while offset < output.frameLength {
        let count = min(chunk, output.frameLength - offset)
        let piece = AVAudioPCMBuffer(pcmFormat: detector.format, frameCapacity: count)!
        piece.frameLength = count
        let src = output.audioBufferList.pointee.mBuffers
        let dst = piece.mutableAudioBufferList.pointee.mBuffers
        memcpy(dst.mData!, src.mData!.advanced(by: Int(offset) * bytesPerFrame), Int(count) * bytesPerFrame)
        continuation.yield(AnalyzerInput(buffer: piece))
        offset += count
        if realtime {
            let due = Double(offset) / detector.format.sampleRate
            let ahead = due - Date().timeIntervalSince(begin)
            if ahead > 0 { try await Task.sleep(for: .seconds(ahead)) }
        }
    }
    continuation.finish()
    try await detector.analyzer.finalizeAndFinishThroughEndOfInput()
    return Double(output.frameLength) / detector.format.sampleRate
}

func detect(_ phrase: String, _ path: String, realtime: Bool, useDetector: Bool, alternates: [String],
            truthPath: String?) async throws {
    let detector = try await Detector(phrase: phrase, alternates: alternates, useDetector: useDetector)
    let wallStart = Date().timeIntervalSinceReferenceDate
    let cpuStart = cpuSeconds()
    let watching = detector.watch { at in print(String(format: "wake in the speech from %.2f s", at)) }
    let audioSeconds = try await feed(URL(fileURLWithPath: path), to: detector, realtime: realtime) {}
    try await watching.value
    let wall = Date().timeIntervalSinceReferenceDate - wallStart
    let cpu = cpuSeconds() - cpuStart
    print(String(format: "audio %.0f s, wall %.0f s, cpu %.1f s: %.1f%% of one core while listening, %.3f cpu s per audio s",
                 audioSeconds, wall, cpu, 100 * cpu / wall, cpu / audioSeconds))
    guard let truthPath else {
        print("\(detector.wakes.count) wakes")
        return
    }
    let truth = try JSONDecoder().decode(Truth.self, from: Data(contentsOf: URL(fileURLWithPath: truthPath)))
    var hit = Set<Int>()
    var falseWakes = 0
    var lags: [Double] = []
    for wake in detector.wakes {
        if let i = truth.wakes.firstIndex(where: { wake.audio >= $0[0] - 1.0 && wake.audio <= $0[1] }) {
            if hit.insert(i).inserted { lags.append(wake.wall - wallStart - truth.wakes[i][1]) }
        } else {
            falseWakes += 1
        }
    }
    if realtime, !lags.isEmpty {
        // How long after the phrase ended the wake came, in a run paced like a microphone.
        lags.sort()
        print(String(format: "wake lag after the phrase: median %.2f s, max %.2f s", lags[lags.count / 2], lags.last!))
    }
    print("\(truth.phrase): \(hit.count) of \(truth.wakes.count) heard, \(falseWakes) false wakes")
    let missed = truth.wakes.indices.filter { !hit.contains($0) }
    if !missed.isEmpty { print("missed tries: \(missed.map { $0 + 1 })") }
    if ProcessInfo.processInfo.environment["WAKE_SHOW_TEXT"] != nil { print(detector.heard.joined(separator: " | ")) }
}

func listen(_ phrase: String, alternates: [String]) async throws {
    let detector = try await Detector(phrase: phrase, alternates: alternates, useDetector: true)
    let engine = AVAudioEngine()
    let input = engine.inputNode
    let source = input.outputFormat(forBus: 0)
    let converter = AVAudioConverter(from: source, to: detector.format)!
    let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
    input.installTap(onBus: 0, bufferSize: 2048, format: source) { buffer, _ in
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * detector.format.sampleRate / source.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: detector.format, frameCapacity: capacity) else { return }
        var given = false
        converter.convert(to: out, error: nil) { _, status in
            if given { status.pointee = .noDataNow; return nil }
            given = true
            status.pointee = .haveData
            return buffer
        }
        continuation.yield(AnalyzerInput(buffer: out))
    }
    try await detector.analyzer.start(inputSequence: stream)
    try engine.start()
    note("listening for \"\(phrase)\"; Control-C stops")
    let watching = detector.watch { at in
        print(String(format: "WAKE at %.1f s", at))
        NSSound(named: "Glass")?.play()
    }
    try await watching.value
}

// MARK: - Main

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "clips":
    guard args.count == 2 else { fail("wake-demo clips out/") }
    try await clips(args[1])
case "detect":
    guard args.count >= 3 else { fail("wake-demo detect PHRASE file.wav [--realtime] [--no-detector] [--also a,b] [--truth truth.json]") }
    let truth = args.firstIndex(of: "--truth").map { args[$0 + 1] }
    let also = args.firstIndex(of: "--also").map { args[$0 + 1].split(separator: ",").map(String.init) } ?? []
    try await detect(args[1], args[2], realtime: args.contains("--realtime"),
                     useDetector: !args.contains("--no-detector"), alternates: also, truthPath: truth)
case "listen":
    guard args.count >= 2 else { fail("wake-demo listen PHRASE [--also a,b]") }
    let also = args.firstIndex(of: "--also").map { args[$0 + 1].split(separator: ",").map(String.init) } ?? []
    try await listen(args[1], alternates: also)
default:
    fail("wake-demo clips|detect|listen")
}
