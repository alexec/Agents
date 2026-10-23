import AgentsKitCore
#if os(iOS)
import AVFoundation
#endif
import Foundation
import Observation

/// Voice mode (#2322): the person talks to one chat and hears its replies.
///
/// One chat at a time, for the whole app. While it is on, the microphone listens through
/// `Dictation` (on the device). A pause of 2 seconds after some words sends them, with
/// `voice` set so the daemon asks for a short spoken reply. Words said while a turn runs
/// are sent the same way, and wait on the chat's queue (#95). The reply
/// (`TurnParts.replyText`, never the thoughts or the steps) is cleaned by `Speakable` and
/// spoken in the Paradee voice a sentence at a time, each one as soon as it is written
/// (#2375). The microphone stays open while it speaks, with echo cancellation
/// (`VoiceAudio`), and words said over the voice stop it and are the next prompt.
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
        didSet {
            speaker.isMuted = isWalked
            audio.listens = !isWalked
        }
    }

    /// Sends an answer to a form, and says whether it went.
    typealias Answer = (ElicitationRequest, [String: JSONValue]) async -> Bool

    /// How long a pause is before the words go: 2.5 s at first (#1792), 2 s since Alex
    /// tried it (#2375).
    static let pause: Duration = .milliseconds(2_000)

    @ObservationIgnored let dictation: Dictation
    @ObservationIgnored private let audio: VoiceAudio
    @ObservationIgnored private let voice: ParadeeVoice
    @ObservationIgnored private let speaker: VoiceSpeaker
    /// Sends words as a voice prompt, and says which chat took them: nil when none did.
    /// A new session's starts the chat with them (#2375).
    typealias Send = (String) async -> UUID?
    private var send: Send?
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
    /// When voice mode turned on: a hang_up before it is an old call's.
    private var turnedOnAt = Date.distantPast
    /// The agent hung up (#2375): voice mode ends once the reply has been said.
    private var isHangingUp = false
    /// The turn the person last talked over: the host stops it (#2375), and what it says
    /// after is not read out.
    private var talkedOver: UUID?

    private init() {
        let audio = VoiceAudio()
        let voice = ParadeeVoice()
        self.audio = audio
        self.voice = voice
        dictation = Dictation(shared: audio)
        speaker = VoiceSpeaker(voice: voice, audio: audio)
        #if os(iOS)
        // A call, an alarm or a locked phone takes the audio: voice mode ends (Alex,
        // U20261022-49). A real background mode is for a later spec.
        NotificationCenter.default.addObserver(forName: AVAudioSession.didBecomeInactiveNotification, object: nil,
                                               queue: .main) { _ in
            MainActor.assumeIsolated {
                guard VoiceMode.shared.phase != .off else { return }
                VoiceMode.shared.turnOff()
            }
        }
        #endif
    }

    /// Whether voice mode is on in this chat; nil is a new session, not started yet (#2375).
    func isOn(in agentID: UUID?) -> Bool { self.agentID == agentID && phase != .off }

    /// What the prompt field says while it is empty in voice mode: what it waits for, or
    /// the sentence being said.
    var hint: String {
        switch phase {
        case .off: ""
        case .loading: "Getting the voice ready…"
        case .sending: "Sending…"
        case .speaking: saying ?? "Speaking…"
        case .listening:
            if isAsking { "Say your answer." }
            else if isWaitingForReply { "Working on it. You can say more." }
            else { "Say what you want." }
        }
    }

    /// Turns voice mode on in a chat, or a new session (nil) that its first words start.
    /// `send` sends words to it as a voice prompt, and says
    /// whether the host took them.
    /// `words`: what was said after "Hey Agents" (#2420), the start of the first prompt.
    func turnOn(in agentID: UUID?, vocabulary: [String] = [], words: String = "", send: @escaping Send) {
        if phase != .off { turnOff() }
        self.agentID = agentID
        self.send = send
        self.vocabulary = vocabulary
        problem = nil
        heard = ""
        isWaitingForReply = false
        // What was said before voice mode is not read out: the chat's last turn is taken
        // as spoken when it is first seen.
        needsBaseline = agentID != nil
        turnedOnAt = Date()
        isHangingUp = false
        talkedOver = nil
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
            do {
                try audio.open()
            } catch {
                fail("The microphone and speaker would not start: \(error.localizedDescription)")
                return
            }
            listen(after: words)
        }
    }

    /// Turns voice mode off: the microphone closes, the voice stops and is let go.
    func turnOff() {
        pauseTimer?.cancel()
        speaking?.cancel()
        speaking = nil
        speaker.stop()
        dictation.stop()
        audio.close()
        queue = []
        afterSpeaking = nil
        stream = nil
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

    /// "Hey Agents" was heard (#2420): voice mode, in this chat or a new session (nil), with
    /// `words` said after the phrase as the start of the first prompt. The prompt bar of that
    /// chat takes it (`takeWake`) and turns voice mode on, as its button does.
    struct Wake: Equatable {
        let id = UUID()
        let agentID: UUID?
        let words: String
    }

    private(set) var wake: Wake?

    func wake(in agentID: UUID?, words: String) {
        wake = Wake(agentID: agentID, words: words)
    }

    /// The wake for the prompt bar of this chat, once.
    func takeWake(for agentID: UUID?) -> Wake? {
        guard let wake, wake.agentID == agentID else { return nil }
        self.wake = nil
        return wake
    }

    /// The person left this chat, or the new session (nil), or the app went to the
    /// background: voice mode ends, so no microphone is left open on a chat not in front
    /// (#2388). Not while a new session's first words are starting it: the bar goes as
    /// its chat opens.
    func leave(_ agentID: UUID?) {
        guard isOn(in: agentID), !(agentID == nil && phase == .sending) else { return }
        turnOff()
    }

    /// Stop: the voice stops at once, and it listens again. What was not said stays on
    /// the screen.
    func stopSpeaking() {
        guard phase == .speaking else { return }
        quiet()
        listen()
    }

    /// The voice stops, and what it had still to say is dropped: it is on the screen.
    private func quiet() {
        speaking?.cancel()
        speaking = nil
        speaker.stop()
        queue = []
        afterSpeaking = nil
        saying = nil
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
        defer {
            askIfWaiting()
            hangUpIfSaid()
        }
        if agent.state == .archived {
            turnOff()
            return
        }
        if let hung = agent.voiceHungUpAt, hung > turnedOnAt { isHangingUp = true }
        let last = items.turns().last
        latestTurn = last?.id
        if needsBaseline {
            needsBaseline = false
            spoken = last.map { ($0.id, TurnParts($0.items, isLive: false).replyText) }
        }
        guard isWaitingForReply, let turn = last, turn.id != talkedOver else { return }
        let working = agent.state == .running || agent.state == .starting || agent.state == .queued
        if working { sawWork = true }
        // The reply comes in a new turn, or in this one going on after an answer.
        guard turn.id != turnAtSend || sawWork else { return }
        let parts = TurnParts(turn.items, isLive: working)
        // A reply already said: the last turn, before the new one shows.
        guard turn.id != spoken?.turn || parts.replyText != spoken?.text else { return }
        // Each sentence is said as soon as it is written (#2375).
        guard !working else {
            streamReply(in: turn.id, parts.replyText, isDone: false)
            return
        }
        guard sawWork || !parts.replyText.isEmpty else { return }
        spoken = (turn.id, parts.replyText)
        isWaitingForReply = false
        sawWork = false
        // A turn that stops to ask with no form (Grok's way): its reply is the question.
        if agent.state == .waitingOnUser, question == nil { sound(.question) }
        streamReply(in: turn.id, parts.replyText, isDone: true)
        stream = nil
    }

    /// The sentences of the reply in this turn said so far.
    private var stream: (turn: UUID, said: [String])?

    /// Says what is new in a reply. While the turn goes on, its last sentence may be half
    /// written, so it waits; a long reply says its first sentences and that the rest is on
    /// the screen (`Speakable.spoken`). A reply that is not the one being said (the agent
    /// went on to a step, then wrote again) is said from its start.
    private func streamReply(in turn: UUID, _ text: String, isDone: Bool) {
        let all = Speakable.sentences(text)
        var said = stream?.turn == turn ? stream?.said ?? [] : []
        if !all.starts(with: said) { said = [] }
        let target = isDone ? Speakable.spoken(text)
                            : Array(all.dropLast().prefix(Speakable.longReplySentences))
        let new = Array(target.dropFirst(said.count))
        stream = (turn, said + new)
        guard !new.isEmpty else { return }
        queue += new
        // Mid-sentence, the person goes first: the reply is said once their words have gone.
        if phase == .listening, heard.isEmpty, confirming == nil { startSpeaking() }
    }

    /// Sentences waiting to be said, and what to do once they have been.
    private var queue: [String] = []
    private var afterSpeaking: (() -> Void)?

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

    /// `chime`: the listening sound, which is left out between the sentences of a reply
    /// still being written.
    /// `words`: heard already, before voice mode turned on (#2420); they go after the pause
    /// with what is said next.
    private func listen(chime: Bool = true, after words: String = "") {
        guard phase != .off else { return }
        heard = ""
        phase = .listening
        defer { askIfWaiting() }
        if !words.isEmpty { heardChanged(words) }
        guard !isWalked else { return }
        if chime { sound(.listening) }
        startDictation(after: words)
    }

    /// Dictation afresh, so what was heard before is not in what comes next.
    private func startDictation(after words: String = "") {
        dictation.stop()
        dictation.start(in: words, selection: nil, vocabulary: vocabulary) { [weak self] text, _ in
            self?.heardChanged(text)
        }
        watchDictation()
    }

    /// Words as if heard, for a walk: they go after the pause, as spoken ones do, and
    /// stop the voice when it is speaking.
    func walkHeard(_ words: String) {
        guard phase == .listening || phase == .speaking else { return }
        heardChanged(words)
    }

    /// Whether the microphone stays open while the voice speaks: only when it cannot hear
    /// the voice, and in a walk, which has no microphone.
    private var listensWhileSpeaking: Bool { isWalked || audio.cancelsEcho }

    private var isWatchingDictation = false

    /// Dictation says its problems itself, and stops; voice mode stops with it.
    private func watchDictation() {
        guard !isWatchingDictation else { return }
        isWatchingDictation = true
        withObservationTracking {
            _ = dictation.problem
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.isWatchingDictation = false
                guard self.phase != .off else { return }
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
        // Over the voice: words that mean something stop it, and are the next prompt.
        if phase == .speaking {
            guard isBargeIn(text) else { return }
            quiet()
            phase = .listening
        }
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
        let target = await send(words)
        guard agentID == agent, phase == .sending else { return }
        if let target {
            sound(.sent)
            // A new session's first words started it: voice mode goes on in its chat.
            if agentID == nil {
                agentID = target
                latestTurn = nil
            }
            // Words said while it works stop its turn (the host does it, #2375): the rest
            // of that turn is not read out.
            talkedOver = latestTurn
            isWaitingForReply = true
            sawWork = false
            turnAtSend = latestTurn
        } else {
            sound(.problem)
        }
        if queue.isEmpty {
            listen()
        } else {
            startSpeaking()
        }
    }

    // MARK: Talking over the voice

    /// What is said while the voice speaks that is only listening, not talking.
    private static let backchannel: Set<String> = [
        "mm", "mmm", "hmm", "mhm", "mm-hmm", "uh-huh", "uh", "um", "er", "ah", "oh",
        "yeah", "yep", "yes", "ok", "okay", "right", "sure", "huh", "cool", "nice",
    ]

    /// Whether words heard over the voice are the person talking: two words that are not
    /// backchannel ("mm-hmm", "yeah", a cough heard as "uh"), or one while a question is
    /// read, as "two!". Words the voice is saying now are its own, heard back.
    private func isBargeIn(_ text: String) -> Bool {
        let meant = Self.words(text).filter { !Self.backchannel.contains($0) }
        guard meant.count >= (asking == nil ? 2 : 1) else { return false }
        let own = Set(said.suffix(2).flatMap(Self.words))
        let echoed = meant.filter(own.contains).count
        return Double(echoed) < Double(meant.count) * 0.7
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased()
            .split { !$0.isLetter && !$0.isNumber && $0 != "-" && $0 != "'" }
            .map(String.init)
    }

    // MARK: Speaking

    /// Says `sentences` after what is being said, then does `then`.
    private func speak(_ sentences: [String], then: (() -> Void)? = nil) {
        queue += sentences
        if let then { afterSpeaking = then }
        startSpeaking()
    }

    /// Says what waits in the queue, until it is empty. The microphone listens on for the
    /// person talking over it (`listensWhileSpeaking`), or closes.
    private func startSpeaking() {
        guard phase != .speaking, !queue.isEmpty else { return }
        pauseTimer?.cancel()
        phase = .speaking
        heard = ""
        if !listensWhileSpeaking {
            dictation.stop()
        } else if !isWalked {
            startDictation()
        }
        speaking = Task { [weak self] in
            guard let self else { return }
            do {
                // Sentences that came as the last one ended are said too.
                repeat {
                    try await speaker.say(next: { self.queue.isEmpty ? nil : self.queue.removeFirst() }) { sentence in
                        self.saying = sentence
                        self.said = Array((self.said + [sentence]).suffix(20))
                    }
                } while !Task.isCancelled && phase == .speaking && !queue.isEmpty
            } catch {
                if !Task.isCancelled { fail("The voice could not speak: \(error.localizedDescription)") }
                return
            }
            guard !Task.isCancelled, phase == .speaking else { return }
            speaking = nil
            saying = nil
            let then = afterSpeaking
            afterSpeaking = nil
            listen(chime: !isWaitingForReply && !isHangingUp)
            then?()
            hangUpIfSaid()
        }
    }

    /// Ends voice mode once the agent has hung up and its goodbye has been said.
    private func hangUpIfSaid() {
        guard isHangingUp, !isWaitingForReply, phase == .listening, queue.isEmpty, heard.isEmpty else { return }
        turnOff()
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
