import Foundation

/// Groups (#1761, spec 736 FR-027, FR-028): everyone, or named users. A group owns
/// workspace providers: only its users see them and start machines from them. A provider
/// with no group is the admins' alone.
public extension DaemonAPI {
    /// A group, in `groups/list` and as `groups/set` answers.
    struct Group: Codable, Sendable, Hashable, Identifiable {
        public var id: String
        public var name: String
        public var everyone: Bool
        public var members: [String]

        public init(id: String, name: String, everyone: Bool = false, members: [String] = []) {
            self.id = id
            self.name = name
            self.everyone = everyone
            self.members = members
        }

        /// Says a user is in it.
        public func has(_ user: String) -> Bool { everyone || members.contains(user) }
    }

    /// `groups/list`: every group for an admin; for a member, the groups they are in.
    struct GroupList: Codable, Sendable, Hashable {
        public var groups: [Group]

        public init(groups: [Group] = []) { self.groups = groups }
    }

    /// `groups/set`: makes a group, or with `id` changes one.
    struct GroupSet: Codable, Sendable, Hashable {
        public var id: String?
        public var name: String
        public var everyone: Bool?
        public var members: [String]?

        public init(id: String? = nil, name: String, everyone: Bool? = nil, members: [String]? = nil) {
            self.id = id
            self.name = name
            self.everyone = everyone
            self.members = members
        }
    }

    /// `groups/remove`. Refused while a workspace provider or a bot has the group.
    struct GroupRequest: Codable, Sendable, Hashable {
        public var id: String

        public init(id: String) { self.id = id }
    }

    /// `providers/setGroup`: no group is the admins' alone.
    struct ProviderGroup: Codable, Sendable, Hashable {
        public var provider: ProviderID
        public var group: String?

        public init(provider: ProviderID, group: String? = nil) {
            self.provider = provider
            self.group = group
        }
    }

    /// `control/groupsChanged`: a group was made, changed or removed.
    struct GroupsChanged: Codable, Sendable, Hashable {
        public var id: String?
        public var removed: Bool?

        public init(id: String? = nil, removed: Bool? = nil) {
            self.id = id
            self.removed = removed
        }
    }
}

public extension DaemonAPI.Method {
    /// `Empty` → `GroupList` (#1761).
    static let groupsList = "groups/list"
    /// `GroupSet` → `Group`, an admin's only (#1761).
    static let groupsSet = "groups/set"
    /// `GroupRequest` → `{}`, an admin's only (#1761).
    static let groupsRemove = "groups/remove"
    /// `ProviderGroup` → `{}`, an admin's only (#1761).
    static let providersSetGroup = "providers/setGroup"
}

public extension DaemonAPI.Notification {
    /// `GroupsChanged`: load Groups again (#1761).
    static let controlGroupsChanged = "control/groupsChanged"
}
