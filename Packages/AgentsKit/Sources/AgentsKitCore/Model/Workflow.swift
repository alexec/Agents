import Foundation

/// Why a workflow cannot run, when the reason is the file itself.
///
/// The line between these two is the whole care of it. A file we cannot read is broken
/// and somebody has to fix it. A file we can read but cannot act on is a file from the
/// future, and the right response is to leave it alone. They get different rows on the
/// project page and different words, because they ask different things of the reader.
public enum WorkflowProblem: Codable, Hashable, Sendable {
    /// The front matter, or the body, could not be read. Says where.
    case unreadable(String)
    /// Every trigger in it names something this version does not know.
    case triggerNotSupported(String)
    /// The `agent:` value names a mode this version does not know.
    case unsupportedMode(String)

    public var message: String {
        switch self {
        case .unreadable(let detail): return detail
        case .triggerNotSupported(let name):
            return "Waits for \"\(name)\", which this version does not know about yet"
        case .unsupportedMode(let name):
            return "Runs \"\(name)\", which this version does not know about yet"
        }
    }

    /// Whether this is something the reader has to fix, as against something to leave
    /// alone until the app catches up. Only the first earns the colour.
    public var needsAPerson: Bool {
        if case .unreadable = self { return true }
        return false
    }
}

/// One workflow: a prompt that runs itself.
///
/// The file in the project is the whole of the definition, which is what lets a
/// project's standing arrangements travel with its code, be reviewed in a pull request
/// and be edited by anyone with an editor. Nothing about running it is written back.
public struct Workflow: Codable, Hashable, Sendable, Identifiable {
    /// The file name without its extension. Identity, which is why renaming a workflow
    /// is deletion and creation rather than a rename: the pause and the standing agent
    /// belong to the name.
    public var workflowID: String
    /// The project it is in, standardised the way every other folder in the app is.
    public var folder: URL
    /// What to call it. The file may say; otherwise the file name does.
    public var name: String
    /// What makes it run. At least one, or the file is unreadable.
    public var triggers: [WorkflowTrigger]
    /// Which agent gets the prompt.
    public var mode: WorkflowMode
    /// The body, verbatim. This is sent as the prompt with no templating.
    public var prompt: String
    /// Set when the file could not be fully understood. `nil` on a good file.
    public var problem: WorkflowProblem?
    /// Front-matter keys this version does not know, kept so that writing the file back
    /// does not quietly delete what a later version put there.
    public var unknownFields: [String: JSONValue]

    /// Unique across projects, so one window showing two of them cannot collide.
    public var id: String { folder.path + "/" + workflowID }

    public init(workflowID: String, folder: URL, name: String? = nil,
                triggers: [WorkflowTrigger] = [], mode: WorkflowMode = .new,
                prompt: String = "", problem: WorkflowProblem? = nil,
                unknownFields: [String: JSONValue] = [:]) {
        self.workflowID = workflowID
        self.folder = Project.standardize(folder)
        self.name = name ?? Self.defaultName(for: workflowID)
        self.triggers = triggers
        self.mode = mode
        self.prompt = prompt
        self.problem = problem
        self.unknownFields = unknownFields
    }

    /// A file name turned into something worth reading: `morning-build-check` becomes
    /// `Morning build check`.
    public static func defaultName(for workflowID: String) -> String {
        let words = workflowID.split(whereSeparator: { $0 == "-" || $0 == "_" })
        guard let first = words.first else { return workflowID }
        return ([first.capitalized] + words.dropFirst().map(String.init)).joined(separator: " ")
    }

    /// The triggers this version can actually act on.
    public var supportedTriggers: [WorkflowTrigger] { triggers.filter(\.isSupported) }

    /// The schedules it runs on, of which there is usually one and may be none.
    public var schedules: [WorkflowSchedule] { triggers.compactMap(\.schedule) }

    /// Whether anything could make this fire on its own.
    ///
    /// A workflow with no supported trigger is still runnable by hand — that is FR-012,
    /// and it is what makes a file from the future something you can try rather than
    /// something you can only read.
    public var canFire: Bool {
        guard problem == nil else { return false }
        return !supportedTriggers.isEmpty
    }

    /// What it is, in one line, in the words a person would use.
    ///
    /// One renderer, read by the project-page row and by what an agent's write is told
    /// it made. Two would drift, and what the agent reports would stop being what the
    /// person later sees.
    public var summary: String {
        if let problem { return problem.message }
        let supported = supportedTriggers
        guard !supported.isEmpty else {
            return triggers.first?.summary ?? "Nothing makes this run"
        }
        let triggerPart = supported.map(\.summary).joined(separator: ", and ")
        return "\(triggerPart), \(mode.summary)"
    }

    /// The next time a clock makes this fire, across all of its schedules.
    public func nextDue(after date: Date, calendar: Calendar = .current) -> Date? {
        guard problem == nil else { return nil }
        return schedules.compactMap { $0.nextDue(after: date, calendar: calendar) }.min()
    }

    /// Whether an agent event should fire this workflow.
    public func responds(to event: WorkflowAgentEvent) -> Bool {
        problem == nil && triggers.contains { $0.matches(event) }
    }

    /// Whether another workflow's run completing should fire this one.
    public func respondsToCompletion(of otherID: String) -> Bool {
        guard problem == nil else { return false }
        return triggers.contains { trigger in
            guard case .workflowCompleted(let id) = trigger else { return false }
            // A workflow watching every workflow must not watch itself: that is a loop
            // with nothing in it, and the depth limit should not have to be what stops
            // something this obvious.
            guard otherID != workflowID else { return false }
            return id == nil || id == otherID
        }
    }
}

/// A workflow, plus what the app knows about it that its file cannot say.
///
/// Resolved by the daemon and sent whole, for the reason `ProjectSummary` is: two
/// windows cannot then disagree, and one that missed a notification is put right by the
/// next rather than drifting.
public struct WorkflowSummary: Codable, Hashable, Sendable, Identifiable {
    public var workflow: Workflow
    /// Put away by the person. Archived workflows are still listed — under their own
    /// heading, where they can be brought back — and never run.
    public var isArchived: Bool
    /// Which ceiling this one is past, if any: listed, and inert until something else
    /// is archived. Resolved by the daemon because it is a fact about every project at
    /// once rather than about this workflow, and two windows must not count differently.
    public var overLimit: WorkflowLimit?
    /// When a clock will next make it run. `nil` when nothing will.
    public var nextFireAt: Date?
    /// What happened the last time it was asked to run. The only evidence a refused
    /// fire leaves, which is why it is here rather than derived.
    public var lastOutcome: WorkflowOutcome?
    public var isRunning: Bool

    public var id: String { workflow.id }
    public var folder: URL { workflow.folder }
    public var workflowID: String { workflow.workflowID }

    /// Lenient about `isArchived` for the same reason `WorkflowState` is: a window and
    /// a daemon of different vintages should disagree about a flag, not fail.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        workflow = try c.decode(Workflow.self, forKey: .workflow)
        isArchived = try c.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
        overLimit = try c.decodeIfPresent(WorkflowLimit.self, forKey: .overLimit)
        nextFireAt = try c.decodeIfPresent(Date.self, forKey: .nextFireAt)
        lastOutcome = try c.decodeIfPresent(WorkflowOutcome.self, forKey: .lastOutcome)
        isRunning = try c.decodeIfPresent(Bool.self, forKey: .isRunning) ?? false
    }

    public init(workflow: Workflow, isArchived: Bool = false,
                overLimit: WorkflowLimit? = nil, nextFireAt: Date? = nil,
                lastOutcome: WorkflowOutcome? = nil, isRunning: Bool = false) {
        self.workflow = workflow
        self.isArchived = isArchived
        self.overLimit = overLimit
        self.nextFireAt = nextFireAt
        self.lastOutcome = lastOutcome
        self.isRunning = isRunning
    }

    /// Whether this row is the one thing on the page that wants a person.
    ///
    /// The app's rule is that grey is everything and colour means somebody is needed.
    /// A refusal that will resolve itself is information; a refusal that will keep
    /// happening until somebody acts is the only kind that earns it.
    public var needsAPerson: Bool {
        // Nothing put away is anybody's problem any more, including a file that cannot
        // be read: archiving it is how you say so.
        if isArchived { return false }
        // Nothing resolves this one on its own: it stays over the limit until somebody
        // archives or removes another.
        if overLimit != nil { return true }
        if workflow.problem?.needsAPerson == true { return true }
        if case .refused(let refusal, _, _) = lastOutcome { return refusal.needsAPerson }
        return false
    }
}
