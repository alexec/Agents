import Foundation

/// What an event is about: the part of its name before the dot.
public enum EventSubject: String, Codable, Hashable, Sendable, CaseIterable {
    case agent
    /// The project as a whole: every agent in it at once (#360).
    case project
    case workflow
    case branch
    /// A file arriving in a project's drop box, `.agents/dropbox/` (#231).
    case dropbox
    case lease
    case mac
    /// The machine the host runs on, whatever it is: a Mac or a Linux server (#372).
    case machine
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
        case .agent, .project: return "●"
        case .workflow: return "⟳"
        case .branch: return "⎇"
        case .dropbox: return "⇣"
        case .mac, .machine, .person, .lease, .cost, .server: return "⌘"
        case .custom: return "✦"
        }
    }

    /// The capsule on the events page that shows it.
    public var group: EventGroup {
        switch self {
        case .agent, .project: return .agents
        case .workflow: return .workflows
        case .branch: return .branches
        case .dropbox: return .dropbox
        case .mac, .machine, .person, .lease, .cost, .server: return .mac
        case .custom: return .custom
        }
    }
}

/// The page's six filter capsules (042 FR-028, wireframes §1). Several subjects about
/// the machine and the person share one, because to the person they are all "This Mac".
public enum EventGroup: String, Codable, Hashable, Sendable, CaseIterable {
    case agents
    case workflows
    case branches
    case dropbox
    case mac
    case custom

    public var title: String {
        switch self {
        case .agents: return "Agents"
        case .workflows: return "Workflows"
        case .branches: return "Branches"
        case .dropbox: return "Drop box"
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
    /// The details it carries (073), the few a wait or a trigger may narrow it by marked
    /// as filters (#574). `agent_title` rides along with `agent` and is not listed.
    public var detailDescriptions: [EventDetail]
    /// What it means, in the one sentence every place that lists it uses (FR-024).
    public var meaning: String
    /// Today's trigger names that answer to it (FR-022).
    public var aliases: [String]
    /// Raised only by a daemon on a Mac: a Linux host has nothing that hears it (#372).
    public var isMacOnly: Bool

    public var subject: EventSubject { EventSubject(name: name)! }

    /// The keys of the details it carries.
    public var details: [String] { detailDescriptions.map(\.key) }

    public func detail(_ key: String) -> EventDetail? {
        detailDescriptions.first { $0.key == key }
    }

    /// The details a wait or a trigger may narrow it by (#574).
    public var filters: [EventDetail] { detailDescriptions.filter(\.isFilter) }

    init(_ name: String, _ scope: EventScopeKind, _ details: [EventDetail], _ meaning: String,
         aliases: [String] = [], macOnly: Bool = false) {
        self.name = name
        self.isMacOnly = macOnly
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
        EventKind("agent.finished", .project, about("outcome", "afterwards"),
                  "An agent in this project ended a turn having done its work.", aliases: ["agent-finished"]),
        EventKind("agent.asked_permission", .project, about(),
                  "An agent in this project is asking for permission.", aliases: ["agent-asked-permission"]),
        EventKind("agent.asked_form", .project, about(),
                  "An agent in this project raised a form to fill in.", aliases: ["agent-asked-form"]),
        EventKind("agent.blocked", .project, about("waiting_on"),
                  "An agent in this project ended its turn waiting on something."),
        EventKind("agent.stopped", .project, about("by"),
                  "An agent in this project was stopped before finishing.", aliases: ["agent-stopped"]),
        EventKind("agent.failed", .project, about("reason"),
                  "An agent in this project ended in an error.", aliases: ["agent-stopped"]),
        EventKind("agent.parked", .project, about("outcome"),
                  "An agent in this project was parked: put down to come back to."),
        EventKind("agent.messaged", .project, about("from", "from_title"),
                  "An agent in this project was sent a message by another, with message_agent."),
        EventKind("agent.archived", .project, about("by", "outcome"), "An agent in this project was archived."),
        EventKind("agent.deleted", .project, about("because"),
                  "An archived agent was deleted with its conversation.", aliases: ["agent.retired"]),
        EventKind("project.idle", .project,
                  shown("agents", "finished", "blocked", "waiting_on_you", "stopped", "failed", "since", "ids"),
                  "Every agent in this project has stopped working."),
        EventKind("workflow.ran", .project, shown("workflow", "agent"), "A workflow in this project started an agent."),
        EventKind("workflow.completed", .project, shown("workflow", "agent", "outcome"),
                  "A workflow's run in this project finished.", aliases: ["workflow-completed"]),
        EventKind("workflow.refused", .project, shown("workflow", "reason"),
                  "A workflow in this project did not run, and why."),
        EventKind("branch.moved", .project, [EventDetail("branch", isFilter: true)] + shown("from", "to"),
                  "A branch moved: the default branch, or one an agent works on."),
        EventKind("dropbox.file_added", .project, shown("path", "name", "folder", "extension", "size"),
                  "A file arrived in this project's drop box, .agents/dropbox/, or a folder in it."),
        EventKind("lease.granted", .mac, shown("resource", "agent"), "An agent was given a lease."),
        EventKind("lease.released", .mac, shown("resource", "how"), "A lease was given back, ended or ran out."),
        EventKind("mac.sleep", .mac, [], "This Mac is going to sleep.", macOnly: true),
        EventKind("mac.wake", .mac, [], "This Mac woke up.", macOnly: true),
        EventKind("machine.disk_low", .mac,
                  shown("volume", "free_bytes", "free_percent", "level", "threshold", "worktrees"),
                  "Free space on a volume holding the Agents root, a project or a worktree fell below its low or critical threshold."),
        EventKind("machine.disk_ok", .mac, shown("volume", "free_bytes", "free_percent", "threshold"),
                  "Free space on a volume that was low climbed back above its threshold."),
        EventKind("person.away", .mac, [why], "You locked the screen or stepped away for 5 minutes.", macOnly: true),
        EventKind("person.back", .mac, [why], "You unlocked the screen or came back.", macOnly: true),
        EventKind("cost.limit_reached", .either, shown("limit") + about(), "A spending limit was reached."),
        EventKind("cost.allowance_out", .mac, shown("runtime", "until", "retry_after", "reason"),
                  "A runtime's allowance ran out."),
        EventKind("cost.allowance_back", .mac, shown("runtime", "how"), "A runtime's allowance came back."),
        EventKind("server.offline", .mac, shown("server"), "A server went offline."),
        EventKind("server.online", .mac, shown("server"), "A server came back."),
    ]

    // MARK: Details (073, #574)

    /// `agent`, these, then what every event about an agent carries about it at the
    /// moment it happened (073 FR-001): its labels, its runtime, and who started it.
    private static func about(_ own: String...) -> [EventDetail] {
        shown(["agent"] + own + ["labels", "runtime", "started_by"])
    }

    private static func shown(_ keys: String...) -> [EventDetail] { shown(keys) }

    private static func shown(_ keys: [String]) -> [EventDetail] { keys.map { EventDetail($0) } }

    private static let why = EventDetail("why", isFilter: true, values: ["locked", "idle"])

    /// The filters a pattern on `name` may use: the kind's own, or for `subject.*`
    /// those of every kind in the subject (073 FR-021). Empty for a custom event, whose
    /// details are its publisher's.
    public static func filters(for name: String) -> [EventDetail] {
        if let kind = kind(named: name) { return kind.filters }
        guard name.hasSuffix(".*"), let subject = EventSubject(rawValue: String(name.dropLast(2))) else { return [] }
        var found: [EventDetail] = []
        for detail in kinds(in: subject).flatMap(\.filters) where !found.contains(where: { $0.key == detail.key }) {
            found.append(detail)
        }
        return found
    }

    public static let customMeaning = "An agent in this project published this."

    private static let byName: [String: EventKind] = Dictionary(uniqueKeysWithValues: all.map { ($0.name, $0) })

    public static func kind(named name: String) -> EventKind? { byName[name] }

    /// Names an event went by before it was renamed, and what it is called now (#372):
    /// the disk events fire on a Linux server too, so they are the machine's, not the
    /// Mac's. A trigger or a wait naming the old one is read as the new one.
    public static let renamed: [String: String] = [
        "mac.disk_low": "machine.disk_low",
        "mac.disk_ok": "machine.disk_ok",
    ]

    /// The name as the catalogue has it today.
    public static func currentName(_ name: String) -> String { renamed[name] ?? name }

    /// Whether only a Mac raises what a pattern names: a Mac-only kind, or a subject
    /// whose every kind is (#372). A custom event or a name the catalogue does not know
    /// is not.
    public static func isMacOnly(_ name: String) -> Bool {
        if name.hasSuffix(".*") {
            guard let subject = EventSubject(rawValue: String(name.dropLast(2))), subject != .custom else { return false }
            let kinds = kinds(in: subject)
            return !kinds.isEmpty && kinds.allSatisfy(\.isMacOnly)
        }
        return kind(named: name)?.isMacOnly ?? false
    }

    /// The kinds an old trigger name answers to. Empty for a name that is not one.
    public static func kinds(forAlias alias: String) -> [EventKind] {
        all.filter { $0.aliases.contains(alias) }
    }

    /// `custom.` and a name of lowercase letters, digits and `_`, up to 40 characters.
    public static func isCustom(_ name: String) -> Bool {
        name.range(of: #"^custom\.[a-z0-9_]{1,40}$"#, options: .regularExpression) != nil
    }

    // MARK: Events from MCP servers (#383)

    /// The nouns only the app raises events about: every subject, `custom` included. A
    /// server's event with one of these is refused, so it can never pass for the app's.
    public static let reservedNouns: Set<String> = Set(EventSubject.allCases.map(\.rawValue))

    /// Whether a name has the one shape every event has, whoever raises it: `noun.verbed`.
    public static func isEventName(_ name: String) -> Bool {
        name.range(of: #"^[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*$"#, options: .regularExpression) != nil
    }

    /// Whether a name can only be a server's event: shaped `noun.verbed`, not in the
    /// catalogue (an old name included), and not about one of the app's own subjects.
    public static func isServerEventName(_ name: String) -> Bool {
        guard isEventName(name), kind(named: currentName(name)) == nil,
              let dot = name.firstIndex(of: ".") else { return false }
        return !reservedNouns.contains(String(name[..<dot]))
    }

    /// The kinds in a subject.
    public static func kinds(in subject: EventSubject) -> [EventKind] {
        all.filter { $0.subject == subject }
    }

    /// The one description of the catalogue, returned by the wait tool's `list` and
    /// appended to the workflow tool's description, so the two cannot drift (FR-024).
    /// It names only the filters (#574): every other detail is shown, not matched on.
    public static func describe() -> String {
        var lines = ["Events (the same names work in wait_for_event and as workflow triggers under on:):"]
        for kind in all {
            let filters = kind.filters.map { detail in
                detail.values.map { "\(detail.key)=\($0.joined(separator: "|"))" } ?? detail.key
            }
            let narrowed = filters.isEmpty ? "" : " [narrow by \(filters.joined(separator: ", "))]"
            let macOnly = kind.isMacOnly ? " Only a Mac raises it, never a Linux server." : ""
            lines.append("- \(kind.name)\(narrowed): \(kind.meaning)\(macOnly)")
        }
        lines.append("- custom.<name>: \(customMeaning) "
                     + "<name> is lowercase letters, digits and _, up to 40 characters.")
        lines.append("A subject with .* matches all of its events, e.g. agent.*. "
                     + "Only the details in [narrow by …] narrow an event, e.g. branch: main; "
                     + "a list matches any of its values, e.g. why: [locked, idle]. "
                     + "Every event shows more details than that when it happens. "
                     + "To wait for particular agents, use wait_for_event with agents.")
        return lines.joined(separator: "\n")
    }
}
