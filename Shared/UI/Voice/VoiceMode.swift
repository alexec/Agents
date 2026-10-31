import Accessibility
import AgentsKitCore
#if os(iOS)
import AVFoundation
#endif
import Foundation
import Observation

/// Voice mode (#2322): the person talks to one chat and hears its replies.
///
/// One chat at a time, for the whole app. While it is on, the microphone listens through
/// `Dictation` (`SpeechTranscriber`, on the device, #2515). A pause of 2 seconds after some words sends them, with
/// `voice` set so the daemon asks for a short spoken reply. Words said while a turn runs
/// are sent the same way, and wait on the chat's queue (#95). The reply
/// (`TurnParts.replyText`, never the thoughts or the steps) is cleaned by `Speakable` and
/// spoken in the Kokoro voice a sentence at a time, each one as soon as it is written
/// (#2375). The microphone stays open while it speaks, with echo cancellation
/// (`VoiceAudio`), and words said over the voice stop it and are the next prompt. Enter
/// sends the words heard so far at once (#2519).
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
    /// The switch that would fix `problem`, when one would: its alert opens it (#2444).
    private(set) var problemPermission: Dictation.Permission?
    /// The words of a prompt the host did not take: the strip keeps them until the next
    /// words are heard (#2441).
    private(set) var unsent: String?
    /// The sentences said lately, newest last: what a walk reads back.
    private(set) var said: [String] = []
    /// Set by a walk (`VoiceWalk`): no microphone and no sound.
    var isWalked = false {
        didSet {
            speaker.isMuted = isWalked
            audio.listens = !isWalked
            armTick()
        }
    }
    /// Set by a walk: the next prompt does not go, as when the host is away.
    var walkSendFails = false
    /// Set by a walk: as if VoiceOver were on (#2446).
    var walkVoiceOver = false
    /// What was last told to VoiceOver, and when: heard back through the microphone, it
    /// is not a prompt (#2446).
    private var announced: (text: String, at: Date)?
    /// What was told to VoiceOver lately, newest last: what a walk reads back.
    private(set) var announcements: [String] = []

    /// Tells VoiceOver what the strip says: only the strip says it, as the voice and the
    /// sounds say the rest (#2446).
    func announce(_ text: String) {
        // Once, not after each reply: "Say what you want." again is noise.
        guard !text.isEmpty, text != announcements.last else { return }
        announced = (text, Date())
        announcements = Array((announcements + [text]).suffix(20))
        AccessibilityNotification.Announcement(text).post()
    }

    /// Sends an answer to a form, and says whether it went.
    typealias Answer = (ElicitationRequest, [String: JSONValue]) async -> Bool
    /// Answers a permission request with one of its options, and says whether it went (#2358).
    typealias Approve = (PermissionRequest, String) async -> Bool

    /// How long a pause is before the words go: 2.5 s at first (#1792), 2 s since Alex
    /// tried it (#2375).
    /// Settings ▸ Voice can make it longer or shorter (Alex, 2026-10-29).
    static var pause: Duration { .milliseconds(Int(VoiceSettings.wait * 1000)) }

    /// How often a tick says it is still listening, while nothing is heard (#2520).
    static let tickEvery: Duration = .seconds(8)
    /// How often the working sound plays while the agent works and nothing is said.
    static var workingEvery: Duration { .milliseconds(Int(VoiceSettings.workingEvery * 1000)) }

    @ObservationIgnored let dictation: Dictation
    @ObservationIgnored private let audio: VoiceAudio
    @ObservationIgnored private let voice: KokoroVoice
    @ObservationIgnored private let speaker: VoiceSpeaker
    /// Sends words as a voice prompt, and says which chat took them: nil when none did.
    /// A new session's starts the chat with them (#2375).
    typealias Send = (String, UUID?) async -> UUID?
    private var send: Send?
    private var vocabulary: [String] = []
    private var pauseTimer: Task<Void, Never>?
    /// The next quiet tick (#2520). Nil while one should not play.
    private var tickTask: Task<Void, Never>?
    /// Lets the voice go a minute after Settings' sample while voice mode is off (#2880).
    private var sampleUnload: Task<Void, Never>?
    private static let sampleKeptFor: Duration = .seconds(60)
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
    /// A quick second phrase can join the prompt before the agent adds to its transcript.
    private var joinTarget: UUID?
    private var joinFirstText: String?
    private var joinText: String?
    /// When voice mode last opened the audio, so late word of an older session is not an end.
    private(set) var audioOpenedAt: ContinuousClock.Instant?
    private var joinStarted = false
    private var joinDeadline: ContinuousClock.Instant?
    private var joinBaselineItemIDs: Set<UUID> = []
    private var observedItemIDs: Set<UUID> = []
    private var observedAgentResponseIDs: Set<UUID> = []
    private static let joinFor: Duration = .milliseconds(2_500)

    private init() {
        let audio = VoiceAudio()
        let voice = KokoroVoice()
        self.audio = audio
        self.voice = voice
        #if os(macOS)
        // Mac voice mode favors fast, live words over the newer model's lower word error
        // rate. Its vocabulary is still supplied by the prompt bar (#2575).
        dictation = Dictation(shared: audio, model: .systemDictation)
        #else
        dictation = Dictation(shared: audio)
        #endif
        speaker = VoiceSpeaker(voice: voice, audio: audio)
        #if os(iOS)
        // A call, an alarm or a locked phone takes the audio: voice mode ends (Alex,
        // U20261022-49). A real background mode is for a later spec.
        NotificationCenter.default.addObserver(forName: AVAudioSession.didBecomeInactiveNotification, object: nil,
                                               queue: .main) { _ in
            MainActor.assumeIsolated {
                guard VoiceMode.shared.phase != .off else { return }
                // Late word of a session given back just before (Dictate's, or the last
                // voice mode's) comes as voice mode opens it again: not a call (Alex's iPad,
                // 2026-10-29, once it listened at once).
                if let opened = VoiceMode.shared.audioOpenedAt, ContinuousClock.now - opened < .seconds(1) {
                    note("voice: the audio session went inactive just after it opened: kept on")
                    return
                }
                note("voice: the audio session went inactive in \(VoiceMode.shared.phase): off")
                VoiceMode.shared.turnOff()
            }
        }
        #endif
    }

    /// Whether voice mode is on in any chat: Dictate is off meanwhile, so two do not
    /// listen at once (#2445).
    var isOn: Bool { phase != .off }

    /// Whether voice mode is on in this chat; nil is a new session, not started yet (#2375).
    func isOn(in agentID: UUID?) -> Bool { self.agentID == agentID && phase != .off }

    /// What the prompt field says while it is empty in voice mode: what it waits for, or
    /// the sentence being said.
    var hint: String {
        switch phase {
        case .off: ""
        case .loading: "Getting the voice ready…"
        case .sending: "Sending…"
        case .speaking:
            if let unsent, saying == VoiceModeWords.notSent { VoiceModeWords.unsent(unsent) }
            else { saying ?? "Speaking…" }
        case .listening:
            if let confirmLine { confirmLine }
            else if isAsking { "Say your answer." }
            else if let unsent { VoiceModeWords.unsent(unsent) }
            else if isWaitingForReply { "Working on it. You can say more." }
            else { "Say what you want." }
        }
    }

    /// Turns voice mode on in a chat, or a new session (nil) that its first words start.
    /// `send` sends words to it as a voice prompt, and says
    /// whether the host took them.
    func turnOn(in agentID: UUID?, vocabulary: [String] = [], send: @escaping Send) {
        if phase != .off { turnOff() }
        sampleUnload?.cancel()
        sampleUnload = nil
        self.agentID = agentID
        self.send = send
        self.vocabulary = vocabulary
        dismissProblem()
        heard = ""
        unsent = nil
        isWaitingForReply = false
        // What was said before voice mode is not read out: the chat's last turn is taken
        // as spoken when it is first seen.
        needsBaseline = agentID != nil
        turnedOnAt = Date()
        isHangingUp = false
        talkedOver = nil
        clearJoin()
        phase = .loading
        note("voice: on")
        // Listening at once, and the voice loads while the person speaks: it is needed only
        // for the reply (Alex, 2026-10-29). A sentence said before it is ready waits for it.
        Task {
            guard self.agentID == agentID, phase == .loading else { return }
            do {
                try await audio.open()
                // Turned off, or on elsewhere, while a set-up ahead was waited for.
                guard self.agentID == agentID, phase == .loading else {
                    if phase == .off { audio.close() }
                    return
                }
                audioOpenedAt = .now
                note("voice: audio open, \(audio.route)")
            } catch {
                note("voice: audio would not open: \(error)")
                fail("The microphone and speaker would not start: \(error.localizedDescription)")
                return
            }
            listen()
        }
        Task {
            do {
                try await voice.load()
                note("voice: the voice is ready")
            } catch {
                guard self.agentID == agentID, phase != .off else { return }
                note("voice: the voice would not load: \(error)")
                fail("The voice would not load: \(error.localizedDescription)")
            }
        }
    }

    /// Readies the microphone's echo cancellation while voice mode is off, so a press listens
    /// at once. Opens no microphone.
    func prepare() {
        guard phase == .off, !isWalked else { return }
        audio.prepare()
    }

    /// Turns voice mode off: the microphone closes, the voice stops and is let go.
    /// A short falling sound says it stopped (#2520).
    func turnOff() {
        let wasOn = phase != .off
        pauseTimer?.cancel()
        tickTask?.cancel()
        tickTask = nil
        speaking?.cancel()
        speaking = nil
        speaker.stop()
        dictation.stop()
        audio.close()
        queue = []
        afterSpeaking = nil
        stream = nil
        clearJoin()
        agentID = nil
        send = nil
        phase = .off
        heard = ""
        unsent = nil
        saying = nil
        isWaitingForReply = false
        asking = nil
        questionReplay?.cancel()
        questionReplay = nil
        confirming?.cancel()
        confirming = nil
        pendingConfirm = nil
        confirmLine = nil
        waiting = nil
        approving = nil
        permission = nil
        stillWorking?.cancel()
        stillWorking = nil
        // dictation.stop() can call back and arm a tick before the phase is off.
        tickTask?.cancel()
        tickTask = nil
        pauseTimer?.cancel()
        if wasOn {
            note("voice: off")
            sound(.ended)
        }
        Task { await voice.unload() }
    }

    /// A sentence in the voice Settings has now, for Settings' sample (Alex, 2026-10-29):
    /// the same voice, so no second copy of the model and no two runs at once.
    /// With voice mode off, the voice is let go a minute after the last sample, so one
    /// press of Play does not keep the model in memory (#2880).
    func sample(_ sentence: String) async throws -> [Float] {
        sampleUnload?.cancel()
        sampleUnload = nil
        defer { unloadAfterSample() }
        return try await voice.audio(for: sentence)
    }

    private func unloadAfterSample() {
        guard phase == .off else { return }
        sampleUnload?.cancel()
        sampleUnload = Task { [voice] in
            try? await Task.sleep(for: Self.sampleKeptFor)
            guard !Task.isCancelled, phase == .off else { return }
            note("voice: let go after the sample")
            await voice.unload()
        }
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

    func dismissProblem() {
        problem = nil
        problemPermission = nil
    }

    /// What the chat shows now. The chat calls this as its agent and items change.
    func observe(_ agent: Agent, items: [TranscriptItem], question: ElicitationRequest? = nil,
                 answer: Answer? = nil, permission: PermissionRequest? = nil, approve: Approve? = nil) {
        guard agent.id == agentID, phase != .off else { return }
        waiting = question
        if let answer { self.answer = answer }
        self.permission = permission
        if let approve { self.approve = approve }
        who = PoolWords.runtimeName(agent.runtimeID)
        worktree = agent.worktree == nil ? nil : agent.cwd
        // Answered on the screen, or withdrawn: it is not asked any more.
        if let asking, asking.request.id != question?.id {
            self.asking = nil
            questionReplay?.cancel()
            questionReplay = nil
            confirming?.cancel()
            confirming = nil
            confirmLine = nil
        }
        if let approving, approving.request.id != permission?.id {
            self.approving = nil
            confirming?.cancel()
            confirming = nil
            confirmLine = nil
        }
        step = items.turns().last.flatMap { Self.step(in: $0.items) }
        defer {
            armTick()
            askIfWaiting()
            hangUpIfSaid()
        }
        if agent.state == .archived {
            turnOff()
            return
        }
        if let hung = agent.voiceHungUpAt, hung > turnedOnAt { isHangingUp = true }
        let last = items.turns().last
        if joinTarget != nil {
            let responseStarted = items.contains { item in
                !joinBaselineItemIDs.contains(item.id)
                    && Self.isAgentResponse(item)
            }
            if responseStarted { clearJoin() }
        }
        observedItemIDs = Set(items.map(\.id))
        observedAgentResponseIDs = Set(items.filter(Self.isAgentResponse).map(\.id))
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
        if agent.state == .waitingOnUser, question == nil, permission == nil { sound(.question) }
        streamReply(in: turn.id, parts.replyText, isDone: true)
        stream = nil
    }

    /// The sentences of the reply in this turn said so far.
    private var stream: (turn: UUID, said: [String])?

    /// Says what is new in a reply. While the turn goes on, its last sentence may be half
    /// written, so it waits; a reply still being written speaks only a few sentences until
    /// it ends, then `Speakable.spoken` supplies every sentence (#2534). A reply that is
    /// not the one being said (the agent
    /// went on to a step, then wrote again) is said from its start.
    private func streamReply(in turn: UUID, _ text: String, isDone: Bool) {
        // No more are said while it is written than the first three, and one more shows
        // the third is whole: the rest of a long reply is not cleaned (#2429).
        let all = Speakable.sentences(text, limit: Speakable.longReplySentences + 1)
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
    /// A question is repeated once after eight seconds of silence (#2358).
    private var questionReplay: Task<Void, Never>?
    private var replayedQuestions: Set<UUID> = []
    private static let questionRepeatAfter: Duration = .seconds(8)
    /// "Sending: File.", and two seconds to say no.
    private var confirming: Task<Void, Never>?
    /// The answer to send when the confirm wait ends, or Enter ends it early (#2519).
    private var pendingConfirm: (() async -> Bool)?
    /// What the strip says while an answer waits for a "no": "Sending File. Say no to
    /// stop." (#2443). Set while it waits, with Don't Send beside it.
    private(set) var confirmLine: String?
    private static let confirmFor: Duration = .seconds(2)

    /// Whether a question or a permission is being answered by voice: the strip says so.
    var isAsking: Bool { asking != nil || approving != nil }

    // MARK: Permissions and plans (#2358)

    /// The permission the agent waits on, as last seen, and how to answer it.
    private var permission: PermissionRequest?
    private var approve: Approve?
    /// The permission being asked by voice, and how many answers missed.
    private var approving: (request: PermissionRequest, spoken: SpokenPermission, misses: Int)?
    /// The runtime's name, as "Claude", and the agent's worktree, when it has one.
    private var who = "The agent"
    private var worktree: URL?

    /// Reads out a permission that waits, once: answerable by voice when low risk, else
    /// "This one needs your screen."
    private func askPermissionIfWaiting() {
        guard let request = permission, !asked.contains(request.id) else { return }
        asked.insert(request.id)
        sound(.question)
        let spoken = SpokenPermission(request, who: who, worktree: worktree)
        if spoken.isAnswerable { approving = (request, spoken, 0) }
        speak(spoken.sentences)
    }

    /// The person's words, as the answer to the permission being asked. Allowing waits two
    /// seconds for a "no", as an answer to a question does; refusing goes at once.
    private func approveHeard(_ words: String) {
        guard var approving else { return }
        guard let answer = approving.spoken.answer(for: words) else {
            approving.misses += 1
            if approving.misses >= 2 {
                self.approving = nil
                speak(["It stays on the screen."])
            } else {
                self.approving = approving
                speak([SpokenPermission.notCaught])
            }
            return
        }
        let request = approving.request
        switch answer {
        case .allow(let optionID):
            let doing = approving.spoken.isPlan ? "Approving the plan" : "Allowing it once"
            speak([doing + "."]) { [weak self] in
                self?.confirm(doing) { [weak self] in await self?.approve?(request, optionID) ?? false }
            }
        case .reject(let optionID):
            self.approving = nil
            speak(["Not allowed."])
            Task { [weak self] in
                if await self?.approve?(request, optionID) != true { self?.answerDidNotGo() }
            }
        }
    }

    // MARK: Still working (#2358)

    /// The current step of the turn: its last tool call still going, in the chat's words.
    private var step: String?
    /// The steps already said, in this turn: each is said once.
    private var saidSteps: Set<String> = []
    private var stillWorking: Task<Void, Never>?

    private static func step(in items: [TranscriptItem]) -> String? {
        for item in items.reversed() {
            guard case .toolRun(_, let calls) = item, let call = calls.last(where: { !$0.isTheApps }) else { continue }
            return call.isUnderway ? call.line : nil
        }
        return nil
    }

    /// After `StillWorking.after` of nothing said or heard while a turn runs, says what
    /// it is doing: "Still working. Running the tests." Once a step.
    private func armStillWorking() {
        stillWorking?.cancel()
        guard isWaitingForReply else { return }
        stillWorking = Task { [weak self] in
            try? await Task.sleep(for: StillWorking.after)
            guard !Task.isCancelled, let self, self.isWaitingForReply, self.phase == .listening,
                  self.heard.isEmpty, !self.isAsking, self.confirming == nil else { return }
            let key = self.step ?? ""
            guard self.saidSteps.insert(key).inserted else { return }
            self.speak([StillWorking.line(step: self.step)])
        }
    }

    /// Reads out a question that waits, once, when nothing else is being said or heard.
    private func askIfWaiting() {
        guard phase == .listening, heard.isEmpty, !isAsking, confirming == nil else { return }
        guard let question = waiting, !asked.contains(question.id) else {
            askPermissionIfWaiting()
            return
        }
        asked.insert(question.id)
        sound(.question)
        guard let spoken = SpokenQuestion(question) else {
            speak([SpokenQuestion.needsTheScreen])
            return
        }
        asking = (question, spoken, 0)
        speak(spoken.sentences) { [weak self] in self?.armQuestionReplay(for: question.id) }
    }

    /// Repeats an unanswered question once, eight seconds after its first reading ends.
    private func armQuestionReplay(for id: UUID) {
        questionReplay?.cancel()
        guard !replayedQuestions.contains(id) else { return }
        questionReplay = Task { [weak self] in
            try? await Task.sleep(for: Self.questionRepeatAfter)
            guard !Task.isCancelled, let self,
                  self.phase == .listening, self.heard.isEmpty, self.confirming == nil,
                  self.asking?.request.id == id, self.waiting?.id == id,
                  self.replayedQuestions.insert(id).inserted else { return }
            self.questionReplay = nil
            self.sound(.question)
            self.speak(self.asking?.spoken.sentences ?? [])
        }
    }

    private func clearJoin() {
        joinTarget = nil
        joinFirstText = nil
        joinText = nil
        joinStarted = false
        joinDeadline = nil
        joinBaselineItemIDs = []
    }

    private static func isAgentResponse(_ item: TranscriptItem) -> Bool {
        return switch item {
        case .toolRun:
            true
        case .entry(let entry):
            switch entry.kind {
            case .agentMessage, .agentThought, .toolCall, .toolCallUpdate: true
            default: false
            }
        }
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
                let id = asking.request.id
                speak([SpokenQuestion.notCaught]) { [weak self] in self?.armQuestionReplay(for: id) }
            }
            return
        }
        let title = SpokenQuestion.spokenTitle(choice.title)
        let (request, property) = (asking.request, asking.spoken.property)
        speak(["Sending: \(title)."]) { [weak self] in
            self?.confirm("Sending \(title)") { [weak self] in
                await self?.answer?(request, [property: .string(choice.value)]) ?? false
            }
        }
    }

    /// Listens for two seconds for a "no", then sends the answer. `doing` is what the
    /// strip says meanwhile, as "Sending File".
    private func confirm(_ doing: String, _ send: @escaping () async -> Bool) {
        confirmLine = VoiceModeWords.sayNoToStop(doing)
        pendingConfirm = send
        armTick()
        confirming = Task { [weak self] in
            try? await Task.sleep(for: Self.confirmFor)
            guard let self, !Task.isCancelled else { return }
            await self.finishConfirm()
        }
    }

    /// The confirm wait ended, or Enter cut it short (#2519).
    private func finishConfirm() async {
        let send = pendingConfirm
        guard let send, phase != .off else {
            pendingConfirm = nil
            return
        }
        pendingConfirm = nil
        confirming?.cancel()
        confirming = nil
        confirmLine = nil
        asking = nil
        approving = nil
        heard = ""
        pauseTimer?.cancel()
        pauseTimer = nil
        let sent = walkSendFails ? false : await send()
        guard phase != .off else { return }
        if sent {
            // The turn goes on, and its reply is said when it ends.
            isWaitingForReply = true
            sawWork = false
            turnAtSend = latestTurn
        } else {
            answerDidNotGo()
        }
        armTick()
    }

    /// An answer that did not go: the question is not read again (it is in `asked`), so
    /// the voice says where it is (#2442).
    private func answerDidNotGo() {
        guard phase != .off else { return }
        sound(.problem)
        speak([VoiceModeWords.answerNotSent])
    }

    // MARK: Listening

    /// `chime`: the listening sound, which is left out between the sentences of a reply
    /// still being written.
    /// `words`: heard already, before voice mode turned on (#2420); they go after the pause
    /// with what is said next.
    private func listen(chime: Bool = true, after words: String = "") {
        guard phase != .off else { return }
        if phase == .loading { note("voice: listening, echo cancelled \(audio.cancelsEcho)") }
        heard = ""
        phase = .listening
        armStillWorking()
        armTick()
        defer { askIfWaiting() }
        if !words.isEmpty { heardChanged(words) }
        guard !isWalked else { return }
        startDictation(after: words)
        // The sound once the microphone really hears, so words said on it are not lost.
        if chime { chimeWhenListening() }
    }

    /// Plays the listening sound as soon as dictation listens, or after a second at most.
    private func chimeWhenListening() {
        Task { [weak self] in
            for _ in 0..<20 {
                guard let self, self.phase == .listening else { return }
                if self.dictation.isListening { break }
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard let self, self.phase == .listening else { return }
            self.sound(.listening)
        }
    }

    /// Dictation afresh, so what was heard before is not in what comes next.
    private func startDictation(after words: String = "") {
        dictation.stop()
        dictation.start(in: words, selection: nil, vocabulary: vocabulary) { [weak self] text, _ in
            self?.heardChanged(text)
        }
        watchDictation()
    }

    /// The microphone as if refused, for a walk: the alert dictation's refusal brings.
    func walkRefuseMicrophone() {
        guard phase != .off else { return }
        fail(VoiceModeWords.problem(dictation: "Dictation needs the microphone. " + Dictation.whereTheSwitchIs),
             permission: .microphone)
    }

    /// Words as if heard, for a walk: they go after the pause, as spoken ones do, stop
    /// the voice when it is speaking, and while a prompt sends (#3070), join the one
    /// already on its way there.
    func walkHeard(_ words: String) {
        guard phase == .listening || phase == .speaking || phase == .sending else { return }
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
                if let problem = self.dictation.problem {
                    note("voice: dictation: \(problem.message)")
                    self.dictation.dismissProblem()
                    self.fail(VoiceModeWords.problem(dictation: problem.message), permission: problem.permission)
                } else {
                    self.watchDictation()
                }
            }
        }
    }

    private func heardChanged(_ text: String) {
        // VoiceOver saying what it was told, heard through the microphone (#2446).
        if let announced, Date().timeIntervalSince(announced.at) < 8,
           VoiceModeWords.isEcho(text, of: announced.text) {
            // Heard afresh, so the person's next words do not start with VoiceOver's.
            if !isWalked, phase == .listening { startDictation() }
            return
        }
        defer { armTick() }
        // Over the voice: words that mean something stop it, and are the next prompt.
        if phase == .speaking {
            guard isBargeIn(text) else { return }
            quiet()
            phase = .listening
        }
        if !text.isEmpty {
            questionReplay?.cancel()
            questionReplay = nil
            if joinStarted, joinTarget != nil {
                joinText = text
            } else if let deadline = joinDeadline, ContinuousClock.now < deadline, joinTarget != nil {
                joinStarted = true
                joinText = text
            } else if joinDeadline != nil {
                clearJoin()
            }
        }
        heard = text
        if !text.isEmpty { unsent = nil }
        pauseTimer?.cancel()
        armStillWorking()
        if confirming != nil, SpokenQuestion.isNo(text) {
            dontSend()
            return
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        pauseTimer = Task { [weak self] in
            try? await Task.sleep(for: Self.pause)
            guard !Task.isCancelled else { return }
            await self?.sendHeard()
        }
    }

    /// No, or Don't Send (#2443): the answer waiting to go does not, and the question is
    /// asked again.
    func dontSend() {
        guard confirming != nil else { return }
        confirming?.cancel()
        confirming = nil
        pendingConfirm = nil
        confirmLine = nil
        heard = ""
        pauseTimer?.cancel()
        dictation.stop()
        if let asking {
            let id = asking.request.id
            speak(["Not sent."] + asking.spoken.sentences) { [weak self] in self?.armQuestionReplay(for: id) }
        }
        else if let approving { speak(["Not sent."] + approving.spoken.sentences) }
    }

    private func sendHeard() async {
        let words = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        guard phase == .listening, !words.isEmpty, let send else { return }
        if isAsking, confirming == nil {
            dictation.stop()
            if approving != nil { approveHeard(words) } else { answerHeard(words) }
            return
        }
        // Words while an answer waits to go are not a prompt.
        guard confirming == nil else { return }
        // The microphone stays open through send(): a continuation said right after the
        // pause fires is heard, not lost, on exactly the round trip that takes longest, a
        // new session's (#3070).
        phase = .sending
        armTick()
        let agent = agentID
        let itemBaseline = observedItemIDs
        let responseBaseline = observedAgentResponseIDs
        let joined = joinTarget != nil && joinText != nil && joinStarted
        let outgoing = joined ? [joinFirstText, joinText].compactMap { $0 }.joined(separator: " ") : words
        let stop = joined ? joinTarget : nil
        clearJoin()
        let target = walkSendFails ? nil : await send(outgoing, stop)
        guard agentID == agent, phase == .sending else { return }
        // What was heard while that call was in flight, not sent with it (#3070).
        let continued = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        let leftover = continued == words ? "" :
            (continued.hasPrefix(words) ? String(continued.dropFirst(words.count)) : continued)
                .trimmingCharacters(in: .whitespacesAndNewlines)
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
            if observedAgentResponseIDs.subtracting(responseBaseline).isEmpty {
                joinTarget = target
                joinFirstText = words
                // Already heard while sending: joined at once, not waiting for a fresh
                // word to arrive once the mic is confirmed open again (#3070).
                joinText = leftover.isEmpty ? nil : leftover
                joinStarted = !leftover.isEmpty
                joinBaselineItemIDs = itemBaseline
                armJoinDeadline()
            }
            saidSteps = []
        } else {
            // The words are not lost: the strip keeps them, and the voice says so first.
            sound(.problem)
            unsent = words
            queue.insert(VoiceModeWords.notSent, at: 0)
        }
        if queue.isEmpty {
            listen(after: leftover)
        } else {
            startSpeaking()
        }
    }

    /// Arms the join window once the microphone is confirmed listening again, not from
    /// when `send()` returned: a slow round trip can otherwise spend the window before the
    /// mic has even reopened (#3070).
    private func armJoinDeadline() {
        Task { [weak self] in
            for _ in 0..<20 {
                guard let self, self.joinTarget != nil else { return }
                if self.isWalked || self.dictation.isListening { break }
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard let self, self.joinTarget != nil else { return }
            self.joinDeadline = ContinuousClock.now.advanced(by: Self.joinFor)
        }
    }

    /// Enter (#2519): send the words heard so far without waiting for the pause.
    /// Nothing while the voice speaks or when no words have been heard. While the
    /// confirm line waits, send that answer at once.
    func sendNow() {
        guard phase == .listening else { return }
        if confirming != nil {
            confirming?.cancel()
            Task { await self.finishConfirm() }
            return
        }
        guard !heard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        pauseTimer?.cancel()
        pauseTimer = nil
        Task { await self.sendHeard() }
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
        guard meant.count >= (isAsking ? 1 : 2) else { return false }
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
        stillWorking?.cancel()
        phase = .speaking
        heard = ""
        armTick()
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
                if !Task.isCancelled { note("voice: could not speak: \(error)") }
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

    /// Listening, nothing heard, and no answer waiting for a "no". A turn that is still
    /// running counts: the microphone is open, and that long silence is when the tick
    /// says it is still on (#2520). "Still working" stays the spoken line (#2358).
    private var ticksInSilence: Bool {
        phase == .listening && heard.isEmpty && confirmLine == nil && !isWalked
    }

    /// Starts the tick, or stops it. A tick already waiting is left, so an empty update
    /// does not put the next one off.
    private func armTick() {
        guard ticksInSilence else {
            tickTask?.cancel()
            tickTask = nil
            return
        }
        guard tickTask == nil else { return }
        tickTask = Task { [weak self] in
            // While the agent works, the working sound, more often; else the tick.
            let working = self?.isWaitingForReply == true
            try? await Task.sleep(for: working ? Self.workingEvery : Self.tickEvery)
            guard !Task.isCancelled, let self else { return }
            self.tickTask = nil
            guard self.ticksInSilence else { return }
            self.sound(self.isWaitingForReply ? .working : .tick)
            self.armTick()
        }
    }

    /// A sound, but none in a walk.
    private func sound(_ sound: VoiceSound) {
        if !isWalked { sound.play() }
    }

    private func fail(_ message: String, permission: Dictation.Permission? = nil) {
        sound(.problem)
        turnOff()
        problem = message
        problemPermission = permission
    }
}
