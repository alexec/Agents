import Foundation

/// The forge's releases (#4426): `forge/releases` lists the releases of the folders' repos, and
/// `forge/release` reads one, with the pull requests between its tag and the release before it.
public extension DaemonAPI {
    /// `forge/releases`' question: every folder's repo, or one folder's; at most `limit` (1 to
    /// 100, 30 when nil) of each repo.
    struct ForgeReleasesRequest: Codable, Sendable, Hashable {
        public var folder: String?
        public var limit: Int?

        public init(folder: String? = nil, limit: Int? = nil) {
            self.folder = folder
            self.limit = limit
        }
    }

    /// A release on a forge. `node` is its lineage node (kind release), which `forge/release`
    /// reads. `publishedAt` is nil on a draft; `latest` is the repo's newest published release
    /// that is neither a draft nor a pre-release.
    struct ForgeRelease: Codable, Sendable, Hashable {
        public var node: LineageNode
        public var forge: String
        public var repo: String
        public var folder: String?
        public var tag: String
        public var name: String
        public var body: String?
        public var draft: Bool
        public var prerelease: Bool
        public var latest: Bool
        public var createdAt: String?
        public var publishedAt: String?
        public var author: String?
        public var authorAvatar: String?
        public var assets: Int
        public var url: String

        public init(node: LineageNode, forge: String, repo: String, folder: String? = nil, tag: String, name: String,
                    body: String? = nil, draft: Bool = false, prerelease: Bool = false, latest: Bool = false,
                    createdAt: String? = nil, publishedAt: String? = nil, author: String? = nil,
                    authorAvatar: String? = nil, assets: Int = 0, url: String) {
            self.node = node
            self.forge = forge
            self.repo = repo
            self.folder = folder
            self.tag = tag
            self.name = name
            self.body = body
            self.draft = draft
            self.prerelease = prerelease
            self.latest = latest
            self.createdAt = createdAt
            self.publishedAt = publishedAt
            self.author = author
            self.authorAvatar = authorAvatar
            self.assets = assets
            self.url = url
        }
    }

    /// `forge/releases`' answer, newest first. `none` are the forges in reach that have no
    /// releases, and why; `errors` the forges that could not be read.
    struct ForgeReleases: Codable, Sendable, Hashable {
        public var releases: [ForgeRelease]
        public var none: [ForgeListError]?
        public var errors: [ForgeListError]?

        public init(releases: [ForgeRelease] = [], none: [ForgeListError]? = nil, errors: [ForgeListError]? = nil) {
            self.releases = releases
            self.none = none
            self.errors = errors
        }
    }

    /// `forge/release`'s question: a release's node.
    struct ForgeReleaseRequest: Codable, Sendable, Hashable {
        public var node: LineageNode

        public init(node: LineageNode) { self.node = node }
    }

    /// A pull request in a release: its node, number, its squash commit's title and the commit.
    struct ForgeReleasePull: Codable, Sendable, Hashable {
        public var node: LineageNode
        public var number: Int
        public var title: String
        public var sha: String

        public init(node: LineageNode, number: Int, title: String, sha: String) {
            self.node = node
            self.number = number
            self.title = title
            self.sha = sha
        }
    }

    /// `forge/release`'s answer: the release, the tag before it (nil for the first, or a draft),
    /// the commits between the two, and the pull requests they merged, oldest first.
    struct ForgeReleaseDetail: Codable, Sendable, Hashable {
        public var release: ForgeRelease
        public var previous: String?
        public var compareUrl: String?
        public var commits: Int
        public var pulls: [ForgeReleasePull]

        public init(release: ForgeRelease, previous: String? = nil, compareUrl: String? = nil, commits: Int = 0,
                    pulls: [ForgeReleasePull] = []) {
            self.release = release
            self.previous = previous
            self.compareUrl = compareUrl
            self.commits = commits
            self.pulls = pulls
        }
    }
}
