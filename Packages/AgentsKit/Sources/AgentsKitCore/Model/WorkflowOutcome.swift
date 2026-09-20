import Foundation

/// A ceiling on how many workflows may run, and which one has been reached.
///
/// Two of them, and they are different worries. The per-project one is about a project
/// filling up: an agent can write a workflow without asking anybody, so three is what
/// stops one project's folder becoming a queue nobody reviewed. The total one is about
/// the machine: ten running workflows is already more unattended agents than a person
/// can read after a weekend away, and the count has to hold across projects or ten
/// projects of three is thirty.
///
/// Both are fixed, and deliberately not settable — the same reasoning as the chain
/// depth limit, which this sits beside. A ceiling something can raise for itself is not
/// a ceiling.
public enum WorkflowLimit: String, Codable, Hashable, Sendable {
    /// Three live workflows in one project.
    case project
    /// Ten live workflows across every project.
    case total

    public var allowed: Int {
        switch self {
        case .project: return 3
        case .total: return 10
        }
    }

    /// What a person is told on the row, and an agent in a refusal.
    public var message: String {
        switch self {
        case .project: return "this project already runs its \(allowed) workflows"
        case .total: return "\(allowed) workflows are already running, across every project"
        }
    }

    /// What to do about it, which is the same move in both cases and worth saying
    /// because "archive" is not the first thing anybody reaches for.
    public var remedy: String {
        switch self {
        case .project: return "Archive another in this project to let it run"
        case .total: return "Archive one, in any project, to let it run"
        }
    }

    /// The same fact as a sentence of its own, for a row or a heading rather than the
    /// tail of a refusal. One renderer either way, so the page and the agent cannot
    /// come to describe the same ceiling differently.
    public var sentence: String {
        switch self {
        case .project: return "This project already runs its \(allowed) workflows"
        case .total: return "\(allowed) workflows are already running, across every project"
        }
    }
}

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
    /// The person put it away. Unlike every other refusal here, this one is a decision
    /// rather than a circumstance, which is why it is checked before all of them.
    case archived
    /// A ceiling has been reached — this project's, or every project's together.
    case overLimit(WorkflowLimit)
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
    /// The day's spending limit has been reached, so nothing new may start.
    case dayLimitReached

    /// Said the way the app says a refusal everywhere else: a sentence, because an
    /// agent may be reading it and a person certainly is.
    public var message: String {
        switch self {
        case .chainTooDeep(let depth): return "this chain is already \(depth) deep"
        case .runInFlight: return "a run is still going"
        case .archived: return "it is archived"
        case .overLimit(let limit): return limit.message
        case .unreadable(let detail): return detail
        case .triggerNotSupported(let name): return "\"\(name)\" is not something this version can watch for"
        case .agentUnavailable: return "the agent it would have resumed is gone"
        case .noTriggeringAgent: return "nothing triggered it, so there was no agent to resume"
        case .missedWhileClosed: return "the app was closed"
        case .folderGone: return "the project folder is not there"
        case .dayLimitReached: return "the day's spending limit has been reached"
        }
    }

    /// Whether somebody has to do something, or whether this sorts itself out.
    ///
    /// Only the first kind earns colour on the project page. Colouring every refusal
    /// would make the page shout about a workflow skipping one fire, and would spend
    /// the one signal this app reserves for an agent waiting on an answer.
    public var needsAPerson: Bool {
        switch self {
        // Over the limit earns the colour: unlike a skipped fire, this one keeps
        // happening until somebody archives or removes another workflow.
        case .chainTooDeep, .unreadable, .folderGone, .overLimit: return true
        // Grey, not coloured: midnight resolves it with nobody doing anything, which
        // is the same shape as a fire missed while the app was closed.
        case .runInFlight, .archived, .triggerNotSupported, .agentUnavailable,
             .noTriggeringAgent, .missedWhileClosed, .dayLimitReached: return false
        }
    }

    /// Whether two refusals are the same reason, for the purpose of collapsing repeats.
    /// The depth in `chainTooDeep` is not part of it: three identical loop refusals are
    /// one thing that keeps happening, not three things.
    public func isSameReason(as other: WorkflowRefusal) -> Bool {
        switch (self, other) {
        case (.chainTooDeep, .chainTooDeep), (.runInFlight, .runInFlight),
             (.archived, .archived), (.agentUnavailable, .agentUnavailable),
             (.noTriggeringAgent, .noTriggeringAgent), (.missedWhileClosed, .missedWhileClosed),
             (.folderGone, .folderGone), (.dayLimitReached, .dayLimitReached):
            return true
        case (.overLimit(let a), .overLimit(let b)): return a == b
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
    /// Pure: workflow, its state, the proposed depth, the clock. No file system, no
    /// actor, no clock of its own. That is what makes every refusal rule a table test
    /// rather than something needing a daemon to demonstrate — and if a refusal ever
    /// needs one, the decision has leaked out of here and belongs back.
    public func refusalIfBlocked(isRunning: Bool, depth: Int,
                                 isArchived: Bool = false,
                                 overLimit: WorkflowLimit? = nil,
                                 dayLimitReached: Bool = false,
                                 folderExists: Bool = true,
                                 triggeringAgentIsUsable: Bool? = nil) -> WorkflowRefusal? {
        // First, and ahead even of a file that cannot be read: somebody has already
        // said they do not want this one, and that answers every other question.
        if isArchived { return .archived }
        if case .unreadable(let detail) = problem { return .unreadable(detail) }
        if !folderExists { return .folderGone }
        // After the file's own problems, because "this one is broken" is the more
        // useful thing to hear about a broken file, and before the rest, because no
        // amount of unpausing will help.
        if let overLimit { return .overLimit(overLimit) }
        // After archived and paused, and after the file's own problems: a workflow
        // the person put away is refused for that reason, not for the budget. It
        // does not pause the workflow or alter its schedule — it refused one fire
        // and will try again when it is next due.
        if dayLimitReached { return .dayLimitReached }
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
