import Foundation

/// What an event is about: the part of its name before the dot.
public enum EventSubject: String, Codable, Hashable, Sendable, CaseIterable {
    case agent
    /// The folder as a whole: every agent in it at once (#360).
    case folder
    case workflow
    case branch
    /// A file arriving in a folder's drop box, `.agents/dropbox/` (#231).
    case dropbox
    case lease
    case mac
    /// The machine the host runs on, whatever it is: a Mac or a Linux server (#372).
    case machine
    case person
    case cost
    case server
    /// The daemon itself: `system.restarted` (#1219).
    case system

    public init?(name: String) {
        guard let dot = name.firstIndex(of: ".") else { return nil }
        self.init(rawValue: String(name[..<dot]))
    }

    /// Monochrome, and never tinted: an event is a fact, not a state (042 wireframes §5).
    public var glyph: String {
        switch self {
        case .agent, .folder: return "●"
        case .workflow: return "⟳"
        case .branch: return "⎇"
        case .dropbox: return "⇣"
        case .mac, .machine, .person, .lease, .cost, .server, .system: return "⌘"
        }
    }

    /// The capsule on the events page that shows it.
    public var group: EventGroup {
        switch self {
        case .agent, .folder: return .agents
        case .workflow: return .workflows
        case .branch: return .branches
        case .dropbox: return .dropbox
        case .mac, .machine, .person, .lease, .cost, .server, .system: return .mac
        }
    }
}

/// The page's five filter capsules (042 FR-028, wireframes §1). Several subjects about
/// the machine and the person share one, because to the person they are all "This Mac".
public enum EventGroup: String, Codable, Hashable, Sendable, CaseIterable {
    case agents
    case workflows
    case branches
    case dropbox
    case mac

    public var title: String {
        switch self {
        case .agents: return "Agents"
        case .workflows: return "Workflows"
        case .branches: return "Branches"
        case .dropbox: return "Drop box"
        case .mac: return "This Mac"
        }
    }

    public var subjects: [EventSubject] { EventSubject.allCases.filter { $0.group == self } }
}

/// Whose events of a kind are: the Mac's, a folder's, or either.
public enum EventScopeKind: String, Codable, Hashable, Sendable {
    case mac
    case folder
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

    /// What a wait or a trigger may narrow it by, as JSON Schema (#579): its filters,
    /// and nothing else.
    public var inputSchema: JSONValue { EventCatalogue.schema(filters, closed: true) }

    /// What it carries, as JSON Schema (#579): every detail, `agent_title` beside
    /// `agent`. Every value is text.
    public var payloadSchema: JSONValue {
        var shown = detailDescriptions
        if let at = shown.firstIndex(where: { $0.key == "agent" }) {
            shown.insert(EventDetail("agent_title"), at: at + 1)
        }
        return EventCatalogue.schema(shown, closed: false)
    }

    /// As `events/list` would describe it (#579), so it reads like a server's event.
    public var definition: EventDefinition {
        let macOnly = isMacOnly ? " Only a Mac raises it, never a Linux server." : ""
        return EventDefinition(name: name, description: meaning + macOnly, delivery: [],
                               inputSchema: inputSchema, payloadSchema: payloadSchema)
    }

    init(_ name: String, _ scope: EventScopeKind, _ details: [EventDetail], _ meaning: String,
         macOnly: Bool = false) {
        self.name = name
        self.isMacOnly = macOnly
        self.scope = scope
        self.detailDescriptions = details
        self.meaning = meaning
    }
}

/// Every event the app raises, in one table (042 FR-003, contracts/catalogue.md).
///
/// The wait tool's list, the workflow tool's description, the workflow file parser and
/// the events page all read this, so an agent can wait on exactly what a workflow can
/// trigger on, described in the same words. There is no `custom.` family: agents do not
/// raise events (#639).
public enum EventCatalogue {
    public static let all: [EventKind] = [
        EventKind("agent.started", .folder, about(), "An agent in this folder started working."),
        EventKind("agent.finished", .folder, about(outcome, EventDetail("afterwards", values: ["archive_requested", "archived", "stay"])),
                  "An agent in this folder ended a turn having done its work."),
        EventKind("agent.asked_permission", .folder, about(),
                  "An agent in this folder is asking for permission."),
        EventKind("agent.asked_form", .folder, about(),
                  "An agent in this folder raised a form to fill in."),
        EventKind("agent.waiting", .folder, about(EventDetail("waiting_on")),
                  "An agent in this folder ended its turn waiting on something."),
        EventKind("agent.stopped", .folder, about(EventDetail("by", values: ["you", "admin", "cost_limit", "unknown"])),
                  "An agent in this folder was stopped before finishing."),
        EventKind("agent.failed", .folder, about(EventDetail("reason", values: EndedReason.allCases.map(\.code))),
                  "An agent in this folder ended in an error."),
        EventKind("agent.archive_requested", .folder, about(outcome),
                  "An agent in this folder archived itself, and waits for the person to approve it."),
        EventKind("agent.messaged", .folder, about(EventDetail("from"), EventDetail("from_title")),
                  "An agent in this folder was sent a message by another, with message_session."),
        EventKind("agent.archived", .folder, about(EventDetail("by", values: ["agent", "you"]), outcome),
                  "An agent in this folder was archived."),
        EventKind("agent.deleted", .folder, about(EventDetail("because", values: ["age", "person"])),
                  "An archived agent was deleted with its conversation."),
        EventKind("folder.idle", .folder,
                  shown("agents", "finished", "waiting", "waiting_on_you", "stopped", "failed", "since", "ids"),
                  "Every agent in this folder has stopped working."),
        EventKind("workflow.ran", .folder, shown("workflow", "agent"), "A workflow in this folder started an agent."),
        EventKind("workflow.completed", .folder, shown("workflow", "agent") + [outcome],
                  "A workflow's run in this folder finished."),
        EventKind("workflow.refused", .folder,
                  shown("workflow") + [EventDetail("reason", values: WorkflowRefusal.codes)],
                  "A workflow in this folder did not run, and why."),
        EventKind("branch.moved", .folder, [EventDetail("branch", isFilter: true)] + shown("from", "to"),
                  "A branch an agent works on moved; never the default branch."),
        EventKind("dropbox.file_added", .folder, shown("path", "name", "folder", "extension", "size"),
                  "A file arrived in this folder's drop box, .agents/dropbox/, or a folder in it."),
        // Narrowed by agent and resource: a place in a lease's line is a wait on its own
        // grant (#2361).
        EventKind("lease.granted", .mac, [EventDetail("resource", isFilter: true), EventDetail("agent", isFilter: true)],
                  "An agent was given a lease."),
        EventKind("lease.released", .mac,
                  shown("resource") + [EventDetail("how", values: ["expired", "ended", "released"])],
                  "A lease was given back, ended or ran out."),
        EventKind("mac.sleep", .mac, [], "This Mac is going to sleep.", macOnly: true),
        EventKind("mac.wake", .mac, [], "This Mac woke up.", macOnly: true),
        EventKind("machine.disk_low", .mac,
                  shown("volume", "free_bytes", "free_percent")
                      + [EventDetail("level", values: DiskLevel.allCases.filter { $0 != .ok }.map(\.rawValue))]
                      + shown("threshold", "worktrees"),
                  "Free space on a volume holding the Agents root, a folder or a worktree fell below its low or critical threshold."),
        EventKind("machine.disk_ok", .mac, shown("volume", "free_bytes", "free_percent", "threshold"),
                  "Free space on a volume that was low climbed back above its threshold."),
        EventKind("person.away", .mac, [why], "You locked the screen or stepped away for 5 minutes.", macOnly: true),
        EventKind("person.back", .mac, [why], "You unlocked the screen or came back.", macOnly: true),
        EventKind("cost.limit_reached", .either, shown("limit") + about(), "A spending limit was reached."),
        EventKind("cost.allowance_out", .mac,
                  shown("runtime", "until", "retry_after") + [EventDetail("reason", values: [
                      "allowance spent", "credit used up", "paid extra usage began", "still rate limited",
                      "runtime failed", "learned from another host",
                  ])],
                  "A runtime's allowance ran out."),
        EventKind("cost.allowance_back", .mac, shown("runtime") + [EventDetail("how", values: [
                      "worked", "answering", "another host", "person", "time", "check",
                  ])],
                  "A runtime's allowance came back."),
        EventKind("server.offline", .mac, shown("server"), "A server went offline."),
        EventKind("server.online", .mac, shown("server"), "A server came back."),
        EventKind("system.restarted", .mac,
                  [EventDetail("reason", values: RestartGap.Reason.allCases.map(\.rawValue))]
                      + shown("down_since", "down_for", "down_for_text"),
                  "Agents started again, after a stop or a crash."),
    ]

    // MARK: Details (073, #574, #579)

    /// `agent`, these, then what every event about an agent carries about it at the
    /// moment it happened (073 FR-001): its labels, its runtime, and who started it.
    private static func about(_ own: EventDetail...) -> [EventDetail] {
        [EventDetail("agent")] + own
            + shown("labels", "runtime") + [EventDetail("started_by", values: ["agent", "workflow", "person"])]
    }

    private static func shown(_ keys: String...) -> [EventDetail] { keys.map { EventDetail($0) } }

    private static let outcome = EventDetail("outcome", values: WorkOutcome.allCases.map(\.rawValue))

    private static let why = EventDetail("why", isFilter: true, values: ["locked", "idle"])

    /// Details as a JSON Schema object. A closed one takes no key it does not list.
    static func schema(_ details: [EventDetail], closed: Bool) -> JSONValue {
        var object: [String: JSONValue] = [
            "type": "object",
            "properties": .object(Dictionary(details.map { ($0.key, $0.schema) }, uniquingKeysWith: { first, _ in first })),
        ]
        if closed { object["additionalProperties"] = false }
        return .object(object)
    }

    /// What a pattern on `name` may be narrowed by, as JSON Schema (#579): the kind's
    /// own, or for `subject.*` those of every kind in the subject (073 FR-021).
    public static func inputSchema(for name: String) -> JSONValue {
        if let kind = kind(named: name) { return kind.inputSchema }
        guard name.hasSuffix(".*"), let subject = EventSubject(rawValue: String(name.dropLast(2))) else {
            return schema([], closed: true)
        }
        return schema(kinds(in: subject).flatMap(\.filters), closed: true)
    }

    /// The keys a pattern on `name` may be narrowed by.
    public static func filterKeys(for name: String) -> [String] {
        inputSchema(for: name)["properties"]?.objectValue?.keys.sorted() ?? []
    }

    private static let byName: [String: EventKind] = Dictionary(uniqueKeysWithValues: all.map { ($0.name, $0) })

    public static func kind(named name: String) -> EventKind? { byName[name] }

    /// Whether only a Mac raises what a pattern names: a Mac-only kind, or a subject
    /// whose every kind is (#372). A name the catalogue does not know is not.
    public static func isMacOnly(_ name: String) -> Bool {
        if name.hasSuffix(".*") {
            guard let subject = EventSubject(rawValue: String(name.dropLast(2))) else { return false }
            let kinds = kinds(in: subject)
            return !kinds.isEmpty && kinds.allSatisfy(\.isMacOnly)
        }
        return kind(named: name)?.isMacOnly ?? false
    }

    /// Whether a name is under `custom.`, which agents announced events with until #639.
    /// Nothing raises one now, so a wait or a trigger naming one is refused, saying why.
    public static func isRetiredCustom(_ name: String) -> Bool {
        name == retiredCustomNoun || name.hasPrefix(retiredCustomNoun + ".")
    }

    static let retiredCustomNoun = "custom"

    // MARK: Events from MCP servers (#383)

    /// The nouns only the app raises events about: every subject, and `custom`, which an
    /// agent's events had (#639). A server's event with one of these is refused, so it can
    /// never pass for the app's.
    public static let reservedNouns: Set<String> = Set(EventSubject.allCases.map(\.rawValue) + [retiredCustomNoun])

    /// Whether a name has the one shape every event has, whoever raises it: `noun.verbed`.
    public static func isEventName(_ name: String) -> Bool {
        name.range(of: #"^[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*$"#, options: .regularExpression) != nil
    }

    /// Whether a name can only be a server's event: shaped `noun.verbed`, not in the
    /// catalogue, and not about one of the app's own subjects.
    public static func isServerEventName(_ name: String) -> Bool {
        guard isEventName(name), kind(named: name) == nil,
              let dot = name.firstIndex(of: ".") else { return false }
        return !reservedNouns.contains(String(name[..<dot]))
    }

    /// The kinds in a subject.
    public static func kinds(in subject: EventSubject) -> [EventKind] {
        all.filter { $0.subject == subject }
    }

    /// Every one of the app's events as `events/list` would describe it (#579).
    public static var definitions: [EventDefinition] { all.map(\.definition) }
}

/// The one list of events an agent reads (#579): the app's, then each server's, every
/// one in `events/list`'s shape and marked with where it comes from. Returned by the
/// wait tool's `list`, and appended, the app's alone, to the workflow tool's
/// description, so the two cannot drift (FR-024).
public enum EventList {
    /// Where an event comes from: `app`, or the server that offers it.
    public typealias Source = String

    public static let app: Source = "app"

    public static func text(servers: [(source: Source, events: [EventDefinition])] = [],
                            unlisted: [String] = []) -> String {
        var lines = [
            "Events (the same names work in wait_for_event and as workflow triggers under on:), one per line "
                + "as MCP events/list describes them, each with its source: app, or the MCP server that offers it.",
            "inputSchema is what where (or the keys under a trigger) may narrow it by; payloadSchema is the "
                + "details it carries when it happens, as a woken agent is told them.",
        ]
        lines += EventCatalogue.definitions.map { line($0, source: app) }
        for (source, events) in servers {
            lines += events.map { line($0, source: source) }
        }
        lines += unlisted
        lines.append("A subject with .* matches all of its events, e.g. agent.*; for an MCP server's noun, all of "
                     + "that noun's events. A list in where matches any of its values, e.g. why: [locked, idle]. "
                     + "To wait for particular agents, use wait_for_agents.")
        return lines.joined(separator: "\n")
    }

    /// One entry as a line of JSON, name first and the schemas last. `delivery` is
    /// left out, since the app hears every one the same way.
    static func line(_ definition: EventDefinition, source: Source) -> String {
        var fields: [(String, JSONValue)] = [("name", .string(definition.name)), ("source", .string(source))]
        if let description = definition.description { fields.append(("description", .string(description))) }
        fields.append(("inputSchema", definition.inputSchema ?? ["type": "object"]))
        fields.append(("payloadSchema", definition.payloadSchema ?? ["type": "object"]))
        let json = fields.map { key, value in "\"\(key)\":\(MCPEventTrigger.canonicalJSON(value))" }
        return "{" + json.joined(separator: ",") + "}"
    }
}
