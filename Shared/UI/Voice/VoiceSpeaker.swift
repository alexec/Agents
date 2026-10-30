@preconcurrency import AVFoundation
import Foundation

/// Says sentences in the voice, one after another (#2322).
///
/// The next sentence is made while the one before it plays, so there is no gap after the
/// first. `stop()` stops at once: the person pressed Stop, or spoke, and what was not said
/// is still on the screen. It plays through voice mode's engine (`VoiceAudio`), so the
/// microphone can leave it out (#2375).
@MainActor
final class VoiceSpeaker {
    private let voice: KokoroVoice
    private let audio: VoiceAudio
    private var engine: AVAudioEngine { audio.engine }
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: KokoroVoice.sampleRate, channels: 1)
    private var run = 0
    private var isConnected = false
    /// Made and played in silence: a walk on the person's Mac says nothing out loud.
    var isMuted = false {
        didSet { engine.mainMixerNode.outputVolume = isMuted ? 0 : 1 }
    }

    init(voice: KokoroVoice, audio: VoiceAudio) {
        self.voice = voice
        self.audio = audio
        engine.attach(player)
    }

    /// Says each sentence `next` gives, until it gives none: a reply is spoken while it is
    /// still being written (#2375). `next` is asked again once a sentence has been heard,
    /// so one that came meanwhile is said too.
    func say(next: () -> String?, onSentence: (String) -> Void = { _ in }) async throws {
        guard let format, var sentence = next() else { return }
        run += 1
        let thisRun = run
        try await openOutput()
        defer { if thisRun == run { closeOutput() } }
        var samples = try await voice.audio(for: sentence)
        while thisRun == run {
            guard let buffer = Self.buffer(samples, format: format) else { return }
            onSentence(sentence)
            let playing = try play(buffer)
            // The next one is made while this one is heard.
            var following = next()
            var made: [Float]?
            if let following { made = try await voice.audio(for: following) }
            await playing.value
            if following == nil, thisRun == run, let late = next() {
                following = late
                made = try await voice.audio(for: late)
            }
            guard let following, let made else { return }
            sentence = following
            samples = made
        }
    }

    /// Stops at once, mid-word if it must.
    func stop() {
        run += 1
        player.stop()
        closeOutput()
    }

    /// Plays `buffer`; the task ends once it has been heard, or the player was stopped.
    private func play(_ buffer: AVAudioPCMBuffer, again: Bool = true) throws -> Task<Void, Never> {
        let (heard, done) = AsyncStream<Void>.makeStream()
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { @Sendable _ in
            done.finish()
        }
        if !player.isPlaying {
            do {
                try player.playAudio()
            } catch where again {
                // The second voice after a launch could find the graph changed under the
                // engine, though it said it was joined and running (-10863, #2472): join
                // it again and start once more.
                player.stop()
                try rejoin()
                return try play(buffer, again: false)
            }
        }
        return Task { for await _ in heard {} }
    }

    /// The route is voice mode's (`VoiceAudio.open`): this joins the player and starts the engine.
    private func openOutput() async throws {
        try await audio.open()
        // Again each time the engine is stopped: voice processing turned off and on
        // remakes the engine's graph.
        if !isConnected || !engine.isRunning, let format {
            try engine.connectNode(player, to: engine.mainMixerNode, format: format)
            isConnected = true
        }
        try audio.start()
    }

    /// Stops the engine, joins the mixer and the player again and starts it.
    private func rejoin() throws {
        guard let format else { return }
        try audio.rejoin()
        try engine.connectNode(player, to: engine.mainMixerNode, format: format)
        isConnected = true
        try audio.start()
    }

    /// The engine goes on for the microphone; the voice only stops.
    private func closeOutput() {
        player.stop()
    }

    private static func buffer(_ samples: [Float], format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return }
            channel.update(from: base, count: samples.count)
        }
        return buffer
    }
}
