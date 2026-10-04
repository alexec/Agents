import Foundation

/// What an event is about: the part of its name before the dot.
public enum EventSubject: String, Codable, Hashable, Sendable, CaseIterable {
    case agent
    case workflow
    case branch
    case lease
    case mac
    case person
    case cost
    case server
    case custom

    public init?(name: String) {
        guard let dot = name.firstIndex(of: ".") else { return nil }
        self.init(rawValue: String(name[..<dot]))
    }

    /// Monochrome, and never tinted: an event is a fact, not a state (042 wireframes §5).
    public var glyph: String {
        switch self {
        case .agent: return "●"
        case .workflow: return "⟳"
        case .branch: return "⎇"
        case .mac, .person, .lease, .cost, .server: return "⌘"
        case .custom: return "✦"
        }
    }

    /// The capsule on the events page that shows it.
    public var group: EventGroup {
        switch self {
        case .agent: return .agents
        case .workflow: return .workflows
        case .branch: return .branches
        case .mac, .person, .lease, .cost, .server: return .mac
        case .custom: return .custom
        }
    }
}

/// The page's five filter capsules (042 FR-028, wireframes §1). Several subjects about
/// the machine and the person share one, because to the person they are all "This Mac".
public enum EventGroup: String, Codable, Hashable, Sendable, CaseIterable {
    case agents
    case workflows
    case branches
    case mac
    case custom

    public var title: String {
        switch self {
        case .agents: return "Agents"
        case .workflows: return "Workflows"
        case .branches: return "Branches"
        case .mac: return "This Mac"
        case .custom: return "Custom"
        }
    }

    public var subjects: [EventSubject] { EventSubject.allCases.filter { $0.group == self } }
}

/// Whose events of a kind are: the Mac's, a project's, or either.
public enum EventScopeKind: String, Codable, Hashable, Sendable {
    case mac
    case project
    case either
}

/// One entry in the catalogue.
public struct EventKind: Hashable, Sendable {
    public var name: String
    public var scope: EventScopeKind
    /// The details it carries, which are also the keys a wait or a trigger may narrow
    /// it by, with what each can hold (073). `agent_title` rides along with `agent` and
    /// is not listed: it is for reading, not matching.
    public var detailDescriptions: [EventDetail]
    /// What it means, in the one sentence every place that lists it uses (FR-024).
    public var meaning: String
    /// Today's trigger names that answer to it (FR-022).
    public var aliases: [String]

    public var subject: EventSubject { EventSubject(name: name)! }

    /// The keys of the details it carries.
    public var details: [String] { detailDescriptions.map(\.key) }

    public func detail(_ key: String) -> EventDetail? {
        detailDescriptions.first { $0.key == key }
    }

    init(_ name: String, _ scope: EventScopeKind, _ details: [EventDetail], _ meaning: String,
         aliases: [String] = []) {
        self.name = name
        self.scope = scope
        self.detailDescriptions = details
        self.meaning = meaning
        self.aliases = aliases
    }
}

/// Every event the app raises, in one table (042 FR-003, contracts/catalogue.md).
///
/// The wait tool's list, the workflow tool's description, the workflow file parser and
/// the events page all read this, so an agent can wait on exactly what a workflow can
/// trigger on, described in the same words. `custom.<name>` is a family rather than an
/// entry: anything under it is an agent's to name.
public enum EventCatalogue {
    public static let all: [EventKind] = [
        EventKind("agent.started", .project, about(), "An agent in this project started working."),
        EventKind("agent.finished", .project, about(outcome, afterwards),
                  "An agent in this project ended a turn having done its work.", aliases: ["agent-finished"]),
        EventKind("agent.asked_permission", .project, about(),
                  "An agent in this project is asking for permission.", aliases: ["agent-asked-permission"]),
        EventKind("agent.asked_form", .project, about(),
                  "An agent in this project raised a form to fill in.", aliases: ["agent-asked-form"]),
        EventKind("agent.blocked", .project, about(EventDetail("waiting_on")),
                  "An agent in this project ended its turn waiting on something."),
        EventKind("agent.stopped", .project, about(stoppedBy),
                  "An agent in this project was stopped before finishing.", aliases: ["agent-stopped"]),
        EventKind("agent.failed", .project, about(failedReason),
                  "An agent in this project ended in an error.", aliases: ["agent-stopped"]),
        EventKind("agent.parked", .project, about(outcome),
                  "An agent in this project was parked: put down to come back to."),
        EventKind("agent.archived", .project, about(archivedBy, outcome), "An agent in this project was archived."),
        EventKind("agent.retired", .project, about(fixed("because", ["age", "cap", "person"])),
                  "An archived agent was retired and its conversation deleted."),
        EventKind("workflow.ran", .project, [workflow, agent], "A workflow in this project started an agent."),
        EventKind("workflow.completed", .project, [workflow, agent, outcome],
                  "A workflow's run in this project finished.", aliases: ["workflow-completed"]),
        EventKind("workflow.refused", .project, [workflow, refusedReason],
                  "A workflow in this project did not run, and why."),
        EventKind("branch.moved", .project, open("branch", "from", "to"),
                  "A branch moved: the default branch, or one an agent works on."),
        EventKind("lease.granted", .mac, [EventDetail("resource"), agent], "An agent was given a lease."),
        EventKind("lease.released", .mac, [EventDetail("resource"), fixed("how", ["expired", "ended", "released"])],
                  "A lease was given back, ended or ran out."),
        EventKind("mac.sleep", .mac, [], "This Mac is going to sleep."),
        EventKind("mac.wake", .mac, [], "This Mac woke up."),
        EventKind("mac.disk_low", .mac,
                  open("volume", "free_bytes", "free_percent") + [fixed("level", ["low", "critical"])]
                      + open("threshold", "worktrees"),
                  "Free space on a volume holding the Agents root, a project or a worktree fell below its low or critical threshold."),
        EventKind("mac.disk_ok", .mac, open("volume", "free_bytes", "free_percent", "threshold"),
                  "Free space on a volume that was low climbed back above its threshold."),
        EventKind("person.away", .mac, [fixed("why", ["locked", "idle"])],
                  "You locked the screen or stepped away for 5 minutes."),
        EventKind("person.back", .mac, [fixed("why", ["locked", "idle"])], "You unlocked the screen or came back."),
        EventKind("cost.limit_reached", .either, [EventDetail("limit")] + about(), "A spending limit was reached."),
        EventKind("cost.allowance_out", .mac, [runtime] + open("until", "retry_after", "reason"),
                  "A runtime's allowance ran out."),
        EventKind("cost.allowance_back", .mac,
                  [runtime, fixed("how", ["worked", "another host", "person", "time", "check"])],
                  "A runtime's allowance came back."),
        EventKind("server.offline", .mac, open("server"), "A server went offline."),
        EventKind("server.online", .mac, open("server"), "A server came back."),
    ]

    // MARK: Details (073)

    /// What every event about an agent carries about it, at the moment it happened
    /// (073 FR-001): its labels, its runtime, and who started it.
    public static let context: [EventDetail] = [
        EventDetail("labels", isSet: true, isContext: true, wording: .labelled),
        EventDetail("runtime", isContext: true, values: .runtimes, wording: .runtime),
        EventDetail("started_by", isContext: true, values: .fixed(["person", "workflow", "agent"]), wording: .startedBy),
    ]

    /// `agent`, these, then the context.
    private static func about(_ own: EventDetail...) -> [EventDetail] {
        [agent] + own + context
    }

    private static func open(_ keys: String...) -> [EventDetail] { keys.map { EventDetail($0) } }

    private static func fixed(_ key: String, _ values: [String]) -> EventDetail {
        EventDetail(key, values: .fixed(values))
    }

    private static let agent = EventDetail("agent")
    private static let workflow = EventDetail("workflow")
    private static let runtime = EventDetail("runtime", values: .runtimes, wording: .runtime)
    private static let outcome = EventDetail("outcome", values: .fixed(WorkOutcome.allCases.map(\.rawValue)),
                                             wording: .spaced)
    private static let afterwards = EventDetail("afterwards", values: .fixed(["park", "stay"]), wording: .afterwards)

    /// `agent.stopped`'s `by` (073 FR-008), and the words it was before.
    private static let stoppedBy = EventDetail(
        "by", values: .fixed(["you", "cost_limit", "unknown"]),
        oldWords: [.exactly("stopped by you", code: "you"), .exactly("reached its cost limit", code: "cost_limit"),
                   .exactly("stopped", code: "unknown")],
        wording: .codes(["you": "stopped by you", "cost_limit": "at its cost limit",
                         "unknown": "with no reason recorded"]))

    /// `agent.archived`'s `by` (073 FR-009).
    private static let archivedBy = EventDetail(
        "by", values: .fixed(["you", "agent"]),
        oldWords: [.exactly("another agent", code: "agent")],
        wording: .codes(["you": "by you", "agent": "by another agent"]))

    /// The endings `agent.failed` is raised for: everything nobody chose.
    public static let failedReasons: [EndedReason] = EndedReason.allCases.filter {
        ![.endTurn, .cancelled, .costLimit].contains($0)
    }

    /// `agent.failed`'s `reason` (073 FR-007): the ending's code, once its summary.
    private static let failedReason = EventDetail(
        "reason", values: .fixed(failedReasons.map(\.code)),
        oldWords: failedReasons.compactMap { reason in
            reason.summary.map { .exactly($0.lowercased(), code: reason.code) }
        },
        wording: .codes(Dictionary(uniqueKeysWithValues: failedReasons.map {
            ($0.code, $0.summary?.lowercased() ?? $0.code)
        })))

    /// The refusals `workflow.refused` is raised for: a workflow turned off or cooling
    /// down is not news (#100, #103).
    public static let refusedReasons: [(code: String, words: String)] = [
        ("run_in_flight", WorkflowRefusal.runInFlight.message),
        ("chain_too_deep", "its chain was too deep"),
        ("archived", WorkflowRefusal.archived.message),
        ("over_limit", "over a workflow limit"),
        ("unreadable", "its file could not be read"),
        ("trigger_not_supported", "it watches for something this version cannot"),
        ("agent_unavailable", WorkflowRefusal.agentUnavailable.message),
        ("no_triggering_agent", WorkflowRefusal.noTriggeringAgent.message),
        ("missed_while_closed", WorkflowRefusal.missedWhileClosed.message),
        ("folder_gone", WorkflowRefusal.folderGone.message),
        ("day_limit_reached", WorkflowRefusal.dayLimitReached.message),
        ("setting_refused", "a setting it names cannot be had"),
        ("awaiting_approval", WorkflowRefusal.awaitingApproval.message),
    ]

    /// `workflow.refused`'s `reason` (073 FR-010). The messages that vary map by their
    /// fixed part; a file's own error words (`unreadable`, `setting_refused`) map to
    /// nothing, and are refused naming the codes (FR-013).
    private static let refusedReason = EventDetail(
        "reason", values: .fixed(refusedReasons.map(\.code)),
        oldWords: [WorkflowRefusal.runInFlight, .archived, .agentUnavailable, .noTriggeringAgent,
                   .missedWhileClosed, .folderGone, .dayLimitReached, .awaitingApproval]
            .map { .exactly($0.message, code: $0.code) }
            + [.starting("this chain is already ", code: "chain_too_deep"),
               .starting("this project already runs its ", code: "over_limit"),
               .starting("this project already has ", code: "over_limit"),
               .ending(" workflows are already running, across every project", code: "over_limit"),
               .ending(" is not something this version can watch for", code: "trigger_not_supported")],
        wording: .codes(Dictionary(uniqueKeysWithValues: refusedReasons.map { ($0.code, $0.words) })))

    /// A detail as a pattern on `name` sees it: the kind's own, or for `subject.*` the
    /// details of that key across the subject's kinds, together (073 FR-021). `nil` for
    /// a key nothing there carries, and for anything about a custom event.
    public static func detail(_ key: String, in name: String) -> EventDetail? {
        if let kind = kind(named: name) { return kind.detail(key) }
        guard name.hasSuffix(".*"), let subject = EventSubject(rawValue: String(name.dropLast(2))),
              subject != .custom else { return nil }
        let found = kinds(in: subject).compactMap { $0.detail(key) }
        guard var merged = found.first else { return nil }
        if found.contains(where: { $0.source == .open }) {
            merged.source = .open
        } else if found.count > 1 {
            var values: [String] = []
            for value in found.flatMap({ $0.values ?? [] }) where !values.contains(value) { values.append(value) }
            merged.source = .fixed(values)
        }
        merged.isSet = found.contains(where: \.isSet)
        merged.oldWords = found.flatMap(\.oldWords)
        var words: [String: String] = [:]
        for detail in found { if case .codes(let more) = detail.wording { words.merge(more) { first, _ in first } } }
        if !words.isEmpty { merged.wording = .codes(words) }
        return merged
    }

    public static let customMeaning = "An agent in this project published this."

    private static let byName: [String: EventKind] = Dictionary(uniqueKeysWithValues: all.map { ($0.name, $0) })

    public static func kind(named name: String) -> EventKind? { byName[name] }

    /// The kinds an old trigger name answers to. Empty for a name that is not one.
    public static func kinds(forAlias alias: String) -> [EventKind] {
        all.filter { $0.aliases.contains(alias) }
    }

    /// `custom.` and a name of lowercase letters, digits and `_`, up to 40 characters.
    public static func isCustom(_ name: String) -> Bool {
        name.range(of: #"^custom\.[a-z0-9_]{1,40}$"#, options: .regularExpression) != nil
    }

    /// The kinds in a subject.
    public static func kinds(in subject: EventSubject) -> [EventKind] {
        all.filter { $0.subject == subject }
    }

    /// The one description of the catalogue, returned by the wait tool's `list` and
    /// appended to the workflow tool's description, so the two cannot drift (FR-024).
    public static func describe() -> String {
        var lines = ["Events (the same names work in wait_for_event and as workflow triggers under on:):"]
        for kind in all {
            let own = kind.detailDescriptions.filter { !$0.isContext }.map { detail in
                detail.values.map { "\(detail.key)=\($0.joined(separator: "|"))" } ?? detail.key
            }
            let context = kind.detailDescriptions.contains(where: \.isContext) ? ["…"] : []
            let details = own.isEmpty && context.isEmpty ? "" : " [\((own + context).joined(separator: ", "))]"
            lines.append("- \(kind.name)\(details): \(kind.meaning)")
        }
        lines.append("- custom.<name> [publisher, message, and anything published]: \(customMeaning) "
                     + "<name> is lowercase letters, digits and _, up to 40 characters.")
        let runtimes = RuntimeCatalog.builtIn.map(\.id).joined(separator: "|")
        lines.append("… Every agent event also carries labels (the agent's labels: a filter matches an agent "
                     + "with that label), runtime=\(runtimes) and started_by=person|workflow|agent.")
        lines.append("A subject with .* matches all of its events, e.g. agent.*. "
                     + "Narrow any of them by their details, e.g. workflow: nightly. "
                     + "A detail given a list matches any of its values, e.g. outcome: [done, nothing_to_do]. "
                     + "A detail with values listed above takes only those.")
        return lines.joined(separator: "\n")
    }
}
