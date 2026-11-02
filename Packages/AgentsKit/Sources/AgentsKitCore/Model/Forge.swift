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

    /// How `forge/merge` merges a pull request (#3130).
    enum ForgeMergeMethod: String, Codable, Sendable, Hashable, CaseIterable {
        case merge, squash, rebase
    }

    /// The new-agent form for an issue (#3130, Start Agent), as a view's `agents/start-agent` fills it.
    struct ForgeStart: Codable, Sendable, Hashable {
        public var prompt: String
        public var labels: [String]
        public var worktree: String?

        public init(prompt: String, labels: [String] = [], worktree: String? = nil) {
            self.prompt = prompt
            self.labels = labels
            self.worktree = worktree
        }
    }

    /// One item with its body and a page of its comments: the newest page first, at most 50,
    /// oldest first in the page. `cursor` is the page before it; nil at the first comment. A pull
    /// request's `head` is the commit a merge or an approval names, and `mergeMethods` its repo's,
    /// the default first (#3130); an issue's `start` is its new-agent form.
    struct ForgeItemDetail: Codable, Sendable, Hashable {
        public var item: ForgeItem
        public var body: String
        public var comments: [ForgeComment]
        public var cursor: String?
        public var checks: [ForgeCheck]?
        public var reviewThreads: Int?
        public var filesChanged: Int?
        public var head: String?
        public var mergeMethods: [ForgeMergeMethod]?
        public var start: ForgeStart?

        public init(item: ForgeItem, body: String = "", comments: [ForgeComment] = [], cursor: String? = nil,
                    checks: [ForgeCheck]? = nil, reviewThreads: Int? = nil, filesChanged: Int? = nil,
                    head: String? = nil, mergeMethods: [ForgeMergeMethod]? = nil, start: ForgeStart? = nil) {
            self.item = item
            self.body = body
            self.comments = comments
            self.cursor = cursor
            self.checks = checks
            self.reviewThreads = reviewThreads
            self.filesChanged = filesChanged
            self.head = head
            self.mergeMethods = mergeMethods
            self.start = start
        }
    }

    // MARK: Writes (#3130)

    /// `forge/labels`, `forge/rerun` and `forge/diff`'s question: the issue or pull request.
    struct ForgeNodeRequest: Codable, Sendable, Hashable {
        public var node: LineageNode

        public init(node: LineageNode) { self.node = node }
    }

    /// `forge/comment`: a comment, as Markdown.
    struct ForgeCommentRequest: Codable, Sendable, Hashable {
        public var node: LineageNode
        public var body: String

        public init(node: LineageNode, body: String) {
            self.node = node
            self.body = body
        }
    }

    /// `forge/label`: labels to add, and labels to take off, by name.
    struct ForgeLabelRequest: Codable, Sendable, Hashable {
        public var node: LineageNode
        public var add: [String]?
        public var remove: [String]?

        public init(node: LineageNode, add: [String]? = nil, remove: [String]? = nil) {
            self.node = node
            self.add = add
            self.remove = remove
        }
    }

    /// `forge/close`: close it, or with `reopen` open it again.
    struct ForgeCloseRequest: Codable, Sendable, Hashable {
        public var node: LineageNode
        public var reopen: Bool?

        public init(node: LineageNode, reopen: Bool? = nil) {
            self.node = node
            self.reopen = reopen
        }
    }

    /// `forge/merge`: merge at `sha`, the head the page shows, by `method` (the repo's default
    /// when nil); with `auto`, once its checks pass.
    struct ForgeMergeRequest: Codable, Sendable, Hashable {
        public var node: LineageNode
        public var sha: String
        public var method: ForgeMergeMethod?
        public var auto: Bool?

        public init(node: LineageNode, sha: String, method: ForgeMergeMethod? = nil, auto: Bool? = nil) {
            self.node = node
            self.sha = sha
            self.method = method
            self.auto = auto
        }
    }

    /// `forge/approve`: approve at `sha`, the head the page shows.
    struct ForgeApproveRequest: Codable, Sendable, Hashable {
        public var node: LineageNode
        public var sha: String

        public init(node: LineageNode, sha: String) {
            self.node = node
            self.sha = sha
        }
    }

    /// `forge/log`: the failed checks' logs, or one check's by name.
    struct ForgeLogRequest: Codable, Sendable, Hashable {
        public var node: LineageNode
        public var check: String?

        public init(node: LineageNode, check: String? = nil) {
            self.node = node
            self.check = check
        }
    }

    /// What a write did: `url` is the comment or the item; `auto` says a merge waits for the
    /// checks; `reran` is how many runs or pipelines ran again.
    struct ForgeDone: Codable, Sendable, Hashable {
        public var url: String?
        public var auto: Bool?
        public var reran: Int?

        public init(url: String? = nil, auto: Bool? = nil, reran: Int? = nil) {
            self.url = url
            self.auto = auto
            self.reran = reran
        }
    }

    /// `forge/labels`: the labels it can have, at most 100.
    struct ForgeLabels: Codable, Sendable, Hashable {
        public var labels: [ForgeLabel]

        public init(labels: [ForgeLabel] = []) { self.labels = labels }
    }

    /// `forge/log`: the last lines of each failed check's log.
    struct ForgeLog: Codable, Sendable, Hashable {
        public var text: String

        public init(text: String) { self.text = text }
    }

    /// One @@ block of a file's diff.
    struct ForgeDiffHunk: Codable, Sendable, Hashable {
        public var oldStart: Int
        public var newStart: Int
        public var lines: [DiffLine]

        public init(oldStart: Int, newStart: Int, lines: [DiffLine]) {
            self.oldStart = oldStart
            self.newStart = newStart
            self.lines = lines
        }
    }

    /// One file a pull request changes; `note` says why it has no hunks, when it has none.
    struct ForgeDiffFile: Codable, Sendable, Hashable {
        public var path: String
        public var previousPath: String?
        public var change: String
        public var additions: Int
        public var deletions: Int
        public var hunks: [ForgeDiffHunk]
        public var note: String?

        public init(path: String, previousPath: String? = nil, change: String = "modified", additions: Int = 0,
                    deletions: Int = 0, hunks: [ForgeDiffHunk] = [], note: String? = nil) {
            self.path = path
            self.previousPath = previousPath
            self.change = change
            self.additions = additions
            self.deletions = deletions
            self.hunks = hunks
            self.note = note
        }
    }

    /// `forge/diff`: a pull request's files at its head, as the app's own diff draws them (#1341).
    struct ForgeDiff: Codable, Sendable, Hashable {
        public var url: String?
        public var files: [ForgeDiffFile]
        public var cut: Bool

        public init(url: String? = nil, files: [ForgeDiffFile] = [], cut: Bool = false) {
            self.url = url
            self.files = files
            self.cut = cut
        }

        /// The same diff as a view's `agents/open-diff` gives it, for the app's diff page.
        public func appViewDiff(title: String) -> AppViewDiff {
            AppViewDiff(title: title, url: url.flatMap(URL.init(string:)), files: files.map { f in
                AppViewDiff.File(path: f.path, previousPath: f.previousPath, change: f.change, additions: f.additions,
                                 deletions: f.deletions, hunks: f.hunks.map { h in
                                     AppViewDiff.Hunk(oldStart: max(1, h.oldStart), newStart: max(1, h.newStart), lines: h.lines.map {
                                         AppViewDiff.Line(kind: AppViewDiff.Kind(rawValue: $0.kind.rawValue) ?? .context, text: $0.text)
                                     })
                                 }, note: f.note)
            }, cut: cut)
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
    /// The writes (#3130): `ForgeCommentRequest`, `ForgeLabelRequest`, `ForgeCloseRequest`,
    /// `ForgeMergeRequest`, `ForgeApproveRequest` and `ForgeNodeRequest` → `ForgeDone`.
    static let forgeComment = "forge/comment"
    static let forgeLabel = "forge/label"
    static let forgeClose = "forge/close"
    static let forgeMerge = "forge/merge"
    static let forgeApprove = "forge/approve"
    static let forgeRerun = "forge/rerun"
    /// `ForgeNodeRequest` → `ForgeLabels`, `ForgeLogRequest` → `ForgeLog`, `ForgeNodeRequest` → `ForgeDiff` (#3130).
    static let forgeLabels = "forge/labels"
    static let forgeLog = "forge/log"
    static let forgeDiff = "forge/diff"
}
