import AgentsKitCore
import Foundation
import Observation

/// Voice mode (#2322): the person talks to one chat and hears its replies.
///
/// One chat at a time, for the whole app. While it is on, the microphone listens through
/// `Dictation` (on the device). A pause of 2.5 seconds after some words sends them, with
/// `voice` set so the daemon asks for a short spoken reply. Words said while a turn runs
/// are sent the same way, and wait on the chat's queue (#95). When the turn ends, its reply
/// (`TurnParts.replyText`, never the thoughts or the steps) is cleaned by `Speakable` and
/// spoken in the Paradee voice, with the microphone closed, so the voice does not hear
/// itself. Then it listens again.
@MainActor
@Observable
final class VoiceMode {
    static let shared = VoiceMode()

    enum Phase: Equatable {
        case off
        /// The voice is loading: the first time after launch, about half a second.
        case loading
        case listening
        /// Words went to the host, which has not taken them yet.
        case sending
        case speaking
    }

    /// The chat that voice mode is on in.
    private(set) var agentID: UUID?
    private(set) var phase: Phase = .off
    /// The words heard for the next prompt.
    private(set) var heard = ""
    /// The sentence being spoken now.
    private(set) var saying: String?
    /// Whether a prompt went and its turn has not ended yet.
    private(set) var isWaitingForReply = false
    private(set) var problem: String?
    /// The sentences said lately, newest last: what a walk reads back.
    private(set) var said: [String] = []
    /// Set by a walk (`VoiceWalk`): no microphone and no sound.
    var isWalked = false {
        didSet { speaker.isMuted = isWalked }
    }

    /// How long a pause is before the words go (#1792: speech within 2.5 s joins them).
    static let pause: Duration = .milliseconds(2_500)

    @ObservationIgnored let dictation = Dictation()
    @ObservationIgnored private let voice: ParadeeVoice
    @ObservationIgnored private let speaker: VoiceSpeaker
    private var send: ((String) async -> Bool)?
    private var vocabulary: [String] = []
    private var pauseTimer: Task<Void, Never>?
    private var speaking: Task<Void, Never>?
    /// The last turn when the latest words went, and whether the agent was seen working
    /// since: a turn has ended only once both have moved on.
    private var turnAtSend: UUID?
    private var sawWork = false
    /// The turn last spoken, so a reply is said once.
    private var spokenTurn: UUID?
    /// The chat's last turn, as last seen.
    private var latestTurn: UUID?
    /// Set when voice mode turns on, until the chat is first seen.
    private var needsBaseline = false

    private init() {
        let voice = ParadeeVoice()
        self.voice = voice
        speaker = VoiceSpeaker(voice: voice)
    }

    func isOn(in agentID: UUID) -> Bool { self.agentID == agentID && phase != .off }

    /// Turns voice mode on in a chat. `send` sends words to it as a voice prompt, and says
    /// whether the host took them.
    func turnOn(in agentID: UUID, vocabulary: [String] = [], send: @escaping (String) async -> Bool) {
        if self.agentID != nil { turnOff() }
        self.agentID = agentID
        self.send = send
        self.vocabulary = vocabulary
        problem = nil
        heard = ""
        isWaitingForReply = false
        // What was said before voice mode is not read out: the chat's last turn is taken
        // as spoken when it is first seen.
        needsBaseline = true
        phase = .loading
        Task {
            do {
                try await voice.load()
            } catch {
                guard self.agentID == agentID else { return }
                fail("The voice would not load: \(error.localizedDescription)")
                return
            }
            guard self.agentID == agentID, phase == .loading else { return }
            listen()
        }
    }

    /// Turns voice mode off: the microphone closes, the voice stops and is let go.
    func turnOff() {
        pauseTimer?.cancel()
        speaking?.cancel()
        speaker.stop()
        dictation.stop()
        agentID = nil
        send = nil
        phase = .off
        heard = ""
        saying = nil
        isWaitingForReply = false
        Task { await voice.unload() }
    }

    /// Stop: the voice stops at once, and it listens again. What was not said stays on
    /// the screen.
    func stopSpeaking() {
        guard phase == .speaking else { return }
        speaking?.cancel()
        speaker.stop()
        saying = nil
        listen()
    }

    func dismissProblem() { problem = nil }

    /// What the chat shows now. The chat calls this as its agent and items change.
    func observe(_ agent: Agent, items: [TranscriptItem]) {
        guard agent.id == agentID, phase != .off else { return }
        if agent.state == .archived {
            turnOff()
            return
        }
        let last = items.turns().last
        latestTurn = last?.id
        if needsBaseline {
            needsBaseline = false
            spokenTurn = last?.id
        }
        guard isWaitingForReply else { return }
        let working = agent.state == .running || agent.state == .starting || agent.state == .queued
        if working {
            sawWork = true
            return
        }
        guard let turn = last, turn.id != spokenTurn else { return }
        let parts = TurnParts(turn.items, isLive: false)
        // Ended: seen working since the send, or a new turn that already has its reply.
        guard sawWork || (turn.id != turnAtSend && !parts.replyText.isEmpty) else { return }
        spokenTurn = turn.id
        isWaitingForReply = false
        sawWork = false
        let asks = agent.state == .waitingOnUser
        let sentences = Speakable.spoken(parts.replyText)
        if asks { sound(.question) }
        guard !sentences.isEmpty else { return }
        // Mid-sentence, the person goes first: the reply is said once their words have gone.
        if !heard.isEmpty { pendingReply = sentences; return }
        speak(sentences)
    }

    /// A reply held while the person was still talking.
    private var pendingReply: [String]?

    // MARK: Listening

    private func listen() {
        guard agentID != nil else { return }
        heard = ""
        phase = .listening
        guard !isWalked else { return }
        sound(.listening)
        dictation.start(in: "", selection: nil, vocabulary: vocabulary) { [weak self] text, _ in
            self?.heardChanged(text)
        }
        watchDictation()
    }

    /// Words as if heard, for a walk: they go after the pause, as spoken ones do.
    func walkHeard(_ words: String) {
        guard phase == .listening else { return }
        heardChanged(words)
    }

    /// Dictation says its problems itself, and stops; voice mode stops with it.
    private func watchDictation() {
        withObservationTracking {
            _ = dictation.problem
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.phase != .off else { return }
                if let message = self.dictation.problem?.message {
                    self.dictation.dismissProblem()
                    self.fail(message)
                } else {
                    self.watchDictation()
                }
            }
        }
    }

    private func heardChanged(_ text: String) {
        heard = text
        pauseTimer?.cancel()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        pauseTimer = Task { [weak self] in
            try? await Task.sleep(for: Self.pause)
            guard !Task.isCancelled else { return }
            await self?.sendHeard()
        }
    }

    private func sendHeard() async {
        let words = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        guard phase == .listening, !words.isEmpty, let send else { return }
        dictation.stop()
        phase = .sending
        let agent = agentID
        let took = await send(words)
        guard agentID == agent, phase == .sending else { return }
        if took {
            sound(.sent)
            isWaitingForReply = true
            sawWork = false
            turnAtSend = latestTurn
        } else {
            sound(.problem)
        }
        if let reply = pendingReply {
            pendingReply = nil
            speak(reply)
        } else {
            listen()
        }
    }

    // MARK: Speaking

    private func speak(_ sentences: [String]) {
        pauseTimer?.cancel()
        dictation.stop()
        phase = .speaking
        speaking = Task { [weak self] in
            guard let self else { return }
            do {
                try await speaker.say(sentences) { sentence in
                    self.saying = sentence
                    self.said = Array((self.said + [sentence]).suffix(20))
                }
            } catch {
                if !Task.isCancelled { fail("The voice could not speak: \(error.localizedDescription)") }
                return
            }
            guard !Task.isCancelled, phase == .speaking else { return }
            saying = nil
            listen()
        }
    }

    /// A sound, but none in a walk.
    private func sound(_ sound: VoiceSound) {
        if !isWalked { sound.play() }
    }

    private func fail(_ message: String) {
        sound(.problem)
        turnOff()
        problem = message
    }
}
