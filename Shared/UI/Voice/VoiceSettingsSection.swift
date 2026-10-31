@preconcurrency import AVFoundation
import FluidAudio
import SwiftUI

/// Whether this device has voice mode (#2322). On at first since Alex looked for its button
/// and found none (2026-10-29): on, the chat has the button, and nothing loads and no
/// microphone opens until it is pressed. Kept on this device only, as Show thoughts is
/// (#1725). Off, the chat has no voice button and no voice is loaded.
enum VoiceSettings {
    static let onKey = "voiceMode"
    static let onAtFirst = true

    // How it speaks and sounds, to try options out (Alex, 2026-10-29). On this device only.

    /// Kokoro's voice pack, each inside the app.
    static let voiceKey = "voiceMode.voice"
    static let voiceAtFirst = "af_heart"
    /// The English voices, American and British: the other packs speak English with an accent.
    static let voices = KokoroAneConstants.englishVoices.filter { ["af_", "am_", "bf_", "bm_"].contains(String($0.prefix(3))) }

    /// Kokoro's pace, 1 its own. A little faster at first (Alex, 2026-10-29).
    static let speedKey = "voiceMode.speed"
    static let speedAtFirst = 1.15

    /// Silence left between sentences, once each sentence's own silence is cut off.
    static let gapKey = "voiceMode.gapMilliseconds"
    static let gapAtFirst = 150.0

    /// How long a pause is before the words heard go: 2 s since #2375.
    static let waitKey = "voiceMode.waitSeconds"
    static let waitAtFirst = 2.0

    /// How often the working sound plays.
    static let workingEveryKey = "voiceMode.workingEverySeconds"
    static let workingEveryAtFirst = 3.0

    /// Every sound this Mac has in /System/Library/Sounds.
    static let sounds = ["Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero", "Morse",
                         "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink"]
    /// The name kept for a sound that plays nothing.
    static let noSound = ""

    @MainActor static func soundKey(_ sound: VoiceSound) -> String { "voiceMode.sound.\(sound)" }

    static var voice: String { WindowDefaults.store.string(forKey: voiceKey) ?? voiceAtFirst }
    static var speed: Double { number(speedKey) ?? speedAtFirst }
    static var gap: Double { number(gapKey) ?? gapAtFirst }
    static var wait: Double { number(waitKey) ?? waitAtFirst }
    static var workingEvery: Double { number(workingEveryKey) ?? workingEveryAtFirst }
    @MainActor static func soundName(_ sound: VoiceSound) -> String {
        WindowDefaults.store.string(forKey: soundKey(sound)) ?? sound.soundAtFirst
    }

    private static func number(_ key: String) -> Double? {
        WindowDefaults.store.object(forKey: key) == nil ? nil : WindowDefaults.store.double(forKey: key)
    }
}

/// The Voice mode switch, in Settings on the Mac and the Remote.
struct VoiceSettingsSection: View {
    /// The Remote's Settings page has no title of its own for it, so the section says it.
    var header: String? = nil
    @AppStorage(VoiceSettings.onKey, store: WindowDefaults.store) private var isOn = VoiceSettings.onAtFirst

    var body: some View {
        Section {
            Toggle("Voice mode", isOn: $isOn)
        } header: {
            if let header { Text(header) }
        } footer: {
            Text(footer)
                .appText(.fine)
                .foregroundStyle(.secondary)
        }
        .paperListRow()
        .onChange(of: isOn) { _, on in
            if !on { VoiceMode.shared.turnOff() }
        }
        if isOn { VoiceTuningSections() }
    }

    /// Only iOS ends voice mode in the background or on a call (`VoiceModeControls`,
    /// `VoiceMode`), so the Mac says only that leaving the chat ends it (#2898).
    private var footer: String {
        #if os(iOS)
        let ends = "Voice mode ends when you leave the chat, or the app goes to the background or is interrupted by a call."
        #else
        let ends = "Voice mode ends when you leave the chat."
        #endif
        return "On, each chat and New Session has a voice button beside the prompt. Say what you want and hear the reply. The voice runs on this device. \(ends) Off, no voice is loaded."
    }
}

/// The voice, its pace and pauses, and the sounds of voice mode, to try options out
/// (Alex, 2026-10-29). Kept on this device.
private struct VoiceTuningSections: View {
    @AppStorage(VoiceSettings.voiceKey, store: WindowDefaults.store) private var voice = VoiceSettings.voiceAtFirst
    @AppStorage(VoiceSettings.speedKey, store: WindowDefaults.store) private var speed = VoiceSettings.speedAtFirst
    @AppStorage(VoiceSettings.gapKey, store: WindowDefaults.store) private var gap = VoiceSettings.gapAtFirst
    @AppStorage(VoiceSettings.waitKey, store: WindowDefaults.store) private var wait = VoiceSettings.waitAtFirst
    @AppStorage(VoiceSettings.workingEveryKey, store: WindowDefaults.store) private var workingEvery = VoiceSettings.workingEveryAtFirst
    private var sample: VoiceSample { VoiceSample.shared }

    var body: some View {
        Section {
            Picker("Voice", selection: $voice) {
                ForEach(VoiceSettings.voices, id: \.self) { Text(Self.title($0)).tag($0) }
            }
            slider("Speed", value: $speed, in: 0.8...1.6, step: 0.05, shows: String(format: "%.2f×", speed))
            slider("Pause between sentences", value: $gap, in: 0...800, step: 25, shows: "\(Int(gap)) ms")
            // Last, as it plays what the settings above it make (Alex, 2026-10-29).
            #if os(iOS)
            // A plain button row: in a phone's Form, a button in a LabeledContent drew the row
            // far taller than its content (#3028).
            sampleButton
            #else
            LabeledContent("Sample") { sampleButton }
            #endif
            if let problem = sample.problem {
                Text(problem)
                    .appText(.fine)
                    .tinted(.failure)
            }
        } header: {
            Text("How it speaks")
        } footer: {
            Text("Each sentence's own silence is cut off, and the pause is what is left between sentences. The sample plays these settings.")
                .appText(.fine)
                .foregroundStyle(.secondary)
        }
        .paperListRow()
        // Apart from How it speaks, so it is not mixed up with the pause between sentences (#3018).
        Section {
            slider("Wait before your words go", value: $wait, in: 0.8...3.5, step: 0.1, shows: String(format: "%.1f s", wait))
        } header: {
            Text("How it listens")
        } footer: {
            Text("How long you stay quiet before what you said is sent.")
                .appText(.fine)
                .foregroundStyle(.secondary)
        }
        .paperListRow()
        #if os(macOS)
        Section {
            ForEach(VoiceSound.allCases, id: \.self) { sound in
                SoundPicker(sound: sound)
            }
            slider("Working sound every", value: $workingEvery, in: 1...10, step: 0.5, shows: String(format: "%.1f s", workingEvery))
        } header: {
            Text("Voice mode sounds")
        } footer: {
            Text("Each sound plays when you choose it.")
                .appText(.fine)
                .foregroundStyle(.secondary)
        }
        .paperListRow()
        #endif
    }

    private var sampleButton: some View {
        Button {
            sample.play()
        } label: {
            if sample.isMaking {
                ProgressView().controlSize(.small)
            } else {
                Label("Play a Sample", systemImage: "play.circle")
            }
        }
        .disabled(sample.isMaking)
        .help("Hear this voice at this speed, with this pause between sentences")
    }

    private func slider(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>, step: Double,
                        shows: String) -> some View {
        #if os(iOS)
        // The slider under its words: a phone's row is too narrow for both.
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text(shows)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: step)
        }
        #else
        LabeledContent(title) {
            HStack {
                Slider(value: value, in: range, step: step)
                Text(shows)
                    .monospacedDigit()
                    .frame(minWidth: 56, alignment: .trailing)
            }
        }
        #endif
    }

    /// "af_heart": "Heart (American woman)".
    static func title(_ id: String) -> String {
        let parts = id.split(separator: "_", maxSplits: 1)
        guard parts.count == 2, let kind = parts.first, kind.count == 2 else { return id }
        let accent = kind.hasPrefix("b") ? "British" : "American"
        let who = kind.hasSuffix("m") ? "man" : "woman"
        return "\(parts[1].capitalized) (\(accent) \(who))"
    }
}

#if os(macOS)
private struct SoundPicker: View {
    let sound: VoiceSound
    @AppStorage private var name: String

    init(sound: VoiceSound) {
        self.sound = sound
        _name = AppStorage(wrappedValue: sound.soundAtFirst, VoiceSettings.soundKey(sound), store: WindowDefaults.store)
    }

    var body: some View {
        HStack {
            Picker(sound.title, selection: $name) {
                Text("None").tag(VoiceSettings.noSound)
                ForEach(VoiceSettings.sounds, id: \.self) { Text($0).tag($0) }
            }
            Button {
                sound.play()
            } label: {
                Image(systemName: "play.circle")
            }
            .buttonStyle(.borderless)
            .disabled(name == VoiceSettings.noSound)
            .help("Play this sound")
            .accessibilityLabel("Play \(sound.title)")
        }
        .onChange(of: name) { sound.play() }
    }
}
#endif

/// Settings' voice sample (Alex, 2026-10-29): a few sentences in the voice, speed and pause
/// chosen, played on this device's own output, so no microphone opens for it.
@MainActor
@Observable
final class VoiceSample {
    static let shared = VoiceSample()

    static let sentences = [
        "Hi, I'm your agent.",
        "I've read the files and the tests pass.",
        "Do you want me to open a pull request?",
    ]

    private(set) var isMaking = false
    private(set) var problem: String?
    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private let player = AVAudioPlayerNode()
    @ObservationIgnored private let format = AVAudioFormat(standardFormatWithSampleRate: KokoroVoice.sampleRate, channels: 1)

    private init() {
        engine.attach(player)
        if let format { try? engine.connectNode(player, to: engine.mainMixerNode, format: format) }
    }

    func play() {
        guard !isMaking, let format else { return }
        isMaking = true
        problem = nil
        player.stop()
        Task {
            defer { isMaking = false }
            do {
                var samples: [Float] = []
                for sentence in Self.sentences { samples += try await VoiceMode.shared.sample(sentence) }
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
                      let channel = buffer.floatChannelData?[0] else { return }
                buffer.frameLength = AVAudioFrameCount(samples.count)
                samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
                if !engine.isRunning { try engine.start() }
                player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { @Sendable _ in }
                try player.playAudio()
            } catch {
                problem = "The sample would not play: \(error.localizedDescription)"
            }
        }
    }
}
