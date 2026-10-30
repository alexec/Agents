import Foundation

public enum ClientPermissionMode: String, Codable, Sendable, Hashable {
    case `default`
    case alwaysApprove

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case Self.alwaysApprove.rawValue, "autoReview":
            // `autoReview` was the 061 smart-review value; treat it as always-approve.
            self = .alwaysApprove
        default:
            self = .default
        }
    }
}

/// The Mac's independent permission choices (061): Cursor, Grok and OpenCode (049), each
/// asking or answered for the person. No per-agent override.
public struct ClientPermissionSettings: Codable, Sendable, Hashable {
    public var cursor: ClientPermissionMode
    public var grok: ClientPermissionMode
    public var opencode: ClientPermissionMode
    /// Set when the organisation's mode ceiling is below approving every request:
    /// **Always approve** is refused and answers nothing. Only read: never written.
    public var setBy: DaemonAPI.PolicySetBy?

    public init(cursor: ClientPermissionMode = .default, grok: ClientPermissionMode = .default,
                opencode: ClientPermissionMode = .default, setBy: DaemonAPI.PolicySetBy? = nil) {
        self.cursor = cursor
        self.grok = grok
        self.opencode = opencode
        self.setBy = setBy
    }

    /// A key a saved file or an older daemon never wrote reads as asking, so a new runtime
    /// never starts out answered for the person.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cursor = try c.decodeIfPresent(ClientPermissionMode.self, forKey: .cursor) ?? .default
        grok = try c.decodeIfPresent(ClientPermissionMode.self, forKey: .grok) ?? .default
        opencode = try c.decodeIfPresent(ClientPermissionMode.self, forKey: .opencode) ?? .default
        setBy = try c.decodeIfPresent(DaemonAPI.PolicySetBy.self, forKey: .setBy)
    }

    /// The choices only: `setBy` is the daemon's to say.
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(cursor, forKey: .cursor)
        try c.encode(grok, forKey: .grok)
        try c.encode(opencode, forKey: .opencode)
    }

    private enum CodingKeys: String, CodingKey { case cursor, grok, opencode, setBy }

    public static func supports(_ runtimeID: String) -> Bool {
        [RuntimeCatalog.cursor.id, RuntimeCatalog.grok.id, RuntimeCatalog.opencode.id].contains(runtimeID)
    }

    public func mode(for runtimeID: String) -> ClientPermissionMode {
        switch runtimeID {
        case RuntimeCatalog.cursor.id: cursor
        case RuntimeCatalog.grok.id: grok
        case RuntimeCatalog.opencode.id: opencode
        default: .default
        }
    }

    /// The same settings with one runtime's choice changed; others untouched.
    public func setting(_ mode: ClientPermissionMode, for runtimeID: String) -> ClientPermissionSettings {
        var settings = self
        switch runtimeID {
        case RuntimeCatalog.cursor.id: settings.cursor = mode
        case RuntimeCatalog.grok.id: settings.grok = mode
        case RuntimeCatalog.opencode.id: settings.opencode = mode
        default: break
        }
        return settings
    }
}
