import Foundation

/// A project's repository on GitHub, read from its `origin` (038 FR-001).
///
/// "On GitHub" is the host containing `github`, which takes in github.com and
/// Enterprise hosts such as `github.example.com` alike. A host that only happens to
/// have the word in it gets one line saying pull requests can't be seen, and nothing
/// else, which is the cheap way to be wrong.
public struct GitHubRepository: Codable, Hashable, Sendable {
    /// Lowercased.
    public var host: String
    public var owner: String
    /// Without `.git`.
    public var name: String

    public init(host: String, owner: String, name: String) {
        self.host = host.lowercased()
        self.owner = owner
        self.name = name
    }

    public init?(remote: GitRemote) {
        guard remote.host.contains("github") else { return nil }
        let parts = remote.path.split(separator: "/").map(String.init)
        guard parts.count == 2 else { return nil }
        var name = parts[1]
        if name.hasSuffix(".git") { name.removeLast(4) }
        guard !parts[0].isEmpty, !name.isEmpty else { return nil }
        self.init(host: remote.host, owner: parts[0], name: name)
    }

    /// `owner/name`, the way GitHub writes it.
    public var fullName: String { "\(owner)/\(name)" }

    public var webURL: URL { URL(string: "https://\(host)/\(owner)/\(name)")! }
}

/// A check that failed on a pull request's head commit.
public struct FailedCheck: Codable, Hashable, Sendable {
    /// GitHub's id for the check run, or the status context's name. What makes a re-run
    /// a new failure and the same run the same one.
    public var id: String
    public var name: String
    public var logURL: URL?

    public init(id: String, name: String, logURL: URL?) {
        self.id = id
        self.name = name
        self.logURL = logURL
    }
}

public enum PullRequestChecks: Codable, Hashable, Sendable {
    case passing
    case failing([FailedCheck])
    case running
    /// The head commit has no checks at all.
    case none
}

public enum PullRequestReview: String, Codable, Hashable, Sendable {
    case approved
    case changesRequested
    case commented
    case none
}

public enum PullRequestConflicts: String, Codable, Hashable, Sendable {
    case clean
    case conflicting
    /// GitHub works mergeability out lazily. Not yet known is not a conflict.
    case unknown
}

/// Something a reviewer wrote that may start babysitting.
///
/// Only the ones that count are kept (FR-011a): by somebody with write access, who is
/// not the viewer and not a bot. Anybody else's words never reach an agent.
public struct ReviewItem: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Hashable, Sendable {
        /// A review as a whole: asking for changes, or commenting with a body.
        case review
        /// A comment on a line, in a review thread.
        case threadComment
        /// A comment on the pull request's conversation.
        case conversationComment
    }

    /// GitHub's databaseId.
    public var id: Int
    public var kind: Kind
    public var author: String
    public var body: String
    public var path: String?
    public var line: Int?
    public var createdAt: Date
    public var url: URL?
    /// Set on a review asking for changes, which the prompt says in words.
    public var requestsChanges: Bool

    public init(id: Int, kind: Kind, author: String, body: String, path: String? = nil,
                line: Int? = nil, createdAt: Date, url: URL? = nil, requestsChanges: Bool = false) {
        self.id = id
        self.kind = kind
        self.author = author
        self.body = body
        self.path = path
        self.line = line
        self.createdAt = createdAt
        self.url = url
        self.requestsChanges = requestsChanges
    }
}

/// Where a pull request's branch is checked out in this project (FR-006).
///
/// Not an `AgentWorktree`: that one records how an agent was started, and a pull
/// request is checked out wherever git says its branch is, the project folder included.
public struct PullRequestWorktree: Codable, Hashable, Sendable {
    /// Where an agent works: the same subfolder of the worktree that the project folder
    /// is of its repository, or the project folder itself.
    public var root: URL
    /// The top of the checkout, which is what git and 030's `.existing` know it by.
    public var checkout: URL
    /// The folder's name, or "project folder".
    public var name: String
    public var isProjectFolder: Bool

    public init(root: URL, checkout: URL? = nil, name: String, isProjectFolder: Bool) {
        self.root = root
        self.checkout = checkout ?? root
        self.name = name
        self.isProjectFolder = isProjectFolder
    }
}

/// What the pull request's row says about babysitting (FR-019, FR-023).
public struct BabysittingStatus: Codable, Hashable, Sendable {
    /// The last fire for this pull request, across its workflows.
    public var lastRun: WorkflowOutcome?
    public var lastRunWorkflowID: String?
    /// 0 to 3.
    public var consecutiveRuns: Int
    /// At the limit, until somebody acts or Resume is chosen.
    public var isStopped: Bool
    public var isRunning: Bool

    public init(lastRun: WorkflowOutcome? = nil, lastRunWorkflowID: String? = nil,
                consecutiveRuns: Int = 0, isStopped: Bool = false, isRunning: Bool = false) {
        self.lastRun = lastRun
        self.lastRunWorkflowID = lastRunWorkflowID
        self.consecutiveRuns = consecutiveRuns
        self.isStopped = isStopped
        self.isRunning = isRunning
    }
}

/// One of the viewer's open pull requests on the repository, as last fetched.
public struct PullRequest: Codable, Hashable, Sendable, Identifiable {
    public var number: Int
    public var title: String
    public var url: URL
    public var isDraft: Bool
    public var createdAt: Date
    public var headBranch: String
    public var headOid: String
    public var baseBranch: String
    public var baseOid: String
    /// Where the push tool pushes: the head repository, which is a fork's for a fork.
    public var headRepositoryURL: URL?
    public var isFromFork: Bool
    public var checks: PullRequestChecks
    public var review: PullRequestReview
    public var conflicts: PullRequestConflicts
    /// Only the ones that count (FR-011a), oldest first.
    public var countableComments: [ReviewItem]
    /// The viewer's own latest action on it: their latest comment or review, or the
    /// head commit. Where a first sight starts counting comments from (R6).
    public var viewerLastActionAt: Date?
    public var worktree: PullRequestWorktree?
    public var babysitting: BabysittingStatus

    public var id: Int { number }

    public init(number: Int, title: String, url: URL, isDraft: Bool = false,
                createdAt: Date, headBranch: String, headOid: String,
                baseBranch: String, baseOid: String, headRepositoryURL: URL? = nil,
                isFromFork: Bool = false, checks: PullRequestChecks = .none,
                review: PullRequestReview = .none, conflicts: PullRequestConflicts = .unknown,
                countableComments: [ReviewItem] = [], viewerLastActionAt: Date? = nil,
                worktree: PullRequestWorktree? = nil,
                babysitting: BabysittingStatus = BabysittingStatus()) {
        self.number = number
        self.title = title
        self.url = url
        self.isDraft = isDraft
        self.createdAt = createdAt
        self.headBranch = headBranch
        self.headOid = headOid
        self.baseBranch = baseBranch
        self.baseOid = baseOid
        self.headRepositoryURL = headRepositoryURL
        self.isFromFork = isFromFork
        self.checks = checks
        self.review = review
        self.conflicts = conflicts
        self.countableComments = countableComments
        self.viewerLastActionAt = viewerLastActionAt
        self.worktree = worktree
        self.babysitting = babysitting
    }
}

/// Why the section can't list anything, in the one line it shows instead (FR-003).
public enum PullRequestProblem: Codable, Hashable, Sendable {
    case noCLI
    case notSignedIn(host: String)
    case cannotSee(host: String, repository: String, login: String?)
    /// Network down or rate-limited. Never the one line: the last good rows stay, and
    /// the footer says when they are from (FR-009).
    case unreachable(String)

    /// The one line. `nil` for `unreachable`, which is a footer rather than a line.
    public var message: String? {
        switch self {
        case .noCLI:
            return "Can't see pull requests: the GitHub CLI isn't installed."
        case .notSignedIn:
            return "Can't see pull requests: gh isn't signed in."
        case .cannotSee(_, let repository, let login):
            return login.map { "Can't see pull requests on \(repository) with the account \($0)." }
                ?? "Can't see pull requests on \(repository) with this sign-in."
        case .unreachable:
            return nil
        }
    }

    /// What to type to fix it, shown as text to copy, never run for the person (FR-002).
    public var fix: String? {
        switch self {
        case .noCLI: return "brew install gh"
        case .notSignedIn(let host): return "gh auth login --hostname \(host)"
        case .cannotSee, .unreachable: return nil
        }
    }

    public var isUnreachable: Bool {
        if case .unreachable = self { return true }
        return false
    }
}

/// The whole Pull requests section for one project, sent whole like `WorkflowSummary`.
///
/// A project that is not on GitHub has none, which is how the section is absent there
/// (SC-006).
public struct PullRequestList: Codable, Hashable, Sendable {
    public var folder: URL
    public var repository: GitHubRepository
    /// The signed-in login, once known.
    public var viewer: String?
    /// Newest first.
    public var pullRequests: [PullRequest]
    /// When the list was last good.
    public var fetchedAt: Date?
    public var problem: PullRequestProblem?
    /// A workflow here with a pull-request trigger, archived or not (US4-2).
    public var babysitterWorkflowID: String?

    public init(folder: URL, repository: GitHubRepository, viewer: String? = nil,
                pullRequests: [PullRequest] = [], fetchedAt: Date? = nil,
                problem: PullRequestProblem? = nil, babysitterWorkflowID: String? = nil) {
        self.folder = Project.standardize(folder)
        self.repository = repository
        self.viewer = viewer
        self.pullRequests = pullRequests.sorted { $0.createdAt > $1.createdAt }
        self.fetchedAt = fetchedAt
        self.problem = problem
        self.babysitterWorkflowID = babysitterWorkflowID
    }

    /// Whether the rows are worth showing: a problem other than being unreachable
    /// replaces them with its one line.
    public var showsRows: Bool { problem == nil || problem?.isUnreachable == true }
}
