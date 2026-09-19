import Foundation

/// A conversation a runtime is holding, which may or may not be an agent in this app.
///
/// The runtime's list is the only way to find work started somewhere else: a session
/// from a terminal yesterday, in a folder this app knows.
public struct RuntimeSession: Codable, Hashable, Sendable, Identifiable {
    public var sessionID: String
    public var cwd: URL
    public var additionalDirectories: [URL]
    /// The title the runtime wrote for itself.
    public var title: String?
    public var updatedAt: Date?
    /// Whether an agent in this app already has it. Flagged rather than hidden, so the
    /// list is the truth about the runtime.
    public var isHeld: Bool

    public var id: String { sessionID }

    public init(sessionID: String, cwd: URL, additionalDirectories: [URL] = [],
                title: String? = nil, updatedAt: Date? = nil, isHeld: Bool = false) {
        self.sessionID = sessionID
        self.cwd = cwd
        self.additionalDirectories = additionalDirectories
        self.title = title
        self.updatedAt = updatedAt
        self.isHeld = isHeld
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try c.decode(String.self, forKey: .sessionID)
        cwd = try c.decode(URL.self, forKey: .cwd)
        additionalDirectories = try c.decodeIfPresent([URL].self, forKey: .additionalDirectories) ?? []
        title = try c.decodeIfPresent(String.self, forKey: .title)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
        isHeld = try c.decodeIfPresent(Bool.self, forKey: .isHeld) ?? false
    }
}
