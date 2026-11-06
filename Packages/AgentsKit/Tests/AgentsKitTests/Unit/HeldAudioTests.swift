#if canImport(AVFoundation)
import AVFoundation
import Testing
@testable import AgentsKitCore

/// #3563: the audio between two runs of voice mode's dictation is kept for the next one,
/// so the first words of a prompt are not lost while its analyser starts.
@Suite("Audio held while the analyser starts")
struct HeldAudioTests {
    private static let microphone = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!

    /// A buffer of `seconds`, every sample `value`.
    private static func buffer(_ seconds: Double, value: Float) -> AVAudioPCMBuffer {
        let frames = AVAudioFrameCount(seconds * microphone.sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: microphone, frameCapacity: max(frames, 1))!
        buffer.frameLength = frames
        for frame in 0..<Int(frames) { buffer.floatChannelData![0][frame] = value }
        return buffer
    }

    private static func value(of buffer: AVAudioPCMBuffer) -> Float { buffer.floatChannelData![0][0] }

    @Test func everythingHeldIsGivenInOrderThenNothing() {
        var held = HeldAudio(limit: 3)
        for value in [1, 2, 3] as [Float] { held.append(Self.buffer(0.1, value: value)) }
        #expect(abs(held.seconds - 0.3) < 0.001)
        #expect(held.take().map(Self.value) == [1, 2, 3])
        #expect(held.take().isEmpty)
        #expect(held.seconds == 0)
    }

    /// A long hold keeps its newest seconds, not all of it.
    @Test func noMoreThanTheLimitIsKeptTheNewest() {
        var held = HeldAudio(limit: 1)
        for value in 1...15 { held.append(Self.buffer(0.1, value: Float(value))) }
        #expect(held.seconds <= 1.0001)
        #expect(held.buffers.map(Self.value) == (6...15).map(Float.init))
    }

    /// The tap may write into its buffer again once it returns: what is held is a copy.
    @Test func whatIsHeldIsACopy() throws {
        var held = HeldAudio(limit: 3)
        let given = Self.buffer(0.05, value: 0.25)
        held.append(given)
        given.floatChannelData![0][0] = 0.75
        let kept = try #require(held.take().first)
        #expect(Self.value(of: kept) == 0.25)
        #expect(kept.frameLength == given.frameLength)
    }

    @Test func anEmptyBufferIsNotKept() {
        var held = HeldAudio(limit: 3)
        held.append(Self.buffer(0, value: 1))
        #expect(held.buffers.isEmpty)
    }
}
#endif
