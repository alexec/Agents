import Foundation

/// The project New Session at the top of the sidebar starts in (#495, #2160), the same on
/// the Mac and the Remote: the last one a session was started in or a new session opened
/// in, by any way, while it is still a live project; otherwise the selected one; otherwise
/// the first. Kept with its host, so a project on a server is not taken for the Mac's.
public struct NewSessionProject: Equatable, Sendable {
    public enum Why: String, Sendable {
        case remembered, selected, first
    }

    public let key: ProjectKey
    public let why: Why

    public init(key: ProjectKey, why: Why) {
        self.key = key
        self.why = why
    }

    public static func choose(live: [ProjectKey], remembered: ProjectKey?,
                              selected: ProjectKey?) -> NewSessionProject? {
        if let remembered, live.contains(remembered) { return NewSessionProject(key: remembered, why: .remembered) }
        if let selected, live.contains(selected) { return NewSessionProject(key: selected, why: .selected) }
        return live.first.map { NewSessionProject(key: $0, why: .first) }
    }

    /// What a log says of the choice: which project, and why.
    public var sentence: String { "\(key) (\(why.rawValue))" }
}
