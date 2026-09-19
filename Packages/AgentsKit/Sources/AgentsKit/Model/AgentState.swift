import Foundation

/// What an agent is doing. Exactly one at a time.
///
/// The distinction that matters, and the one the protocol forced: `running` means a
/// turn is in flight, not that a process is alive. These runtimes are long-lived
/// servers that never exit when their work is done, so process liveness says nothing
/// about whether there is work happening.
public enum AgentState: String, Codable, Hashable, Sendable, CaseIterable {
    case running
    case waitingOnUser
    case finished
    case stopped
    case archived

    /// Whether this state implies the daemon is holding a live runtime for it.
    ///
    /// `finished` is deliberately absent: a finished agent's process is let go, because
    /// every runtime hands its session back afterwards.
    public var holdsRuntime: Bool {
        switch self {
        case .running, .waitingOnUser: return true
        case .finished, .stopped, .archived: return false
        }
    }

    /// Whether a turn is already in flight, so a prompt has to wait rather than start
    /// one of its own.
    ///
    /// The same two states as `holdsRuntime` today, and a different question: that one
    /// is about a process being alive, this one is about the conversation being busy.
    /// `waitingOnUser` is in here because a permission question is asked in the middle
    /// of a turn, not between two of them.
    public var hasTurnInFlight: Bool {
        switch self {
        case .running, .waitingOnUser: return true
        case .finished, .stopped, .archived: return false
        }
    }
}

/// The things that happen to an agent.
public enum AgentEvent: Hashable, Sendable {
    case promptSent
    case permissionAsked
    case permissionAnswered
    case turnEnded(EndedReason)
    case stoppedByUser
    case processDied
    case foundDead
    case archivedByUser
    case unarchivedByUser
}

extension AgentState {
    /// The next state, or nil when the event must not happen in this state.
    ///
    /// Returning nil rather than throwing keeps this pure and cheap to exhaust in
    /// tests, and every refusal here is a rule from the spec:
    ///
    /// - `finished` is reachable only by a turn ending in `endTurn` (FR-012).
    /// - Nothing reaches `archived` except by the user asking (FR-012).
    /// - Archiving a live agent is refused, because it must be stopped first (FR-013).
    /// - A prompt from any settled state picks the agent up rather than copying it
    ///   (FR-012b), archived included.
    public func applying(_ event: AgentEvent, endedReason: EndedReason? = nil) -> AgentState? {
        switch (self, event) {
        case (.running, .promptSent):
            return nil // A turn is already in flight.
        case (_, .promptSent):
            return .running

        case (.running, .permissionAsked):
            return .waitingOnUser
        case (_, .permissionAsked):
            return nil

        case (.waitingOnUser, .permissionAnswered):
            return .running
        case (_, .permissionAnswered):
            return nil

        case (.running, .turnEnded(let reason)), (.waitingOnUser, .turnEnded(let reason)):
            return reason == .endTurn ? .finished : .stopped
        case (_, .turnEnded):
            return nil

        case (.running, .stoppedByUser), (.waitingOnUser, .stoppedByUser):
            return .stopped
        case (_, .stoppedByUser):
            return nil

        case (.running, .processDied), (.waitingOnUser, .processDied):
            return .stopped
        case (_, .processDied):
            return nil

        case (.running, .foundDead), (.waitingOnUser, .foundDead):
            return .stopped
        case (_, .foundDead):
            return nil

        case (.running, .archivedByUser), (.waitingOnUser, .archivedByUser):
            return nil // Stop it first.
        case (.archived, .archivedByUser):
            return nil
        case (_, .archivedByUser):
            return .archived

        case (.archived, .unarchivedByUser):
            return endedReason == .endTurn ? .finished : .stopped
        case (_, .unarchivedByUser):
            return nil
        }
    }
}
