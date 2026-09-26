import Foundation

/// What an agent's row shows beside its title: one of six shapes, and no more.
///
/// There used to be ten — a filled check for `done`, a hollow one for `nothing_to_do`
/// and for a turn nobody vouched for, a half-filled circle, a triangle, a hollow and a
/// filled question mark, a dotted circle, a box — each marking a real distinction, and
/// together a legend nobody could hold in their head. The distinctions still exist and
/// are still said in words: in the tooltip, to a screen reader, and in the report under
/// the title. The shape only has to say which of six things is true.
///
/// Here rather than in either app so the Mac's row and the phone's card cannot disagree
/// about it. Before this there were two copies of the same switch, one in each app.
public enum StatusShape: Hashable, Sendable {
    /// A turn is going, or the daemon is bringing the chat back after a restart.
    case working
    /// Something is waiting on a person: a question mid-turn, or a turn that ended
    /// saying it needs an answer, got only partway, or is stuck. The only colour.
    case needsYou
    /// The turn ended blocked on something the app cannot watch (039), so only the
    /// person can carry it on. No colour: it is not asking them anything.
    case blocked
    /// Waiting on something the app watches, and will carry on by itself (039, 042).
    /// No colour: nobody has to do anything.
    case waiting
    /// The turn ended and nobody is waiting on anyone.
    case done
    /// Stopped short, by the person or by something going wrong, or archived.
    case stopped

    /// `isWaiting` is `Agent.isWaiting`: the app will carry it on by itself.
    public init(state: AgentState, outcome: WorkOutcome?, isWaiting: Bool, isComingBack: Bool) {
        // Coming back is work being done on the chat's behalf, even though the record
        // still reads stopped until the pick-up lands. Showing the stop mark would say
        // it was left for dead; the spinner says wait.
        if isComingBack { self = .working; return }
        switch state {
        case .starting, .running: self = .working
        case .waitingOnUser: self = .needsYou
        // Only a finished agent's outcome counts. A stopped one keeps the stop mark
        // whatever it last claimed, which is the rule `AgentGroup` follows too.
        case .finished:
            switch outcome {
            case .some(let outcome) where outcome.needsAPerson: self = .needsYou
            case _ where isWaiting: self = .waiting
            case .blocked: self = .blocked
            default: self = .done
            }
        case .stopped, .archived: self = .stopped
        }
    }

    /// The SF Symbol to draw. Nil for `working`, which is drawn as a spinner.
    public var symbol: String? {
        switch self {
        case .working: return nil
        case .needsYou: return "exclamationmark.circle.fill"
        case .blocked: return "hand.raised.circle"
        case .waiting: return "hourglass.circle"
        case .done: return "checkmark.circle"
        case .stopped: return "stop.circle"
        }
    }

    /// What the Mac's row and the phone's card say for `waiting`, in place of the
    /// outcome's heading: a blocked report the app will resume is not Blocked to the
    /// person, whatever word the agent used.
    public static let waitingLabel = "Waiting"

    /// Whether this shape gets the app's one colour.
    public var wantsAPerson: Bool { self == .needsYou }
}
