import Foundation

/// What an agent is doing. Exactly one at a time.
///
/// The distinction that matters, and the one the protocol forced: `running` means a
/// turn is in flight, not that a process is alive. These runtimes are long-lived
/// servers that never exit when their work is done, so process liveness says nothing
/// about whether there is work happening.
public enum AgentState: String, Codable, Hashable, Sendable, CaseIterable {
    /// It exists, a runtime is made or is being made, and its conversation has not
    /// begun.
    ///
    /// The state that was missing. Without it a new agent had to be written down as
    /// `stopped` with `endTurn` — an ending it never had — because the record's
    /// invariants require a stopped agent to carry a reason and `endTurn` was the only
    /// one that prints nothing on the row. The falsehood went into the record instead
    /// of onto the screen, and the agent appeared under **Stopped** for the instant
    /// before its first turn began.
    case starting
    case running
    case waitingOnUser
    case finished
    case stopped
    case archived

    /// What a row calls a starting agent, in the window and on the phone.
    ///
    /// Here rather than in a view for the reason `EndedReason.summary` gives: the phone
    /// and the window have to say the same words about the same agent, and two copies
    /// of a switch are two chances to drift.
    ///
    /// One constant rather than a full `AgentState.label`, deliberately. The other five
    /// words are *not* in fact identical across the two apps — `AgentRow` says "Waiting
    /// for your answer" where its own accessibility label says "Waiting on you" — so a
    /// single shared `label` would have to pick a winner between them. That is 018's
    /// argument to have, not this feature's.
    public static let startingLabel = "Starting"

    /// Whether this state implies the daemon is holding a live runtime for it.
    ///
    /// `finished` is deliberately absent: a finished agent's process is let go, because
    /// every runtime hands its session back afterwards.
    /// `starting` is in here because the session really is made before the record
    /// exists — the `Agent` is constructed after `freshSession` returns — so there is a
    /// live process to account for from the agent's first moment. `runUntilIdle` reads
    /// this to decide whether the daemon may go, and it must not exit out from under an
    /// agent that is being born (FR-003).
    public var holdsRuntime: Bool {
        switch self {
        case .starting, .running, .waitingOnUser: return true
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
    /// `starting` answers yes because the turn it was created for is about to begin.
    /// `enqueue` and `sendNextQueued` both gate on this, so a second prompt arriving
    /// while an agent starts joins the queue rather than racing the first — FR-004, and
    /// it costs no new code at all.
    ///
    /// **A third near-identical predicate lives outside this file and must not be
    /// confused with either of these**: `DaemonCore.hasWorkInFlight`
    /// (`DaemonCore+Wakefulness.swift`) asks *is the CPU busy*, and so excludes
    /// `waitingOnUser` — the one state the two above include. It is what decides
    /// whether the Mac is held awake, and using this property there would hold it all
    /// night for a permission prompt nobody answered (024 FR-003).
    ///
    /// Four predicates of this shape now exist — `holdsRuntime`, this one,
    /// `DaemonCore.isHoldingAgents` and `DaemonCore.hasWorkInFlight` — and they give
    /// three different answers about `waitingOnUser`. Each is right for its own
    /// question. None is a bug to be fixed into another.
    public var hasTurnInFlight: Bool {
        switch self {
        case .starting, .running, .waitingOnUser: return true
        case .finished, .stopped, .archived: return false
        }
    }
}

/// The things that happen to an agent.
public enum AgentEvent: Hashable, Sendable {
    case promptSent
    /// The first turn of a new agent beginning.
    ///
    /// Not folded into `promptSent`, because `beginTurn` is reached two ways: as the
    /// first turn of an agent that is `starting`, and as an ordinary prompt to a
    /// settled one. Keeping them apart is the only thing that lets
    /// `(.starting, .promptSent)` be refused, which is how FR-004 comes to live in the
    /// table rather than only in a guard inside the daemon.
    case turnBegun
    case permissionAsked
    case permissionAnswered
    case turnEnded(EndedReason)
    case stoppedByUser
    /// The agent that started this one stopped it (028). The person's stop, with its
    /// own ending.
    case stoppedByAgent
    case processDied
    case foundDead
    /// The person stopped an agent whose turn had ended blocked (039). The only stop a
    /// finished agent takes: it has no turn to cancel, but it has a resume coming, and
    /// stopping it is how the person says it should not come.
    case stoppedWaitingByUser
    /// The agent that started this one stopped it while it was blocked (039).
    case stoppedWaitingByAgent
    case archivedByUser
    /// The agent that started this one put it away (028). The person's archive, with
    /// its own reason.
    case archivedByAgent
    case unarchivedByUser
}

/// What happens to an agent's ending when an event is applied.
///
/// Three small enums rather than an `EndedReason??`, because the third case is real and
/// a double optional is a shape nobody reads correctly twice: `unarchivedByUser` leaves
/// the existing ending exactly where it is, and `promptSent` clears the archive reason
/// without touching the ending at all.
public enum ReasonChange: Hashable, Sendable {
    case set(EndedReason)
    case leave
}

/// What happens to an agent's archive reason when an event is applied.
public enum ArchiveChange: Hashable, Sendable {
    case set(Agent.ArchivedReason)
    case clear
    case leave
}

/// The whole of what an accepted event does to a record.
///
/// The reason an agent ended is carried here, worked out from the event, rather than
/// being passed alongside it by the caller. That is the point of this type: `move`
/// used to take an `endedReason:` parameter, so a caller could say `.stoppedByUser`
/// and hand it `.maxTokens`, and nothing anywhere checked that the two agreed. Now
/// there is nothing to disagree with.
///
/// `nil` from `applying` — rather than a `Transition` — still means the event must not
/// happen in this state, and the agent is then left entirely unchanged: its state, its
/// ending, its archive reason, its pick-up count, and when it was last active.
public struct Transition: Hashable, Sendable {
    public var next: AgentState
    public var endedReason: ReasonChange
    public var archivedReason: ArchiveChange
    /// Whether this ending is evidence the chat can reach the end of a turn without
    /// taking the daemon with it, which is the only question the count asks.
    public var clearsPickUpCount: Bool

    public init(next: AgentState,
                endedReason: ReasonChange = .leave,
                archivedReason: ArchiveChange = .leave,
                clearsPickUpCount: Bool = false) {
        self.next = next
        self.endedReason = endedReason
        self.archivedReason = archivedReason
        self.clearsPickUpCount = clearsPickUpCount
    }
}

extension AgentState {
    /// A turn ending, and what it does to the record.
    ///
    /// The one place `endTurn` is turned into `finished` and everything else into
    /// `stopped`, and the one place the pick-up rule is applied to an ordinary ending.
    private static func ending(_ reason: EndedReason) -> Transition {
        Transition(next: reason == .endTurn ? .finished : .stopped,
                   endedReason: .set(reason),
                   // Both arms above are settled, so the whole of the rule here is
                   // whether the daemon going is what ended it. See `Transition.
                   // clearsPickUpCount`.
                   clearsPickUpCount: reason != .daemonGone)
    }

    /// What this event does to an agent in this state, or nil when the event must not
    /// happen here.
    ///
    /// Returning nil rather than throwing keeps this pure and cheap to exhaust in
    /// tests, and every refusal here is a rule from the spec:
    ///
    /// - `finished` is reachable only by a turn ending in `endTurn` (FR-012).
    /// - Nothing reaches `archived` except by the user asking (FR-012).
    /// - Archiving a live agent is refused, because it must be stopped first (FR-013).
    /// - A prompt from any settled state picks the agent up rather than copying it
    ///   (FR-012b), archived included.
    ///
    /// The `endedReason` parameter is the agent's **existing** ending, and only
    /// `unarchivedByUser` reads it — to decide whether an unarchived agent goes back to
    /// `finished` or to `stopped`. It is no longer how a caller supplies a *new* reason
    /// (020 FR-011); new reasons come from the event, and are in the returned value.
    public func applying(_ event: AgentEvent, endedReason: EndedReason? = nil) -> Transition? {
        switch (self, event) {
        case (.running, .promptSent):
            return nil // A turn is already in flight.
        case (.starting, .promptSent):
            // A prompt arriving while an agent starts joins the queue rather than
            // beginning a turn of its own (FR-004). Refused here, in the table, and not
            // only by the daemon's `hasTurnInFlight` guard — a rule that exists in two
            // places is a rule with two chances to drift, and this is the one place a
            // person can read the whole of what may happen to an agent.
            return nil
        case (_, .promptSent):
            // Picked up where it was left. The archive reason goes because the agent is
            // no longer archived; the ending stays, because it is still how the last
            // turn ended until this one ends.
            return Transition(next: .running, archivedReason: .clear)

        case (.starting, .turnBegun):
            return Transition(next: .running)
        case (_, .turnBegun):
            // A turn can only begin out of a start. From `running` it would be a second
            // turn, and from the three settled states it would be a turn beginning with
            // no prompt behind it.
            return nil

        case (.running, .permissionAsked):
            return Transition(next: .waitingOnUser)
        case (_, .permissionAsked):
            return nil

        case (.waitingOnUser, .permissionAnswered):
            return Transition(next: .running)
        case (_, .permissionAnswered):
            return nil

        case (.running, .turnEnded(let reason)), (.waitingOnUser, .turnEnded(let reason)):
            return Self.ending(reason)
        case (_, .turnEnded):
            return nil

        case (.starting, .stoppedByUser), (.running, .stoppedByUser), (.waitingOnUser, .stoppedByUser):
            return Transition(next: .stopped, endedReason: .set(.cancelled),
                              clearsPickUpCount: true)
        case (_, .stoppedByUser):
            return nil

        // Every row the person's stop has, and no other: an agent's stop is that stop,
        // saying who made it.
        case (.starting, .stoppedByAgent), (.running, .stoppedByAgent), (.waitingOnUser, .stoppedByAgent):
            return Transition(next: .stopped, endedReason: .set(.stoppedByAgent),
                              clearsPickUpCount: true)
        case (_, .stoppedByAgent):
            return nil

        // Only from finished, which is the one place a blocked agent can be (039). The
        // daemon sends these only when the report is an open block; the table cannot
        // see the report, so it takes the daemon's word for that part.
        case (.finished, .stoppedWaitingByUser):
            return Transition(next: .stopped, endedReason: .set(.cancelled),
                              clearsPickUpCount: true)
        case (_, .stoppedWaitingByUser):
            return nil
        case (.finished, .stoppedWaitingByAgent):
            return Transition(next: .stopped, endedReason: .set(.stoppedByAgent),
                              clearsPickUpCount: true)
        case (_, .stoppedWaitingByAgent):
            return nil

        case (.starting, .processDied), (.running, .processDied), (.waitingOnUser, .processDied):
            return Transition(next: .stopped, endedReason: .set(.processDied),
                              clearsPickUpCount: true)
        case (_, .processDied):
            return nil

        case (.starting, .foundDead), (.running, .foundDead), (.waitingOnUser, .foundDead):
            // The one ending that never clears the pick-up count (020 FR-015). A chat
            // the daemon took down with it has said nothing about whether it can reach
            // the end of a turn, which is the only thing the count is evidence of.
            // This used to be an inline `if` in `DaemonCore.move`, defended by a
            // comment saying `recover` wrote the state directly so it could never clear
            // the count on its way past. It lives here so it holds on its own.
            return Transition(next: .stopped, endedReason: .set(.daemonGone),
                              clearsPickUpCount: false)
        case (_, .foundDead):
            return nil

        case (.starting, .archivedByUser), (.running, .archivedByUser),
             (.waitingOnUser, .archivedByUser):
            return nil // Stop it first.
        case (.archived, .archivedByUser):
            return nil
        case (_, .archivedByUser):
            return Transition(next: .archived, archivedReason: .set(.byUser))

        // Likewise the person's archive, row for row.
        case (.starting, .archivedByAgent), (.running, .archivedByAgent),
             (.waitingOnUser, .archivedByAgent):
            return nil // Stop it first.
        case (.archived, .archivedByAgent):
            return nil
        case (_, .archivedByAgent):
            return Transition(next: .archived, archivedReason: .set(.byAgent))

        case (.archived, .unarchivedByUser):
            // An archived agent with no recorded ending cannot be reached today — the
            // only ways into `archived` are from `finished` and `stopped`, which both
            // carry a reason. It becomes reachable the moment a record is hand-edited
            // or written by another build, and `stopped` with no reason breaks the
            // record's second invariant. `unrecognised` is the honest word: nothing
            // vouched for that ending, which is what it already means everywhere else.
            return Transition(next: endedReason == .endTurn ? .finished : .stopped,
                              endedReason: endedReason == nil ? .set(.unrecognised) : .leave,
                              archivedReason: .clear,
                              clearsPickUpCount: endedReason != .daemonGone)
        case (_, .unarchivedByUser):
            return nil
        }
    }
}
