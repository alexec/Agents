#if canImport(AVFoundation)
@preconcurrency import AVFoundation

/// The microphone's audio while no speech analyser takes it: between two runs of voice
/// mode's dictation, and before the first one is ready (#3563).
///
/// Each run of dictation starts a new analyser, which takes up to a second or more to be
/// ready on a phone. Before, the microphone heard nothing in that time, so the first words
/// said after the voice stopped, or after a prompt went, were lost. The audio is now kept
/// here and given to the next analyser first, so it hears every word, in order.
///
/// Bounded: no more than `limit` seconds are kept, the newest. A hold is a second or two;
/// a longer one (the speech model downloads the first time) keeps the end of it.
public struct HeldAudio {
    public let limit: Double
    public private(set) var buffers: [AVAudioPCMBuffer] = []

    public init(limit: Double) { self.limit = limit }

    /// The seconds of audio kept.
    public var seconds: Double {
        buffers.reduce(0) { $0 + Double($1.frameLength) / $1.format.sampleRate }
    }

    /// Keeps a copy of `buffer`: the tap can use its own buffer again once it returns.
    /// The oldest go when more than `limit` is kept.
    public mutating func append(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0, let copy = Self.copy(buffer) else { return }
        buffers.append(copy)
        var total = seconds
        while total > limit, let first = buffers.first {
            total -= Double(first.frameLength) / first.format.sampleRate
            buffers.removeFirst()
        }
    }

    /// Everything kept, oldest first, and nothing kept after.
    public mutating func take() -> [AVAudioPCMBuffer] {
        defer { buffers = [] }
        return buffers
    }

    public mutating func removeAll() { buffers = [] }

    static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
            return nil
        }
        copy.frameLength = buffer.frameLength
        let from = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let to = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard from.count == to.count else { return nil }
        for (source, target) in zip(from, to) {
            guard let data = source.mData, let into = target.mData else { return nil }
            memcpy(into, data, Int(min(source.mDataByteSize, target.mDataByteSize)))
        }
        return copy
    }
}
#endif
