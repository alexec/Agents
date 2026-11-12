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

    /// How long a live frame stands for its source after it is heard (#4140): the host sends
    /// frames while the agent drives it and stops 10 seconds after its last call, so none for
    /// this long means the agent stopped.
    /// Counted on this client's clock from when it heard the frame, never from `capturedAt`,
    /// the Mac's clock, which a phone's may differ from.
    public static let staleAfter: TimeInterval = 15

    /// Whether the tile still shows a frame heard at `heardAt`, at `now`.
    public static func isFresh(heardAt: Date, now: Date) -> Bool { now.timeIntervalSince(heardAt) < staleAfter }
}

public struct DesktopControlSettings: Codable, Sendable, Hashable {
    public var enabled: Bool
    /// Ask, Always Approve or Off (#4264). Nil from a daemon before it: then `enabled` is
    /// Always Approve or Off.
    public var mode: DriveApproval?

    public init(enabled: Bool = false, mode: DriveApproval? = nil) {
        self.enabled = enabled
        self.mode = mode
    }

    public init(mode: DriveApproval) {
        self.init(enabled: mode != .off, mode: mode)
    }

    /// The setting as the picker shows it.
    public var shownMode: DriveApproval { mode ?? (enabled ? .always : .off) }
}

/// The browser's own setting on a machine (#4264): `browserControl/state` reads it,
/// `browserControl/set` changes it (the person's own clients only).
public struct BrowserControlSettings: Codable, Sendable, Hashable {
    public var mode: DriveApproval

    public init(mode: DriveApproval) { self.mode = mode }
}

/// Whether an agent's lease of the browser or the screen waits on a person (#4264): Ask
/// (each lease asks in Needs you), Always Approve (never asks) or Off (the tools are not
/// offered). Ask is the default on a machine a person uses; Always Approve on one only
/// agents use, where Ask counts as Always Approve.
public enum DriveApproval: String, Codable, Sendable, CaseIterable, Identifiable {
    case ask, always, off

    public var id: String { rawValue }

    /// The picker's words, the approval words of #4263.
    public var word: String {
        switch self {
        case .ask: "Ask"
        case .always: "Always Approve"
        case .off: "Off"
        }
    }
}

/// Settings ▸ Desktop control's and Settings ▸ Browser's words for the setting (#4264), as the
/// web page says them (`Web/src/model/driveApproval.ts`).
public enum DriveApprovalWords {
    public static let screenLabel = "Agents drive apps on this Mac"
    public static let browserLabel = "Agents use the browser"
    public static let browserHeader = "Agents"

    public static func screenFooter(_ mode: DriveApproval) -> String {
        switch mode {
        case .ask: "Before an agent drives the screen, it asks you in Needs you: Approve, Approve for This Session, Always Approve or Deny. macOS asks you to grant Agents the Accessibility permission the first time."
        case .always: "An agent can click, type and read the screen of any app on this Mac, not only the sandboxed browser, and does not ask first. macOS asks you to grant Agents the Accessibility permission the first time an agent tries."
        case .off: "An agent cannot click, type or read the screen of any other app."
        }
    }

    public static func browserFooter(_ mode: DriveApproval) -> String {
        switch mode {
        case .ask: "Before an agent uses this browser and the sign-ins it keeps, it asks you in Needs you: Approve, Approve for This Session, Always Approve or Deny."
        case .always: "An agent can use this browser and the sign-ins it keeps, and does not ask first."
        case .off: "No agent can use this browser. Agents do not get the browser tools."
        }
    }
}
