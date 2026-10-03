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
    /// What the file says about how its agent should be started.
    ///
    /// Part of the file, and therefore part of the repository, which is the difference
    /// between this and `isArchived` or the standing agent: those are the app's own
    /// bookkeeping and are deliberately kept out of it, because writing them back would
    /// put the app's bookkeeping into a history nobody wants to review. How much an
    /// agent is allowed to do while nobody is watching is not bookkeeping.
    public var settings: WorkflowSettings
    /// The least time from the start of one run to the start of the next, from the
    /// file's `cooldown:` (#103). A trigger inside it is held, and the latest held one
    /// runs once when it ends; `nil` is no cooldown, as before.
    public var cooldown: TimeInterval?
    /// Where the Enabled switch starts, from the file's `enabled:` (#42): `false` is a
    /// workflow checked in for somebody to turn on when they are ready. `nil` is a file
    /// that does not say, which starts on. Once anybody moves the switch, their choice
    /// is kept by the app and this no longer decides.
    public var enabled: Bool?

    /// Unique across projects, so one window showing two of them cannot collide.
    public var id: String { folder.path + "/" + workflowID }

    public init(workflowID: String, folder: URL, name: String? = nil,
                triggers: [WorkflowTrigger] = [], mode: WorkflowMode = .new,
                prompt: String = "", problem: WorkflowProblem? = nil,
                unknownFields: [String: JSONValue] = [:],
                settings: WorkflowSettings = WorkflowSettings(),
                cooldown: TimeInterval? = nil, enabled: Bool? = nil) {
        self.cooldown = cooldown
        self.enabled = enabled
        self.workflowID = workflowID
        self.folder = Project.standardize(folder)
        self.name = name ?? Self.defaultName(for: workflowID)
        self.triggers = triggers
        self.mode = mode
        self.prompt = prompt
        self.problem = problem
        self.unknownFields = unknownFields
        self.settings = settings
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
        var base = "\(triggerPart), \(mode.summary)"
        if let cooldownPart { base += ", \(cooldownPart)" }
        // A `triggering` workflow never starts an agent — it resumes the one that set
        // it off — so it never applies a setting, and a row saying "in plan mode" about
        // one would be a false statement in the one place this feature exists to make
        // true. The settings are still in the file and still shown on the page, which
        // says the longer version; what must not happen is the row asserting them.
        guard mode != .triggering, let settingsPart = settings.summary else { return base }
        return "\(base), \(settingsPart)"
    }

    /// The cooldown as the row says it: `at most once every 15 minutes`.
    public var cooldownPart: String? {
        cooldown.map { "at most once every \(WorkflowCooldown.words($0))" }
    }

    /// When a run started at `lastStarted` lets the next one start, if that is later
    /// than `now`.
    public func cooldownEnds(after lastStarted: Date?, now: Date) -> Date? {
        guard let cooldown, let lastStarted else { return nil }
        let end = lastStarted.addingTimeInterval(cooldown)
        return end > now ? end : nil
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
    /// Switched on or off by the person (#100), and on unless they said otherwise.
    /// Unlike archiving, an off workflow stays where it is on the list and keeps its
    /// place under the ceiling, so turning one off for an afternoon moves nothing else;
    /// none of its triggers fire, and Run now still runs it.
    public var isEnabled: Bool
    /// Which ceiling this one is past, if any: listed, and inert until something else
    /// is approved, archived or removed — `.project` for a waiting one past the three
    /// a project may have waiting (#132), `.total` for an approved one past the ten. Resolved by the daemon because it is a fact about every project at
    /// once rather than about this workflow, and two windows must not count differently.
    public var overLimit: WorkflowLimit?
    /// When a clock will next make it run. `nil` when nothing will.
    public var nextFireAt: Date?
    /// The same, for each trigger in the file's order (#98): a time for each schedule
    /// and `nil` for the rest, or empty when nothing will run it. Resolved here, by the
    /// host's clock, because a server's day may not be the window's.
    public var nextFireAtByTrigger: [Date?]
    /// What happened the last time it was asked to run. The only evidence a refused
    /// fire leaves, which is why it is here rather than derived.
    public var lastOutcome: WorkflowOutcome?
    /// The event that caused `lastOutcome`, when an event did (042 FR-030): what the
    /// row's "on workflow.completed workflow nightly" links to.
    public var causingEvent: EventPosition?
    public var causingEventName: String?
    public var isRunning: Bool
    /// Set while the file is not the one the person approved: new since they last
    /// looked, or changed. Nothing fires until they approve it.
    public var awaitingApproval: WorkflowApproval?
    /// When it last started an agent, and what set that run off (#98). Apart from
    /// `lastOutcome`, which a refusal overwrites: a workflow turned off for a week has
    /// a week of refusals on top of the last time it actually ran.
    public var lastFiredAt: Date?
    public var lastFiredBy: WorkflowCause?
    /// When its cooldown lets the next run start, while that is still to come (#103).
    /// By the host's clock, as the next times are.
    public var cooldownEndsAt: Date?
    /// Whether a trigger is being held for when the cooldown ends, or the run in flight
    /// does: the one run the fires that arrived meanwhile collapse into.
    public var holdsAFire: Bool
    /// Why it is off, while it is (#124): what the page says beside the switch, so a
    /// workflow that started off reads as waiting for somebody rather than as broken.
    public var offReason: WorkflowOffReason?

    public var id: String { workflow.id }
    public var folder: URL { workflow.folder }
    public var workflowID: String { workflow.workflowID }

    public init(workflow: Workflow, isArchived: Bool = false, isEnabled: Bool = true,
                overLimit: WorkflowLimit? = nil, nextFireAt: Date? = nil,
                lastOutcome: WorkflowOutcome? = nil, isRunning: Bool = false,
                causingEvent: EventPosition? = nil, causingEventName: String? = nil,
                awaitingApproval: WorkflowApproval? = nil,
                lastFiredAt: Date? = nil, lastFiredBy: WorkflowCause? = nil,
                nextFireAtByTrigger: [Date?] = [],
                cooldownEndsAt: Date? = nil, holdsAFire: Bool = false,
                offReason: WorkflowOffReason? = nil) {
        self.offReason = offReason
        self.cooldownEndsAt = cooldownEndsAt
        self.holdsAFire = holdsAFire
        self.nextFireAtByTrigger = nextFireAtByTrigger
        self.awaitingApproval = awaitingApproval
        self.isEnabled = isEnabled
        self.lastFiredAt = lastFiredAt
        self.lastFiredBy = lastFiredBy
        self.causingEvent = causingEvent
        self.causingEventName = causingEventName
        self.workflow = workflow
        self.isArchived = isArchived
        self.overLimit = overLimit
        self.nextFireAt = nextFireAt
        self.lastOutcome = lastOutcome
        self.isRunning = isRunning
    }

    /// Waiting for approval behind the three a project may have waiting (#132): listed
    /// and inert, with no Approve until one ahead of it is approved or removed.
    public var waitsItsTurn: Bool { awaitingApproval != nil && overLimit == .project }

    /// Whether Approve is offered: waiting, and one of the ones allowed to wait.
    public var canBeApproved: Bool { awaitingApproval != nil && !waitsItsTurn }

    /// Whether this row is the one thing on the page that wants a person.
    ///
    /// The app's rule is that grey is everything and colour means somebody is needed.
    /// A refusal that will resolve itself is information; a refusal that will keep
    /// happening until somebody acts is the only kind that earns it.
    public var needsAPerson: Bool {
        // Nothing put away is anybody's problem any more, including a file that cannot
        // be read: archiving it is how you say so.
        if isArchived { return false }
        // Nothing runs until somebody has looked at it.
        if awaitingApproval != nil { return true }
        // Nothing resolves this one on its own: it stays over the limit until somebody
        // archives or removes another.
        if overLimit != nil { return true }
        if workflow.problem?.needsAPerson == true { return true }
        if case .refused(let refusal, _, _) = lastOutcome { return refusal.needsAPerson }
        return false
    }

    /// What a page says about a workflow turned off (#100), on the Mac and the phone
    /// alike: that nothing fires it, that it still holds its place under the ceiling,
    /// and that Run now still works, the three things that set it apart from archived.
    public static let turnedOffSentence = "Turned off — none of its triggers run it. "
        + "It still counts towards the workflow limits, "
        + "and Run now still runs it"

    /// The same, led by why it is off when that is something the person is waiting on
    /// (#124). The Remote and the web page say the same words.
    public var turnedOffSentence: String {
        guard let why = offReason?.sentence else { return Self.turnedOffSentence }
        return why + ". None of its triggers run it until it is turned on. "
            + "It still counts towards the workflow limits, "
            + "and Run now still runs it"
    }

    /// Read leniently: a daemon from before #100 sends no `isEnabled`, and an outcome
    /// this version does not know (a refusal added later) costs the outcome rather than
    /// the whole project's list.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        workflow = try c.decode(Workflow.self, forKey: .workflow)
        isArchived = try c.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        overLimit = try? c.decodeIfPresent(WorkflowLimit.self, forKey: .overLimit)
        nextFireAt = try c.decodeIfPresent(Date.self, forKey: .nextFireAt)
        nextFireAtByTrigger = (try? c.decodeIfPresent([Date?].self, forKey: .nextFireAtByTrigger)) ?? []
        lastOutcome = (try? c.decodeIfPresent(WorkflowOutcome.self, forKey: .lastOutcome)) ?? nil
        causingEvent = try? c.decodeIfPresent(EventPosition.self, forKey: .causingEvent)
        causingEventName = try c.decodeIfPresent(String.self, forKey: .causingEventName)
        isRunning = try c.decodeIfPresent(Bool.self, forKey: .isRunning) ?? false
        awaitingApproval = try? c.decodeIfPresent(WorkflowApproval.self, forKey: .awaitingApproval)
        lastFiredAt = try c.decodeIfPresent(Date.self, forKey: .lastFiredAt)
        lastFiredBy = (try? c.decodeIfPresent(WorkflowCause.self, forKey: .lastFiredBy)) ?? nil
        cooldownEndsAt = try c.decodeIfPresent(Date.self, forKey: .cooldownEndsAt)
        holdsAFire = try c.decodeIfPresent(Bool.self, forKey: .holdsAFire) ?? false
        offReason = (try? c.decodeIfPresent(WorkflowOffReason.self, forKey: .offReason)) ?? nil
    }

    /// What its cooldown is doing, in one sentence, for the pages that show triggers
    /// (#103): how long it is, when it ends if it has not, and whether a fire is held
    /// for then. `nil` without a cooldown.
    public func cooldownSentence(formatting time: (Date) -> String) -> String? {
        guard let cooldown = workflow.cooldown else { return nil }
        var sentence = "Cooldown \(WorkflowCooldown.words(cooldown)): at most one run starts in any \(WorkflowCooldown.words(cooldown))"
        if let end = cooldownEndsAt {
            sentence += holdsAFire
                ? ". Cooling down until \(time(end)), then it runs once for what came in meanwhile"
                : ". Cooling down until \(time(end))"
        } else if holdsAFire {
            sentence += ". It runs once more for what came in while this run was going"
        }
        return sentence
    }
}

/// Why a workflow is off (#124). The page leads with it, so one that started off is
/// read as waiting for somebody to turn it on rather than as something gone wrong.
public enum WorkflowOffReason: String, Codable, Hashable, Sendable {
    /// Its file says `enabled: false` and nobody has turned it on yet (#42).
    case file
    /// An agent wrote it through manage_workflows, and new ones start off so the
    /// person turns them on knowingly.
    case writtenByAgent
    /// An agent turned it off, and may turn it back on.
    case agent
    /// The person turned it off.
    case person

    /// What the page says first. `nil` for the person's own switch: they know.
    public var sentence: String? {
        switch self {
        case .file: "Off: its file asks to start off. Turn it on when you are ready"
        case .writtenByAgent: "Off: written by an agent. Turn it on when you are ready"
        case .agent: "Off: an agent turned it off"
        case .person: nil
        }
    }
}

/// What set a workflow's run off (#98): a person, with Run now, or one of its triggers.
public enum WorkflowCause: Codable, Hashable, Sendable {
    case byHand
    case trigger(WorkflowTrigger)
}

/// What a workflow waiting for approval is waiting on (security review).
///
/// The digest is of the file as the daemon read it, and it is what Approve sends back,
/// so what gets approved is exactly what the person was shown: a file changed between
/// their looking and their clicking is still waiting afterwards.
public struct WorkflowApproval: Codable, Hashable, Sendable {
    public var digest: String
    /// Never approved before, as opposed to changed since it was.
    public var isNew: Bool

    public init(digest: String, isNew: Bool) {
        self.digest = digest
        self.isNew = isNew
    }
}
