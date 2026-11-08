import Foundation

/// The control plane's people, open to a member as much as an admin (#2951): for the
/// servers' Team section, and Settings ▸ Account's GitHub, GitLab, Linear, Jira, Forgejo
/// (#3836), Bitbucket and Azure DevOps (#3853) login fields.
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
        /// The Atlassian account's email, account id or display name (#3313).
        public var jiraLogin: String?
        /// Their user name on the connected Forgejo or Gitea (#3836).
        public var forgejoLogin: String?
        /// Their Bitbucket nickname (#3853).
        public var bitbucketLogin: String?
        /// Their sign-in email or display name in the Azure DevOps organization (#3853).
        public var azureDevOpsLogin: String?
        public var you: Bool?

        public init(id: String, name: String, kind: PersonRow.Kind = .person, githubLogin: String? = nil,
                    gitlabLogin: String? = nil, linearLogin: String? = nil, jiraLogin: String? = nil,
                    forgejoLogin: String? = nil, bitbucketLogin: String? = nil, azureDevOpsLogin: String? = nil,
                    you: Bool? = nil) {
            self.id = id
            self.name = name
            self.kind = kind
            self.githubLogin = githubLogin
            self.gitlabLogin = gitlabLogin
            self.linearLogin = linearLogin
            self.jiraLogin = jiraLogin
            self.forgejoLogin = forgejoLogin
            self.bitbucketLogin = bitbucketLogin
            self.azureDevOpsLogin = azureDevOpsLogin
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

    /// `people/setForgeLogins`'s params: the caller's own GitHub, GitLab, Linear, Jira, Forgejo,
    /// Bitbucket and Azure DevOps logins, for Settings ▸ Account, replacing what was kept; blank
    /// clears one.
    struct ForgeLogins: Codable, Sendable, Hashable {
        public var github: String?
        public var gitlab: String?
        public var linear: String?
        public var jira: String?
        public var forgejo: String?
        public var bitbucket: String?
        public var azureDevOps: String?

        public init(github: String? = nil, gitlab: String? = nil, linear: String? = nil, jira: String? = nil,
                    forgejo: String? = nil, bitbucket: String? = nil, azureDevOps: String? = nil) {
            self.github = github
            self.gitlab = gitlab
            self.linear = linear
            self.jira = jira
            self.forgejo = forgejo
            self.bitbucket = bitbucket
            self.azureDevOps = azureDevOps
        }
    }
}

public extension DaemonAPI.Method {
    /// `Empty` → `PeopleForViews`, open to a member as much as an admin (#2951).
    static let peopleForViews = "people/forViews"
    /// `ForgeLogins` → `{}`, the caller's own (#2951).
    static let peopleSetForgeLogins = "people/setForgeLogins"
}
