import Foundation

/// The one GraphQL request a refresh makes for a project, and what it says (038 R2).
///
/// One request per project: the viewer, the repository (only so that one they can't
/// see says so, rather than coming back as an empty search), and their open pull
/// requests, with everything the row, the triggers and the prompt need.
public enum GitHubQuery {
    public static let text = """
        query($owner: String!, $name: String!, $search: String!) {
          viewer { login }
          repository(owner: $owner, name: $name) { id }
          search(type: ISSUE, query: $search, first: 50) {
            nodes {
              ... on PullRequest {
                number title url isDraft createdAt
                headRefName headRefOid baseRefName baseRefOid mergeable isCrossRepository
                headRepository { nameWithOwner url }
                reviewDecision
                commits(last: 1) { nodes { commit { oid committedDate statusCheckRollup { state contexts(first: 50) { nodes {
                  __typename
                  ... on CheckRun { databaseId name status conclusion detailsUrl }
                  ... on StatusContext { context state targetUrl }
                } } } } } }
                reviews(last: 30) { nodes { databaseId author { login __typename } authorAssociation state body submittedAt url } }
                reviewThreads(last: 50) { nodes { comments(last: 20) { nodes { databaseId author { login __typename } authorAssociation body path line createdAt url } } } }
                comments(last: 30) { nodes { databaseId author { login __typename } authorAssociation body createdAt url } }
              }
            }
          }
        }
        """

    public static func variables(for repository: GitHubRepository) -> [String: String] {
        ["owner": repository.owner, "name": repository.name,
         "search": "repo:\(repository.fullName) is:pr is:open author:@me"]
    }

    /// What one response says.
    public struct Result: Sendable {
        public var viewer: String?
        public var pullRequests: [PullRequest]
    }

    public static func decode(_ data: Data) throws -> Result {
        let response = try decoder.decode(Response.self, from: data)
        let viewer = response.data?.viewer?.login
        let nodes = response.data?.search?.nodes ?? []
        let pulls = nodes.compactMap { $0.pullRequest(viewer: viewer) }
        return Result(viewer: viewer, pullRequests: pulls.sorted { $0.createdAt > $1.createdAt })
    }

    /// Who may start babysitting with their words (FR-011a): the people with write
    /// access. Anybody else's comment never fires and never reaches a prompt.
    static let writeAccess: Set<String> = ["OWNER", "MEMBER", "COLLABORATOR"]

    static let failedConclusions: Set<String> =
        ["FAILURE", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE"]

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

// MARK: The response, as GitHub sends it

private struct Response: Decodable {
    var data: Payload?
}

private struct Payload: Decodable {
    var viewer: Login?
    var search: Search?
}

private struct Login: Decodable {
    var login: String
    var typeName: String?

    enum CodingKeys: String, CodingKey {
        case login
        case typeName = "__typename"
    }

    var isBot: Bool { typeName == "Bot" }
}

private struct Search: Decodable {
    /// Lossy, so an issue that somehow matches, or a node GitHub returns empty, costs
    /// itself rather than the list.
    var nodes: [Lossy<Node>]
}

private struct Nodes<Element: Decodable>: Decodable {
    var nodes: [Element]
}

private struct Node: Decodable {
    var number: Int
    var title: String
    var url: URL
    var isDraft: Bool
    var createdAt: Date
    var headRefName: String
    var headRefOid: String
    var baseRefName: String
    var baseRefOid: String
    var mergeable: String
    var isCrossRepository: Bool
    var headRepository: HeadRepository?
    var reviewDecision: String?
    var commits: Nodes<CommitNode>
    var reviews: Nodes<Review>
    var reviewThreads: Nodes<Thread>
    var comments: Nodes<Comment>
}

private struct HeadRepository: Decodable {
    var nameWithOwner: String
    var url: URL
}

private struct CommitNode: Decodable {
    var commit: Commit
}

private struct Commit: Decodable {
    var oid: String
    var committedDate: Date?
    var statusCheckRollup: Rollup?
}

private struct Rollup: Decodable {
    var state: String
    var contexts: Nodes<Lossy<Context>>
}

private struct Context: Decodable {
    var typeName: String
    // CheckRun
    var databaseId: Int?
    var name: String?
    var status: String?
    var conclusion: String?
    var detailsUrl: URL?
    // StatusContext
    var context: String?
    var state: String?
    var targetUrl: URL?

    enum CodingKeys: String, CodingKey {
        case typeName = "__typename"
        case databaseId, name, status, conclusion, detailsUrl, context, state, targetUrl
    }
}

private struct Review: Decodable {
    var databaseId: Int?
    var author: Login?
    var authorAssociation: String
    var state: String
    var body: String
    var submittedAt: Date?
    var url: URL?
}

private struct Thread: Decodable {
    var comments: Nodes<Comment>
}

private struct Comment: Decodable {
    var databaseId: Int?
    var author: Login?
    var authorAssociation: String
    var body: String
    var path: String?
    var line: Int?
    var createdAt: Date
    var url: URL?
}

// MARK: Into the app's terms

extension Lossy {
    fileprivate func pullRequest(viewer: String?) -> PullRequest? where Element == Node {
        value?.pullRequest(viewer: viewer)
    }
}

private extension Node {
    func pullRequest(viewer: String?) -> PullRequest {
        let commit = commits.nodes.last?.commit
        return PullRequest(
            number: number, title: title, url: url, isDraft: isDraft, createdAt: createdAt,
            headBranch: headRefName, headOid: headRefOid,
            baseBranch: baseRefName, baseOid: baseRefOid,
            headRepositoryURL: headRepository?.url, isFromFork: isCrossRepository,
            checks: checks(commit?.statusCheckRollup),
            review: review(viewer: viewer),
            conflicts: mergeable == "CONFLICTING" ? .conflicting : mergeable == "MERGEABLE" ? .clean : .unknown,
            countableComments: countable(viewer: viewer),
            viewerLastActionAt: viewerLastAction(viewer: viewer, headDate: commit?.committedDate))
    }

    /// Failing beats running beats passing: one failed check is the fact about a pull
    /// request, whatever else is still going.
    func checks(_ rollup: Rollup?) -> PullRequestChecks {
        let contexts = rollup?.contexts.nodes.compactMap(\.value) ?? []
        guard !contexts.isEmpty else { return .none }
        var failed: [FailedCheck] = []
        var running = false
        for context in contexts {
            if context.typeName == "CheckRun" {
                if let conclusion = context.conclusion, GitHubQuery.failedConclusions.contains(conclusion) {
                    failed.append(FailedCheck(id: context.databaseId.map(String.init) ?? context.name ?? "check",
                                              name: context.name ?? "check", logURL: context.detailsUrl))
                } else if context.status != "COMPLETED" {
                    running = true
                }
            } else {
                switch context.state {
                case "FAILURE", "ERROR":
                    let name = context.context ?? "status"
                    failed.append(FailedCheck(id: name, name: name, logURL: context.targetUrl))
                case "PENDING", "EXPECTED":
                    running = true
                default:
                    break
                }
            }
        }
        if !failed.isEmpty { return .failing(failed.sorted { $0.id < $1.id }) }
        return running ? .running : .passing
    }

    func review(viewer: String?) -> PullRequestReview {
        switch reviewDecision {
        case "APPROVED": return .approved
        case "CHANGES_REQUESTED": return .changesRequested
        default:
            let others = reviews.nodes.contains { $0.author?.login != viewer }
                || reviewThreads.nodes.contains { $0.comments.nodes.contains { $0.author?.login != viewer } }
            return others ? .commented : .none
        }
    }

    /// Only the words that may start babysitting (FR-011, FR-011a): from somebody with
    /// write access, not the viewer, not a bot. A review counts when it asks for changes,
    /// or comments with something to say.
    func countable(viewer: String?) -> [ReviewItem] {
        func counts(_ author: Login?, _ association: String) -> Bool {
            guard let author, !author.isBot, author.login != viewer else { return false }
            return GitHubQuery.writeAccess.contains(association)
        }
        var items: [ReviewItem] = []
        for review in reviews.nodes {
            guard let id = review.databaseId, let at = review.submittedAt,
                  counts(review.author, review.authorAssociation) else { continue }
            let asksForChanges = review.state == "CHANGES_REQUESTED"
            let hasWords = review.state == "COMMENTED" && !review.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            guard asksForChanges || hasWords else { continue }
            items.append(ReviewItem(id: id, kind: .review, author: review.author!.login, body: review.body,
                                    createdAt: at, url: review.url, requestsChanges: asksForChanges))
        }
        for thread in reviewThreads.nodes {
            for comment in thread.comments.nodes {
                guard let id = comment.databaseId, counts(comment.author, comment.authorAssociation) else { continue }
                items.append(ReviewItem(id: id, kind: .threadComment, author: comment.author!.login,
                                        body: comment.body, path: comment.path, line: comment.line,
                                        createdAt: comment.createdAt, url: comment.url))
            }
        }
        for comment in comments.nodes {
            guard let id = comment.databaseId, counts(comment.author, comment.authorAssociation) else { continue }
            items.append(ReviewItem(id: id, kind: .conversationComment, author: comment.author!.login,
                                    body: comment.body, createdAt: comment.createdAt, url: comment.url))
        }
        return items.sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
    }

    func viewerLastAction(viewer: String?, headDate: Date?) -> Date? {
        guard let viewer else { return headDate }
        var dates: [Date] = headDate.map { [$0] } ?? []
        dates += reviews.nodes.filter { $0.author?.login == viewer }.compactMap(\.submittedAt)
        dates += reviewThreads.nodes.flatMap(\.comments.nodes).filter { $0.author?.login == viewer }.map(\.createdAt)
        dates += comments.nodes.filter { $0.author?.login == viewer }.map(\.createdAt)
        return dates.max()
    }
}
