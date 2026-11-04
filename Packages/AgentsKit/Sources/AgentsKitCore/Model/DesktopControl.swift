import Foundation

/// Desktop control's own person-level switch (#3004, US2, research R5): off by default,
/// kept at `<settings>/desktop-control.json`. `desktopControl/state` reads it,
/// `desktopControl/set` changes it (the person's own clients only).
///
/// `drive_screen`'s own Off/Accessibility refusal (`wire.DesktopControlRefusal` on the Go
/// side) has no Swift mirror here: it is an app tool's error, so only its plain message
/// reaches the runtime over MCP (`Go/internal/agentsd/apptools.go`'s `tools/call`, which
/// keeps `Error.Message` and drops `Error.Data`); no client ever sees the structured
/// reason to draw a dedicated card from (research.md's R5 amendment).
/// An agent's `drive_screen` paused by the person's own touch on the mouse or keyboard
/// (#3004, US3, FR-007): the app it was driving, and when. On `Agent.desktopControlPause`
/// while it waits for Resume or Take Over (`desktopControl/resume`, `desktopControl/takeOver`).
public struct DesktopControlPause: Codable, Sendable, Hashable {
    public var app: String
    public var pausedAt: Date

    public init(app: String, pausedAt: Date) {
        self.app = app
        self.pausedAt = pausedAt
    }
}

/// The live tile's latest look at the Mac's screen while an agent holds the `screen` lease
/// (#3004, US4, FR-011): `desktopControl/liveFrame`, sent only to the clients showing that
/// agent and never recorded. `image` is a base64 JPEG of the whole screen, absent while the
/// screen is locked (`locked`, FR-012). `narration` is the agent's last action, in words.
public struct DesktopControlLiveFrame: Codable, Sendable, Hashable {
    public var agentID: UUID
    public var image: String?
    public var locked: Bool?
    public var narration: String?
    public var capturedAt: Date

    public init(agentID: UUID, image: String? = nil, locked: Bool? = nil, narration: String? = nil,
                capturedAt: Date) {
        self.agentID = agentID
        self.image = image
        self.locked = locked
        self.narration = narration
        self.capturedAt = capturedAt
    }

    /// The picture's bytes, or nil while the screen is locked.
    public var imageData: Data? {
        guard locked != true, let image else { return nil }
        return Data(base64Encoded: image)
    }

    /// How long a frame stands for the screen after it is heard: the host sends one at least
    /// every 5 seconds while it holds the lease, so none for this long means it was let go.
    /// Counted on this client's clock from when it heard the frame, never from `capturedAt`,
    /// the Mac's clock, which a phone's may differ from.
    public static let staleAfter: TimeInterval = 15

    /// Whether the tile still shows a frame heard at `heardAt`, at `now`.
    public static func isFresh(heardAt: Date, now: Date) -> Bool { now.timeIntervalSince(heardAt) < staleAfter }
}

public struct DesktopControlSettings: Codable, Sendable, Hashable {
    public var enabled: Bool

    public init(enabled: Bool = false) {
        self.enabled = enabled
    }
}
