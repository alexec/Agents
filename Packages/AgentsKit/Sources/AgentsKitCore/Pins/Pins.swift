import Foundation

// A project's pinned pages (#159): Markdown documents and HTML pages pinned under the
// project, beside its Dashboard. specs/159-pinned-pages/README.md is the reference.

/// `<project>/.agents/pins.json`, as written: the pins in the order shown.
public struct PinsFile: Codable, Sendable, Hashable {
    public var pins: [PinEntry]

    public init(pins: [PinEntry] = []) { self.pins = pins }

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
        for entry in raw.pins {
            guard let path = PinRules.normalize(entry.path), PinRules.kind(path) != nil,
                  !seen.contains(path), kept.count < PinLimits.perProject else { continue }
            seen.insert(path)
            var clean = entry
            clean.path = path
            kept.append(clean)
        }
        return (PinsFile(pins: kept), raw.pins.count - kept.count)
    }
}

/// One pin in the file.
public struct PinEntry: Codable, Sendable, Hashable {
    /// Relative to the project folder, `/` between its parts, no `..`. The pin's identity.
    public var path: String
    /// What the row says, if not the file's own name.
    public var title: String?
    public var pinnedBy: Pinner

    enum CodingKeys: String, CodingKey {
        case path, title
        case pinnedBy = "pinned_by"
    }

    public init(path: String, title: String? = nil, pinnedBy: Pinner) {
        self.path = path
        self.title = title
        self.pinnedBy = pinnedBy
    }
}

/// Who pinned a page: the person (any client: one grant for every client), an agent, or
/// the workflow whose runs pin it, as a tile's keeper is.
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
}

public enum PinLimits {
    /// Pins a project may hold, the Dashboard not counted (Alex, #159).
    public static let perProject = 10
    public static let titleLength = 60
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

    public init(path: String, title: String, kind: PinKind, missing: Bool, pinnedBy: PinnerView) {
        self.path = path
        self.title = title
        self.kind = kind
        self.missing = missing
        self.pinnedBy = pinnedBy
    }
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

    public init(folder: URL, pins: [PinView]) {
        self.folder = folder
        self.pins = pins
    }
}
