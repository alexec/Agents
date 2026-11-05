@preconcurrency import AVFoundation
import FluidAudio
import Foundation

// The #3564 demo: Kokoro says each filler in each voice, once as written text and once as
// phonemes given by hand, so a person can listen and keep what sounds human.
//
//   fillers out/ [voice …]          one WAV per voice and filler, and timings.json
//   fillers scene out/ [voice …]    50 s of an agent at work, then its reply: once with the
//                                   Morse click every 3 s (now), once with thinking sounds
//
// The models come from the build cache (scripts/voice-models.sh), linked into FluidAudio's
// cache folder as the app links them from its bundle.

let sampleRate = Double(KokoroAneConstants.sampleRate)

func note(_ message: String) { FileHandle.standardError.write(Data((message + "\n").utf8)) }
func now() -> Double { Date().timeIntervalSinceReferenceDate }

/// A filler: its name in the file, and either text for the G2P or phonemes to say as given.
struct Filler {
    var name: String
    var text: String?
    var phonemes: String?
}

let fillers: [Filler] = [
    // As text, through the English front end.
    .init(name: "t-hmm", text: "Hmm."),
    .init(name: "t-hmm-q", text: "Hmm?"),
    .init(name: "t-hmmm", text: "Hmmm…"),
    .init(name: "t-mm", text: "Mm."),
    .init(name: "t-mm-hm", text: "Mm-hm."),
    .init(name: "t-uh", text: "Uh…"),
    .init(name: "t-um", text: "Um…"),
    .init(name: "t-huh-q", text: "Huh?"),
    .init(name: "t-okay", text: "Okay."),
    .init(name: "t-right", text: "Right…"),
    .init(name: "t-let-me-see", text: "Let me see."),
    .init(name: "t-let-me-think", text: "Let me think."),
    .init(name: "t-one-moment", text: "One moment."),
    .init(name: "t-ah", text: "Ah."),
    .init(name: "t-oh-q", text: "Oh?"),
    // As phonemes, by hand (Kokoro's vocab: ˈ stress, ː long, ə schwa, ʌ, ɜ).
    .init(name: "p-hmm", phonemes: "hmː"),
    .init(name: "p-hmmm", phonemes: "hmːː"),
    .init(name: "p-mmm", phonemes: "mːː"),
    .init(name: "p-hm-rising", phonemes: "hmː?"),
    .init(name: "p-uh", phonemes: "ʌː"),
    .init(name: "p-erm", phonemes: "ɜːm"),
    .init(name: "p-huh-q", phonemes: "hˈʌ?"),
    .init(name: "p-mm-hm", phonemes: "mˈː hmː"),
]

let voices = CommandLine.arguments.count > 2
    ? Array(CommandLine.arguments.dropFirst(2))
    : ["af_heart", "af_bella", "am_michael", "bf_emma", "bm_george"]

// MARK: - Scene

/// The thinking sounds a scene picks from, and the one a question or an error gets.
let thinking = ["Hmm.", "Hmmm…", "Mm.", "Let me see.", "Right…", "Okay."]
let puzzled = "Huh?"

/// Samples of a sound file at `sampleRate`, mono, through afconvert.
func samples(of path: String) throws -> [Float] {
    let wav = FileManager.default.temporaryDirectory.appending(path: "fillers-\(UUID().uuidString).wav")
    let convert = Process()
    convert.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
    convert.arguments = ["-f", "WAVE", "-d", "LEF32@\(Int(sampleRate))", "-c", "1", path, wav.path]
    try convert.run()
    convert.waitUntilExit()
    defer { try? FileManager.default.removeItem(at: wav) }
    let file = try AVAudioFile(forReading: wav)
    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: buffer)
    return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
}

/// `sound` into `track` at `seconds`, at `volume`.
func mix(_ sound: [Float], into track: inout [Float], at seconds: Double, volume: Float) {
    let start = Int(seconds * sampleRate)
    if track.count < start + sound.count { track += [Float](repeating: 0, count: start + sound.count - track.count) }
    for (i, sample) in sound.enumerated() { track[start + i] += sample * volume }
}

/// 50 s of work, then the reply. Morse: the working sound now, every 3 s at 0.3. Thinking:
/// one sound a second after the prompt went, then one after a random 6 to 12 s, never the
/// same twice running, at 0.5; "Huh?" when a tool fails at 30 s.
func scenes(voices: [String]) async throws {
    let work = 50.0
    let morse = try samples(of: "/System/Library/Sounds/Morse.aiff")
    let sent = try samples(of: "/System/Library/Sounds/Bottle.aiff")
    let problem = 30.0
    for voice in voices {
        let reply = trimmed(try await manager.synthesizeDetailed(
            text: "Done. All forty tests pass, and the build is green.", voice: voice).samples)
        var made: [String: [Float]] = [:]
        for line in thinking + [puzzled] {
            made[line] = trimmed(try await manager.synthesizeDetailed(text: line, voice: voice).samples)
        }
        var clicks: [Float] = []
        mix(sent, into: &clicks, at: 0, volume: 1)
        for at in stride(from: 3.0, to: work, by: 3) { mix(morse, into: &clicks, at: at, volume: 0.3) }
        mix(reply, into: &clicks, at: work + 0.5, volume: 1)
        try writeWav(clicks, to: out.appending(path: "scene-morse-\(voice).wav"))

        var generator = SystemRandomNumberGenerator()
        var talk: [Float] = []
        var said: [String] = []
        mix(sent, into: &talk, at: 0, volume: 1)
        var at = 1.0
        var last = ""
        var puzzledYet = false
        while at < work - 2 {
            let line: String
            if at >= problem, !puzzledYet {
                line = puzzled
                puzzledYet = true
                at = problem
            } else {
                line = thinking.filter { $0 != last }.randomElement(using: &generator)!
            }
            mix(made[line]!, into: &talk, at: at, volume: 0.5)
            said.append("\(String(format: "%.1f", at)) s \(line)")
            last = line
            at += Double.random(in: 6...12, using: &generator)
            // Never two at once: one due just before the problem gives way to it.
            if !puzzledYet, at > problem - 3, at < problem { at = problem }
        }
        mix(reply, into: &talk, at: work + 0.5, volume: 1)
        try writeWav(talk, to: out.appending(path: "scene-thinking-\(voice).wav"))
        note("\(voice): \(said.joined(separator: ", "))")
    }
}

/// The voice from the build cache into FluidAudio's cache folder, as `KokoroVoice.link`.
func link() throws {
    let files = FileManager.default
    let voice = files.homeDirectoryForCurrentUser.appending(path: "Library/Caches/Agents-build/voice")
    let models = try TtsCacheDirectory.ensure().appending(path: "Models")
    for folder in ["kokoro", "kokoro-82m-coreml/ANE"] {
        let source = voice.appending(path: folder)
        guard let names = try? files.contentsOfDirectory(atPath: source.path) else { continue }
        let cache = models.appending(path: folder)
        try files.createDirectory(at: cache, withIntermediateDirectories: true)
        for name in names where !files.fileExists(atPath: cache.appending(path: name).path) {
            try files.createSymbolicLink(at: cache.appending(path: name), withDestinationURL: source.appending(path: name))
        }
    }
}

/// Without the silence at the ends, as `KokoroVoice.trimmed` with no gap.
func trimmed(_ samples: [Float]) -> [Float] {
    guard let first = samples.firstIndex(where: { abs($0) > 0.01 }),
          let last = samples.lastIndex(where: { abs($0) > 0.01 }) else { return [] }
    let margin = Int(sampleRate * 0.03)
    return Array(samples[max(0, first - margin)..<min(samples.count, last + margin)])
}

func writeWav(_ samples: [Float], to url: URL) throws {
    let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
    ]
    let file = try AVAudioFile(forWriting: url, settings: settings)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(samples.count, 1)))!
    buffer.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
    try file.write(from: buffer)
}

struct Row: Codable {
    var voice: String
    var filler: String
    var phonemes: String
    var synthMs: Int
    var seconds: Double
    var peak: Float
}

let isScene = CommandLine.arguments.count > 1 && CommandLine.arguments[1] == "scene"
let args = isScene ? Array(CommandLine.arguments.dropFirst()) : CommandLine.arguments
guard args.count > 1 else {
    note("usage: fillers [scene] out/ [voice …]")
    exit(2)
}
let out = URL(fileURLWithPath: args[1])
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
try link()
let manager = KokoroAneManager(defaultVoice: "af_heart")
var start = now()
try await manager.initialize()
_ = try? await manager.synthesizeDetailed(text: "Hi.")
note("loaded in \(Int((now() - start) * 1000)) ms")
if isScene {
    try await scenes(voices: args.count > 2 ? Array(args.dropFirst(2)) : ["af_heart"])
    exit(0)
}
var rows: [Row] = []
for voice in voices {
    start = now()
    _ = try? await manager.synthesizeDetailed(text: "Hi.", voice: voice)
    note("\(voice): first use \(Int((now() - start) * 1000)) ms")
    for filler in fillers {
        let begin = now()
        let result: KokoroAneSynthesisResult
        do {
            if let text = filler.text {
                result = try await manager.synthesizeDetailed(text: text, voice: voice)
            } else {
                result = try await manager.synthesizeFromPhonemesDetailed(filler.phonemes!, voice: voice)
            }
        } catch {
            note("\(voice) \(filler.name): \(error)")
            continue
        }
        let ms = Int((now() - begin) * 1000)
        let samples = trimmed(result.samples)
        try writeWav(samples, to: out.appending(path: "\(voice)-\(filler.name).wav"))
        var phonemes = filler.phonemes ?? "?"
        if let text = filler.text, let said = try? await manager.phonemes(for: text) { phonemes = said }
        rows.append(Row(voice: voice, filler: filler.name, phonemes: phonemes, synthMs: ms,
                        seconds: Double(samples.count) / sampleRate, peak: samples.map(abs).max() ?? 0))
        note("\(voice) \(filler.name) /\(phonemes)/ \(ms) ms \(String(format: "%.2f", Double(samples.count) / sampleRate)) s")
    }
}
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
try encoder.encode(rows).write(to: out.appending(path: "timings.json"))
