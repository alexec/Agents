import Foundation

/// What the Live Activity says on the Lock Screen and in the Dynamic Island (#1657).
///
/// The words, not the drawing: the Remote works them out from the model it already holds,
/// and the widget extension draws them. Here, in Core, so the rule is tested without a
/// phone, and so the activity says the same thing about a session as its row does: the
/// plan step it is on while it works, the banner's words while it asks, the report or the
/// reason once it ends.
///
/// A device shows one activity in total (#2991), not one for each session: `summary(of:)`
/// makes it from each turn sent from here, and it shows the session that most needs the
/// person, with a count of the others.
///
/// It is ActivityKit's `ContentState`, so it is small (the system refuses more than 4 KB)
/// and only `Codable`.
///
/// The control plane updates it by push while the Remote is not running (#1744). Apple
/// reads a pushed state, so the control plane writes only the phase, the session, the
/// counts and the times, with no title, place or line (public-security.md §5): the
/// activity then says how many sessions, and a line that says to open the app.
public struct TurnActivityContent: Codable, Hashable, Sendable {
    public enum Phase: String, Codable, Hashable, Sendable {
        case working
        /// It asked a question (an elicitation), or waits on the person with none open.
        case question
        /// A permission, or a guarded change to keep or undo.
        case approval
        case done
        /// It ended cleanly, but wanting the person: a question (#1916), Outcome
        /// unknown, or a question in its report (#1861). The sidebars put it under Needs you.
        case needsYou = "needs_you"
        /// Cut short on purpose, so the sidebars show a neutral mark (#1869).
        case paused
        /// It ended for a reason that is not a clean end of turn, and nobody chose it.
        case failed
    }

    public var phase: Phase
    /// The session it shows, for a tap to open it. Nil from a build before #2991.
    public var agentID: UUID?
    /// The session's title: a runtime names a new session after its first turn has begun.
    /// Nil from a push, which carries no words.
    public var title: String?
    /// The runtime and the folder, "Claude · Agents". Nil from a push.
    public var place: String?
    /// The grey line: the step, the question, the report or the reason. Nil says nothing.
    public var line: String?
    /// When this device sent the turn's prompt; in a summary, the oldest turn's. The timer
    /// counts from here.
    public var startedAt: Date
    /// When it ended, so the timer stops there.
    public var endedAt: Date?
    /// The other turns still running from here that ask the person, and that work.
    public var othersAsking: Int
    public var othersWorking: Int

    public init(phase: Phase, agentID: UUID? = nil, title: String?, place: String? = nil, line: String?,
                startedAt: Date, endedAt: Date? = nil, othersAsking: Int = 0, othersWorking: Int = 0) {
        self.phase = phase
        self.agentID = agentID
        self.title = title
        self.place = place
        self.line = line.map(Self.shortened).flatMap { $0.isEmpty ? nil : $0 }
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.othersAsking = othersAsking
        self.othersWorking = othersWorking
    }

    /// A state with no counts, as a push from a control plane before #2991 writes it.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        phase = try c.decode(Phase.self, forKey: .phase)
        agentID = try c.decodeIfPresent(UUID.self, forKey: .agentID)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        place = try c.decodeIfPresent(String.self, forKey: .place)
        line = try c.decodeIfPresent(String.self, forKey: .line)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        endedAt = try c.decodeIfPresent(Date.self, forKey: .endedAt)
        othersAsking = try c.decodeIfPresent(Int.self, forKey: .othersAsking) ?? 0
        othersWorking = try c.decodeIfPresent(Int.self, forKey: .othersWorking) ?? 0
    }

    /// Whether the turn is over, and the activity ends with this.
    public var isOver: Bool { phase == .done || phase == .needsYou || phase == .paused || phase == .failed }

    /// Whether it waits on the person.
    public var asks: Bool { phase == .question || phase == .approval }

    /// The phase in a word or two, as the sidebar's marks say it.
    public var word: String {
        switch phase {
        case .working: "Working"
        case .question: "Question waiting"
        case .approval: "Needs approval"
        case .done: "Done"
        case .needsYou: "Needs you"
        case .paused: "Paused"
        case .failed: "Unexpected stop"
        }
    }

    /// How many turns it speaks for: the one it shows and the others.
    public var sessions: Int { 1 + othersAsking + othersWorking }

    /// The title to show: the session's, else, from a push, how many sessions.
    public var shownTitle: String {
        title ?? (sessions == 1 ? "Your session" : "\(sessions) sessions")
    }

    /// The others in a few words, "+1 needs you · +2 working"; nil when there are none.
    public var others: String? {
        let parts = [othersAsking > 0 ? "+\(othersAsking) needs you" : nil,
                     othersWorking > 0 ? "+\(othersWorking) working" : nil].compactMap(\.self)
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The line under the title. While it works and the Remote has not been heard from for
    /// a while, it says so rather than going on showing a step it may have left; a pushed
    /// state that waits on the person, which has no words, says where they are.
    public func line(isStale: Bool) -> String? {
        if isStale && !isOver { return "Open Agents to see where it is" }
        if line == nil, title == nil {
            switch phase {
            case .question: return "Open Agents to answer it"
            case .approval: return "Open Agents to decide"
            case .needsYou: return "Open Agents to see what it needs"
            case .working, .done, .paused, .failed: return nil
            }
        }
        return line
    }

    /// The endings the sidebars show as Paused (StatusShape): stops someone chose.
    public static let pausingReasons: Set<EndedReason> = [.cancelled, .stoppedByAgent, .stoppedByAdmin]

    /// The line for a turn that ended without a report saying how the work went.
    public static let outcomeUnknown = "Outcome unknown"

    /// The title a session with none yet is shown with.
    public static let untitled = "New session"

    /// The longest line kept. The Lock Screen shows two lines at most, and the whole state
    /// has to stay well under ActivityKit's 4 KB.
    public static let lineLimit = 160

    /// A prompt this device has just sent: working, from now.
    public static func sent(agentID: UUID? = nil, title: String?, place: String? = nil,
                            at date: Date = Date()) -> TurnActivityContent {
        TurnActivityContent(phase: .working, agentID: agentID, title: title ?? untitled, place: place, line: nil,
                            startedAt: date)
    }

    /// The one activity from each turn sent from here (#2991): the session that most needs
    /// the person (one that asks, else the newest working one) with a count of the others
    /// still running, and the timer from the oldest of them. Once every turn has ended, the
    /// one that ended last. Nil when there are none. The control plane's push picks the same
    /// way (activities.go).
    public static func summary(of turns: some Sequence<TurnActivityContent>) -> TurnActivityContent? {
        let turns = Array(turns)
        let running = turns.filter { !$0.isOver }
        guard let first = running.first else {
            return turns.max { ($0.endedAt ?? $0.startedAt, $0.startedAt) < ($1.endedAt ?? $1.startedAt, $1.startedAt) }
        }
        let shown = running.max { ($0.asks ? 1 : 0, $0.startedAt) < ($1.asks ? 1 : 0, $1.startedAt) } ?? first
        let others = running.filter { $0 != shown }
        var summary = shown
        summary.startedAt = running.map(\.startedAt).min() ?? shown.startedAt
        summary.othersAsking = others.count(where: \.asks)
        summary.othersWorking = others.count - summary.othersAsking
        return summary
    }

    /// What the activity says about this session now, for a turn that began at `startedAt`.
    ///
    /// - Parameter needs: the needs the model holds; only this session's are read, and the
    ///   newest of them wins, as the widget's row does.
    /// - Returns: nil when there is no session to speak of any more (archived, or gone), and
    ///   the activity goes at once.
    public static func make(agent: Agent?, needs: some Sequence<Need>, startedAt: Date,
                            place: String? = nil) -> TurnActivityContent? {
        guard let agent, agent.state != .archived else { return nil }
        var content = makeWords(agent: agent, needs: needs, startedAt: startedAt)
        content?.agentID = agent.id
        content?.place = place
        return content
    }

    private static func makeWords(agent: Agent, needs: some Sequence<Need>, startedAt: Date) -> TurnActivityContent? {
        let title = agent.title ?? untitled
        let need = needs.filter { $0.agentID == agent.id }.max { $0.raisedAt < $1.raisedAt }
        switch need?.kind {
        case .permission?, .guardedChange?:
            return TurnActivityContent(phase: .approval, title: title, line: need?.headline.h3, startedAt: startedAt)
        case .elicitation?:
            return TurnActivityContent(phase: .question, title: title, line: need?.headline.h3, startedAt: startedAt)
        case .report?, .notice?, nil:
            break
        }
        switch agent.state {
        case .starting, .running, .queued:
            return TurnActivityContent(phase: .working, title: title, line: agent.currentStep, startedAt: startedAt)
        case .waitingOnUser:
            return TurnActivityContent(phase: .question, title: title, line: nil, startedAt: startedAt)
        case .finished, .stopped:
            let ended = max(agent.lastActivityAt, startedAt)
            // The docs' words for the reason (statuses.md), and the word says which kind:
            // Paused for a stop someone chose, else Unexpected stop.
            if agent.state == .stopped || agent.endedReason?.summary != nil {
                let paused = agent.endedReason.map(pausingReasons.contains) ?? false
                return TurnActivityContent(phase: paused ? .paused : .failed, title: title, line: agent.endedReason?.summary,
                                           startedAt: startedAt, endedAt: ended)
            }
            // The sidebars' rule (StatusShape): a clean end that still wants the person.
            if StatusShape(row: agent, isComingBack: false) == .needsYou {
                let line = agent.report.map { "\($0.outcome.heading): \($0.message)" } ?? outcomeUnknown
                return TurnActivityContent(phase: .needsYou, title: title, line: line, startedAt: startedAt,
                                           endedAt: ended)
            }
            return TurnActivityContent(phase: .done, title: title, line: agent.report?.message, startedAt: startedAt,
                                       endedAt: ended)
        case .archived:
            return nil
        }
    }

    /// One line, at most `lineLimit` characters, with an ellipsis where it was cut.
    private static func shortened(_ text: String) -> String {
        let one = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let trimmed = one.trimmingCharacters(in: .whitespaces)
        guard trimmed.count > lineLimit else { return trimmed }
        return String(trimmed.prefix(lineLimit - 1)) + "…"
    }
}
