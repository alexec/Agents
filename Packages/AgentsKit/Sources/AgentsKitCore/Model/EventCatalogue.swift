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
    /// it by. `agent_title` rides along with `agent` and is not listed: it is for
    /// reading, not matching.
    public var details: [String]
    /// What it means, in the one sentence every place that lists it uses (FR-024).
    public var meaning: String
    /// Today's trigger names that answer to it (FR-022).
    public var aliases: [String]

    public var subject: EventSubject { EventSubject(name: name)! }

    init(_ name: String, _ scope: EventScopeKind, _ details: [String], _ meaning: String,
         aliases: [String] = []) {
        self.name = name
        self.scope = scope
        self.details = details
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
        EventKind("agent.started", .project, ["agent"], "An agent in this project started working."),
        EventKind("agent.finished", .project, ["agent", "outcome"],
                  "An agent in this project ended a turn having done its work.", aliases: ["agent-finished"]),
        EventKind("agent.asked_permission", .project, ["agent"],
                  "An agent in this project is asking for permission.", aliases: ["agent-asked-permission"]),
        EventKind("agent.asked_form", .project, ["agent"],
                  "An agent in this project raised a form to fill in.", aliases: ["agent-asked-form"]),
        EventKind("agent.blocked", .project, ["agent", "waiting_on"],
                  "An agent in this project ended its turn waiting on something."),
        EventKind("agent.stopped", .project, ["agent", "by"],
                  "An agent in this project was stopped before finishing.", aliases: ["agent-stopped"]),
        EventKind("agent.failed", .project, ["agent", "reason"],
                  "An agent in this project ended in an error.", aliases: ["agent-stopped"]),
        EventKind("agent.retired", .project, ["agent", "because"],
                  "An archived agent was retired and its conversation deleted."),
        EventKind("workflow.ran", .project, ["workflow", "agent"], "A workflow in this project started an agent."),
        EventKind("workflow.completed", .project, ["workflow", "agent"],
                  "A workflow's run in this project finished.", aliases: ["workflow-completed"]),
        EventKind("workflow.refused", .project, ["workflow", "reason"],
                  "A workflow in this project did not run, and why."),
        EventKind("branch.moved", .project, ["branch", "from", "to"],
                  "A branch moved: the default branch, or one an agent works on."),
        EventKind("lease.granted", .mac, ["resource", "agent"], "An agent was given a lease."),
        EventKind("lease.released", .mac, ["resource", "how"], "A lease was given back, ended or ran out."),
        EventKind("mac.sleep", .mac, [], "This Mac is going to sleep."),
        EventKind("mac.wake", .mac, [], "This Mac woke up."),
        EventKind("person.away", .mac, ["why"], "You locked the screen or stepped away for 5 minutes."),
        EventKind("person.back", .mac, ["why"], "You unlocked the screen or came back."),
        EventKind("cost.limit_reached", .either, ["limit", "agent"], "A spending limit was reached."),
        EventKind("agent.runtime_switched", .project, ["agent", "from", "to", "reason"],
                  "An agent carried on with another runtime when its own ran out."),
        EventKind("cost.allowance_out", .mac, ["runtime", "until", "retry_after", "reason"], "A runtime's allowance ran out."),
        EventKind("cost.allowance_back", .mac, ["runtime", "how"], "A runtime's allowance came back."),
        EventKind("server.offline", .mac, ["server"], "A server went offline."),
        EventKind("server.online", .mac, ["server"], "A server came back."),
    ]

    /// What every custom event carries besides what its publisher adds.
    public static let customDetails = ["publisher", "message"]
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
            let details = kind.details.isEmpty ? "" : " [\(kind.details.joined(separator: ", "))]"
            lines.append("- \(kind.name)\(details): \(kind.meaning)")
        }
        lines.append("- custom.<name> [publisher, message, and anything published]: \(customMeaning) "
                     + "<name> is lowercase letters, digits and _, up to 40 characters.")
        lines.append("A subject with .* matches all of its events, e.g. agent.*. "
                     + "Narrow any of them by their details, e.g. workflow: nightly.")
        return lines.joined(separator: "\n")
    }
}
