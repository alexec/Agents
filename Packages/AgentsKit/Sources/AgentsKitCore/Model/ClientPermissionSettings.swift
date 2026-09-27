import Foundation

public enum ClientPermissionMode: String, Codable, Sendable, Hashable {
    case `default`
    case autoReview
}

/// The Mac's two independent permission choices (061). No per-agent override.
public struct ClientPermissionSettings: Codable, Sendable, Hashable {
    public var cursor: ClientPermissionMode
    public var grok: ClientPermissionMode

    public init(cursor: ClientPermissionMode = .default, grok: ClientPermissionMode = .default) {
        self.cursor = cursor
        self.grok = grok
    }

    public static func supports(_ runtimeID: String) -> Bool {
        runtimeID == RuntimeCatalog.cursor.id || runtimeID == RuntimeCatalog.grok.id
    }

    public func mode(for runtimeID: String) -> ClientPermissionMode {
        switch runtimeID {
        case RuntimeCatalog.cursor.id: cursor
        case RuntimeCatalog.grok.id: grok
        default: .default
        }
    }
}
