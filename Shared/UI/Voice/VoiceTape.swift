#if DEBUG
@preconcurrency import AVFoundation
import Foundation

/// A walk's tape of what voice mode would play (#4854): a video mixes it under the frames
/// (`scripts/video/make.py`). No speaker, no audio device and no permission, so it works on
/// a scratch set-up and with a locked screen, as the frames do.
///
/// The tape is a folder:
/// - `speech.wav`: the voice's samples (Kokoro's 24 kHz mono), each sentence at the time it
///   would play, after the one before it, as on the voice's player. Written when the tape ends.
/// - `marks.json`: `start` (seconds since 1970, the clock of the video's frames) and `marks`,
///   each at `t` seconds from the start: a sentence (`said`, `seconds`; `said` is null for
///   "Let me think.") or a sound (`sound`, `volume`). A sound is the Mac's sound name, or on
///   the Remote its SystemSoundID. Written at each mark.
@MainActor
final class VoiceTape {
    /// The tape a walk started, if any: the speaker and the sounds write to it in place of
    /// playing.
    private(set) static var current: VoiceTape?

    let folder: URL
    /// When the tape started, as seconds since 1970.
    let start: Double
    private var samples: [Float] = []
    private var marks: [[String: Any]] = []

    /// Ends the tape on, if any, and starts one in `path`, unless it is empty.
    static func start(_ path: String) throws {
        let ending = current
        current = nil
        try ending?.end()
        guard !path.isEmpty else { return }
        current = try VoiceTape(folder: URL(fileURLWithPath: path))
    }

    private init(folder: URL) throws {
        self.folder = folder
        start = Date().timeIntervalSince1970
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: folder.appendingPathComponent("speech.wav"))
        try writeMarks()
    }

    private static var rate: Double { KokoroVoice.sampleRate }
    /// Seconds since the tape started.
    private var now: Double { Date().timeIntervalSince1970 - start }

    /// Puts `clip` on the tape where it would play: now, or after what is on it already.
    /// Gives the time it would end, for `heard(until:)`.
    func speak(_ clip: [Float], said: String?) -> Double {
        let at = max(Int(now * Self.rate), samples.count)
        if at > samples.count { samples += repeatElement(0, count: at - samples.count) }
        samples += clip
        add(["t": Double(at) / Self.rate, "said": said ?? NSNull(), "seconds": Double(clip.count) / Self.rate])
        return Double(samples.count) / Self.rate
    }

    /// Waits until `end` (a time `speak` gave), as the voice's player waits until a buffer
    /// was heard; a cancel ends the wait at once, as `stop()` stops the player.
    func heard(until end: Double) async {
        let wait = end - now
        guard wait > 0 else { return }
        try? await Task.sleep(for: .milliseconds(Int(wait * 1000)))
    }

    /// The voice stopped now, mid-word if it must: what was not heard yet comes off the tape.
    func cut() {
        let at = max(0, Int(now * Self.rate))
        guard at < samples.count else { return }
        samples.removeLast(samples.count - at)
        let end = Double(at) / Self.rate
        marks = marks.compactMap { mark in
            guard let t = mark["t"] as? Double, let seconds = mark["seconds"] as? Double else { return mark }
            if t >= end { return nil }
            var cut = mark
            cut["seconds"] = min(seconds, end - t)
            return cut
        }
        try? writeMarks()
    }

    /// A sound, now: its name on the Mac, its SystemSoundID on the Remote.
    func sound(_ sound: Any, volume: Float) {
        add(["t": now, "sound": sound, "volume": Double(volume)])
    }

    private func add(_ mark: [String: Any]) {
        marks.append(mark)
        try? writeMarks()
    }

    private func writeMarks() throws {
        let data = try JSONSerialization.data(withJSONObject: ["start": start, "marks": marks], options: [.prettyPrinted, .sortedKeys])
        try data.write(to: folder.appendingPathComponent("marks.json"), options: .atomic)
    }

    /// Writes `speech.wav` (16-bit, 24 kHz mono) and the marks.
    private func end() throws {
        try writeMarks()
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Self.rate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: folder.appendingPathComponent("speech.wav"), settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return }
            channel.update(from: base, count: samples.count)
        }
        try file.write(from: buffer)
    }
}
#endif
