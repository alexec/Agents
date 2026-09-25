import Foundation

/// What an agent's row shows beside its title: one of five shapes, and no more.
///
/// There used to be ten — a filled check for `done`, a hollow one for `nothing_to_do`
/// and for a turn nobody vouched for, a half-filled circle, a triangle, a hollow and a
/// filled question mark, a dotted circle, a box — each marking a real distinction, and
/// together a legend nobody could hold in their head. The distinctions still exist and
/// are still said in words: in the tooltip, to a screen reader, and in the report under
/// the title. The shape only has to say which of five things is true.
///
/// Here rather than in either app so the Mac's row and the phone's card cannot disagree
/// about it. Before this there were two copies of the same switch, one in each app.
public enum StatusShape: Hashable, Sendable {
    /// A turn is going, or the daemon is bringing the chat back after a restart.
    case working
    /// Something is waiting on a person: a question mid-turn, or a turn that ended
    /// saying it needs an answer, got only partway, or is stuck. The only colour.
    case needsYou
    /// The turn ended waiting on something other than a person (039). No colour: nobody
    /// has to do anything.
    case blocked
    /// The turn ended and nobody is waiting on anyone.
    case done
    /// Stopped short, by the person or by something going wrong, or archived.
    case stopped

    public init(state: AgentState, outcome: WorkOutcome?, isComingBack: Bool) {
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
        case .blocked: return "hourglass.circle"
        case .done: return "checkmark.circle"
        case .stopped: return "stop.circle"
        }
    }

    /// Whether this shape gets the app's one colour.
    public var wantsAPerson: Bool { self == .needsYou }
}
