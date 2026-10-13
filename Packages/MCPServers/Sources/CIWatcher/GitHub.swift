// The GitHub side of the CI watcher: every call is `gh` as the signed-in person, so the
// server holds no token (RealGitHub). FakeGitHub reads and writes a JSON file instead, for
// tests and walks.
import Foundation
import MCPServerKit

public struct PR: Sendable, Equatable {
    public var number: Int
    public var title: String
    public var branch: String
    public var url: String

    var json: JSON { ["number": .int(number), "title": .string(title), "branch": .string(branch), "url": .string(url)] }
}

public enum Checks: String, Sendable { case passing, failing, running, none }

public struct BoardPR: Sendable {
    public var pr: PR
    public var checks: Checks
    public var failedRunId: Int?
    /// Whether it conflicts with its base (#712); nil while GitHub is still working it out.
    public var conflicts: Bool?

    var json: JSON {
        var j = pr.json.merging(["checks": .string(checks.rawValue)])
        if let failedRunId { j["failedRunId"] = .int(failedRunId) }
        if let conflicts { j["conflicts"] = .bool(conflicts) }
        return j
    }
}

/// A failed run as listed, before its PR and jobs are looked up.
public struct RunRef: Sendable {
    public var id: Int
    public var attempt: Int
    public var name: String
    public var url: String
    public var headSha: String
    public var branch: String
    public var prNumber: Int?
    public var updatedAt: String
}

/// A `checks.failed` event's data: the run's PR and its failed jobs.
public struct FailedRunData: Sendable {
    public var pr: PR
    public var headSha: String
    public var run: RunRef
    public var failedJobs: [(name: String, url: String)]
    /// Whether the PR's author is one of the repo's own (#728).
    public var trusted: Bool

    var json: JSON {
        ["pr": pr.json, "headSha": .string(headSha),
         "run": ["id": .int(run.id), "attempt": .int(run.attempt), "name": .string(run.name), "url": .string(run.url)],
         "failedJobs": .array(failedJobs.map { ["name": .string($0.name), "url": .string($0.url)] })]
    }
}

/// An open pull request, as `pr.opened` sees it (#833).
public struct OpenPR: Sendable {
    public var pr: PR
    public var author: String
    public var draft: Bool
    /// Whether its author is one of the repo's own (#728).
    public var trusted: Bool
}

public struct MergedPR: Sendable {
    public var pr: PR
    public var mergedAt: String
    public var mergeSha: String
    var json: JSON { ["pr": pr.json, "mergedAt": .string(mergedAt), "mergeSha": .string(mergeSha)] }
}

/// A pull request closed without being merged.
public struct ClosedPR: Sendable {
    public var pr: PR
    public var closedAt: String
    var json: JSON { ["pr": pr.json, "closedAt": .string(closedAt)] }
}

public struct Issue: Sendable {
    public var number: Int
    public var title: String
    public var author: String
    public var labels: [String]
    public var url: String
    /// Logins of the people it is assigned to: who works on it (#905).
    public var assignees: [String] = []

    var json: JSON {
        ["number": .int(number), "title": .string(title), "author": .string(author), "labels": JSON(labels), "url": .string(url),
         "assignees": JSON(assignees)]
    }
}

public struct ListedIssue: Sendable {
    public var issue: Issue
    public var comments: Int
    public var updatedAt: String
    var json: JSON { issue.json.merging(["comments": .int(comments), "updatedAt": .string(updatedAt)]) }
}

public enum IssueKind: String, Sendable, CaseIterable { case opened, labelled, commented, closed }

/// One thing that happened to an issue (never a pull request).
public struct IssueActivity: Sendable {
    public enum What: Sendable {
        case opened
        case labelled(label: String, by: String)
        case commented(author: String, url: String, body: String)
        case closed(reason: String, by: String)
    }

    public var id: String
    public var at: String
    public var issue: Issue
    public var what: What
    /// Whether whoever did it is one of the repo's own (#728): who opened it, commented or
    /// labelled it, or who closed it.
    public var trusted: Bool

    public var kind: IssueKind {
        switch what {
        case .opened: .opened
        case .labelled: .labelled
        case .commented: .commented
        case .closed: .closed
        }
    }

    /// Its event's details.
    var data: JSON {
        switch what {
        case .opened:
            ["issue": issue.json, "openedAt": .string(at)]
        case .labelled(let label, let by):
            ["issue": issue.json, "label": .string(label), "by": .string(by), "labelledAt": .string(at)]
        case .commented(let author, let url, let body):
            ["issue": issue.json, "comment": ["author": .string(author), "url": .string(url), "body": .string(body)],
             "commentedAt": .string(at)]
        case .closed(let reason, let by):
            ["issue": issue.json, "reason": .string(reason), "by": .string(by), "closedAt": .string(at)]
        }
    }
}

public protocol GitHub: Sendable {
    /// Failed `pull_request` runs updated at or after `since`, in any order.
    func failedRuns(repo: String, branch: String?, since: String) async throws -> (runs: [RunRef], truncated: Bool)
    /// The run's PR and failed jobs, or nil when it belongs to no PR.
    func runDetails(repo: String, run: RunRef) async throws -> FailedRunData?
    /// The repo the server's folder pushes to, owner/name: what an argument without `repo` means (#702).
    func defaultRepo() async throws -> String
    /// PRs merged, and PRs closed without merging, at or after `since`.
    func closedPRs(repo: String, since: String) async throws -> (merged: [MergedPR], closed: [ClosedPR], truncated: Bool)
    func listPRs(repo: String) async throws -> [BoardPR]
    /// Open PRs, drafts too, with their authors.
    func openPRs(repo: String) async throws -> [OpenPR]
    /// What happened to the repo's issues at or after `since`, of one kind.
    func issueActivity(repo: String, kind: IssueKind, since: String) async throws -> (items: [IssueActivity], truncated: Bool)
    /// Open issues, newest updated first, at most 100; with `label`, only those with it.
    func listIssues(repo: String, label: String?) async throws -> [ListedIssue]
    func failedLog(repo: String, runId: Int, job: String?) async throws -> String
    func rerunFailed(repo: String, runId: Int) async throws -> JSON
    func commentOnPR(repo: String, number: Int, body: String) async throws -> JSON
    /// One pull request as its page shows it (#837): `prPage`'s shape. Each file's `patch` only
    /// with `diff`.
    func prDetail(repo: String, number: Int, diff: Bool) async throws -> JSON
    /// Squash-merges it and deletes its branch; with `auto`, once its checks pass (#837).
    func mergePR(repo: String, number: Int, auto: Bool) async throws -> JSON
    /// Approves it, or asks for changes with `body`, as the signed-in person (#837).
    func reviewPR(repo: String, number: Int, event: ReviewEvent, body: String) async throws -> JSON
    /// Branches pushed in the last `branchDays` days with no open or merged PR, newest first,
    /// and the base a PR would go into (#837).
    func branchesWithoutPR(repo: String) async throws -> (base: String, branches: [Branch])
    /// What `gh pr create --fill` would write for `branch`: its commits ahead of the base (#837).
    func prFill(repo: String, branch: String) async throws -> (base: String, commits: [String])
    /// Opens a PR from `branch` into `base`, as the signed-in person (#837).
    func createPR(repo: String, branch: String, base: String, title: String, body: String, draft: Bool) async throws -> JSON
}

/// A branch with no pull request, as the board offers it (#837).
public struct Branch: Sendable, Equatable {
    public var name: String
    public var updatedAt: String
    /// Its last commit's first line.
    public var headline: String

    var json: JSON { ["name": .string(name), "updatedAt": .string(updatedAt), "headline": .string(headline)] }
}

/// How far back the board looks for a branch without a pull request.
let branchDays = 14

/// The repository's branches as one GraphQL answer gives them (`RealGitHub.branchQuery`): the
/// ones pushed in the last `branchDays` days before `now` with no open or merged PR, not the
/// base itself, newest first.
public func branchesFrom(graphQL: JSON, now: Date) -> (base: String, branches: [Branch]) {
    let repository = graphQL["data"]?["repository"]
    let base = repository?["defaultBranchRef"]?["name"]?.string ?? "main"
    let since = now.addingTimeInterval(-Double(branchDays) * 86400).timeIntervalSince1970 * 1000
    let branches = (repository?["refs"]?["nodes"]?.array ?? []).compactMap { node -> Branch? in
        let name = node["name"]?.string ?? ""
        let date = node["target"]?["committedDate"]?.string ?? ""
        guard !name.isEmpty, name != base, (node["associatedPullRequests"]?["totalCount"]?.int ?? 0) == 0,
              at(date) >= since else { return nil }
        return Branch(name: name, updatedAt: date, headline: node["target"]?["messageHeadline"]?.string ?? "")
    }
    return (base, branches.sorted { at($0.updatedAt) > at($1.updatedAt) })
}

/// A new PR's title and body from its commits' messages, oldest first, as `gh pr create --fill`
/// writes them: one commit gives its first line and the rest; more give the branch's name, and
/// each commit's first line as a list.
public func fillPR(branch: String, messages: [String]) -> (title: String, body: String) {
    if messages.count == 1, let message = messages.first {
        let lines = message.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let body = lines.count > 1 ? String(lines[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
        return (String(lines.first ?? "").trimmingCharacters(in: .whitespaces), body)
    }
    let leaf = branch.split(separator: "/").last.map(String.init) ?? branch
    let title = leaf.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
    let body = messages.map { "- " + (($0.split(separator: "\n").first).map(String.init) ?? "") }.joined(separator: "\n")
    return (title.prefix(1).uppercased() + title.dropFirst(), body)
}

/// A person's verdict on someone else's pull request (#837). GitHub refuses either on one's own.
public enum ReviewEvent: String, Sendable, CaseIterable {
    case approve
    case requestChanges = "request_changes"
}

public struct GhError: Error, Sendable, CustomStringConvertible {
    public enum Kind: Sendable { case notSignedIn, rateLimited, notFound, failed }
    public var kind: Kind
    public var message: String
    public var retryAfterMs: Int?

    public init(_ kind: Kind, _ message: String, retryAfterMs: Int? = nil) {
        self.kind = kind
        self.message = message
        self.retryAfterMs = retryAfterMs
    }

    public var description: String { message }
}

// MARK: Shared by both

let logLines = 300
/// A comment's body as an event gives it: at most this many characters.
let commentChars = 4000

/// The last `lines` lines of `text`, without its trailing newlines.
func tail(_ text: String, lines: Int = logLines) -> String {
    var trimmed = Substring(text)
    while trimmed.last == "\n" { trimmed = trimmed.dropLast() }
    return trimmed.split(separator: "\n", omittingEmptySubsequences: false).suffix(lines).joined(separator: "\n")
}

/// Text without terminal escapes or other control characters, but with its tabs and newlines.
func plain(_ text: String) -> String {
    text.replacingOccurrences(of: "\u{1b}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
        .replacingOccurrences(of: "\u{1b}\\][^\u{07}\u{1b}]*(\u{07}|\u{1b}\\\\)", with: "", options: .regularExpression)
        .replacingOccurrences(of: "[\u{00}-\u{08}\u{0b}-\u{1f}\u{7f}]", with: "", options: .regularExpression)
}

func runURL(_ repo: String, _ runId: Int) -> String { "https://github.com/\(repo)/actions/runs/\(runId)" }

func clip(_ text: String?) -> String {
    let body = text ?? ""
    return body.count > commentChars ? String(body.prefix(commentChars)) + "…" : body
}

/// Whether GitHub's `author_association` and account make someone the repo's own (#728): its
/// owner, a member of its organisation or a collaborator, and not a bot. Anyone else's issue,
/// comment or pull request raises no event unless the workflow asks for `anyone`.
func isTrusted(association: String?, login: String?, type: String? = nil) -> Bool {
    let bot = type == "Bot" || (login ?? "").hasSuffix("[bot]")
    return !bot && ["OWNER", "MEMBER", "COLLABORATOR"].contains((association ?? "").uppercased())
}

/// Whether a label or a close was the repo's own doing (#728). Labelling takes triage access,
/// so a person who did it is trusted; closing does not, since an author may close their own.
func isTrustedActor(_ actor: String, type: String? = nil, closing: Bool, issueAuthor: String, authorTrusted: Bool) -> Bool {
    if type == "Bot" || actor.hasSuffix("[bot]") { return false }
    return !closing || actor != issueAuthor || authorTrusted
}

func reasonOf(_ reason: String?) -> String { reason == "not_planned" ? "not_planned" : "completed" }

func isFailed(_ conclusion: String?) -> Bool {
    ["failure", "timed_out", "startup_failure"].contains((conclusion ?? "").lowercased())
}

/// Milliseconds since 1970 for an ISO time; -infinity for one that is not, so it sorts first.
func at(_ time: String?) -> Double {
    time.flatMap(Time.parse).map { $0.timeIntervalSince1970 * 1000 } ?? -.infinity
}

func formatLogs(_ jobs: [(name: String, url: String, log: String)], runId: Int) -> String {
    if jobs.isEmpty { return "No failed jobs in run \(runId)." }
    return jobs.map { "== \($0.name) (\($0.url)), last \(logLines) lines ==\n\(tail(plain($0.log)))" }
        .joined(separator: "\n\n")
}

// MARK: A pull request's page (#837)

/// The most diff lines a page is sent, all files together; past it a file's `patch` is left out.
let diffLines = 2000

/// One check of a PR's rollup, as its page lists it: passing, failing, running or skipped.
func checkRun(_ item: JSON) -> JSON {
    let state: String
    if item["__typename"]?.string == "StatusContext" {
        switch (item["state"]?.string ?? "").uppercased() {
        case "SUCCESS": state = "passing"
        case "FAILURE", "ERROR": state = "failing"
        default: state = "running"
        }
        return ["name": .string(item["context"]?.string ?? ""), "state": .string(state), "url": .string(item["targetUrl"]?.string ?? "")]
    }
    let conclusion = item["conclusion"]?.string
    if (item["status"]?.string ?? "").uppercased() != "COMPLETED" { state = "running" }
    else if isFailed(conclusion) || conclusion?.uppercased() == "ACTION_REQUIRED" { state = "failing" }
    else if conclusion?.uppercased() == "SUCCESS" { state = "passing" }
    else { state = "skipped" }
    return ["name": .string(item["name"]?.string ?? ""), "state": .string(state), "url": .string(item["detailsUrl"]?.string ?? "")]
}

/// A unified diff as each file's hunks, from its first `@@` on, by the file's new path.
func patches(_ diff: String) -> [(path: String, lines: [Substring])] {
    var out = [(path: String, lines: [Substring])]()
    var inHunks = false
    for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
        if line.hasPrefix("diff --git ") {
            // `diff --git a/x b/x`: the new path is after the last " b/".
            let path = line.range(of: " b/", options: .backwards).map { String(line[$0.upperBound...]) } ?? ""
            out.append((path, []))
            inHunks = false
        } else if !out.isEmpty {
            if line.hasPrefix("@@") { inHunks = true }
            if inHunks { out[out.count - 1].lines.append(line) }
        }
    }
    return out
}

/// `gh pr view --json …`'s answer, and `gh pr diff`'s when asked, as the page's JSON.
public func prPage(gh p: JSON, diff: String?) -> JSON {
    let (checks, failedRunId) = rollup(p["statusCheckRollup"]?.array)
    let mergeable = p["mergeable"]?.string
    let state = (p["state"]?.string ?? "").lowercased()
    let byPath = diff.map { Dictionary(patches($0).map { ($0.path, $0.lines) }) { a, _ in a } } ?? [:]
    var budget = diffLines, truncated = false
    let files: [JSON] = (p["files"]?.array ?? []).map { f in
        let path = f["path"]?.string ?? ""
        var file: JSON = ["path": .string(path), "additions": .int(f["additions"]?.int ?? 0), "deletions": .int(f["deletions"]?.int ?? 0)]
        if diff != nil {
            let lines = byPath[path] ?? []
            if lines.count <= budget {
                file["patch"] = .string(lines.joined(separator: "\n"))
                budget -= lines.count
            } else { truncated = true }
        }
        return file
    }
    let comments = (p["comments"]?.array ?? []).map { c -> (at: String, json: JSON) in
        let at = c["createdAt"]?.string ?? ""
        return (at, ["author": .string(c["author"]?["login"]?.string ?? ""), "body": .string(c["body"]?.string ?? ""),
                     "at": .string(at), "url": .string(c["url"]?.string ?? "")])
    }
    // A review with no words and only a COMMENTED state is a line comment's wrapper: not shown.
    let reviews = (p["reviews"]?.array ?? []).compactMap { r -> (at: String, json: JSON)? in
        let review = (r["state"]?.string ?? "").lowercased(), body = r["body"]?.string ?? ""
        if review == "commented" && body.isEmpty || review == "pending" { return nil }
        let at = r["submittedAt"]?.string ?? ""
        return (at, ["author": .string(r["author"]?["login"]?.string ?? ""), "body": .string(body), "at": .string(at),
                     "review": .string(review)])
    }
    var page: JSON = [
        "number": .int(p["number"]?.int ?? 0), "title": .string(p["title"]?.string ?? ""),
        "branch": .string(p["headRefName"]?.string ?? ""), "base": .string(p["baseRefName"]?.string ?? ""),
        "url": .string(p["url"]?.string ?? ""), "author": .string(p["author"]?["login"]?.string ?? ""),
        "state": .string(["merged", "closed"].contains(state) ? state : "open"), "draft": .bool(p["isDraft"]?.bool == true),
        "body": .string(p["body"]?.string ?? ""), "createdAt": .string(p["createdAt"]?.string ?? ""),
        "additions": .int(p["additions"]?.int ?? 0), "deletions": .int(p["deletions"]?.int ?? 0),
        "checks": .string(checks.rawValue), "autoMerge": .bool((p["autoMergeRequest"] ?? .null) != .null),
        "checkRuns": .array((p["statusCheckRollup"]?.array ?? []).map(checkRun)),
        "files": .array(files),
        "comments": .array((comments + reviews).sorted { at($0.at) < at($1.at) }.map(\.json)),
    ]
    if let failedRunId { page["failedRunId"] = .int(failedRunId) }
    if mergeable == "CONFLICTING" { page["conflicts"] = true } else if mergeable == "MERGEABLE" { page["conflicts"] = false }
    if let decision = p["reviewDecision"]?.string, !decision.isEmpty { page["review"] = .string(decision.lowercased()) }
    if truncated { page["diffTruncated"] = true }
    return page
}

/// The rollup of one PR's checks, as `gh pr list --json statusCheckRollup` gives them.
public func rollup(_ items: [JSON]?) -> (checks: Checks, failedRunId: Int?) {
    guard let items, !items.isEmpty else { return (.none, nil) }
    var running = false, failing = false
    var failedRunId: Int?
    for item in items {
        if item["__typename"]?.string == "StatusContext" {
            let state = (item["state"]?.string ?? "").uppercased()
            if state == "FAILURE" || state == "ERROR" { failing = true }
            else if state == "PENDING" || state == "EXPECTED" { running = true }
            continue
        }
        if (item["status"]?.string ?? "").uppercased() != "COMPLETED" { running = true; continue }
        let conclusion = item["conclusion"]?.string
        if isFailed(conclusion) || conclusion?.uppercased() == "ACTION_REQUIRED" {
            failing = true
            let details = item["detailsUrl"]?.string ?? ""
            if failedRunId == nil, let range = details.range(of: "/actions/runs/[0-9]+", options: .regularExpression) {
                failedRunId = Int(details[range].split(separator: "/").last ?? "")
            }
        }
    }
    if failing { return (.failing, failedRunId) }
    return (running ? .running : .passing, nil)
}
