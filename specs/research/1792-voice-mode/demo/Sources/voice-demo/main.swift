@preconcurrency import AVFoundation
import Darwin
import FluidAudio
import Foundation
import Speakable

// The #1792 demo. Five commands:
//
//   voice-demo clean  [file.json | -]                 the speakable text of each reply
//   voice-demo render paradee|kokoro file.json out/   one WAV per reply, and the timings
//   voice-demo blind  out/                            shuffled, unlabelled pairs for a blind listen
//   voice-demo speak  paradee|kokoro [text | -]       clean a reply and say it, a sentence at a time
//   voice-demo phonemes file.json                    misaki phonemes per sentence, for the web page
//
// Paradee-8M and Kokoro-82M both say `af_heart`; Apple's voices are out (#1792).

let sampleRate = 24_000.0

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

func note(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

/// What this process holds in memory now, as Activity Monitor counts it.
func footprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
}

func now() -> Double { Date().timeIntervalSinceReferenceDate }

// MARK: - The two voices

protocol Voice: Sendable {
    func load() async throws
    func say(_ sentence: String) async throws -> [Float]
}

struct ParadeeVoice: Voice {
    let manager = ParadeeManager(variant: .int8, computeUnits: .cpuOnly)
    func load() async throws { try await manager.initialize() }
    func say(_ sentence: String) async throws -> [Float] { try await manager.synthesize(text: sentence) }
}

struct KokoroVoice: Voice {
    let manager = KokoroAneManager(defaultVoice: "af_heart")
    func load() async throws { try await manager.initialize() }
    func say(_ sentence: String) async throws -> [Float] {
        try await manager.synthesizeDetailed(text: sentence, voice: "af_heart").samples
    }
}

func voice(_ name: String) -> Voice {
    switch name {
    case "paradee": ParadeeVoice()
    case "kokoro": KokoroVoice()
    default: fail("no voice \(name): paradee or kokoro")
    }
}

// MARK: - Files

func replies(_ path: String) -> [String] {
    let data: Data
    if path == "-" {
        data = FileHandle.standardInput.readDataToEndOfFile()
    } else if let contents = FileManager.default.contents(atPath: path) {
        data = contents
    } else {
        fail("cannot read \(path)")
    }
    if let list = try? JSONDecoder().decode([String].self, from: data) { return list }
    return [String(decoding: data, as: UTF8.self)]
}

func writeWav(_ samples: [Float], to url: URL) throws {
    let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
    ]
    let file = try AVAudioFile(forWriting: url, settings: settings)
    try file.write(from: buffer(samples, format: format))
}

func buffer(_ samples: [Float], format: AVAudioFormat) -> AVAudioPCMBuffer {
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(samples.count, 1)))!
    buffer.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
    return buffer
}

// MARK: - Commands

struct Timing: Codable {
    var reply: Int
    var sentences: Int
    var words: Int
    var firstSoundMs: Int
    var synthMs: Int
    var audioSeconds: Double
    var realTimeFactor: Double
}

struct Run: Codable {
    var voice: String
    var loadSeconds: Double
    var peakFootprintMB: Double
    var replies: [Timing]
}

func render(_ name: String, _ path: String, _ out: String) async throws {
    let dir = URL(fileURLWithPath: out)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let v = voice(name)
    let start = now()
    try await v.load()
    var run = Run(voice: name, loadSeconds: now() - start, peakFootprintMB: footprintMB(), replies: [])
    note("\(name): loaded in \(String(format: "%.2f", run.loadSeconds)) s")
    for (index, reply) in replies(path).enumerated() {
        let sentences = Speakable.sentences(reply)
        let begin = now()
        var first = 0.0
        var all: [Float] = []
        for sentence in sentences {
            all += try await v.say(sentence)
            if first == 0 { first = now() - begin }
            // A short breath between sentences, as a person leaves one.
            all += [Float](repeating: 0, count: Int(sampleRate * 0.15))
        }
        let synth = now() - begin
        let seconds = Double(all.count) / sampleRate
        try writeWav(all, to: dir.appendingPathComponent(String(format: "%@-%02d.wav", name, index + 1)))
        run.peakFootprintMB = max(run.peakFootprintMB, footprintMB())
        let words = sentences.joined(separator: " ").split(separator: " ").count
        run.replies.append(Timing(reply: index + 1, sentences: sentences.count, words: words,
                                  firstSoundMs: Int(first * 1000), synthMs: Int(synth * 1000),
                                  audioSeconds: (seconds * 10).rounded() / 10,
                                  realTimeFactor: ((synth / seconds) * 1000).rounded() / 1000))
        let t = run.replies.last!
        print("\(name)\t\(t.reply)\tfirst \(t.firstSoundMs) ms\tsynth \(t.synthMs) ms\taudio \(t.audioSeconds) s\tRTF \(t.realTimeFactor)")
    }
    print("\(name)\tload \(String(format: "%.2f", run.loadSeconds)) s\tpeak \(Int(run.peakFootprintMB)) MB")
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(run).write(to: dir.appendingPathComponent("\(name)-timings.json"))
}

/// Pairs the two voices' WAVs, A and B in a random order, and writes the key apart.
func blind(_ out: String) throws {
    let dir = URL(fileURLWithPath: out)
    let pairs = dir.appendingPathComponent("blind")
    try? FileManager.default.removeItem(at: pairs)
    try FileManager.default.createDirectory(at: pairs, withIntermediateDirectories: true)
    var key: [String: String] = [:]
    for index in 1...99 {
        let p = dir.appendingPathComponent(String(format: "paradee-%02d.wav", index))
        let k = dir.appendingPathComponent(String(format: "kokoro-%02d.wav", index))
        guard FileManager.default.fileExists(atPath: p.path), FileManager.default.fileExists(atPath: k.path) else { break }
        let paradeeFirst = Bool.random()
        let (a, b) = paradeeFirst ? (p, k) : (k, p)
        try FileManager.default.copyItem(at: a, to: pairs.appendingPathComponent(String(format: "%02d-A.wav", index)))
        try FileManager.default.copyItem(at: b, to: pairs.appendingPathComponent(String(format: "%02d-B.wav", index)))
        key[String(format: "%02d", index)] = paradeeFirst ? "A=paradee B=kokoro" : "A=kokoro B=paradee"
    }
    try JSONSerialization.data(withJSONObject: key, options: [.prettyPrinted, .sortedKeys])
        .write(to: dir.appendingPathComponent("blind-key.json"))
    print("\(key.count) pairs in \(pairs.path); the key is \(dir.path)/blind-key.json")
}

/// Voice mode's last step: the reply is cleaned, and its first sentence plays while the
/// rest are still being made.
func speak(_ name: String, _ text: String) async throws {
    let v = voice(name)
    let loadStart = now()
    try await v.load()
    note("\(name): loaded in \(String(format: "%.2f", now() - loadStart)) s")
    let sentences = Speakable.sentences(text)
    note("speaking: " + sentences.joined(separator: " "))
    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
    engine.attach(player)
    engine.connect(player, to: engine.mainMixerNode, format: format)
    try engine.start()
    player.play()
    let begin = now()
    var last: AVAudioPCMBuffer?
    for (index, sentence) in sentences.enumerated() {
        let samples = try await v.say(sentence) + [Float](repeating: 0, count: Int(sampleRate * 0.15))
        let b = buffer(samples, format: format)
        player.scheduleBuffer(b, completionHandler: nil)
        last = b
        if index == 0 { note("first sound after \(Int((now() - begin) * 1000)) ms") }
    }
    if last != nil {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            player.scheduleBuffer(buffer([0], format: format), completionCallbackType: .dataPlayedBack) { _ in
                done.resume()
            }
        }
    }
    engine.stop()
}

// MARK: - Main

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "clean":
    for (index, reply) in replies(args.count > 1 ? args[1] : "-").enumerated() {
        print("\(index + 1). \(Speakable.text(reply))\n")
    }
case "render":
    guard args.count == 4 else { fail("voice-demo render paradee|kokoro replies.json out/") }
    try await render(args[1], args[2], args[3])
case "blind":
    guard args.count == 2 else { fail("voice-demo blind out/") }
    try blind(args[1])
case "phonemes":
    // The web page's input: misaki phonemes made here, so the browser needs no eSpeak NG (GPL).
    guard args.count == 2 else { fail("voice-demo phonemes replies.json > phonemes.json") }
    let paradee = ParadeeManager()
    try await paradee.initialize()
    var all: [[String]] = []
    for reply in replies(args[1]) {
        var sentences: [String] = []
        for sentence in Speakable.sentences(reply) { sentences.append(try await paradee.phonemes(for: sentence)) }
        all.append(sentences)
    }
    let data = try JSONSerialization.data(withJSONObject: all, options: [.prettyPrinted])
    print(String(decoding: data, as: UTF8.self))
case "speak":
    guard args.count >= 2 else { fail("voice-demo speak paradee|kokoro [text | -]") }
    let text = args.count > 2 && args[2] != "-" ? args[2...].joined(separator: " ")
        : String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
    try await speak(args[1], text)
default:
    fail("voice-demo clean|render|blind|speak")
}
