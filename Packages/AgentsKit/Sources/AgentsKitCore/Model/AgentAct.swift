import Foundation

/// Something a person asked of a whole agent, while it is on its way to the agent's
/// host (#87).
public enum AgentAct: Sendable, Hashable {
    case stop
    case park
    case unpark
    case archive
    /// A queued prompt sent into the running turn, by its id.
    case sendNow(UUID)

    public init(_ action: ParkAction) {
        self = action == .park ? .park : .unpark
    }

    /// What the pending mark says it is doing, before "telling your Mac".
    public var doing: String {
        switch self {
        case .stop: return "Stopping"
        case .park: return "Parking"
        case .unpark: return "Unparking"
        case .archive: return "Archiving"
        case .sendNow: return "Sending"
        }
    }
}
