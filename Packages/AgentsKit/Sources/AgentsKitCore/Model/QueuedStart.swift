import Foundation

/// What `start_agent` asked for, kept on a queued helper's record until a place frees
/// (#362).
///
/// The words as the starter wrote them, not a settled start: settling a mode or a model
/// makes a runtime to ask what it offers, and a queued agent spawns nothing. They are
/// settled when it starts, and one that no longer can be is stopped saying why.
public struct QueuedStart: Codable, Hashable, Sendable {
    public var runtimeID: String?
    public var permissionMode: String?
    public var model: String?
    public var worktree: WorktreeChoice?
    public var labels: [String]

    public init(runtimeID: String? = nil, permissionMode: String? = nil, model: String? = nil,
                worktree: WorktreeChoice? = nil, labels: [String] = []) {
        self.runtimeID = runtimeID
        self.permissionMode = permissionMode
        self.model = model
        self.worktree = worktree
        self.labels = labels
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        runtimeID = try c.decodeIfPresent(String.self, forKey: .runtimeID)
        permissionMode = try c.decodeIfPresent(String.self, forKey: .permissionMode)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        worktree = try? c.decodeIfPresent(WorktreeChoice.self, forKey: .worktree)
        labels = try c.decodeIfPresent([String].self, forKey: .labels) ?? []
    }
}
