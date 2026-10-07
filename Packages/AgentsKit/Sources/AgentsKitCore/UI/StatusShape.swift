import Foundation

/// What an agent's row shows beside its title.
///
/// There used to be ten — a filled check for `done`, a hollow one for `nothing_to_do`
/// and for a turn nobody vouched for, a half-filled circle, a triangle, a hollow and a
/// filled question mark, a dotted circle, a box — each marking a real distinction, and
/// together a legend nobody could hold in their head. The distinctions still exist and
/// are still said in words: in the tooltip, to a screen reader, and in the report under
/// the title. The shape says who acts next.
///
/// Here rather than in either app so the Mac's row and the phone's card cannot disagree
/// about it. Before this there were two copies of the same switch, one in each app.
public enum StatusShape: Hashable, Sendable {
    /// A turn is going, or the daemon is bringing the chat back after a restart.
    case working
    /// Something is waiting on a person: a question mid-turn, or a turn that ended
    /// saying it needs an answer, got only partway, or is stuck. The only colour.
    case needsYou
    /// Waiting on something the app watches, and will carry on by itself (039, 042).
    /// No colour: nobody has to do anything.
    case waiting
    /// The turn ended and nobody is waiting on anyone.
    case done
    /// Stopped short, by the person or by something going wrong, or archived.
    case stopped

    /// `isWaiting` is `Agent.isWaiting`: the app will carry it on by itself.
    public init(state: AgentState, outcome: WorkOutcome?, isWaiting: Bool, isComingBack: Bool,
                endedReason: EndedReason? = nil,
                waitingForAllowance: Bool = false, outcomeUnknown: Bool = false) {
        // Coming back is work being done on the chat's behalf, even though the record
        // still reads stopped until the pick-up lands. Showing the stop mark would say
        // it was left for dead; the spinner says wait.
        if isComingBack { self = .working; return }
        switch state {
        case .starting, .running: self = .working
        case .waitingOnUser: self = .needsYou
        // Only a finished agent's outcome counts. A stopped one keeps the stop mark
        // whatever it last claimed, which is the rule `AgentGroup` follows too. Unread
        // is not here: it is the row's mark, not a need (#70).
        case .finished where outcomeUnknown: self = .needsYou
        case .finished:
            switch outcome {
            case .some(let outcome) where outcome.needsAPerson: self = .needsYou
            case _ where isWaiting: self = .waiting
            case .blocked: self = .needsYou
            default: self = .done
            }
        case .stopped where waitingForAllowance: self = .waiting
        // The same three as `AgentGroup`'s Paused: stopped on purpose, or out of allowance
        // (065), where the way on is a new chat. Anything else stopped wants a person.
        case .stopped where ![.cancelled, .stoppedByAgent, .allowanceSpent].contains(endedReason):
            self = .needsYou
        case .stopped, .archived: self = .stopped
        // Starts by itself when a place frees (#362).
        case .queued: self = .waiting
        }
    }

    /// The SF Symbol to draw. Nil for `working`, which is drawn as a spinner.
    public var symbol: String? {
        switch self {
        case .working: return nil
        case .needsYou: return "exclamationmark.circle.fill"
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

public extension StatusShape {
    /// The shape an agent's row in the Mac's sessions list draws, asked the way the row
    /// asks it. The web remote draws the same (071, research R7).
    init(row agent: Agent, isComingBack: Bool) {
        self.init(state: agent.state, outcome: agent.report?.outcome, isWaiting: agent.isWaiting,
                  isComingBack: isComingBack, endedReason: agent.endedReason,
                  outcomeUnknown: agent.endingIsUnaccountedFor)
    }

    /// Whether the row draws the shape in the app's one colour: it wants a person, and the
    /// person has not parked it or been told it waits for an allowance.
    static func isTinted(_ shape: StatusShape, isParked: Bool, isWaitingForAllowance: Bool = false) -> Bool {
        shape.wantsAPerson && !isParked && !isWaitingForAllowance
    }

    /// What a screen reader hears for the shape, and what the tooltip says. Precise where
    /// the shape is not: the outcome's words come from `WorkOutcome.heading`, and a
    /// stopped agent says why.
    static func words(_ shape: StatusShape, state: AgentState, isComingBack: Bool, outcome: WorkOutcome?,
                      isUnaccountedFor: Bool, ending: String?, isUnread: Bool,
                      isWaitingForAllowance: Bool = false) -> String {
        if isComingBack { return AgentsModel.comingBackDescription }
        if isUnread && state == .finished { return "Unread · \(outcome?.heading ?? "Finished")" }
        if isWaitingForAllowance { return "Waiting for an allowance" }
        if state == .queued { return HelperLimit.queuedLabel(position: nil) }
        if shape == .waiting { return waitingLabel }
        if state == .finished, let outcome { return outcome.heading }
        if isUnaccountedFor && state == .finished { return "Finished without saying how it went" }
        switch state {
        case .running: return "Working"
        case .starting: return AgentState.startingLabel
        case .waitingOnUser: return "Waiting on you"
        case .finished: return "Finished"
        case .stopped: return ending ?? "Stopped"
        case .archived: return "Archived"
        case .queued: return HelperLimit.queuedLabel(position: nil)
        }
    }

    /// The words for an agent's row, as `init(row:isComingBack:)` draws its shape.
    static func words(row agent: Agent, isComingBack: Bool) -> String {
        words(StatusShape(row: agent, isComingBack: isComingBack), state: agent.state, isComingBack: isComingBack,
              outcome: agent.report?.outcome, isUnaccountedFor: agent.endingIsUnaccountedFor,
              ending: agent.endedReason?.summary, isUnread: agent.isUnread)
    }
}
