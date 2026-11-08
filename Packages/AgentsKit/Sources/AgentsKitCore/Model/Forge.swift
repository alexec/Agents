import Foundation

/// `forge/issues`, `forge/pulls`, `forge/issue` and `forge/pull` (#3129): a machine's issues and
/// pull requests as its forges say them, one model for GitHub, GitLab, Linear and Jira (#3260), so
/// one page draws each. The data behind Work ▸ Issues and Pull requests and their pages (#3119).
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
    /// is open, closed or merged; `status` is the tracker's own name for its step, where its
    /// workflow has steps (a Jira status, as In Progress); `folder` is a folder on the machine on its repo. A pull
    /// request's own: `checks` is passing, failing, running or none; `review` is approved,
    /// changes_requested or review_required; `mergeable` is mergeable, conflicting or unknown.
    struct ForgeItem: Codable, Sendable, Hashable {
        public var node: LineageNode
        public var title: String
        public var state: String
        public var status: String?
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
        /// The hierarchy (#3267): the issue it is a sub-issue of; its level (epic, story, task or
        /// spike, from its labels); its feature (the name of its `feature:` label); and a
        /// parent's closed children of all of them, where the forge says it.
        public var parent: LineageNode?
        public var level: String?
        public var feature: String?
        public var progress: ForgeProgress?

        public init(node: LineageNode, title: String, state: String, url: String? = nil, folder: String? = nil,
                    labels: [ForgeLabel] = [], author: String? = nil, assignees: [String] = [], milestone: String? = nil,
                    updatedAt: Date, comments: Int = 0, draft: Bool? = nil, checks: String? = nil, review: String? = nil,
                    mergeable: String? = nil, autoMerge: Bool? = nil, parent: LineageNode? = nil, level: String? = nil,
                    feature: String? = nil, progress: ForgeProgress? = nil, status: String? = nil) {
            self.node = node
            self.title = title
            self.state = state
            self.status = status
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
            self.parent = parent
            self.level = level
            self.feature = feature
            self.progress = progress
        }
    }

    /// A parent issue's children (#3267): `done` are closed, of `total`.
    struct ForgeProgress: Codable, Sendable, Hashable {
        public var done: Int
        public var total: Int

        public init(done: Int, total: Int) {
            self.done = done
            self.total = total
        }
    }

    /// `forge/issues` and `forge/pulls`' question: every folder's on the machine, or one
    /// folder's. `state` is open (when nil), closed or all; `limit` is 1 to 100, 50 when nil;
    /// `feature` (a name: work for the label feature:work) narrows it to one feature (#3267);
    /// `board` (a board's url, from `forge/boards`) to one board (#3282).
    struct ForgeListRequest: Codable, Sendable, Hashable {
        public var folder: String?
        public var state: String?
        public var label: String?
        public var assignee: String?
        public var query: String?
        public var cursor: String?
        public var limit: Int?
        public var feature: String?
        public var board: String?

        public init(folder: String? = nil, state: String? = nil, label: String? = nil, assignee: String? = nil,
                    query: String? = nil, cursor: String? = nil, limit: Int? = nil, feature: String? = nil,
                    board: String? = nil) {
            self.folder = folder
            self.state = state
            self.label = label
            self.assignee = assignee
            self.query = query
            self.cursor = cursor
            self.limit = limit
            self.feature = feature
            self.board = board
        }
    }

    /// A forge a list could not read (not connected, a rate limit): github, gitlab, forgejo, bitbucket, azuredevops, linear, jira or azureboards.
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

    /// A move an issue's workflow allows now (Jira, #3260): its `id`, which `forge/close` takes,
    /// its `name` (as Start Progress), and the status `category` it goes to: new, indeterminate or done.
    struct ForgeTransition: Codable, Sendable, Hashable {
        public var id: String
        public var name: String
        public var category: String?

        public init(id: String, name: String, category: String? = nil) {
            self.id = id
            self.name = name
            self.category = category
        }
    }

    /// One item with its body and a page of its comments: the newest page first, at most 50,
    /// oldest first in the page. `cursor` is the page before it; nil at the first comment. A pull
    /// request's `head` is the commit a merge or an approval names, and `mergeMethods` its repo's,
    /// the default first (#3130); an issue's `start` is its new-agent form, and `transitions` the
    /// moves its workflow allows (Jira, #3260), in place of Close and Reopen.
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
        public var transitions: [ForgeTransition]?

        public init(item: ForgeItem, body: String = "", comments: [ForgeComment] = [], cursor: String? = nil,
                    checks: [ForgeCheck]? = nil, reviewThreads: Int? = nil, filesChanged: Int? = nil,
                    head: String? = nil, mergeMethods: [ForgeMergeMethod]? = nil, start: ForgeStart? = nil,
                    transitions: [ForgeTransition]? = nil) {
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
            self.transitions = transitions
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

    /// `forge/add-child` (#3271): a new child (`title`, with its `level`) or one that is there
    /// (`issue`: #12, owner/repo#12, its URL, or a key such as ENG-4), added to the epic `node`.
    struct ForgeAddChildRequest: Codable, Sendable, Hashable {
        public var node: LineageNode
        public var title: String?
        public var level: String?
        public var issue: String?

        public init(node: LineageNode, title: String? = nil, level: String? = nil, issue: String? = nil) {
            self.node = node
            self.title = title
            self.level = level
            self.issue = issue
        }
    }

    /// `forge/blocked-by` (#3271): issues that block the child `node`, to add and to take off.
    struct ForgeBlockedByRequest: Codable, Sendable, Hashable {
        public var node: LineageNode
        public var add: [LineageNode]?
        public var remove: [LineageNode]?

        public init(node: LineageNode, add: [LineageNode]? = nil, remove: [LineageNode]? = nil) {
            self.node = node
            self.add = add
            self.remove = remove
        }
    }

    /// `forge/close`: close it, or with `reopen` open it again; with `transition`, move a Jira
    /// issue by that transition of its workflow, by its id (#3260).
    struct ForgeCloseRequest: Codable, Sendable, Hashable {
        public var node: LineageNode
        public var reopen: Bool?
        public var transition: String?

        public init(node: LineageNode, reopen: Bool? = nil, transition: String? = nil) {
            self.node = node
            self.reopen = reopen
            self.transition = transition
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

        /// The same diff as a view's `agents/open-diff` gives it, for the app's diff page; site is the forge it is on.
        public func appViewDiff(title: String, site: String = "GitHub") -> AppViewDiff {
            AppViewDiff(title: title, url: url.flatMap(URL.init(string:)), files: files.map { f in
                AppViewDiff.File(path: f.path, previousPath: f.previousPath, change: f.change, additions: f.additions,
                                 deletions: f.deletions, hunks: f.hunks.map { h in
                                     AppViewDiff.Hunk(oldStart: max(1, h.oldStart), newStart: max(1, h.newStart), lines: h.lines.map {
                                         AppViewDiff.Line(kind: AppViewDiff.Kind(rawValue: $0.kind.rawValue) ?? .context, text: $0.text)
                                     })
                                 }, note: f.note)
            }, cut: cut, site: site)
        }
    }
}

/// `forge/plan` and `forge/features` (#3267): an epic's children in steps, from the forge's
/// sub-issues and "blocked by" links, with its lead; and the `feature:` labels on the epics.
public extension DaemonAPI {
    /// `forge/plan`'s question: the epic, an issue.
    struct ForgePlanRequest: Codable, Sendable, Hashable {
        public var node: LineageNode

        public init(node: LineageNode) {
            self.node = node
        }
    }

    /// A child of an epic: the issues it is blocked by; its step (1 when no other child blocks
    /// it); and its open blockers outside the plan.
    struct ForgePlanChild: Codable, Sendable, Hashable {
        public var item: ForgeItem
        public var blockedBy: [LineageNode]
        public var blockedOutside: [LineageNode]?
        public var step: Int

        public init(item: ForgeItem, blockedBy: [LineageNode] = [], blockedOutside: [LineageNode]? = nil, step: Int) {
            self.item = item
            self.blockedBy = blockedBy
            self.blockedOutside = blockedOutside
            self.step = step
        }
    }

    /// A step of a plan: its number, from 1, and its children's nodes.
    struct ForgePlanStep: Codable, Sendable, Hashable {
        public var step: Int
        public var nodes: [LineageNode]

        public init(step: Int, nodes: [LineageNode]) {
            self.step = step
            self.nodes = nodes
        }
    }

    /// An epic's lead session: the session labelled with the epic and `lead`.
    struct ForgeLead: Codable, Sendable, Hashable {
        public var session: UUID
        public var title: String?
        public var state: AgentState

        public init(session: UUID, title: String? = nil, state: AgentState) {
            self.session = session
            self.title = title
            self.state = state
        }
    }

    /// An epic and its plan: its children, step by step; the steps; and its lead, if any.
    struct ForgePlan: Codable, Sendable, Hashable {
        public var item: ForgeItem
        public var children: [ForgePlanChild]
        public var steps: [ForgePlanStep]
        public var lead: ForgeLead?

        public init(item: ForgeItem, children: [ForgePlanChild] = [], steps: [ForgePlanStep] = [], lead: ForgeLead? = nil) {
            self.item = item
            self.children = children
            self.steps = steps
            self.lead = lead
        }
    }

    /// `forge/features`' question: every folder's on the machine, or one folder's; `board` (a
    /// board's url) only the epics on that board (#3282).
    struct ForgeFeaturesRequest: Codable, Sendable, Hashable {
        public var folder: String?
        public var board: String?

        public init(folder: String? = nil, board: String? = nil) {
            self.folder = folder
            self.board = board
        }
    }

    /// `forge/boards`' question (#3282): the boards of every folder's project on the machine,
    /// or of one folder's.
    struct ForgeBoardsRequest: Codable, Sendable, Hashable {
        public var folder: String?

        public init(folder: String? = nil) { self.folder = folder }
    }

    /// `forge/boards`' answer: each board once, by url.
    struct ForgeBoards: Codable, Sendable, Hashable {
        public var boards: [ProjectBoard]

        public init(boards: [ProjectBoard] = []) { self.boards = boards }
    }

    /// `forge/image`'s question (#4009): the url of an image on a forge page.
    struct ForgeImageRequest: Codable, Sendable, Hashable {
        public var url: String

        public init(url: String) { self.url = url }
    }

    /// `forge/image`'s answer: the image's bytes and their type (PNG, JPEG, GIF or WebP), so a
    /// client never loads the page's remote URL.
    struct ForgeImage: Codable, Sendable, Hashable {
        public var mimeType: String
        public var data: Data

        public init(mimeType: String, data: Data) {
            self.mimeType = mimeType
            self.data = data
        }
    }

    /// A feature: its label's name after `feature:`, with its colour; its epics, and the open ones;
    /// its open issues that are not epics (#3741), absent from a daemon that does not count them.
    struct ForgeFeature: Codable, Sendable, Hashable {
        public var name: String
        public var color: String?
        public var epics: Int
        public var open: Int
        public var issues: Int?

        public init(name: String, color: String? = nil, epics: Int, open: Int, issues: Int? = nil) {
            self.name = name
            self.color = color
            self.epics = epics
            self.open = open
            self.issues = issues
        }
    }

    /// The features, by name; `errors` says a forge that could not be read.
    struct ForgeFeatures: Codable, Sendable, Hashable {
        public var features: [ForgeFeature]
        public var errors: [ForgeListError]?

        public init(features: [ForgeFeature] = [], errors: [ForgeListError]? = nil) {
            self.features = features
            self.errors = errors
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
    /// `ForgePlanRequest` → `ForgePlan`, `ForgeFeaturesRequest` → `ForgeFeatures` (#3267).
    static let forgePlan = "forge/plan"
    static let forgeFeatures = "forge/features"
    /// `ForgeBoardsRequest` → `ForgeBoards` (#3282).
    static let forgeBoards = "forge/boards"
    /// `ForgeImageRequest` → `ForgeImage` (#4009).
    static let forgeImage = "forge/image"
    /// The plan's writes (#3271): `ForgeAddChildRequest` and `ForgeBlockedByRequest` → `ForgeDone`.
    static let forgeAddChild = "forge/add-child"
    static let forgeBlockedBy = "forge/blocked-by"
}
