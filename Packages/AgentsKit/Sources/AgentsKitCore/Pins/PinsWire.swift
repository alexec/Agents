import Foundation

// Pinned pages (#159) on the wire.

public extension DaemonAPI.Method {
    /// Every live folder's pins, for the sidebar.
    static let pinsList = "pins/list"
    /// A person's Pin to Folder. Every client may.
    static let pinsPin = "pins/pin"
    /// A person's Unpin: any pin.
    static let pinsUnpin = "pins/unpin"
    /// A person's drop or Move item: the whole new order, once.
    static let pinsArrange = "pins/arrange"
    /// A person's Hide on a server's list view (#2032), and Show to take it back.
    static let pinsHideView = "pins/hideView"
    /// A pinned page, or a file an HTML page draws from: any file in
    /// the folder, read as `files/read` reads one for an agent.
    static let pinsRead = "pins/read"
    /// What a person typed on a pinned Markdown page.
    static let pinsWrite = "pins/write"
    /// A person's Pin and Unpin on a session (#180): any session in the folder.
    static let pinsPinSession = "pins/pinSession"
    static let pinsUnpinSession = "pins/unpinSession"
    /// A person's drop or Move item among the pinned sessions: the whole new order.
    static let pinsArrangeSessions = "pins/arrangeSessions"
    /// A person's Pin and Unpin on a workflow (#432): any workflow in the folder.
    static let pinsPinWorkflow = "pins/pinWorkflow"
    static let pinsUnpinWorkflow = "pins/unpinWorkflow"
    /// A person's drop or Move item among the pinned workflows: the whole new order.
    static let pinsArrangeWorkflows = "pins/arrangeWorkflows"
}

public extension DaemonAPI.Notification {
    /// A folder's pins changed: pinned, unpinned, moved, or a pinned file came or went.
    static let pinsChanged = "pins/changed"
    /// A page a screen may be showing changed on disk: a pinned file, or one beside
    /// it. At most once a second per folder.
    static let pagesChanged = "pages/changed"
}

public extension DaemonAPI.Failure {
    /// A pin call the app will not take. The message says why, and what would do.
    static let pinRefused = -32061
}

public extension DaemonAPI {
    struct PinRequest: Codable, Sendable, Hashable {
        public var folder: URL
        /// Relative to the folder, or absolute inside it. A view pin's `ui://`
        /// address, so a host from before #189 refuses it as no file of the folder's.
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

    /// Hide or show one of a folder's server views (#2032), by its `ui://` address.
    struct PinHideViewRequest: Codable, Sendable, Hashable {
        public var folder: URL
        public var uri: String
        public var hidden: Bool

        public init(folder: URL, uri: String, hidden: Bool) {
            self.folder = folder
            self.uri = uri
            self.hidden = hidden
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
        /// Relative to the folder.
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

    /// The whole order a person left the pinned workflows in (#432), by id.
    struct PinArrangeWorkflowsRequest: Codable, Sendable, Hashable {
        public var folder: URL
        public var workflowIDs: [String]

        public init(folder: URL, workflowIDs: [String]) {
            self.folder = folder
            self.workflowIDs = workflowIDs
        }
    }

    struct PinsChangedNotification: Codable, Sendable, Hashable {
        public var folder: URL
        public var pins: [PinView]
        /// The pinned sessions in their order (#180). Nil from a host with none.
        public var sessions: [UUID]?
        /// The pinned workflows' ids in their order (#432). Nil from a host with none.
        public var workflows: [String]?
        /// The servers' list views (#2032), the hidden ones marked. Nil from a host with none.
        public var views: [PinView]?

        public init(folder: URL, pins: [PinView], sessions: [UUID] = [], workflows: [String] = [],
                    views: [PinView] = []) {
            self.folder = folder
            self.pins = pins
            self.sessions = sessions.isEmpty ? nil : sessions
            self.workflows = workflows.isEmpty ? nil : workflows
            self.views = views.isEmpty ? nil : views
        }
    }

    struct PagesChangedNotification: Codable, Sendable, Hashable {
        public var folder: URL
        /// Folders, relative to the folder ("" for its top), where something changed.
        public var folders: [String]

        public init(folder: URL, folders: [String]) {
            self.folder = folder
            self.folders = folders
        }
    }
}
