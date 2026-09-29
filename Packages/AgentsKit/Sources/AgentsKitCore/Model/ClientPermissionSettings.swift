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

    public init(cursor: ClientPermissionMode = .default, grok: ClientPermissionMode = .default,
                opencode: ClientPermissionMode = .default) {
        self.cursor = cursor
        self.grok = grok
        self.opencode = opencode
    }

    /// A key a saved file or an older daemon never wrote reads as asking, so a new runtime
    /// never starts out answered for the person.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cursor = try c.decodeIfPresent(ClientPermissionMode.self, forKey: .cursor) ?? .default
        grok = try c.decodeIfPresent(ClientPermissionMode.self, forKey: .grok) ?? .default
        opencode = try c.decodeIfPresent(ClientPermissionMode.self, forKey: .opencode) ?? .default
    }

    private enum CodingKeys: String, CodingKey { case cursor, grok, opencode }

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
