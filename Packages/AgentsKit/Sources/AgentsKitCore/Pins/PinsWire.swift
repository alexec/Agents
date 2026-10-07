import Foundation

// Pinned pages (#159) on the wire.

public extension DaemonAPI.Method {
    /// Every live project's pins, for the sidebar.
    static let pinsList = "pins/list"
    /// A person's Pin to Project. Every client may.
    static let pinsPin = "pins/pin"
    /// A person's Unpin: any pin.
    static let pinsUnpin = "pins/unpin"
    /// A person's drop or Move item: the whole new order, once.
    static let pinsArrange = "pins/arrange"
    /// A pinned page, or a file an HTML page draws from: any file in
    /// the project folder, read as `files/read` reads one for an agent.
    static let pinsRead = "pins/read"
    /// What a person typed on a pinned Markdown page.
    static let pinsWrite = "pins/write"
    /// A person's Pin and Unpin on a session (#180): any session in the project.
    static let pinsPinSession = "pins/pinSession"
    static let pinsUnpinSession = "pins/unpinSession"
    /// A person's drop or Move item among the pinned sessions: the whole new order.
    static let pinsArrangeSessions = "pins/arrangeSessions"
    /// `pin_session`, relayed: an agent pins or unpins its own session.
    static let pinsPinSessionTool = "pins/pinSessionTool"
    /// `pin_page`, `unpin_page` and `move_pin`, relayed.
    static let pinsPinPage = "pins/pinPage"
    static let pinsUnpinPage = "pins/unpinPage"
    static let pinsMovePin = "pins/movePin"
}

public extension DaemonAPI.Notification {
    /// A project's pins changed: pinned, unpinned, moved, or a pinned file came or went.
    static let pinsChanged = "pins/changed"
    /// A page a screen may be showing changed on disk: a pinned file, or one beside
    /// it. At most once a second per project.
    static let pagesChanged = "pages/changed"
}

public extension DaemonAPI.Failure {
    /// A pin call the app will not take. The message says why, and what would do.
    static let pinRefused = -32061
}

public extension DaemonAPI {
    struct PinRequest: Codable, Sendable, Hashable {
        public var folder: URL
        /// Relative to the project folder, or absolute inside it. A view pin's `ui://`
        /// address, so a host from before #189 refuses it as no file of the project's.
        public var path: String
        public var title: String?
        /// A view to pin, and the call that feeds it (#189).
        public var view: ViewPin?

        public init(folder: URL, path: String, title: String? = nil) {
            self.folder = folder
            self.path = path
            self.title = title
        }

        public init(folder: URL, view: ViewPin, title: String? = nil) {
            self.folder = folder
            self.path = view.uri
            self.title = title
            self.view = view
        }
    }

    struct PinPathRequest: Codable, Sendable, Hashable {
        public var folder: URL
        public var path: String

        public init(folder: URL, path: String) {
            self.folder = folder
            self.path = path
        }
    }

    /// The whole order a person left the pins in.
    struct PinArrangeRequest: Codable, Sendable, Hashable {
        public var folder: URL
        public var paths: [String]

        public init(folder: URL, paths: [String]) {
            self.folder = folder
            self.paths = paths
        }
    }

    struct PinReadRequest: Codable, Sendable, Hashable {
        public var folder: URL
        /// Relative to the project folder.
        public var path: String
        public var knownStamp: FileStamp?

        public init(folder: URL, path: String, knownStamp: FileStamp? = nil) {
            self.folder = folder
            self.path = path
            self.knownStamp = knownStamp
        }
    }

    struct PinWriteRequest: Codable, Sendable, Hashable {
        public var folder: URL
        public var path: String
        public var text: String

        public init(folder: URL, path: String, text: String) {
            self.folder = folder
            self.path = path
            self.text = text
        }
    }

    /// An agent's pin tool, as it called it: the daemon checks the arguments.
    struct PinToolRequest: Codable, Sendable, Hashable {
        public var token: String
        public var arguments: JSONValue

        public init(token: String, arguments: JSONValue) {
            self.token = token
            self.arguments = arguments
        }
    }

    /// A person's Pin or Unpin on one session (#180).
    struct PinSessionRequest: Codable, Sendable, Hashable {
        public var folder: URL
        public var agentID: UUID

        public init(folder: URL, agentID: UUID) {
            self.folder = folder
            self.agentID = agentID
        }
    }

    /// The whole order a person left the pinned sessions in.
    struct PinArrangeSessionsRequest: Codable, Sendable, Hashable {
        public var folder: URL
        public var agentIDs: [UUID]

        public init(folder: URL, agentIDs: [UUID]) {
            self.folder = folder
            self.agentIDs = agentIDs
        }
    }

    struct PinsChangedNotification: Codable, Sendable, Hashable {
        public var folder: URL
        public var pins: [PinView]
        /// The pinned sessions in their order (#180). Nil from a host with none.
        public var sessions: [UUID]?

        public init(folder: URL, pins: [PinView], sessions: [UUID] = []) {
            self.folder = folder
            self.pins = pins
            self.sessions = sessions.isEmpty ? nil : sessions
        }
    }

    struct PagesChangedNotification: Codable, Sendable, Hashable {
        public var folder: URL
        /// Folders, relative to the project ("" for its top), where something changed.
        public var folders: [String]

        public init(folder: URL, folders: [String]) {
            self.folder = folder
            self.folders = folders
        }
    }
}
