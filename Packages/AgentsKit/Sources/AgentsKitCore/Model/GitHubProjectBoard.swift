import Foundation

/// One issue's position on the GitHub Project board.
public enum GitHubProjectIssueStatus: String, Codable, Hashable, Sendable {
    case ready
    case inProgress
}

/// Whether the local assignment has been reflected in the Projects status field.
public enum GitHubProjectStatusSync: String, Codable, Hashable, Sendable {
    case pending
    case synced
    case failed
}

/// A problem reading or changing this repository's GitHub Project.
public struct GitHubProjectProblem: Codable, Hashable, Sendable {
    public var message: String
    /// A terminal command or next step the person can use to repair access/configuration.
    public var fix: String?
    public var isUnreachable: Bool

    public init(message: String, fix: String? = nil, isUnreachable: Bool = false) {
        self.message = message
        self.fix = fix
        self.isUnreachable = isUnreachable
    }
}

/// A Project v2 issue item the board displays.
public struct GitHubProjectIssue: Codable, Hashable, Sendable, Identifiable {
    public var nodeID: String
    public var number: Int
    public var title: String
    public var body: String
    public var labels: [String]
    public var url: URL
    public var itemID: String
    public var status: GitHubProjectIssueStatus
    public var assignment: GitHubIssueAssignment?
    public var statusSync: GitHubProjectStatusSync?
    public var statusSyncProblem: GitHubProjectProblem?

    public var id: String { nodeID }

    public init(nodeID: String, number: Int, title: String, body: String, labels: [String],
                url: URL, itemID: String, status: GitHubProjectIssueStatus,
                assignment: GitHubIssueAssignment? = nil,
                statusSync: GitHubProjectStatusSync? = nil,
                statusSyncProblem: GitHubProjectProblem? = nil) {
        self.nodeID = nodeID
        self.number = number
        self.title = title
        self.body = body
        self.labels = labels
        self.url = url
        self.itemID = itemID
        self.status = status
        self.assignment = assignment
        self.statusSync = statusSync
        self.statusSyncProblem = statusSyncProblem
    }
}

/// An app-owned link from an issue to the fresh agent and worktree started for it.
public struct GitHubIssueAssignment: Codable, Hashable, Sendable {
    public var projectID: String
    public var itemID: String
    public var issueNodeID: String
    public var issueNumber: Int
    public var agentID: UUID
    public var worktree: AgentWorktree
    public var statusSync: GitHubProjectStatusSync
    public var statusSyncProblem: GitHubProjectProblem?
    public var requestID: UUID
    public var createdAt: Date
    public var updatedAt: Date

    public init(projectID: String, itemID: String, issueNodeID: String, issueNumber: Int,
                agentID: UUID, worktree: AgentWorktree, statusSync: GitHubProjectStatusSync,
                statusSyncProblem: GitHubProjectProblem? = nil, requestID: UUID,
                createdAt: Date, updatedAt: Date) {
        self.projectID = projectID
        self.itemID = itemID
        self.issueNodeID = issueNodeID
        self.issueNumber = issueNumber
        self.agentID = agentID
        self.worktree = worktree
        self.statusSync = statusSync
        self.statusSyncProblem = statusSyncProblem
        self.requestID = requestID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// The board on a project page. Nil means the repository has no readable linked project.
public struct GitHubProjectBoard: Codable, Hashable, Sendable {
    public var folder: URL
    public var repository: GitHubRepository
    public var projectID: String?
    public var projectTitle: String?
    public var projectURL: URL?
    public var statusFieldID: String?
    public var readyOptionID: String?
    public var inProgressOptionID: String?
    public var issues: [GitHubProjectIssue]
    public var fetchedAt: Date?
    public var problem: GitHubProjectProblem?

    public init(folder: URL, repository: GitHubRepository, projectID: String? = nil,
                projectTitle: String? = nil, projectURL: URL? = nil, statusFieldID: String? = nil,
                readyOptionID: String? = nil, inProgressOptionID: String? = nil,
                issues: [GitHubProjectIssue] = [], fetchedAt: Date? = nil,
                problem: GitHubProjectProblem? = nil) {
        self.folder = Project.standardize(folder)
        self.repository = repository
        self.projectID = projectID
        self.projectTitle = projectTitle
        self.projectURL = projectURL
        self.statusFieldID = statusFieldID
        self.readyOptionID = readyOptionID
        self.inProgressOptionID = inProgressOptionID
        self.issues = issues
        self.fetchedAt = fetchedAt
        self.problem = problem
    }

    public var canAssignIssues: Bool {
        projectID != nil && statusFieldID != nil && inProgressOptionID != nil && problem == nil
    }
}

/// What the window needs to pick a runtime and prepare a new issue agent.
public struct GitHubIssueAssignmentRequest: Codable, Sendable {
    public var folder: URL
    public var projectID: String
    public var itemID: String
    public var issueNodeID: String
    public var issueNumber: Int
    public var runtimeID: String
    public var prompt: String
    public var requestID: UUID

    public init(folder: URL, projectID: String, itemID: String, issueNodeID: String,
                issueNumber: Int, runtimeID: String, prompt: String, requestID: UUID) {
        self.folder = Project.standardize(folder)
        self.projectID = projectID
        self.itemID = itemID
        self.issueNodeID = issueNodeID
        self.issueNumber = issueNumber
        self.runtimeID = runtimeID
        self.prompt = prompt
        self.requestID = requestID
    }
}

public struct GitHubProjectBoardRequest: Codable, Sendable {
    public var folder: URL

    public init(folder: URL) { self.folder = Project.standardize(folder) }
}

public struct GitHubIssueAssignmentResult: Codable, Sendable {
    public var agentID: UUID
    public var worktree: AgentWorktree
    public var statusSync: GitHubProjectStatusSync
    public var statusSyncProblem: GitHubProjectProblem?

    public init(agentID: UUID, worktree: AgentWorktree, statusSync: GitHubProjectStatusSync,
                statusSyncProblem: GitHubProjectProblem? = nil) {
        self.agentID = agentID
        self.worktree = worktree
        self.statusSync = statusSync
        self.statusSyncProblem = statusSyncProblem
    }
}

public struct GitHubProjectStatusSyncRequest: Codable, Sendable {
    public var folder: URL
    public var projectID: String
    public var itemID: String

    public init(folder: URL, projectID: String, itemID: String) {
        self.folder = Project.standardize(folder)
        self.projectID = projectID
        self.itemID = itemID
    }
}
