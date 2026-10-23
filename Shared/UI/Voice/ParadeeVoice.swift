import FluidAudio
import Foundation

/// The one voice of voice mode (#2322): Paradee-8M int8, through FluidAudio's Core ML build.
///
/// Its models are inside the app (`Resources/Voice`, `scripts/voice-models.sh`), so nothing
/// is downloaded. FluidAudio reads Paradee's two models from any folder, but its English
/// front end (G2P and the lexicon) only from its own cache folder, so those are linked
/// there from the bundle before it loads. Loaded when voice mode turns on and let go when
/// it turns off: the shared front end is most of its 270 MB.
actor ParadeeVoice {
    enum Failure: LocalizedError {
        case notInThisBuild

        var errorDescription: String? {
            "This build has no voice. Build it with the voice models (scripts/voice-models.sh)."
        }
    }

    /// 24 kHz mono.
    static let sampleRate = Double(ParadeeConstants.sampleRate)
    /// A fifth faster than Paradee's own pace (Alex, #2375).
    static let speed = ParadeeConstants.defaultSpeed * 1.2

    private var manager: ParadeeManager?

    /// The bundle's Voice folder, with both of its parts.
    private static var bundled: URL? {
        guard let voice = Bundle.main.url(forResource: "Voice", withExtension: nil) else { return nil }
        let paradee = voice.appending(path: "paradee-8m-coreml/int8/ParadeeText.mlmodelc")
        let kokoro = voice.appending(path: "kokoro/g2p_vocab.json")
        let files = FileManager.default
        guard files.fileExists(atPath: paradee.path), files.fileExists(atPath: kokoro.path) else { return nil } // store-ok: the app's own bundle
        return voice
    }

    /// Loads the models. Safe to call again: the second call does nothing.
    func load() async throws {
        guard manager == nil else { return }
        guard let voice = Self.bundled else { throw Failure.notInThisBuild }
        try Self.linkFrontEnd(from: voice.appending(path: "kokoro"))
        // The CPU: Paradee's LSTMs abort on the GPU, and the Neural Engine route is the one
        // FluidAudio flags on iOS 27 (#1792).
        let manager = ParadeeManager(variant: .int8, directory: voice, computeUnits: .cpuOnly)
        try await manager.initialize()
        self.manager = manager
    }

    /// One sentence, as samples at `sampleRate`.
    func audio(for sentence: String) async throws -> [Float] {
        if manager == nil { try await load() }
        guard let manager else { throw Failure.notInThisBuild }
        return try await manager.synthesize(text: sentence, speed: Self.speed)
    }

    func unload() async {
        await manager?.cleanup()
        manager = nil
    }

    /// The front end's files, linked into FluidAudio's cache folder (in the app's container
    /// on the Mac, Application Support on iOS). A link left by an older copy of the app
    /// points at a bundle that has moved, so each one is made again.
    private static func linkFrontEnd(from kokoro: URL) throws {
        let files = FileManager.default
        let cache = try TtsCacheDirectory.ensure().appending(path: "Models/kokoro")
        try files.createDirectory(at: cache, withIntermediateDirectories: true) // store-ok: the app's own container
        for name in ["G2PEncoder.mlmodelc", "G2PDecoder.mlmodelc", "g2p_vocab.json", "us_lexicon_cache.json"] {
            let link = cache.appending(path: name)
            let target = kokoro.appending(path: name)
            if (try? files.destinationOfSymbolicLink(atPath: link.path)) == target.path { continue }
            try? files.removeItem(at: link) // store-ok: the app's own container
            do {
                try files.createSymbolicLink(at: link, withDestinationURL: target)
            } catch {
                try files.copyItem(at: target, to: link) // store-ok: from the app's own bundle to its container
            }
        }
    }
}
