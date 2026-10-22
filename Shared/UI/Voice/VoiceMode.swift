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

    /// Sends an answer to a form, and says whether it went.
    typealias Answer = (ElicitationRequest, [String: JSONValue]) async -> Bool

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
    /// The reply last spoken and its turn, so a reply is said once.
    private var spoken: (turn: UUID, text: String)?
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
        asking = nil
        confirming?.cancel()
        confirming = nil
        waiting = nil
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
    func observe(_ agent: Agent, items: [TranscriptItem], question: ElicitationRequest? = nil,
                 answer: Answer? = nil) {
        guard agent.id == agentID, phase != .off else { return }
        waiting = question
        if let answer { self.answer = answer }
        // Answered on the screen, or withdrawn: it is not asked any more.
        if let asking, asking.request.id != question?.id {
            self.asking = nil
            confirming?.cancel()
            confirming = nil
        }
        defer { askIfWaiting() }
        if agent.state == .archived {
            turnOff()
            return
        }
        let last = items.turns().last
        latestTurn = last?.id
        if needsBaseline {
            needsBaseline = false
            spoken = last.map { ($0.id, TurnParts($0.items, isLive: false).replyText) }
        }
        guard isWaitingForReply else { return }
        let working = agent.state == .running || agent.state == .starting || agent.state == .queued
        if working {
            sawWork = true
            return
        }
        guard let turn = last else { return }
        let parts = TurnParts(turn.items, isLive: false)
        // A reply not said yet: a new turn, or the same one going on after an answer.
        guard turn.id != spoken?.turn || parts.replyText != spoken?.text else { return }
        // Ended: seen working since the send, or a new turn that already has its reply.
        guard sawWork || (turn.id != turnAtSend && !parts.replyText.isEmpty) else { return }
        spoken = (turn.id, parts.replyText)
        isWaitingForReply = false
        sawWork = false
        // A turn that stops to ask with no form (Grok's way): its reply is the question.
        if agent.state == .waitingOnUser, question == nil { sound(.question) }
        let sentences = Speakable.spoken(parts.replyText)
        guard !sentences.isEmpty else { return }
        // Mid-sentence, the person goes first: the reply is said once their words have gone.
        if !heard.isEmpty { pendingReply = sentences; return }
        speak(sentences)
    }

    /// A reply held while the person was still talking.
    private var pendingReply: [String]?

    // MARK: Questions

    /// The form the agent waits on, as last seen, and how to answer it.
    private var waiting: ElicitationRequest?
    private var answer: Answer?
    /// The question being asked by voice, and how many answers missed.
    private var asking: (request: ElicitationRequest, spoken: SpokenQuestion, misses: Int)?
    /// Questions already read out, so each is read once.
    private var asked: Set<UUID> = []
    /// "Sending: File.", and two seconds to say no.
    private var confirming: Task<Void, Never>?
    private static let confirmFor: Duration = .seconds(2)

    /// Whether a question is being answered by voice: the strip says so.
    var isAsking: Bool { asking != nil }

    /// Reads out a question that waits, once, when nothing else is being said or heard.
    private func askIfWaiting() {
        guard phase == .listening, heard.isEmpty, asking == nil, confirming == nil,
              let question = waiting, !asked.contains(question.id) else { return }
        asked.insert(question.id)
        sound(.question)
        guard let spoken = SpokenQuestion(question) else {
            speak([SpokenQuestion.needsTheScreen])
            return
        }
        asking = (question, spoken, 0)
        speak(spoken.sentences)
    }

    /// The person's words, as the answer to the question being asked.
    private func answerHeard(_ words: String) {
        guard var asking else { return }
        guard let choice = asking.spoken.choice(for: words) else {
            asking.misses += 1
            if asking.misses >= 2 {
                self.asking = nil
                speak(["It stays on the screen."])
            } else {
                self.asking = asking
                speak([SpokenQuestion.notCaught])
            }
            return
        }
        let title = SpokenQuestion.spokenTitle(choice.title)
        speak(["Sending: \(title)."]) { [weak self] in
            self?.confirm(asking.request, property: asking.spoken.property, value: choice.value)
        }
    }

    /// Listens for two seconds for a "no", then sends the answer.
    private func confirm(_ request: ElicitationRequest, property: String, value: String) {
        confirming = Task { [weak self] in
            try? await Task.sleep(for: Self.confirmFor)
            guard let self, !Task.isCancelled else { return }
            confirming = nil
            self.asking = nil
            heard = ""
            pauseTimer?.cancel()
            let sent = await answer?(request, [property: .string(value)]) ?? false
            if sent {
                // The turn goes on, and its reply is said when it ends.
                isWaitingForReply = true
                sawWork = false
                turnAtSend = latestTurn
            } else {
                sound(.problem)
            }
        }
    }

    // MARK: Listening

    private func listen() {
        guard agentID != nil else { return }
        heard = ""
        phase = .listening
        defer { askIfWaiting() }
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
        if confirming != nil, SpokenQuestion.isNo(text) {
            confirming?.cancel()
            confirming = nil
            dictation.stop()
            if let asking { speak(["Not sent."] + asking.spoken.sentences) }
            return
        }
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
        if asking != nil, confirming == nil {
            dictation.stop()
            answerHeard(words)
            return
        }
        // Words while an answer waits to go are not a prompt.
        guard confirming == nil else { return }
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

    private func speak(_ sentences: [String], then: (() -> Void)? = nil) {
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
            then?()
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
