import Foundation

/// The folder New Session at the top of the sidebar starts in (#495, #2160), the same on
/// the Mac and the Remote: the last one a session was started in or a new session opened
/// in, by any way, while it is still a live folder; otherwise the selected one; otherwise
/// the first. Kept with its host, so a folder on a server is not taken for the Mac's.
public struct NewSessionFolder: Equatable, Sendable {
    public enum Why: String, Sendable {
        case remembered, selected, first
    }

    public let key: FolderKey
    public let why: Why

    public init(key: FolderKey, why: Why) {
        self.key = key
        self.why = why
    }

    public static func choose(live: [FolderKey], remembered: FolderKey?,
                              selected: FolderKey?) -> NewSessionFolder? {
        if let remembered, live.contains(remembered) { return NewSessionFolder(key: remembered, why: .remembered) }
        if let selected, live.contains(selected) { return NewSessionFolder(key: selected, why: .selected) }
        return live.first.map { NewSessionFolder(key: $0, why: .first) }
    }

    /// What a log says of the choice: which folder, and why.
    public var sentence: String { "\(key) (\(why.rawValue))" }
}
