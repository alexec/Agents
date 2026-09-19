import Foundation

/// Why a fire produced no agent.
///
/// This type is the point of the feature's third user story. Every safety rule here
/// works by refusing to act, so every safety rule is a way for the feature to fail
/// quietly: without a refusal on the record, a workflow skipping every fire looks
/// exactly like one whose trigger never matched, and the first thing anyone does is
/// edit the file that was never the problem.
public enum WorkflowRefusal: Codable, Hashable, Sendable {
    /// The chain that led here is already as deep as it is allowed to get.
    case chainTooDeep(depth: Int)
    /// The last run has not finished. A second is skipped, never queued.
    case runInFlight
    /// This workflow, or its project, is paused.
    case paused
    /// The file could not be read.
    case unreadable(String)
    /// Every trigger it has names something this version does not know.
    case triggerNotSupported(name: String)
    /// `triggering` mode, and the agent can no longer take a prompt.
    case agentUnavailable
    /// `triggering` mode, fired by a clock or by hand, so there is no agent to resume.
    case noTriggeringAgent
    /// The time came and went while nothing was running to notice.
    case missedWhileClosed
    /// The project folder is not there any more.
    case folderGone

    /// Said the way the app says a refusal everywhere else: a sentence, because an
    /// agent may be reading it and a person certainly is.
    public var message: String {
        switch self {
        case .chainTooDeep(let depth): return "this chain is already \(depth) deep"
        case .runInFlight: return "a run is still going"
        case .paused: return "it is paused"
        case .unreadable(let detail): return detail
        case .triggerNotSupported(let name): return "\"\(name)\" is not something this version can watch for"
        case .agentUnavailable: return "the agent it would have resumed is gone"
        case .noTriggeringAgent: return "nothing triggered it, so there was no agent to resume"
        case .missedWhileClosed: return "the app was closed"
        case .folderGone: return "the project folder is not there"
        }
    }

    /// Whether somebody has to do something, or whether this sorts itself out.
    ///
    /// Only the first kind earns colour on the project page. Colouring every refusal
    /// would make the page shout about a workflow skipping one fire, and would spend
    /// the one signal this app reserves for an agent waiting on an answer.
    public var needsAPerson: Bool {
        switch self {
        case .chainTooDeep, .unreadable, .folderGone: return true
        case .runInFlight, .paused, .triggerNotSupported, .agentUnavailable,
             .noTriggeringAgent, .missedWhileClosed: return false
        }
    }

    /// Whether two refusals are the same reason, for the purpose of collapsing repeats.
    /// The depth in `chainTooDeep` is not part of it: three identical loop refusals are
    /// one thing that keeps happening, not three things.
    public func isSameReason(as other: WorkflowRefusal) -> Bool {
        switch (self, other) {
        case (.chainTooDeep, .chainTooDeep), (.runInFlight, .runInFlight),
             (.paused, .paused), (.agentUnavailable, .agentUnavailable),
             (.noTriggeringAgent, .noTriggeringAgent), (.missedWhileClosed, .missedWhileClosed),
             (.folderGone, .folderGone):
            return true
        case (.unreadable(let a), .unreadable(let b)): return a == b
        case (.triggerNotSupported(let a), .triggerNotSupported(let b)): return a == b
        default: return false
        }
    }
}

/// What the last fire produced.
///
/// Only the latest is kept. A full run history was considered and left out: every run
/// that actually happens is already an agent, and the agent list shows those.
public enum WorkflowOutcome: Codable, Hashable, Sendable {
    case ran(agentID: UUID, at: Date)
    /// `repeats` is how a fortnight away reads as one line rather than a fortnight of
    /// them. It counts consecutive refusals for the same reason.
    case refused(WorkflowRefusal, at: Date, repeats: Int)

    public var at: Date {
        switch self {
        case .ran(_, let at), .refused(_, let at, _): return at
        }
    }

    /// The outcome after this one arrives: a refusal for the same reason as the one
    /// already recorded counts up, and anything else starts again at one.
    public func following(_ previous: WorkflowOutcome?) -> WorkflowOutcome {
        guard case .refused(let refusal, let at, _) = self,
              case .refused(let old, _, let count) = previous,
              refusal.isSameReason(as: old) else { return self }
        return .refused(refusal, at: at, repeats: count + 1)
    }

    /// The line the project page puts under a workflow's name.
    public var summary: String {
        switch self {
        case .ran: return "Ran"
        case .refused(let refusal, _, let repeats):
            let many = repeats > 1
            if case .missedWhileClosed = refusal {
                return many ? "Missed \(repeats) times — \(refusal.message)"
                            : "Missed — \(refusal.message)"
            }
            return many ? "Did not run \(repeats) times — \(refusal.message)"
                        : "Did not run — \(refusal.message)"
        }
    }
}

extension Workflow {
    /// How deep a chain is allowed to get before a fire is refused.
    ///
    /// A fixed three, and deliberately not settable per workflow or per project. The
    /// limit exists to stop a runaway, and a runaway able to raise its own limit is not
    /// stopped by it.
    public static let chainDepthLimit = 3

    /// Whether this workflow may fire, and why not when it may not.
    ///
    /// Pure: workflow, its state, the project's pause, the proposed depth, the clock.
    /// No file system, no actor, no clock of its own. That is what makes every refusal
    /// rule a table test rather than something needing a daemon to demonstrate — and if
    /// a refusal ever needs one, the decision has leaked out of here and belongs back.
    public func refusalIfBlocked(isPaused: Bool, projectIsPaused: Bool,
                                 isRunning: Bool, depth: Int,
                                 folderExists: Bool = true,
                                 triggeringAgentIsUsable: Bool? = nil) -> WorkflowRefusal? {
        if case .unreadable(let detail) = problem { return .unreadable(detail) }
        if !folderExists { return .folderGone }
        if isPaused || projectIsPaused { return .paused }
        if isRunning { return .runInFlight }
        if depth > Self.chainDepthLimit { return .chainTooDeep(depth: Self.chainDepthLimit) }
        if let problem {
            switch problem {
            case .triggerNotSupported(let name), .unsupportedMode(let name):
                return .triggerNotSupported(name: name)
            case .unreadable(let detail):
                return .unreadable(detail)
            }
        }
        if mode == .triggering {
            guard let usable = triggeringAgentIsUsable else { return .noTriggeringAgent }
            guard usable else { return .agentUnavailable }
        }
        return nil
    }
}

/// One firing of one workflow, while it is in flight.
///
/// Not a history: it exists to hold the depth its children inherit and to be the thing
/// a second fire collides with. Once the agent has finished, what is left is an
/// outcome and an agent, both of which are shown elsewhere.
public struct WorkflowRun: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var workflowID: String
    public var folder: URL
    public var trigger: WorkflowTrigger
    public var triggeringAgentID: UUID?
    /// How far this is from something a person or a clock did. Zero for a schedule, for
    /// Run now, and for an agent nobody automated; one more for each step after that.
    public var depth: Int
    public var agentID: UUID?
    public var startedAt: Date

    public init(id: UUID = UUID(), workflowID: String, folder: URL,
                trigger: WorkflowTrigger, triggeringAgentID: UUID? = nil,
                depth: Int = 0, agentID: UUID? = nil, startedAt: Date = Date()) {
        self.id = id
        self.workflowID = workflowID
        self.folder = Project.standardize(folder)
        self.trigger = trigger
        self.triggeringAgentID = triggeringAgentID
        self.depth = depth
        self.agentID = agentID
        self.startedAt = startedAt
    }
}
