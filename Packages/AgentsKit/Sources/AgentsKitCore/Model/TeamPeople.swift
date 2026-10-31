import Foundation

/// The control plane's people, open to a member as much as an admin (#2951): for the
/// github, gitlab and linear servers' Team section, and Settings ▸ Account's GitHub,
/// GitLab and Linear login fields.
public extension DaemonAPI {
    /// One person or bot on this control plane, in `people/forViews`: narrower than
    /// `PersonRow`, with no role, clients or machines.
    struct TeamPerson: Codable, Sendable, Hashable, Identifiable {
        public var id: String
        public var name: String
        public var kind: PersonRow.Kind
        public var githubLogin: String?
        public var gitlabLogin: String?
        public var linearLogin: String?
        public var you: Bool?

        public init(id: String, name: String, kind: PersonRow.Kind = .person, githubLogin: String? = nil,
                    gitlabLogin: String? = nil, linearLogin: String? = nil, you: Bool? = nil) {
            self.id = id
            self.name = name
            self.kind = kind
            self.githubLogin = githubLogin
            self.gitlabLogin = gitlabLogin
            self.linearLogin = linearLogin
            self.you = you
        }
    }

    /// `people/forViews`'s result: every person and bot on this control plane.
    struct PeopleForViews: Codable, Sendable, Hashable {
        public var people: [TeamPerson]

        public init(people: [TeamPerson]) {
            self.people = people
        }
    }

    /// `people/setForgeLogins`'s params: the caller's own GitHub, GitLab and Linear
    /// logins, for Settings ▸ Account, replacing what was kept; blank clears one.
    struct ForgeLogins: Codable, Sendable, Hashable {
        public var github: String?
        public var gitlab: String?
        public var linear: String?

        public init(github: String? = nil, gitlab: String? = nil, linear: String? = nil) {
            self.github = github
            self.gitlab = gitlab
            self.linear = linear
        }
    }
}

public extension DaemonAPI.Method {
    /// `Empty` → `PeopleForViews`, open to a member as much as an admin (#2951).
    static let peopleForViews = "people/forViews"
    /// `ForgeLogins` → `{}`, the caller's own (#2951).
    static let peopleSetForgeLogins = "people/setForgeLogins"
}
