import Foundation
import MCPServerKit

/// GitHub as a JSON file, for tests and walks: read on every call, so a test or a walk can
/// append runs, PRs and issues while it runs; reruns and comments are written back to it.
/// A PR's `draft` is false when left out. An issue's, comment's or PR's `authorAssociation` is GitHub's (`OWNER`, `NONE`…); left out,
/// it is `NONE`, as a stranger. A login ending `[bot]` is a bot.
/// `"gh": "notSignedIn"` or `"gh": {"rateLimitedForMs": n}` makes every call fail that way.
/// `viewer` is the signed-in login; left out, it is `alexec`. A repo's `branches` are
/// `{name, updatedAt, commits: [message]}`, its base `defaultBranch` (`main` left out).
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
                                 .map { ($0["name"]?.string ?? "", $0["url"]?.string ?? "") },
                             trusted: isTrusted(association: p["authorAssociation"]?.string, login: p["author"]?.string))
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

    public func openPRs(repo: String) async throws -> [OpenPR] {
        list(try load(), repo, "prs").filter { $0["state"]?.string == "open" }.map { p in
            OpenPR(pr: Self.toPR(p), author: p["author"]?.string ?? "", draft: p["draft"]?.bool == true,
                   trusted: isTrusted(association: p["authorAssociation"]?.string, login: p["author"]?.string))
        }
    }

    public func issueActivity(repo: String, kind: IssueKind, since: String) async throws -> (items: [IssueActivity], truncated: Bool) {
        var items = [IssueActivity]()
        for i in list(try load(), repo, "issues") {
            let issue = Self.toIssue(i)
            let authorTrusted = isTrusted(association: i["authorAssociation"]?.string, login: issue.author)
            if kind == .opened {
                items.append(IssueActivity(id: String(i["number"]?.int ?? 0), at: i["createdAt"]?.string ?? "", issue: issue,
                                           what: .opened, trusted: authorTrusted))
            }
            if kind == .commented {
                for c in i["comments"]?.array ?? [] {
                    items.append(IssueActivity(
                        id: Self.id(c["id"]), at: c["createdAt"]?.string ?? "", issue: issue,
                        what: .commented(author: c["author"]?.string ?? "", url: c["url"]?.string ?? "", body: clip(c["body"]?.string)),
                        trusted: isTrusted(association: c["authorAssociation"]?.string, login: c["author"]?.string)))
                }
            }
            for e in i["events"]?.array ?? [] {
                let by = e["actor"]?.string ?? ""
                let trusted = isTrustedActor(by, closing: kind == .closed, issueAuthor: issue.author, authorTrusted: authorTrusted)
                if kind == .labelled, e["event"]?.string == "labeled" {
                    items.append(IssueActivity(id: Self.id(e["id"]), at: e["createdAt"]?.string ?? "", issue: issue,
                                               what: .labelled(label: e["label"]?.string ?? "", by: by), trusted: trusted))
                }
                if kind == .closed, e["event"]?.string == "closed" {
                    items.append(IssueActivity(id: Self.id(e["id"]), at: e["createdAt"]?.string ?? "", issue: issue,
                                               what: .closed(reason: reasonOf(e["reason"]?.string), by: by), trusted: trusted))
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

    /// A PR's page from its fixture entry as `gh pr view` would give it: its `checks` as one check
    /// named CI, its `body`, `base`, `files`, `diff`, `reviews` (author, body, state) and the
    /// comments made with `comment_on_pr`.
    public func prDetail(repo: String, number: Int, diff: Bool) async throws -> JSON {
        let data = try load()
        guard let p = list(data, repo, "prs").first(where: { $0["number"]?.int == number }) else {
            throw GhError(.notFound, "not found on GitHub")
        }
        let run: JSON = switch p["checks"]?.string {
        case "passing": ["__typename": "CheckRun", "name": "CI", "status": "COMPLETED", "conclusion": "SUCCESS"]
        case "failing": ["__typename": "CheckRun", "name": "CI", "status": "COMPLETED", "conclusion": "FAILURE",
                         "detailsUrl": .string(runURL(repo, p["failedRunId"]?.int ?? 0) + "/job/1")]
        case "running": ["__typename": "CheckRun", "name": "CI", "status": "IN_PROGRESS"]
        default: .null
        }
        let comments: [JSON] = (data["comments"]?.array ?? []).filter { $0["repo"]?.string == repo && $0["number"]?.int == number }
            .map { ["author": ["login": "alexec"], "body": $0["body"] ?? "", "createdAt": $0["at"] ?? "", "url": ""] }
        let reviews: [JSON] = (p["reviews"]?.array ?? []).map {
            ["author": ["login": $0["author"] ?? ""], "body": $0["body"] ?? "", "state": $0["state"] ?? "COMMENTED",
             "submittedAt": $0["at"] ?? ""]
        }
        let state = p["state"]?.string ?? "open"
        let gh: JSON = [
            "number": .int(number), "title": p["title"] ?? "", "headRefName": p["branch"] ?? "", "baseRefName": p["base"] ?? "main",
            "url": p["url"] ?? "", "author": ["login": p["author"] ?? ""], "state": .string(state.uppercased()),
            "isDraft": .bool(p["draft"]?.bool == true), "body": p["body"] ?? "", "createdAt": p["updatedAt"] ?? "",
            "additions": .int((p["files"]?.array ?? []).reduce(0) { $0 + ($1["additions"]?.int ?? 0) }),
            "deletions": .int((p["files"]?.array ?? []).reduce(0) { $0 + ($1["deletions"]?.int ?? 0) }),
            "mergeable": .string(p["conflicts"]?.bool == true ? "CONFLICTING" : p["conflicts"]?.bool == false ? "MERGEABLE" : "UNKNOWN"),
            "statusCheckRollup": run == .null ? [] : [run], "files": p["files"] ?? [], "comments": .array(comments),
            "reviews": .array(reviews), "autoMergeRequest": p["autoMerge"]?.bool == true ? ["mergeMethod": "SQUASH"] : .null,
        ]
        var page = prPage(gh: gh, diff: diff ? p["diff"]?.string ?? "" : nil)
        page["viewer"] = .string(Self.viewer(data))
        return page
    }

    static func viewer(_ data: JSON) -> String { data["viewer"]?.string ?? "alexec" }

    func base(_ data: JSON, _ repo: String) -> String { repoOf(data, repo)["defaultBranch"]?.string ?? "main" }

    public func branchesWithoutPR(repo: String) async throws -> (base: String, branches: [Branch]) {
        let data = try load()
        let taken = Set(list(data, repo, "prs").filter { ["open", "merged"].contains($0["state"]?.string ?? "open") }
            .compactMap { $0["branch"]?.string })
        let nodes: [JSON] = list(data, repo, "branches").map { b in
            let name = b["name"]?.string ?? ""
            return ["name": .string(name),
                    "target": ["committedDate": b["updatedAt"] ?? "", "messageHeadline": .string(
                        (b["commits"]?.array?.last?.string ?? "").split(separator: "\n").first.map(String.init) ?? "")],
                    "associatedPullRequests": ["totalCount": .int(taken.contains(name) ? 1 : 0)]]
        }
        let answer: JSON = ["data": ["repository": ["defaultBranchRef": ["name": .string(base(data, repo))], "refs": ["nodes": .array(nodes)]]]]
        return branchesFrom(graphQL: answer, now: Date())
    }

    public func prFill(repo: String, branch: String) async throws -> (base: String, commits: [String]) {
        let data = try load()
        guard let b = list(data, repo, "branches").first(where: { $0["name"]?.string == branch }) else {
            throw GhError(.notFound, "not found on GitHub")
        }
        return (base(data, repo), (b["commits"]?.array ?? []).compactMap(\.string))
    }

    /// Opens it as the next number. Refused when the branch is not there or already has an open PR, as GitHub does.
    public func createPR(repo: String, branch: String, base: String, title: String, body: String, draft: Bool) async throws -> JSON {
        try change { data in
            guard list(data, repo, "branches").contains(where: { $0["name"]?.string == branch }) else {
                throw GhError(.failed, "gh: Head sha can't be blank, Base sha can't be blank, No commits between \(base) and \(branch)")
            }
            var prs = list(data, repo, "prs")
            if prs.contains(where: { $0["branch"]?.string == branch && ($0["state"]?.string ?? "open") == "open" }) {
                throw GhError(.failed, "gh: a pull request for branch \"\(branch)\" into branch \"\(base)\" already exists")
            }
            let number = (prs.compactMap { $0["number"]?.int }.max() ?? 0) + 1
            let url = "https://github.com/\(repo)/pull/\(number)"
            prs.append(["number": .int(number), "title": .string(title), "branch": .string(branch), "base": .string(base),
                        "body": .string(body), "draft": .bool(draft), "author": .string(Self.viewer(data)), "authorAssociation": "OWNER",
                        "url": .string(url), "state": "open", "updatedAt": .string(Time.string(Date()))])
            data["repos"]?[repo]?["prs"] = .array(prs)
            return ["number": .int(number), "url": .string(url)]
        }
    }

    /// Adds the viewer's review to it. Refused on one's own PR and on one not open, as GitHub does.
    public func reviewPR(repo: String, number: Int, event: ReviewEvent, body: String) async throws -> JSON {
        try change { data in
            var prs = list(data, repo, "prs")
            guard let i = prs.firstIndex(where: { $0["number"]?.int == number }) else { throw GhError(.notFound, "not found on GitHub") }
            if prs[i]["state"]?.string != "open" { throw GhError(.failed, "gh: Pull request #\(number) is not open") }
            let viewer = Self.viewer(data)
            if prs[i]["author"]?.string == viewer {
                throw GhError(.failed, "gh: Can not \(event == .approve ? "approve" : "request changes on") your own pull request")
            }
            let state = event == .approve ? "APPROVED" : "CHANGES_REQUESTED"
            prs[i]["reviews"] = .array((prs[i]["reviews"]?.array ?? []) + [
                ["author": .string(viewer), "body": .string(body), "state": .string(state), "at": .string(Time.string(Date()))],
            ])
            data["repos"]?[repo]?["prs"] = .array(prs)
            return ["event": .string(event.rawValue), "url": prs[i]["url"] ?? ""]
        }
    }

    /// Merges it at once (state merged, its branch in `deletedBranches`), or with `auto` marks it
    /// `autoMerge`. One in conflict, merged or closed is refused, as GitHub does.
    public func mergePR(repo: String, number: Int, auto: Bool) async throws -> JSON {
        try change { data in
            var prs = list(data, repo, "prs")
            guard let i = prs.firstIndex(where: { $0["number"]?.int == number }) else { throw GhError(.notFound, "not found on GitHub") }
            if prs[i]["state"]?.string != "open" { throw GhError(.failed, "gh: Pull request #\(number) is not open") }
            if prs[i]["conflicts"]?.bool == true { throw GhError(.failed, "gh: Pull request #\(number) is not mergeable") }
            if auto {
                prs[i]["autoMerge"] = true
            } else {
                prs[i]["state"] = "merged"
                prs[i]["mergedAt"] = .string(Time.string(Date()))
                data["deletedBranches"] = .array((data["deletedBranches"]?.array ?? []) + [prs[i]["branch"] ?? ""])
            }
            data["repos"]?[repo]?["prs"] = .array(prs)
            return ["merged": .bool(!auto), "auto": .bool(auto), "url": prs[i]["url"] ?? ""]
        }
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
