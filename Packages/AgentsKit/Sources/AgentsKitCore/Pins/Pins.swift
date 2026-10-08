import Foundation

// A project's pinned pages (#159): Markdown documents and HTML pages pinned under the
// project. specs/159-pinned-pages/README.md is the reference.
// And its pinned sessions (#180), kept at the top of its sessions whatever their state,
// and its pinned workflows (#432), after them.

/// `<project>/.agents/pins.json`, as written: the pins in the order shown.
public struct PinsFile: Codable, Sendable, Hashable {
    public var pins: [PinEntry]
    /// The pinned sessions (#180), in the order shown. Absent when there are none, so a
    /// file of pages alone is the same bytes it always was.
    public var sessions: [SessionPinEntry]?
    /// The pinned workflows (#432), in the order shown, after the pinned sessions. Absent
    /// when there are none, as `sessions` is.
    public var workflows: [WorkflowPinEntry]?
    /// Entries this build cannot read (a newer build's kind of pin), kept as they were and
    /// written back after the rest, so an older reader never loses them (#189). They count
    /// towards the limit.
    public var unread: [JSONValue] = []

    public init(pins: [PinEntry] = [], sessions: [SessionPinEntry] = [], workflows: [WorkflowPinEntry] = [],
                unread: [JSONValue] = []) {
        self.pins = pins
        self.sessions = sessions.isEmpty ? nil : sessions
        self.workflows = workflows.isEmpty ? nil : workflows
        self.unread = unread
    }

    enum CodingKeys: String, CodingKey {
        case pins, sessions, workflows
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var pins: [PinEntry] = []
        var unread: [JSONValue] = []
        for raw in try container.decodeIfPresent([JSONValue].self, forKey: .pins) ?? [] {
            if let entry = try? raw.decode(PinEntry.self) { pins.append(entry) } else { unread.append(raw) }
        }
        self.pins = pins
        self.unread = unread
        sessions = try container.decodeIfPresent([SessionPinEntry].self, forKey: .sessions)
        workflows = try container.decodeIfPresent([WorkflowPinEntry].self, forKey: .workflows)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(try pins.map { try JSONValue.encoding($0) } + unread, forKey: .pins)
        try container.encodeIfPresent(sessions, forKey: .sessions)
        try container.encodeIfPresent(workflows, forKey: .workflows)
    }

    /// Pins of either kind, and those this build cannot read: what the limit counts.
    public var pinCount: Int { pins.count + unread.count }

    /// The pinned sessions, none for a file without the key.
    public var sessionPins: [SessionPinEntry] {
        get { sessions ?? [] }
        set { sessions = newValue.isEmpty ? nil : newValue }
    }

    /// The pinned workflows (#432), none for a file without the key.
    public var workflowPins: [WorkflowPinEntry] {
        get { workflows ?? [] }
        set { workflows = newValue.isEmpty ? nil : newValue }
    }

    /// Nothing pinned at all, of any kind: the file can go.
    public var isEmpty: Bool { pins.isEmpty && sessionPins.isEmpty && workflowPins.isEmpty && unread.isEmpty }

    public static let path = ".agents/pins.json"

    /// Keys sorted and slashes kept, so the file is the same bytes for the same pins.
    public func fileData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(self)
        data.append(0x0A)
        return data
    }

    /// What a file holds that can be used: good paths, each once, at most the limit. The
    /// rest is skipped, not deleted; the next write leaves it out.
    public static func read(_ data: Data) throws -> (file: PinsFile, skipped: Int) {
        let raw = try JSONDecoder().decode(PinsFile.self, from: data)
        var seen: Set<String> = []
        var kept: [PinEntry] = []
        let room = PinLimits.perProject - raw.unread.count
        for entry in raw.pins {
            var clean = entry
            if let view = entry.view {
                guard PinRules.problem(view) == nil else { continue }
                clean.path = view.uri
            } else {
                guard let path = PinRules.normalize(entry.path), PinRules.kind(path) != nil else { continue }
                clean.path = path
            }
            guard !seen.contains(clean.path), kept.count < room else { continue }
            seen.insert(clean.path)
            kept.append(clean)
        }
        var sessions: [SessionPinEntry] = []
        for entry in raw.sessionPins where !sessions.contains(where: { $0.session == entry.session })
            && sessions.count < PinLimits.sessionsPerProject {
            sessions.append(entry)
        }
        var workflows: [WorkflowPinEntry] = []
        for entry in raw.workflowPins where !workflows.contains(where: { $0.workflow == entry.workflow })
            && workflows.count < PinLimits.workflowsPerProject {
            workflows.append(entry)
        }
        return (PinsFile(pins: kept, sessions: sessions, workflows: workflows, unread: raw.unread),
                raw.pins.count - kept.count + raw.sessionPins.count - sessions.count
                    + raw.workflowPins.count - workflows.count)
    }
}

/// One pinned session (#180): which, and who pinned it. Its id is a host's record, so a
/// project carried to another host keeps entries that name nothing there; a screen
/// shows only the ones it holds.
public struct SessionPinEntry: Codable, Sendable, Hashable {
    public var session: UUID
    public var pinnedBy: Pinner

    enum CodingKeys: String, CodingKey {
        case session
        case pinnedBy = "pinned_by"
    }

    public init(session: UUID, pinnedBy: Pinner) {
        self.session = session
        self.pinnedBy = pinnedBy
    }
}

/// One pinned workflow (#432): which, by its id (the file name without `.md`), and who
/// pinned it. A workflow renamed or removed leaves an entry naming nothing, shown nowhere.
public struct WorkflowPinEntry: Codable, Sendable, Hashable {
    public var workflow: String
    public var pinnedBy: Pinner

    enum CodingKeys: String, CodingKey {
        case workflow
        case pinnedBy = "pinned_by"
    }

    public init(workflow: String, pinnedBy: Pinner) {
        self.workflow = workflow
        self.pinnedBy = pinnedBy
    }
}

/// One pin in the file: a page, by its `path`, or a view (#189), by its `view`. Never both.
public struct PinEntry: Codable, Sendable, Hashable {
    /// Relative to the project folder, `/` between its parts, no `..`. The pin's identity.
    /// A view pin's is its `ui://` address, and is not written: `view` says it.
    public var path: String
    /// What the row says, if not the file's own name.
    public var title: String?
    public var pinnedBy: Pinner
    /// A `ui://` view and the call that feeds it (#189).
    public var view: ViewPin?

    enum CodingKeys: String, CodingKey {
        case path, title, view
        case pinnedBy = "pinned_by"
    }

    public init(path: String, title: String? = nil, pinnedBy: Pinner) {
        self.path = path
        self.title = title
        self.pinnedBy = pinnedBy
    }

    public init(view: ViewPin, title: String? = nil, pinnedBy: Pinner) {
        self.path = view.uri
        self.title = title
        self.pinnedBy = pinnedBy
        self.view = view
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let path = try container.decodeIfPresent(String.self, forKey: .path)
        let view = try container.decodeIfPresent(ViewPin.self, forKey: .view)
        guard (path == nil) != (view == nil) else {
            throw DecodingError.dataCorruptedError(forKey: .path, in: container,
                                                   debugDescription: "A pin has one of path and view.")
        }
        self.path = path ?? view!.uri
        self.view = view
        title = try container.decodeIfPresent(String.self, forKey: .title)
        pinnedBy = try container.decode(Pinner.self, forKey: .pinnedBy)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let view { try container.encode(view, forKey: .view) } else { try container.encode(path, forKey: .path) }
        try container.encodeIfPresent(title, forKey: .title)
        try container.encode(pinnedBy, forKey: .pinnedBy)
    }
}

/// A pinned view (#189): which server's `ui://` resource, and the tool call that feeds it.
/// Opening the pin makes that call. Our extension of MCP Apps (SEP-1865), which ties a view
/// only to a call the model made. Shared through git, so `arguments` never holds a secret.
public struct ViewPin: Codable, Sendable, Hashable {
    public var server: String
    public var uri: String
    public var tool: String
    public var arguments: JSONValue?

    public init(server: String, uri: String, tool: String, arguments: JSONValue? = nil) {
        self.server = server
        self.uri = uri
        self.tool = tool
        self.arguments = arguments
    }
}

/// Who pinned a page: the person (any client: one grant for every client), an agent, or
/// the workflow whose runs pin it.
public struct Pinner: Codable, Sendable, Hashable {
    public var person: Bool?
    public var agent: String?
    public var workflow: String?

    public init(person: Bool? = nil, agent: String? = nil, workflow: String? = nil) {
        self.person = person
        self.agent = agent
        self.workflow = workflow
    }

    public static let thePerson = Pinner(person: true)
    public static func agent(_ id: UUID) -> Pinner { Pinner(agent: id.uuidString) }
    public static func workflow(_ id: String) -> Pinner { Pinner(workflow: id) }

    public var isPerson: Bool { person == true }
    public var agentID: UUID? { agent.flatMap(UUID.init(uuidString:)) }
}

public enum PinKind: String, Codable, Sendable, Hashable {
    case markdown, html
    /// A `ui://` view (#189).
    case view
}

public enum PinLimits {
    /// Pins a project may hold (Alex, #159).
    public static let perProject = 10
    /// Pinned sessions a project may hold, apart from its pages (#180).
    public static let sessionsPerProject = 10
    /// Pinned workflows a project may hold, apart from its pages and sessions (#432).
    public static let workflowsPerProject = 10
    public static let titleLength = 60
    /// A view pin's arguments, as JSON (#189).
    public static let viewArgumentsBytes = 2048
}

/// The rules every door holds to: which files, which paths, what a row is called.
public enum PinRules {
    public static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd"]
    public static let htmlExtensions: Set<String> = ["html", "htm"]

    public static func kind(_ path: String) -> PinKind? {
        let ext = (path as NSString).pathExtension.lowercased()
        if markdownExtensions.contains(ext) { return .markdown }
        if htmlExtensions.contains(ext) { return .html }
        return nil
    }

    /// A relative path, tidied: no leading `./` or `/`, no empty parts, nothing that
    /// climbs out. Nil for anything that can't name a file in the project.
    public static func normalize(_ path: String) -> String? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init).filter { $0 != "." }
        guard !parts.isEmpty, !parts.contains(".."), !path.hasPrefix("/") else { return nil }
        return parts.joined(separator: "/")
    }

    /// The path of `file` inside `folder`, or nil when it is not inside.
    public static func relative(_ file: String, in folder: URL) -> String? {
        let base = folder.standardizedFileURL.path(percentEncoded: false)
        let root = base.hasSuffix("/") ? base : base + "/"
        let full = URL(filePath: file).standardizedFileURL.path(percentEncoded: false)
        guard full.hasPrefix(root) else { return nil }
        return normalize(String(full.dropFirst(root.count)))
    }

    /// The row's words without a title: the file's name without its extension, or, for a
    /// `README.md` or `index.html`, its folder's name.
    public static func defaultTitle(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent
        let stem = (name as NSString).deletingPathExtension
        if ["readme", "index"].contains(stem.lowercased()) {
            let folder = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
            if !folder.isEmpty { return folder }
        }
        return stem
    }

    /// What is wrong with a view pin's shape, or nil. Whether its server has the view is
    /// the host's to say.
    public static func problem(_ view: ViewPin) -> String? {
        if view.server.trimmingCharacters(in: .whitespaces).isEmpty { return "a view pin names its server." }
        if !view.uri.hasPrefix("ui://") || view.uri.count <= 5 { return "a view's address starts ui://." }
        if view.tool.trimmingCharacters(in: .whitespaces).isEmpty { return "a view pin names the tool that feeds it." }
        if let arguments = view.arguments {
            guard case .object = arguments else { return "`arguments` is a JSON object." }
            if ((try? JSONEncoder().encode(arguments))?.count ?? .max) > PinLimits.viewArgumentsBytes {
                return "`arguments` is at most \(PinLimits.viewArgumentsBytes / 1024) KB of JSON."
            }
        }
        return nil
    }

    /// The row's words for a view without a title: the last part of its address.
    public static func defaultTitle(_ view: ViewPin) -> String {
        let name = view.uri.split(separator: "/").last.map(String.init) ?? view.uri
        return name.replacingOccurrences(of: "-", with: " ").capitalized(with: nil)
    }

    /// The order after moving `path`: before or after another, or first or last.
    public static func moving(_ paths: [String], _ path: String, before: String? = nil, after: String? = nil,
                              first: Bool = false) -> [String] {
        var rest = paths.filter { $0 != path }
        if let before, let index = rest.firstIndex(of: before) {
            rest.insert(path, at: index)
        } else if let after, let index = rest.firstIndex(of: after) {
            rest.insert(path, at: index + 1)
        } else if first {
            rest.insert(path, at: 0)
        } else {
            rest.append(path)
        }
        return rest
    }
}

/// One pin as a screen draws it.
public struct PinView: Codable, Sendable, Hashable, Identifiable {
    public var id: String { path }
    public var path: String
    /// The title given, or the file's name.
    public var title: String
    public var kind: PinKind
    /// The file is not in the project folder (deleted, moved, or only on a branch).
    public var missing: Bool
    public var pinnedBy: PinnerView
    /// A view pin's view and feeding call (#189); `path` is then its `ui://` address.
    public var view: ViewPin?
    /// Why a view pin is missing here, in a few words: `PinMissing`.
    public var missingReason: String?

    public init(path: String, title: String, kind: PinKind, missing: Bool, pinnedBy: PinnerView,
                view: ViewPin? = nil, missingReason: String? = nil) {
        self.path = path
        self.title = title
        self.kind = kind
        self.missing = missing
        self.pinnedBy = pinnedBy
        self.view = view
        self.missingReason = missingReason
    }
}

/// Why a view pin shows as missing (#189), as a pinned file does until its branch lands.
public enum PinMissing {
    public static let serverNotSetUp = "server not set up here"
    public static let waitingForApproval = "waiting for approval"
    public static let noSuchView = "no such view"
    /// A stdio server's: views from local servers aren't shown yet (#191, Q5).
    public static let localServer = "views from local servers aren't shown yet"
    public static let missingSecret = "a secret is missing"
    /// It wants a sign-in first (#306).
    public static let signIn = "needs a sign-in"
}

/// Who pinned it, named for a person.
public struct PinnerView: Codable, Sendable, Hashable {
    public var kind: PinnerKind
    /// An agent's id or a workflow's; empty for the person.
    public var id: String
    public var name: String

    public init(kind: PinnerKind, id: String, name: String) {
        self.kind = kind
        self.id = id
        self.name = name
    }
}

public enum PinnerKind: String, Codable, Sendable, Hashable {
    case person, agent, workflow
}

/// One project's pins, for the sidebar.
public struct ProjectPins: Codable, Sendable, Hashable {
    public var folder: URL
    public var pins: [PinView]
    /// Its pinned sessions in their order (#180). Nil from a host that has none to say.
    public var sessions: [UUID]?
    /// Its pinned workflows' ids in their order (#432). Nil from a host that has none to say.
    public var workflows: [String]?

    public init(folder: URL, pins: [PinView], sessions: [UUID] = [], workflows: [String] = []) {
        self.folder = folder
        self.pins = pins
        self.sessions = sessions.isEmpty ? nil : sessions
        self.workflows = workflows.isEmpty ? nil : workflows
    }
}
