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
public struct DesktopControlSettings: Codable, Sendable, Hashable {
    public var enabled: Bool

    public init(enabled: Bool = false) {
        self.enabled = enabled
    }
}
