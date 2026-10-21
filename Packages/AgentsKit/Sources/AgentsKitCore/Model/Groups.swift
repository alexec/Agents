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

/// The words Settings ▸ Groups and a provider's group are shown in, the same on the Mac and
/// the Remote (the web page's are in `Web/src/model/teamGroups.ts`).
public enum GroupWords {
    public static let title = "Groups"
    /// A provider with no group.
    public static let adminsOnly = "Admins only"

    /// "Everyone", "Sam, Kim", or "No one".
    public static func members(_ group: DaemonAPI.Group, people: [DaemonAPI.PersonRow]) -> String {
        if group.everyone { return "Everyone" }
        guard !group.members.isEmpty else { return "No one" }
        return group.members.map { id in people.first { $0.id == id }?.name ?? "Someone removed" }
            .joined(separator: ", ")
    }

    /// "DigitalOcean, Docker", or nil with none.
    public static func providers(_ group: DaemonAPI.Group, of all: [DaemonAPI.ProviderSummary]) -> String? {
        let names = all.filter { $0.group == group.id }.map(\.name)
        return names.isEmpty ? nil : names.joined(separator: ", ")
    }

    /// Who a provider is for: its group's name, or the admins alone.
    public static func provider(_ provider: DaemonAPI.ProviderSummary, groups: [DaemonAPI.Group]) -> String {
        guard let id = provider.group, !id.isEmpty else { return adminsOnly }
        return groups.first { $0.id == id }?.name ?? "A group not shown to you"
    }

    /// "For Platform": a provider's line, said only when there are groups.
    public static func providerLine(_ provider: DaemonAPI.ProviderSummary, groups: [DaemonAPI.Group]) -> String? {
        guard !groups.isEmpty || provider.group != nil else { return nil }
        guard provider.group?.isEmpty == false else { return "For admins only" }
        return "For \(self.provider(provider, groups: groups))"
    }

    /// Why New Machine… is not there for a provider the caller sees but may not use.
    public static func mayNotUse(_ provider: DaemonAPI.ProviderSummary, groups: [DaemonAPI.Group]) -> String {
        guard let id = provider.group, !id.isEmpty else {
            return "Give \(provider.name) to a group to start machines from it."
        }
        let name = groups.first { $0.id == id }?.name ?? "its group"
        return "Only \(name) can start machines from \(provider.name)."
    }

    public static func foot(admin: Bool) -> String {
        admin
            ? "A group is everyone, or the people you name. Give a workspace provider to a group, and only its people see it and start machines from it. A provider with no group is for admins only."
            : "The groups you are in. Their workspace providers are the ones you can start machines from."
    }

    public static func removeTitle(_ group: DaemonAPI.Group) -> String { "Remove \(group.name)?" }

    public static let removeMessage = "Its people keep their machines. A provider must go to another group first."
}
