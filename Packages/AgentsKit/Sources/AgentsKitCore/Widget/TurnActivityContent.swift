import Foundation

/// What a turn's Live Activity says on the Lock Screen and in the Dynamic Island (#1657).
///
/// The words, not the drawing: the Remote works them out from the model it already holds,
/// and the widget extension draws them. Here, in Core, so the rule is tested without a
/// phone, and so the activity says the same thing about a session as its row does: the
/// plan step it is on while it works, the banner's words while it asks, the report or the
/// reason once it ends.
///
/// It is ActivityKit's `ContentState`, so it is small (the system refuses more than 4 KB)
/// and only `Codable`.
public struct TurnActivityContent: Codable, Hashable, Sendable {
    public enum Phase: String, Codable, Hashable, Sendable {
        case working
        /// It asked a question (an elicitation), or waits on the person with none open.
        case question
        /// A permission, or a guarded change to keep or undo.
        case approval
        case done
        /// It ended for a reason that is not a clean end of turn.
        case failed
    }

    public var phase: Phase
    /// The session's title, here and not in the attributes: a runtime names a new session
    /// after its first turn has begun.
    public var title: String
    /// The grey line: the step, the question, the report or the reason. Nil says nothing.
    public var line: String?
    /// When this device sent the turn's prompt. The timer counts from here.
    public var startedAt: Date
    /// When it ended, so the timer stops there.
    public var endedAt: Date?

    public init(phase: Phase, title: String, line: String?, startedAt: Date, endedAt: Date? = nil) {
        self.phase = phase
        self.title = title
        self.line = line.map(Self.shortened).flatMap { $0.isEmpty ? nil : $0 }
        self.startedAt = startedAt
        self.endedAt = endedAt
    }

    /// Whether the turn is over, and the activity ends with this.
    public var isOver: Bool { phase == .done || phase == .failed }

    /// Whether it waits on the person.
    public var asks: Bool { phase == .question || phase == .approval }

    /// The phase in a word or two, as the sidebar's marks say it.
    public var word: String {
        switch phase {
        case .working: "Working"
        case .question: "Question waiting"
        case .approval: "Needs approval"
        case .done: "Done"
        case .failed: "Stopped"
        }
    }

    /// The title a session with none yet is shown with.
    public static let untitled = "New session"

    /// The longest line kept. The Lock Screen shows two lines at most, and the whole state
    /// has to stay well under ActivityKit's 4 KB.
    public static let lineLimit = 160

    /// A prompt this device has just sent: working, from now.
    public static func sent(title: String?, at date: Date = Date()) -> TurnActivityContent {
        TurnActivityContent(phase: .working, title: title ?? untitled, line: nil, startedAt: date)
    }

    /// What the activity says about this session now, for a turn that began at `startedAt`.
    ///
    /// - Parameter needs: the needs the model holds; only this session's are read, and the
    ///   newest of them wins, as the widget's row does.
    /// - Returns: nil when there is no session to speak of any more (archived, or gone), and
    ///   the activity goes at once.
    public static func make(agent: Agent?, needs: some Sequence<Need>, startedAt: Date) -> TurnActivityContent? {
        guard let agent, agent.state != .archived else { return nil }
        let title = agent.title ?? untitled
        let need = needs.filter { $0.agentID == agent.id }.max { $0.raisedAt < $1.raisedAt }
        switch need?.kind {
        case .permission?, .guardedChange?:
            return TurnActivityContent(phase: .approval, title: title, line: need?.headline.h3, startedAt: startedAt)
        case .elicitation?:
            return TurnActivityContent(phase: .question, title: title, line: need?.headline.h3, startedAt: startedAt)
        case .report?, nil:
            break
        }
        switch agent.state {
        case .starting, .running, .queued:
            return TurnActivityContent(phase: .working, title: title, line: agent.currentStep, startedAt: startedAt)
        case .waitingOnUser:
            return TurnActivityContent(phase: .question, title: title, line: nil, startedAt: startedAt)
        case .finished, .stopped:
            let ended = max(agent.lastActivityAt, startedAt)
            if let reason = agent.endedReason?.summary {
                return TurnActivityContent(phase: .failed, title: title, line: reason, startedAt: startedAt, endedAt: ended)
            }
            if agent.state == .stopped {
                return TurnActivityContent(phase: .failed, title: title, line: "Stopped", startedAt: startedAt, endedAt: ended)
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
