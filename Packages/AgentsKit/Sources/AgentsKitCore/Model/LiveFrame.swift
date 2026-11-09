import Foundation

/// What a live tile shows (#4138): the Mac's screen (`drive_screen`), the machine's browser
/// (`browser_*` tools) or a simulator.
public enum LiveSource: String, Codable, Sendable, Hashable, CaseIterable {
    case screen, browser, simulator
}

/// A live tile's frame of what an agent drives (#4139, #4140): `live/frame`, sent only while
/// the agent drives the source (a call on it in the last 10 seconds) and only to the clients
/// that have its chat in front. Never recorded, never kept past the next frame of its source.
/// `image` is a base64 JPEG, absent while the screen is locked (`locked`). `title` names the
/// source: the page's title, or the simulator's name; absent for the screen.
public struct LiveFrame: Codable, Sendable, Hashable {
    public var source: LiveSource
    public var agentID: UUID
    public var image: String?
    public var locked: Bool?
    public var narration: String?
    public var title: String?
    public var capturedAt: Date
    public var width: Int?
    public var height: Int?

    public init(source: LiveSource, agentID: UUID, image: String? = nil, locked: Bool? = nil,
                narration: String? = nil, title: String? = nil, capturedAt: Date,
                width: Int? = nil, height: Int? = nil) {
        self.source = source
        self.agentID = agentID
        self.image = image
        self.locked = locked
        self.narration = narration
        self.title = title
        self.capturedAt = capturedAt
        self.width = width
        self.height = height
    }

    /// A screen frame from a host before `live/frame` (`desktopControl/liveFrame`).
    public init(_ old: DesktopControlLiveFrame) {
        self.init(source: .screen, agentID: old.agentID, image: old.image, locked: old.locked,
                  narration: old.narration, capturedAt: old.capturedAt)
    }

    /// The picture's bytes, or nil while the screen is locked.
    public var imageData: Data? {
        guard locked != true, let image else { return nil }
        return Data(base64Encoded: image)
    }
}

/// A live frame, with when this client heard it, on its own clock: `capturedAt` is the
/// host's, which a phone's may differ from.
public struct HeardLiveFrame: Sendable, Hashable {
    public var frame: LiveFrame
    public var heardAt: Date

    public init(frame: LiveFrame, heardAt: Date) {
        self.frame = frame
        self.heardAt = heardAt
    }

    /// Whether it still stands for its source at `now`: the host sends frames while the agent
    /// drives and for 10 seconds after its last call, so none for
    /// `DesktopControlLiveFrame.staleAfter` means it stopped.
    public func isFresh(at now: Date) -> Bool {
        DesktopControlLiveFrame.isFresh(heardAt: heardAt, now: now)
    }
}

/// Which frames one live tile shows (#4140): the fresh ones, newest first, and the one in
/// front, which is the person's choice while it is fresh, else the newest.
public enum LiveTiles {
    public static func fresh(_ frames: [LiveSource: HeardLiveFrame], now: Date) -> [HeardLiveFrame] {
        frames.values.filter { $0.isFresh(at: now) }.sorted { $0.heardAt > $1.heardAt }
    }

    public static func shown(_ frames: [LiveSource: HeardLiveFrame], chosen: LiveSource?, now: Date) -> HeardLiveFrame? {
        let fresh = fresh(frames, now: now)
        return fresh.first { $0.frame.source == chosen } ?? fresh.first
    }
}
