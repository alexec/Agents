import Foundation
import MCPServerKit

/// GitHub as a JSON file, for tests and walks: read on every call, so a test or a walk can
/// append runs, PRs and issues while it runs; reruns and comments are written back to it.
/// `"gh": "notSignedIn"` or `"gh": {"rateLimitedForMs": n}` makes every call fail that way.
public struct FakeGitHub: GitHub {
    public let file: URL
    /// Writes one at a time, so two at once don't lose one.
    private let lock = NSLock()

    public init(file: URL) { self.file = file }

    func load() throws -> JSON {
        let data: JSON
        do { data = try JSON.parse(Data(contentsOf: file)) } catch { throw GhError(.failed, "gh: \(file.path) is not JSON") }
        if data["gh"]?.string == "notSignedIn" { throw GhError(.notSignedIn, "gh not signed in: run `gh auth login`") }
        if let ms = data["gh"]?["rateLimitedForMs"]?.int, ms > 0 {
            throw GhError(.rateLimited, "GitHub rate limit", retryAfterMs: ms)
        }
        return data
    }

    /// Loads, changes and writes the file back, under the lock.
    func change<T>(_ body: (inout JSON) throws -> T) throws -> T {
        try lock.withLock {
            var data = try load()
            let out = try body(&data)
            try Data((data.prettyText + "\n").utf8).write(to: file)
            return out
        }
    }

    func repoOf(_ data: JSON, _ repo: String) -> JSON { data["repos"]?[repo] ?? ["prs": [], "runs": []] }
    func list(_ data: JSON, _ repo: String, _ key: String) -> [JSON] { repoOf(data, repo)[key]?.array ?? [] }

    static func toPR(_ p: JSON) -> PR {
        PR(number: p["number"]?.int ?? 0, title: p["title"]?.string ?? "", branch: p["branch"]?.string ?? "",
           url: p["url"]?.string ?? "")
    }

    static func toIssue(_ i: JSON) -> Issue {
        Issue(number: i["number"]?.int ?? 0, title: i["title"]?.string ?? "", author: i["author"]?.string ?? "",
              labels: (i["labels"]?.array ?? []).compactMap(\.string), url: i["url"]?.string ?? "")
    }

    func findRun(_ data: JSON, _ repo: String, _ runId: Int) throws -> JSON {
        guard let run = list(data, repo, "runs").first(where: { $0["id"]?.int == runId }) else {
            throw GhError(.notFound, "no run \(runId) in \(repo)")
        }
        return run
    }

    public func failedRuns(repo: String, branch: String?, since: String) async throws -> (runs: [RunRef], truncated: Bool) {
        let runs = list(try load(), repo, "runs")
            .filter { $0["event"]?.string == "pull_request" && $0["status"]?.string == "completed" && isFailed($0["conclusion"]?.string) }
            .filter { branch == nil || $0["branch"]?.string == branch }
            .filter { at($0["updatedAt"]?.string) >= at(since) }
            .map { r in
                RunRef(id: r["id"]?.int ?? 0, attempt: r["attempt"]?.int ?? 1, name: r["name"]?.string ?? "",
                       url: r["url"]?.string ?? "", headSha: r["headSha"]?.string ?? "", branch: r["branch"]?.string ?? "",
                       prNumber: r["pr"]?.int, updatedAt: r["updatedAt"]?.string ?? "")
            }
        return (runs, false)
    }

    public func runDetails(repo: String, run ref: RunRef) async throws -> FailedRunData? {
        let data = try load()
        guard let p = list(data, repo, "prs").first(where: { $0["number"]?.int == ref.prNumber }) else { return nil }
        let run = try findRun(data, repo, ref.id)
        return FailedRunData(pr: Self.toPR(p), headSha: ref.headSha, run: ref,
                             failedJobs: (run["jobs"]?.array ?? []).filter { isFailed($0["conclusion"]?.string) }
                                 .map { ($0["name"]?.string ?? "", $0["url"]?.string ?? "") })
    }

    public func defaultRepo() async throws -> String {
        // `defaultRepo` in the file, or its one repo.
        let data = try load()
        let repos = data["repos"]?.object.map { Array($0.keys) } ?? []
        guard let name = data["defaultRepo"]?.string ?? (repos.count == 1 ? repos[0] : nil) else {
            throw GhError(.notFound, "repo is needed: this folder has no GitHub repo")
        }
        return name
    }

    public func closedPRs(repo: String, since: String) async throws -> (merged: [MergedPR], closed: [ClosedPR], truncated: Bool) {
        let prs = list(try load(), repo, "prs")
        let merged = prs.filter { $0["state"]?.string == "merged" && $0["mergedAt"]?.string != nil && at($0["mergedAt"]?.string) >= at(since) }
            .map { MergedPR(pr: Self.toPR($0), mergedAt: $0["mergedAt"]?.string ?? "", mergeSha: $0["mergeSha"]?.string ?? "") }
        let closed = prs.filter { $0["state"]?.string == "closed" && $0["closedAt"]?.string != nil && at($0["closedAt"]?.string) >= at(since) }
            .map { ClosedPR(pr: Self.toPR($0), closedAt: $0["closedAt"]?.string ?? "") }
        return (merged, closed, false)
    }

    public func listPRs(repo: String) async throws -> [BoardPR] {
        list(try load(), repo, "prs").filter { $0["state"]?.string == "open" }.map { p in
            let checks = Checks(rawValue: p["checks"]?.string ?? "") ?? .none
            return BoardPR(pr: Self.toPR(p), checks: checks, failedRunId: checks == .failing ? p["failedRunId"]?.int : nil,
                           conflicts: p["conflicts"]?.bool)
        }
    }

    public func issueActivity(repo: String, kind: IssueKind, since: String) async throws -> (items: [IssueActivity], truncated: Bool) {
        var items = [IssueActivity]()
        for i in list(try load(), repo, "issues") {
            let issue = Self.toIssue(i)
            if kind == .opened {
                items.append(IssueActivity(id: String(i["number"]?.int ?? 0), at: i["createdAt"]?.string ?? "", issue: issue, what: .opened))
            }
            if kind == .commented {
                for c in i["comments"]?.array ?? [] {
                    items.append(IssueActivity(
                        id: Self.id(c["id"]), at: c["createdAt"]?.string ?? "", issue: issue,
                        what: .commented(author: c["author"]?.string ?? "", url: c["url"]?.string ?? "", body: clip(c["body"]?.string))))
                }
            }
            for e in i["events"]?.array ?? [] {
                let by = e["actor"]?.string ?? ""
                if kind == .labelled, e["event"]?.string == "labeled" {
                    items.append(IssueActivity(id: Self.id(e["id"]), at: e["createdAt"]?.string ?? "", issue: issue,
                                               what: .labelled(label: e["label"]?.string ?? "", by: by)))
                }
                if kind == .closed, e["event"]?.string == "closed" {
                    items.append(IssueActivity(id: Self.id(e["id"]), at: e["createdAt"]?.string ?? "", issue: issue,
                                               what: .closed(reason: reasonOf(e["reason"]?.string), by: by)))
                }
            }
        }
        return (items.filter { at($0.at) >= at(since) }, false)
    }

    static func id(_ value: JSON?) -> String { value?.int.map(String.init) ?? value?.string ?? "" }

    public func listIssues(repo: String, label: String?) async throws -> [ListedIssue] {
        list(try load(), repo, "issues")
            .filter { $0["state"]?.string == "open" && (label == nil || ($0["labels"]?.array ?? []).contains(.string(label!))) }
            .sorted { ($0["updatedAt"]?.string ?? "") > ($1["updatedAt"]?.string ?? "") }
            .map { ListedIssue(issue: Self.toIssue($0), comments: $0["comments"]?.array?.count ?? 0, updatedAt: $0["updatedAt"]?.string ?? "") }
    }

    public func failedLog(repo: String, runId: Int, job: String?) async throws -> String {
        let run = try findRun(try load(), repo, runId)
        let jobs = (run["jobs"]?.array ?? []).filter { isFailed($0["conclusion"]?.string) && (job == nil || $0["name"]?.string == job) }
        return formatLogs(jobs.map { ($0["name"]?.string ?? "", $0["url"]?.string ?? "", $0["log"]?.string ?? "") }, runId: runId)
    }

    public func rerunFailed(repo: String, runId: Int) async throws -> JSON {
        try change { data in
            let run = try findRun(data, repo, runId)
            var prs = list(data, repo, "prs")
            if let i = prs.firstIndex(where: { $0["number"] == run["pr"] }) {
                prs[i]["checks"] = "running"
                prs[i]["failedRunId"] = nil
                data["repos"]?[repo]?["prs"] = .array(prs)
            }
            data["reruns"] = .array((data["reruns"]?.array ?? []) + [
                ["repo": .string(repo), "runId": .int(runId), "at": .string(Time.string(Date()))],
            ])
        }
        return ["rerun": true, "url": .string(runURL(repo, runId))]
    }

    public func commentOnPR(repo: String, number: Int, body: String) async throws -> JSON {
        try change { data in
            guard let p = list(data, repo, "prs").first(where: { $0["number"]?.int == number }) else {
                throw GhError(.notFound, "no PR \(number) in \(repo)")
            }
            let comments = (data["comments"]?.array ?? []) + [
                ["repo": .string(repo), "number": .int(number), "body": .string(body), "at": .string(Time.string(Date()))],
            ]
            data["comments"] = .array(comments)
            return ["url": .string("\(p["url"]?.string ?? "")#issuecomment-\(comments.count)")]
        }
    }
}
