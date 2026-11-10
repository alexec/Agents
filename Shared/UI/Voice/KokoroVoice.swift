import AgentsKitCore
import FluidAudio
import Foundation

/// The voice of voice mode: Kokoro-82M's `af_heart`, through FluidAudio's Neural Engine build
/// (Alex, 2026-10-29). Warmer than Paradee, and fast enough to speak a reply as it is written:
/// Chatterbox, the integration videos' voice (#1793), made a second of speech in about three
/// on this Mac, so a reply came with long gaps and lost words.
///
/// Its models and its 28 English voices are inside the app (`Resources/Voice`,
/// `scripts/voice-models.sh`), so nothing is downloaded. FluidAudio reads them only from its
/// own cache folder, so they are linked there from the bundle before it loads. Loaded when
/// voice mode turns on and let go when it turns off, or a minute after Settings' sample (#2880).
actor KokoroVoice {
    /// 24 kHz mono.
    static let sampleRate = Double(KokoroAneConstants.sampleRate)

    private var manager: KokoroAneManager?
    /// "Let me think." in the voice and speed it was made in (#3565): made once, so it plays
    /// as the prompt goes with no wait.
    private var thinking: (voice: String, speed: Double, samples: [Float])?
    /// One Core ML run at a time. The actor lets a second call in while the first awaits,
    /// and two runs of the same model at once trap in Core ML (the crash Alex hit when a
    /// sentence was stopped and the next begun, 2026-10-29).
    private var isBusy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    private func take() async {
        guard isBusy else {
            isBusy = true
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    private func giveBack() {
        if waiting.isEmpty { isBusy = false } else { waiting.removeFirst().resume() }
    }

    /// Loads the models, downloading them the first time. Safe to call again.
    func load() async throws {
        await take()
        defer { giveBack() }
        guard manager == nil else { return }
        // A link left by another copy of the app is one this copy may not read.
        if let bundled = Bundle.main.url(forResource: "Voice", withExtension: nil) {
            try Self.link(from: bundled)
        }
        let manager = KokoroAneManager(defaultVoice: VoiceSettings.voice)
        try await manager.initialize()
        // A word said in silence, so the first-call set-up is not in the first reply.
        _ = try? await manager.synthesizeDetailed(text: "Hi.")
        self.manager = manager
        // Just after the "Hi.", so it is ready at the first prompt (about 200 ms, #3564).
        _ = try? await makeLetMeThink(manager)
    }

    /// "Let me think." in the voice and speed Settings has now (#3565). Made again only
    /// when the voice or the speed has changed since it was made.
    func letMeThink() async throws -> [Float] {
        if manager == nil { try await load() }
        await take()
        defer { giveBack() }
        guard let manager else { return [] }
        return try await makeLetMeThink(manager)
    }

    /// Call only while this holds the model (`take`).
    private func makeLetMeThink(_ manager: KokoroAneManager) async throws -> [Float] {
        let voice = VoiceSettings.voice, speed = VoiceSettings.speed
        if let thinking, thinking.voice == voice, thinking.speed == speed { return thinking.samples }
        let samples = try await manager.synthesizeDetailed(text: VoiceModeWords.letMeThink, voice: voice,
                                                           speed: Float(speed)).samples
        let made = Self.trimmed(samples, gap: 0)
        thinking = (voice, speed, made)
        return made
    }

    /// One sentence, as samples at `sampleRate`.
    func audio(for sentence: String) async throws -> [Float] {
        if manager == nil { try await load() }
        await take()
        defer { giveBack() }
        guard let manager else { return [] }
        let samples = try await manager.synthesizeDetailed(text: sentence, voice: VoiceSettings.voice,
                                                           speed: Float(VoiceSettings.speed)).samples
        return Self.trimmed(samples, gap: VoiceSettings.gap)
    }

    /// The sentence without the silence at its ends, and `gap` milliseconds of silence after
    /// it: Settings ▸ Voice sets the pause between sentences (Alex, 2026-10-29).
    static func trimmed(_ samples: [Float], gap: Double) -> [Float] {
        let quiet: Float = 0.01
        guard let first = samples.firstIndex(where: { abs($0) > quiet }),
              let last = samples.lastIndex(where: { abs($0) > quiet }) else { return samples }
        // A little either side, so a soft first or last sound is not cut.
        let margin = Int(sampleRate * 0.03)
        let start = max(0, first - margin)
        let end = min(samples.count, last + margin)
        return Array(samples[start..<end]) + Array(repeating: 0, count: Int(sampleRate * gap / 1000))
    }

    func unload() async {
        await take()
        defer { giveBack() }
        await manager?.cleanup()
        manager = nil
        thinking = nil
    }

    /// The bundle's Voice folder, linked into FluidAudio's cache folder (in the app's
    /// container on the Mac, Application Support on iOS): the English front end into
    /// `Models/kokoro`, the models and voices into `Models/kokoro-82m-coreml/ANE`. A link left
    /// by an older copy of the app points at a bundle that has moved, so each is made again,
    /// and an entry the bundle no longer has (an older model, such as `KokoroTail.mlmodelc`
    /// next to `KokoroTail_v2.mlmodelc`) is removed (#3747). A build without the voice (a Debug build offline) links nothing, and FluidAudio
    /// downloads what it needs.
    static func link(from voice: URL) throws {
        let files = FileManager.default
        let models = try TtsCacheDirectory.ensure().appending(path: "Models")
        for folder in ["kokoro", "kokoro-82m-coreml/ANE"] {
            let source = voice.appending(path: folder)
            guard let names = try? files.contentsOfDirectory(atPath: source.path) else { continue }
            let cache = models.appending(path: folder)
            try files.createDirectory(at: cache, withIntermediateDirectories: true)
            for name in names {
                let link = cache.appending(path: name)
                let target = source.appending(path: name)
                if (try? files.destinationOfSymbolicLink(atPath: link.path)) == target.path { continue }
                try? files.removeItem(at: link)
                do {
                    try files.createSymbolicLink(at: link, withDestinationURL: target)
                } catch {
                    try files.copyItem(at: target, to: link)
                }
            }
            Leftovers.removeAll(in: cache, except: Set(names))
        }
    }
}
