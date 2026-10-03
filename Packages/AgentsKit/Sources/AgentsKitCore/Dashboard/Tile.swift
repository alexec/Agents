import Foundation

/// One tile on a project's Dashboard (074), as its file in the project holds it:
/// `<project>/.agents/dashboard/<id>.json`, committed with the project.
///
/// No timestamps and no points: those are the host's. So a keeper setting the same value
/// again leaves the file's bytes as they were, and git sees a change only when a value
/// does (FR-015). The keeper is an id, never a name, for the same reason: renaming a
/// session must not touch the file.
///
/// The value sits under one key named for the type. Only that one is set.
public struct TileFile: Codable, Hashable, Sendable {
    public var title: String
    public var type: TileType
    public var section: String?
    public var keeper: TileKeeper
    /// Where the value came from, in one line. Required for number and table tiles.
    public var source: String?
    /// Past this, the tile is greyed on every client. 1 to 168; 24 when left out.
    public var staleAfterHours: Int?
    /// The person's Hide. In the file, so it is shared, reviewable and survives the
    /// keeper's posts (FR-027).
    public var hidden: Bool?
    public var number: TileNumber?
    public var status: TileStatus?
    public var table: TileTable?
    public var note: TileNote?
    public var link: TileLink?

    enum CodingKeys: String, CodingKey {
        case title, type, section, keeper, source
        case staleAfterHours = "stale_after_hours"
        case hidden, number, status, table, note, link
    }

    public init(title: String, type: TileType, section: String? = nil, keeper: TileKeeper,
                source: String? = nil, staleAfterHours: Int? = nil, hidden: Bool? = nil,
                number: TileNumber? = nil, status: TileStatus? = nil, table: TileTable? = nil,
                note: TileNote? = nil, link: TileLink? = nil) {
        self.title = title
        self.type = type
        self.section = section
        self.keeper = keeper
        self.source = source
        self.staleAfterHours = staleAfterHours
        self.hidden = hidden
        self.number = number
        self.status = status
        self.table = table
        self.note = note
        self.link = link
    }

    public var isHidden: Bool { hidden == true }

    /// The stale-after time the tile carries, or the default.
    public var staleAfter: TimeInterval { TimeInterval(staleAfterHours ?? TileLimits.defaultStaleHours) * 3600 }

    /// The bytes written to the project: keys sorted, two-space indent, a newline at the
    /// end. The same tile always makes the same bytes, which is what lets an unchanged
    /// value leave the file alone.
    public func fileData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(self)
        // JSONEncoder indents by two already; it just never ends with a newline.
        data.append(0x0A)
        return data
    }

    public static func read(_ data: Data) throws -> TileFile {
        try JSONDecoder().decode(TileFile.self, from: data)
    }
}

public enum TileType: String, Codable, Hashable, Sendable, CaseIterable {
    case number, status, table, note, link
}

/// Who may set a tile: an agent, or a workflow whose every run keeps it (FR-010).
public struct TileKeeper: Codable, Hashable, Sendable {
    /// An agent's id, as a string.
    public var agent: String?
    /// A workflow's id in this project.
    public var workflow: String?

    public init(agent: String? = nil, workflow: String? = nil) {
        self.agent = agent
        self.workflow = workflow
    }

    public static func agent(_ id: UUID) -> TileKeeper { TileKeeper(agent: id.uuidString) }
    public static func workflow(_ id: String) -> TileKeeper { TileKeeper(workflow: id) }

    public var agentID: UUID? { agent.flatMap(UUID.init(uuidString:)) }

    /// How the host's record and a refusal name it: `agent <uuid>` or `workflow <id>`.
    public var key: String {
        if let workflow { return "workflow \(workflow)" }
        return "agent \(agent ?? "?")"
    }
}

/// A number, with its unit and which way is good. Each set records a point on the host.
public struct TileNumber: Codable, Hashable, Sendable {
    public var value: Double
    public var unit: String?
    public var good: TileGood?

    public init(value: Double, unit: String? = nil, good: TileGood? = nil) {
        self.value = value
        self.unit = unit
        self.good = good
    }
}

public enum TileGood: String, Codable, Hashable, Sendable {
    case up, down
}

/// A light and a line: "● Live f0711855 since 16:59".
public struct TileStatus: Codable, Hashable, Sendable {
    public var level: TileLevel
    public var line: String
    public var since: String?

    public init(level: TileLevel, line: String, since: String? = nil) {
        self.level = level
        self.line = line
        self.since = since
    }
}

public enum TileLevel: String, Codable, Hashable, Sendable, CaseIterable {
    case ok, warn, bad, unknown

    /// Worse is larger: `bad` beats `warn` beats `ok`; unknown says nothing.
    public var severity: Int {
        switch self {
        case .unknown: 0
        case .ok: 1
        case .warn: 2
        case .bad: 3
        }
    }
}

public struct TileTable: Codable, Hashable, Sendable {
    public var columns: [String]
    public var rows: [[TileCell]]

    public init(columns: [String], rows: [[TileCell]]) {
        self.columns = columns
        self.rows = rows
    }
}

/// A table cell: text, and a web address when it is a link.
public struct TileCell: Codable, Hashable, Sendable {
    public var text: String
    public var url: String?

    public init(text: String, url: String? = nil) {
        self.text = text
        self.url = url
    }
}

/// Markdown, shown as a chat message is, without images.
public struct TileNote: Codable, Hashable, Sendable {
    public var markdown: String

    public init(markdown: String) { self.markdown = markdown }
}

/// Somewhere to go: a web address, a session or a workflow in this project, or a file in it.
public struct TileLink: Codable, Hashable, Sendable {
    public var url: String?
    /// A session's id.
    public var session: String?
    /// A path inside the project, from its folder.
    public var file: String?
    /// A workflow's id.
    public var workflow: String?

    public init(url: String? = nil, session: String? = nil, file: String? = nil, workflow: String? = nil) {
        self.url = url
        self.session = session
        self.file = file
        self.workflow = workflow
    }
}

/// The limits in spec 074 (FR-002, FR-009, FR-021, FR-023), said once.
public enum TileLimits {
    /// No leading `_`: names that start with one are the Dashboard's own files, such as
    /// `_order.json` (#147).
    public static let idPattern = "[a-z0-9-][a-z0-9_-]{0,39}"
    public static let titleLength = 80
    public static let sectionLength = 40
    public static let sourceLength = 200
    public static let unitLength = 12
    public static let statusLineLength = 200
    public static let sinceLength = 40
    public static let tableColumns = 6
    public static let tableRows = 50
    public static let cellLength = 200
    public static let noteBytes = 4096
    public static let fileBytes = 8192
    public static let tilesPerProject = 60
    public static let historyBytes = 8 * 1024 * 1024
    public static let setsPerHour = 120
    public static let defaultStaleHours = 24
    public static let staleHours = 1...168
    /// The points that travel to a client for one tile, over 30 days.
    public static let pointsSent = 120
    public static let recentPoints = 10
    /// How long a removal is remembered, only to tell the keeper (FR-028).
    public static let removalKept: TimeInterval = 30 * 86_400

    public static func isValidID(_ id: String) -> Bool {
        (1...40).contains(id.count) && id.first != "_" && id.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "_" || $0 == "-" }
    }
}
