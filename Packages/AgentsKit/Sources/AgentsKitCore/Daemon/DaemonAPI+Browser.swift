import Foundation

/// The machine's browser on the wire (#3528, spike #3527): a client watches its page as a
/// screencast and sends the person's input back. `Packages/Wire/daemon.schema.json` has the
/// same types; `WireSchemaTests` holds them to it.
public extension DaemonAPI {
    /// browser/watch: show the page in a view of this size, in points.
    struct BrowserWatchRequest: Codable, Sendable, Hashable {
        public var width: Int
        public var height: Int
        /// The session whose tab to show (#3916): the newest tab its agent opened. Without
        /// it, the machine's newest tab.
        public var agent: UUID?
        public init(width: Int, height: Int, agent: UUID? = nil) {
            self.width = width
            self.height = height
            self.agent = agent
        }
    }

    enum BrowserPageStatus: String, Codable, Sendable, Hashable {
        case stopped, starting, running, failed

        /// A status this build does not know reads as stopped, not as a failed decode.
        public init(from decoder: any Decoder) throws {
            self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .stopped
        }
    }

    /// The machine's browser as a client shows it: browser/watch's answer and browser/pageChanged.
    struct BrowserPageState: Codable, Sendable, Hashable {
        public var status: BrowserPageStatus
        /// starting: the step, such as Downloading Chromium. failed: why.
        public var detail: String?
        public var url: String?
        public var title: String?
        /// The watched session's agent has opened no tab in the browser (#3916).
        public var noTab: Bool?
        /// The session whose agent holds the browser now, and its title (#3916).
        public var holder: UUID?
        public var holderTitle: String?
        public init(status: BrowserPageStatus, detail: String? = nil, url: String? = nil, title: String? = nil,
                    noTab: Bool? = nil, holder: UUID? = nil, holderTitle: String? = nil) {
            self.status = status
            self.detail = detail
            self.url = url
            self.title = title
            self.noTab = noTab
            self.holder = holder
            self.holderTitle = holderTitle
        }

        /// The browser runs, and the watched session's agent has opened no tab in it.
        public var sessionHasNoTab: Bool { status == .running && noTab == true }

        /// The session that holds the browser, when it is not `session`.
        public func otherHolder(than session: UUID) -> UUID? {
            guard let holder, holder != session else { return nil }
            return holder
        }
    }

    /// browser/frame: a JPEG of the page, and its size in CSS pixels.
    struct BrowserFrame: Codable, Sendable, Hashable {
        public var image: Data
        /// Sent back in browser/ack once drawn.
        public var ack: Int
        public var width: Double
        public var height: Double
        public init(image: Data, ack: Int, width: Double, height: Double) {
            self.image = image
            self.ack = ack
            self.width = width
            self.height = height
        }
    }

    struct BrowserAckRequest: Codable, Sendable, Hashable {
        public var ack: Int
        public init(ack: Int) { self.ack = ack }
    }

    enum BrowserInputKind: String, Codable, Sendable, Hashable {
        case mouse, wheel, key, text, edit
    }

    /// edit's command (#5119): selectAll, undo and redo act in the page; copy says the
    /// page's selection back, and cut also deletes it.
    enum BrowserEditCommand: String, Codable, Sendable, Hashable {
        case selectAll, undo, redo, copy, cut
    }

    /// browser/input: a click, a scroll, a key or a paste, in the page's CSS pixels.
    struct BrowserInputRequest: Codable, Sendable, Hashable {
        public var kind: BrowserInputKind
        /// mouse: mousePressed, mouseReleased or mouseMoved. key: keyDown or keyUp.
        public var type: String?
        public var x: Double?
        public var y: Double?
        public var button: String?
        public var clickCount: Int?
        public var deltaX: Double?
        public var deltaY: Double?
        public var key: String?
        public var code: String?
        public var keyCode: Int?
        public var text: String?
        /// Alt 1, Control 2, Meta 4, Shift 8.
        public var modifiers: Int?
        public var command: BrowserEditCommand?
        public init(kind: BrowserInputKind, type: String? = nil, x: Double? = nil, y: Double? = nil,
                    button: String? = nil, clickCount: Int? = nil, deltaX: Double? = nil, deltaY: Double? = nil,
                    key: String? = nil, code: String? = nil, keyCode: Int? = nil, text: String? = nil,
                    modifiers: Int? = nil, command: BrowserEditCommand? = nil) {
            self.kind = kind
            self.type = type
            self.x = x
            self.y = y
            self.button = button
            self.clickCount = clickCount
            self.deltaX = deltaX
            self.deltaY = deltaY
            self.key = key
            self.code = code
            self.keyCode = keyCode
            self.text = text
            self.modifiers = modifiers
            self.command = command
        }
    }

    /// browser/input's answer: after a click is released, whether the page's focus is now in
    /// a field that takes text; after an edit's copy or cut, the page's selected text. Nil
    /// for other input, and from a host before it said so.
    struct BrowserInputResult: Codable, Sendable, Hashable {
        public var editing: Bool?
        public var copied: String?
        public init(editing: Bool? = nil, copied: String? = nil) {
            self.editing = editing
            self.copied = copied
        }
    }

    enum BrowserNavigateAction: String, Codable, Sendable, Hashable {
        case go, back, forward, reload
    }

    /// browser/navigate: the bar over the page. go opens url, and starts the browser.
    struct BrowserNavigateRequest: Codable, Sendable, Hashable {
        public var action: BrowserNavigateAction
        public var url: String?
        public init(action: BrowserNavigateAction, url: String? = nil) {
            self.action = action
            self.url = url
        }
    }
}
