import Foundation

// The Dashboard (074) on the wire, in a file of its own so the lanes beside it do not
// collide in DaemonAPI.swift. contracts/daemon-api.md is the reference.

public extension DaemonAPI.Method {
    /// `set_tile`, relayed.
    static let dashboardSetTile = "dashboard/setTile"
    /// `remove_tile`, relayed.
    static let dashboardRemoveTile = "dashboard/removeTile"
    /// `read_dashboard`, relayed.
    static let dashboardRead = "dashboard/read"
    /// One project's Dashboard, for a person's screen.
    static let dashboardGet = "dashboard/get"
    /// Every project's row: how many tiles, whether one is bad, the one-line summary.
    static let dashboardSummaries = "dashboard/summaries"
    /// The person's Hide, Show and Remove (FR-027, FR-028). Every client may (FR-029).
    static let dashboardHide = "dashboard/hide"
    static let dashboardShow = "dashboard/show"
    static let dashboardRemove = "dashboard/remove"
}

public extension DaemonAPI.Notification {
    /// A project's Dashboard changed: at most once a second per project.
    static let dashboardChanged = "dashboard/changed"
}

public extension DaemonAPI.Failure {
    /// A tile call the app will not take, or a tile that is not there. The message says
    /// which, and what would do.
    static let dashboardRefused = -32060
}

public extension DaemonAPI {
    /// `set_tile`'s arguments as the agent wrote them: the daemon reads and checks them,
    /// so there is one place that knows the rules.
    struct SetTileRequest: Codable, Sendable, Hashable {
        public var token: String
        public var arguments: JSONValue

        public init(token: String, arguments: JSONValue) {
            self.token = token
            self.arguments = arguments
        }
    }

    struct RemoveTileRequest: Codable, Sendable, Hashable {
        public var token: String
        public var id: String

        public init(token: String, id: String) {
            self.token = token
            self.id = id
        }
    }

    struct DashboardTokenRequest: Codable, Sendable, Hashable {
        public var token: String
        public init(token: String) { self.token = token }
    }

    struct DashboardRequest: Codable, Sendable, Hashable {
        public var folder: URL
        public init(folder: URL) { self.folder = folder }
    }

    struct TileRequest: Codable, Sendable, Hashable {
        public var folder: URL
        public var id: String

        public init(folder: URL, id: String) {
            self.folder = folder
            self.id = id
        }
    }

    struct DashboardChangedNotification: Codable, Sendable, Hashable {
        public var folder: URL
        public var summary: DashboardSummary

        public init(folder: URL, summary: DashboardSummary) {
            self.folder = folder
            self.summary = summary
        }
    }
}

/// One project's Dashboard, as a person's screen draws it.
public struct DashboardSnapshot: Codable, Sendable, Hashable {
    public var folder: URL
    /// Every tile, hidden ones included and flagged, in the order they were made.
    public var tiles: [TileView]
    /// The host's clock when this was made, so ages are measured against one clock.
    public var now: Date
    /// Update now's state (#146). Nil from a host that predates it: no button.
    public var update: DashboardUpdate?

    public init(folder: URL, tiles: [TileView], now: Date, update: DashboardUpdate? = nil) {
        self.folder = folder
        self.tiles = tiles
        self.now = now
        self.update = update
    }
}

/// One tile as a screen needs it: the file, and what the host knows about it.
public struct TileView: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    /// Nil when the file does not parse; `problem` says why.
    public var tile: TileFile?
    public var problem: String?
    /// When it was first made, which orders the Dashboard. Nil for a tile only a file
    /// knows about (a clone, a pull).
    public var made: Date?
    /// When its keeper last set it. Nil for a tile this host has never seen set: its age
    /// is unknown, and it is greyed until its keeper sets it here.
    public var setAt: Date?
    public var keeper: KeeperView
    /// The file is not what this host last wrote: edited by hand, or brought by a pull.
    public var changedOutside: Bool
    /// A number's points over 30 days, at most 120.
    public var points: [TilePoint]
    /// A number's last 10 points, for the detail.
    public var recent: [TilePoint]
    public var keeperChanges: [KeeperChange]

    public init(id: String, tile: TileFile?, problem: String? = nil, made: Date? = nil, setAt: Date? = nil,
                keeper: KeeperView, changedOutside: Bool = false, points: [TilePoint] = [],
                recent: [TilePoint] = [], keeperChanges: [KeeperChange] = []) {
        self.id = id
        self.tile = tile
        self.problem = problem
        self.made = made
        self.setAt = setAt
        self.keeper = keeper
        self.changedOutside = changedOutside
        self.points = points
        self.recent = recent
        self.keeperChanges = keeperChanges
    }
}

/// Who keeps a tile, named for a person.
public struct KeeperView: Codable, Sendable, Hashable {
    public var kind: KeeperKind
    /// An agent's id or a workflow's.
    public var id: String
    /// Its title or the workflow's name.
    public var name: String
    public var state: KeeperState

    public init(kind: KeeperKind, id: String, name: String, state: KeeperState) {
        self.kind = kind
        self.id = id
        self.name = name
        self.state = state
    }
}

public enum KeeperKind: String, Codable, Sendable, Hashable {
    case agent, workflow
}

public enum KeeperState: String, Codable, Sendable, Hashable {
    case active, archived, retired, unknown
}

public struct TilePoint: Codable, Sendable, Hashable {
    public var at: Date
    public var value: Double

    public init(at: Date, value: Double) {
        self.at = at
        self.value = value
    }
}

/// A tile changing hands: taken over, or passed to a workflow (FR-012).
public struct KeeperChange: Codable, Sendable, Hashable {
    public var at: Date
    public var from: String
    public var to: String

    public init(at: Date, from: String, to: String) {
        self.at = at
        self.from = from
        self.to = to
    }
}

/// A project's Dashboard row: what it says without being opened.
public struct DashboardSummary: Codable, Sendable, Hashable {
    public var folder: URL
    /// Tiles shown: not hidden.
    public var tiles: Int
    /// Live (not stale) tiles that are bad: the row's red mark.
    public var bad: Int
    /// "1 needs a look · Open bugs 4", or empty.
    public var line: String

    public init(folder: URL, tiles: Int, bad: Int, line: String) {
        self.folder = folder
        self.tiles = tiles
        self.bad = bad
        self.line = line
    }
}
