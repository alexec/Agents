import Foundation

/// `forge/issues`, `forge/pulls`, `forge/issue` and `forge/pull` (#3129): a machine's issues and
/// pull requests as its forges say them, one model for GitHub, GitLab and Linear, so one page
/// draws each. The data behind Work ▸ Issues and Pull requests and their pages (#3119).
public extension DaemonAPI {
    /// A label, with its `#rrggbb` colour where the forge gives one (#2956).
    struct ForgeLabel: Codable, Sendable, Hashable {
        public var name: String
        public var color: String?

        public init(name: String, color: String? = nil) {
            self.name = name
            self.color = color
        }
    }

    /// An issue or a pull request (a GitLab merge request). `node` is its lineage node; `state`
    /// is open, closed or merged; `folder` is a folder on the machine on its repo. A pull
    /// request's own: `checks` is passing, failing, running or none; `review` is approved,
    /// changes_requested or review_required; `mergeable` is mergeable, conflicting or unknown.
    struct ForgeItem: Codable, Sendable, Hashable {
        public var node: LineageNode
        public var title: String
        public var state: String
        public var url: String?
        public var folder: String?
        public var labels: [ForgeLabel]
        public var author: String?
        public var assignees: [String]
        public var milestone: String?
        public var updatedAt: Date
        public var comments: Int
        public var draft: Bool?
        public var checks: String?
        public var review: String?
        public var mergeable: String?
        public var autoMerge: Bool?

        public init(node: LineageNode, title: String, state: String, url: String? = nil, folder: String? = nil,
                    labels: [ForgeLabel] = [], author: String? = nil, assignees: [String] = [], milestone: String? = nil,
                    updatedAt: Date, comments: Int = 0, draft: Bool? = nil, checks: String? = nil, review: String? = nil,
                    mergeable: String? = nil, autoMerge: Bool? = nil) {
            self.node = node
            self.title = title
            self.state = state
            self.url = url
            self.folder = folder
            self.labels = labels
            self.author = author
            self.assignees = assignees
            self.milestone = milestone
            self.updatedAt = updatedAt
            self.comments = comments
            self.draft = draft
            self.checks = checks
            self.review = review
            self.mergeable = mergeable
            self.autoMerge = autoMerge
        }
    }

    /// `forge/issues` and `forge/pulls`' question: every folder's on the machine, or one
    /// folder's. `state` is open (when nil), closed or all; `limit` is 1 to 100, 50 when nil.
    struct ForgeListRequest: Codable, Sendable, Hashable {
        public var folder: String?
        public var state: String?
        public var label: String?
        public var assignee: String?
        public var query: String?
        public var cursor: String?
        public var limit: Int?

        public init(folder: String? = nil, state: String? = nil, label: String? = nil, assignee: String? = nil,
                    query: String? = nil, cursor: String? = nil, limit: Int? = nil) {
            self.folder = folder
            self.state = state
            self.label = label
            self.assignee = assignee
            self.query = query
            self.cursor = cursor
            self.limit = limit
        }
    }

    /// A forge a list could not read (not connected, a rate limit): github, gitlab or linear.
    struct ForgeListError: Codable, Sendable, Hashable {
        public var forge: String
        public var message: String

        public init(forge: String, message: String) {
            self.forge = forge
            self.message = message
        }
    }

    /// A page of items, the last updated first. `cursor` is the next page; nil at the end.
    struct ForgeList: Codable, Sendable, Hashable {
        public var items: [ForgeItem]
        public var cursor: String?
        public var errors: [ForgeListError]?

        public init(items: [ForgeItem] = [], cursor: String? = nil, errors: [ForgeListError]? = nil) {
            self.items = items
            self.cursor = cursor
            self.errors = errors
        }
    }

    /// `forge/issue` and `forge/pull`'s question: the item, and for an older page of its
    /// comments the cursor of the page after it.
    struct ForgeItemRequest: Codable, Sendable, Hashable {
        public var node: LineageNode
        public var cursor: String?

        public init(node: LineageNode, cursor: String? = nil) {
            self.node = node
            self.cursor = cursor
        }
    }

    /// A comment, as Markdown. `bot` says a bot or an app wrote it.
    struct ForgeComment: Codable, Sendable, Hashable {
        public var author: String
        public var body: String
        public var at: Date
        public var url: String?
        public var bot: Bool?

        public init(author: String, body: String, at: Date, url: String? = nil, bot: Bool? = nil) {
            self.author = author
            self.body = body
            self.at = at
            self.url = url
            self.bot = bot
        }
    }

    /// One of a pull request's checks: passing, failing, running or skipped.
    struct ForgeCheck: Codable, Sendable, Hashable {
        public var name: String
        public var state: String
        public var url: String?

        public init(name: String, state: String, url: String? = nil) {
            self.name = name
            self.state = state
            self.url = url
        }
    }

    /// One item with its body and a page of its comments: the newest page first, at most 50,
    /// oldest first in the page. `cursor` is the page before it; nil at the first comment.
    struct ForgeItemDetail: Codable, Sendable, Hashable {
        public var item: ForgeItem
        public var body: String
        public var comments: [ForgeComment]
        public var cursor: String?
        public var checks: [ForgeCheck]?
        public var reviewThreads: Int?
        public var filesChanged: Int?

        public init(item: ForgeItem, body: String = "", comments: [ForgeComment] = [], cursor: String? = nil,
                    checks: [ForgeCheck]? = nil, reviewThreads: Int? = nil, filesChanged: Int? = nil) {
            self.item = item
            self.body = body
            self.comments = comments
            self.cursor = cursor
            self.checks = checks
            self.reviewThreads = reviewThreads
            self.filesChanged = filesChanged
        }
    }
}

public extension DaemonAPI.Method {
    /// `ForgeListRequest` → `ForgeList` (#3129).
    static let forgeIssues = "forge/issues"
    static let forgePulls = "forge/pulls"
    /// `ForgeItemRequest` → `ForgeItemDetail` (#3129).
    static let forgeIssue = "forge/issue"
    static let forgePull = "forge/pull"
}
