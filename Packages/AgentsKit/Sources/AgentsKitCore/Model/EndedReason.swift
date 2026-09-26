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

    /// The app itself decided this agent had spent enough. The only ending that means
    /// a limit the reader set was reached, and the only one the app chooses rather
    /// than observes. Always arrives at the end of a turn, never in the middle of one.
    case costLimit

    /// A turn ended with a stop reason this app has never heard of. Not in the
    /// protocol's list and not one of ours: it is what happens when a runtime ships a
    /// new one, and it belongs in the record rather than being rounded to the nearest
    /// reason we do recognise.
    case unrecognised

    /// Stopped by the agent that started this one, through its own stop tool (028).
    /// The person's stop is `cancelled`; this is kept apart so the row never says
    /// "Stopped by you" about a stop the person did not make. Not a protocol stop
    /// reason, so `init(stopReason:)` never produces it.
    case stoppedByAgent

    /// The provider refused the sign-in the runtime was started with (043, FR-016): not
    /// a crash, and not something another try fixes until the token is replaced.
    case signInRefused

    /// Stopped short, and why. Never a reason dressed up as a finish, and `nil` for a
    /// turn that simply ended — there is nothing to say about that.
    ///
    /// Here rather than in a view because the phone and the window have to say the same
    /// words about the same agent, and two copies of a switch are two chances to drift.
    public var summary: String? {
        switch self {
        case .endTurn: return nil
        case .maxTokens: return "Ran out of room"
        case .maxTurnRequests: return "Hit its limit"
        case .refusal: return "Refused"
        case .cancelled: return "Stopped by you"
        case .processDied: return "The runtime crashed"
        case .daemonGone: return "Stopped with the daemon"
        case .costLimit: return "Reached its cost limit"
        case .unrecognised: return "Stopped for a reason we do not know"
        case .stoppedByAgent: return "Stopped by the agent that started it"
        case .signInRefused: return "Its sign-in was refused"
        }
    }

    /// A reason written by a newer build reads as `unrecognised`, never as a failure
    /// to read the whole agent. Thrown from here, one new ending made every record
    /// carrying it vanish from an older app and every agent list fail on an older phone.
    public init(from decoder: any Decoder) throws {
        let written = try decoder.singleValueContainer().decode(String.self)
        self = EndedReason(rawValue: written) ?? .unrecognised
    }

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
