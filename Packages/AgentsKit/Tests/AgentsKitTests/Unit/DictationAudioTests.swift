#if canImport(AVFoundation)
import AVFoundation
import Testing
@testable import AgentsKitCore

/// #2419: with voice processing on, a Mac's microphone comes as seven discrete channels,
/// and what the analyser got from them was silence. Voice mode heard nothing.
@Suite("Dictation hears the microphone")
struct DictationAudioTests {
    /// What a Mac's input node gives with voice processing on: 7 discrete channels, 48 kHz.
    private static let voiceProcessed = AVAudioFormat(
        standardFormatWithSampleRate: 48_000,
        channelLayout: AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 7)!)
    private static let microphone = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    /// What the analyser asks for.
    private static let analyser = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000,
                                                channels: 1, interleaved: true)!

    /// A tone in the first channel, silence in the others.
    private static func tone(in format: AVAudioFormat) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800)!
        buffer.frameLength = 4_800
        for frame in 0..<4_800 { buffer.floatChannelData![0][frame] = sin(Float(frame) * 0.05) * 0.5 }
        return buffer
    }

    private static func peak(_ buffer: AVAudioPCMBuffer) -> Int16 {
        (0..<Int(buffer.frameLength)).map { abs(buffer.int16ChannelData![0][$0]) }.max() ?? 0
    }

    @Test func theVoiceProcessedMicrophoneIsHeard() throws {
        let format = Self.voiceProcessed
        #expect(format.channelCount == 7)
        let converter = try #require(DictationAudio.converter(from: format, to: Self.analyser))
        let converted = try #require(DictationAudio.convert(Self.tone(in: format), with: converter))
        #expect(Self.peak(converted) > 10_000)
    }

    @Test func theMicrophoneAloneIsHeard() throws {
        let converter = try #require(DictationAudio.converter(from: Self.microphone, to: Self.analyser))
        let converted = try #require(DictationAudio.convert(Self.tone(in: Self.microphone), with: converter))
        #expect(Self.peak(converted) > 10_000)
    }
}
#endif
