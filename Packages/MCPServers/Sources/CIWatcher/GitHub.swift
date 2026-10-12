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

    var json: JSON {
        var j = pr.json.merging(["checks": .string(checks.rawValue)])
        if let failedRunId { j["failedRunId"] = .int(failedRunId) }
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

    var json: JSON {
        ["pr": pr.json, "headSha": .string(headSha),
         "run": ["id": .int(run.id), "attempt": .int(run.attempt), "name": .string(run.name), "url": .string(run.url)],
         "failedJobs": .array(failedJobs.map { ["name": .string($0.name), "url": .string($0.url)] })]
    }
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

    var json: JSON {
        ["number": .int(number), "title": .string(title), "author": .string(author), "labels": JSON(labels), "url": .string(url)]
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
    /// What happened to the repo's issues at or after `since`, of one kind.
    func issueActivity(repo: String, kind: IssueKind, since: String) async throws -> (items: [IssueActivity], truncated: Bool)
    /// Open issues, newest updated first, at most 100; with `label`, only those with it.
    func listIssues(repo: String, label: String?) async throws -> [ListedIssue]
    func failedLog(repo: String, runId: Int, job: String?) async throws -> String
    func rerunFailed(repo: String, runId: Int) async throws -> JSON
    func commentOnPR(repo: String, number: Int, body: String) async throws -> JSON
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
