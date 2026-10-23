#if canImport(AVFoundation)
@preconcurrency import AVFoundation

/// The microphone's audio, made into what the speech analyser takes (#2419).
///
/// With voice processing on (voice mode's echo cancellation, #2375), a Mac's input node
/// gives seven discrete channels: the processed microphone in the first, and others. A
/// converter told only "seven to one" has no layout to mix them by, and gives silence, so
/// voice mode heard nothing. The analyser gets the first channel: the microphone itself
/// without voice processing, the processed microphone with it.
public enum DictationAudio {
    /// A converter from what the tap gives to what the analyser takes, or nil when there is none.
    public static func converter(from source: AVAudioFormat, to target: AVAudioFormat) -> AVAudioConverter? {
        guard let converter = AVAudioConverter(from: source, to: target) else { return nil }
        if source.channelCount > target.channelCount {
            converter.channelMap = (0..<Int(target.channelCount)).map { NSNumber(value: $0) }
        }
        return converter
    }

    /// `buffer`, converted by `converter` (made by `converter(from:to:)` for its format).
    /// Nil when nothing came out.
    public static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter) -> AVAudioPCMBuffer? {
        let target = converter.outputFormat
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1
        guard let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        let given = Given()
        var error: NSError?
        let status = converter.convert(to: converted, error: &error) { _, status in
            if given.done {
                status.pointee = .noDataNow
                return nil
            }
            given.done = true
            status.pointee = .haveData
            return buffer
        }
        return status != .error && converted.frameLength > 0 ? converted : nil
    }

    /// Whether the converter has had this buffer yet. It asks until told there is no
    /// more for now, and the same buffer twice would be heard twice.
    private final class Given: @unchecked Sendable { var done = false }
}
#endif
