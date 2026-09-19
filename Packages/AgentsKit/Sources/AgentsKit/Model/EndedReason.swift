import Foundation

/// How an agent's last turn, or its last process, came to an end.
///
/// The first five are the protocol's stop reasons, in its own words. The last two are
/// the endings the protocol has no way to report, because in both of them there is
/// nobody left to report anything.
public enum EndedReason: String, Codable, Hashable, Sendable, CaseIterable {
    /// The one ending that means the agent said what it had to say. The only route to
    /// `finished`.
    case endTurn

    case maxTokens
    case maxTurnRequests
    case refusal
    case cancelled

    /// The process went without a stop reason. A crash, not a finish.
    case processDied

    /// Found dead when the daemon started: a logout, a restart, or the daemon killed.
    case daemonGone

    /// The protocol's own spelling, which is what arrives on the wire.
    public init?(stopReason: String) {
        switch stopReason {
        case "end_turn": self = .endTurn
        case "max_tokens": self = .maxTokens
        case "max_turn_requests": self = .maxTurnRequests
        case "refusal": self = .refusal
        case "cancelled": self = .cancelled
        default: return nil
        }
    }

    /// Whether this ending means the agent finished rather than stopped short.
    public var isFinish: Bool { self == .endTurn }
}
