import Foundation

/// Something a person asked of a whole agent, while it is on its way to the agent's
/// host (#87).
public enum AgentAct: Sendable, Hashable {
    case stop
    case archive
    /// A queued prompt sent into the running turn, by its id.
    case sendNow(UUID)
    /// A queued session started at once, past the running limit (#5156).
    case startNow

    /// The change it draws on the agent's record before the host answers (#4786).
    public var write: AgentWrite {
        switch self {
        case .stop: return .stop
        case .archive: return .archive
        case .sendNow(let promptID): return .sendNow(promptID)
        case .startNow: return .startNow
        }
    }

    /// What the pending mark says it is doing, before "telling your Mac".
    public var doing: String {
        switch self {
        case .stop: return "Stopping"
        case .archive: return "Archiving"
        case .sendNow: return "Sending"
        case .startNow: return "Starting"
        }
    }
}
