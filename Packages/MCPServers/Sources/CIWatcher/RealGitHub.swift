import Foundation
import MCPServerKit

/// GitHub through `gh`, as the signed-in person. GET bodies are kept with their ETags, so an
/// unchanged listing costs no rate limit (GitHub doesn't count 304s).
public actor RealGitHub: GitHub {
    static let maxPages = 10
    static let perPage = 100
    /// How far back past `since` a run may have been created and still be rerun into view.
    static let rerunWindowMs = 24.0 * 3600_000

    private var etags: [String: (etag: String, body: String)] = [:]
    private var etagOrder: [String] = []
    /// Asked of gh once; a failure is asked again next time.
    private var repo: Task<String, any Error>?

    public init() {}

    // MARK: gh

    struct Response {
        var status: Int
        var headers: [String: String]
        var body: String
    }

    struct Ran {
        var code: Int32
        var stdout: String
        var stderr: String
        var missing: Bool
    }

    static func gh(_ args: [String]) async -> Ran {
        let outcome = await ChildProcess.run(command: "gh", args, deadline: .seconds(30), outputLimit: 64 * 1024 * 1024)
        // /usr/bin/env says 127 when there is no gh on PATH.
        let missing = outcome.status == 127 || outcome.failure != nil
        return Ran(code: outcome.status, stdout: outcome.text, stderr: outcome.errorText + (outcome.failure ?? ""),
                   missing: missing)
    }

    /// `gh api -i`'s output as a status, headers and body; nil when it is not a response.
    static func parse(_ stdout: String) -> Response? {
        guard stdout.hasPrefix("HTTP/") else { return nil }
        let head: Substring, body: Substring
        if let split = stdout.range(of: "\r\n\r\n") ?? stdout.range(of: "\n\n") {
            head = stdout[..<split.lowerBound]
            body = stdout[split.upperBound...]
        } else {
            head = Substring(stdout)
            body = ""
        }
        let lines = head.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" })
            .map { $0.hasSuffix("\r") ? $0.dropLast() : $0 }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":"), colon > line.startIndex else { continue }
            headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] =
                line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let statusWords = lines.first?.split(separator: " ") ?? []
        return Response(status: statusWords.count > 1 ? Int(statusWords[1]) ?? 0 : 0, headers: headers, body: String(body))
    }

    static func retryAfter(_ headers: [String: String]) -> Int? {
        if let after = headers["retry-after"], let seconds = Double(after) { return max(1000, Int(seconds * 1000)) }
        if headers["x-ratelimit-remaining"] == "0", let reset = Double(headers["x-ratelimit-reset"] ?? ""), reset > 0 {
            return max(1000, Int(reset * 1000 - Date().timeIntervalSince1970 * 1000))
        }
        return nil
    }

    static func failure(_ missing: Bool, _ stderr: String, _ res: Response?) -> GhError {
        if missing { return GhError(.notSignedIn, "gh not signed in: gh is not installed") }
        if res?.status == 401 || stderr.range(of: "auth login|not logged in|authentication required|HTTP 401",
                                              options: [.regularExpression, .caseInsensitive]) != nil {
            return GhError(.notSignedIn, "gh not signed in: run `gh auth login`")
        }
        if let res, res.status == 403 || res.status == 429 {
            let ms = retryAfter(res.headers)
            if ms != nil || res.body.range(of: "rate limit", options: .caseInsensitive) != nil {
                return GhError(.rateLimited, "GitHub rate limit", retryAfterMs: ms ?? 60_000)
            }
        }
        if res == nil, stderr.range(of: "rate limit", options: .caseInsensitive) != nil {
            return GhError(.rateLimited, "GitHub rate limit", retryAfterMs: 60_000)
        }
        if res?.status == 404 || stderr.range(of: "HTTP 404|Could not resolve", options: [.regularExpression, .caseInsensitive]) != nil {
            return GhError(.notFound, "not found on GitHub")
        }
        let firstLine = stderr.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").first.map(String.init)
        let why = res.map { "HTTP \($0.status)" } ?? firstLine ?? "gh failed"
        return GhError(.failed, "gh: \(why)")
    }

    func api(_ path: String, method: String? = nil, fields: [(String, String)] = [], cache: Bool = false,
             log: Bool = false) async throws -> String {
        var args = ["api", "-i", path, "-H", "Accept: application/vnd.github+json"]
        // gh refuses a body with terminal escapes, which job logs have; formatLogs strips them.
        if log { args.append("--allow-escape-sequences") }
        if let method { args += ["-X", method] }
        for (key, value) in fields { args += ["-f", "\(key)=\(value)"] }
        let cached = cache ? etags[path] : nil
        if let cached { args += ["-H", "If-None-Match: \(cached.etag)"] }
        let result = await Self.gh(args)
        let res = Self.parse(result.stdout)
        if let res, res.status == 304, let cached { return cached.body }
        if let res, (200..<300).contains(res.status) {
            if cache, let etag = res.headers["etag"] { remember(path, etag: etag, body: res.body) }
            return res.body
        }
        throw Self.failure(result.missing, result.stderr, res)
    }

    private func remember(_ path: String, etag: String, body: String) {
        etagOrder.removeAll { $0 == path }
        etagOrder.append(path)
        etags[path] = (etag, body)
        if etagOrder.count > 200 { etags[etagOrder.removeFirst()] = nil }
    }

    func json(_ path: String) async throws -> JSON {
        let body = try await api(path, cache: true)
        do { return try JSON.parse(body) } catch { throw GhError(.failed, "gh: GitHub's answer is not JSON") }
    }

    /// The PR, and whether its author is one of the repo's own (#728).
    func pr(_ repo: String, _ number: Int) async throws -> (pr: PR, trusted: Bool) {
        let p = try await json("repos/\(repo)/pulls/\(number)")
        return (PR(number: p["number"]?.int ?? number, title: p["title"]?.string ?? "",
                   branch: p["head"]?["ref"]?.string ?? "", url: p["html_url"]?.string ?? ""),
                Self.trusted(p))
    }

    /// Whether an issue's, comment's or PR's author is one of the repo's own (#728).
    static func trusted(_ item: JSON) -> Bool {
        isTrusted(association: item["author_association"]?.string, login: item["user"]?["login"]?.string,
                  type: item["user"]?["type"]?.string)
    }

    static func issueOf(_ i: JSON) -> Issue {
        Issue(number: i["number"]?.int ?? 0, title: i["title"]?.string ?? "", author: i["user"]?["login"]?.string ?? "",
              labels: (i["labels"]?.array ?? []).map { $0.string ?? $0["name"]?.string ?? "" },
              url: i["html_url"]?.string ?? "")
    }

    /// Pages of `path` (newest first), until an item older than `since` by `time`.
    func newest(_ path: String, since: String, time: (JSON) -> String?) async throws -> (items: [JSON], truncated: Bool) {
        var items = [JSON]()
        for page in 1...Self.maxPages {
            let list = try await json("\(path)\(path.contains("?") ? "&" : "?")per_page=\(Self.perPage)&page=\(page)").array ?? []
            for item in list {
                if at(time(item)) < at(since) { return (items, false) }
                items.append(item)
            }
            if list.count < Self.perPage { return (items, false) }
        }
        return (items, true)
    }

    func failedJobs(_ repo: String, _ runId: Int) async throws -> [JSON] {
        let jobs = try await json("repos/\(repo)/actions/runs/\(runId)/jobs?filter=latest&per_page=100")
        return (jobs["jobs"]?.array ?? []).filter { isFailed($0["conclusion"]?.string) }
    }

    // MARK: GitHub

    public func failedRuns(repo: String, branch: String?, since: String) async throws -> (runs: [RunRef], truncated: Bool) {
        var runs = [RunRef]()
        let floor = at(since) - Self.rerunWindowMs
        var query = "event=pull_request&status=failure&per_page=\(Self.perPage)"
        if let branch { query += "&branch=\(Self.encode(branch))" }
        for page in 1...Self.maxPages {
            let list = try await json("repos/\(repo)/actions/runs?\(query)&page=\(page)")["workflow_runs"]?.array ?? []
            for r in list {
                guard r["status"]?.string == "completed", isFailed(r["conclusion"]?.string),
                      at(r["updated_at"]?.string) >= at(since) else { continue }
                runs.append(RunRef(
                    id: r["id"]?.int ?? 0, attempt: r["run_attempt"]?.int ?? 1,
                    name: r["name"]?.string ?? r["display_title"]?.string ?? "", url: r["html_url"]?.string ?? "",
                    headSha: r["head_sha"]?.string ?? "", branch: r["head_branch"]?.string ?? "",
                    prNumber: r["pull_requests"]?[0]?["number"]?.int, updatedAt: r["updated_at"]?.string ?? ""))
            }
            // Runs are listed newest created first; a rerun keeps its created_at.
            if list.count < Self.perPage || at(list.last?["created_at"]?.string) < floor { return (runs, false) }
        }
        return (runs, true)
    }

    public func runDetails(repo: String, run ref: RunRef) async throws -> FailedRunData? {
        var number = ref.prNumber
        if number == nil {
            // A fork's PR isn't on the run; find it by the head commit.
            let pulls = try await json("repos/\(repo)/commits/\(ref.headSha)/pulls").array ?? []
            number = (pulls.first { $0["head"]?["ref"]?.string == ref.branch } ?? pulls.first)?["number"]?.int
        }
        guard let number else { return nil }
        let jobs = try await failedJobs(repo, ref.id)
        let (pr, trusted) = try await pr(repo, number)
        return FailedRunData(pr: pr, headSha: ref.headSha, run: ref,
                             failedJobs: jobs.map { ($0["name"]?.string ?? "", $0["html_url"]?.string ?? "") },
                             trusted: trusted)
    }

    public func defaultRepo() async throws -> String {
        if let repo { return try await repo.value }
        let task = Task<String, any Error> {
            let result = await Self.gh(["repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner"])
            let name = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if result.code != 0 || name.isEmpty {
                throw result.missing ? GhError(.notSignedIn, "gh is not installed")
                    : GhError(.notFound, "repo is needed: \(FileManager.default.currentDirectoryPath) has no GitHub repo")
            }
            return name
        }
        repo = task
        do { return try await task.value } catch {
            repo = nil
            throw error
        }
    }

    public func closedPRs(repo: String, since: String) async throws -> (merged: [MergedPR], closed: [ClosedPR], truncated: Bool) {
        var merged = [MergedPR](), closed = [ClosedPR]()
        for page in 1...Self.maxPages {
            let list = try await json("repos/\(repo)/pulls?state=closed&sort=updated&direction=desc&per_page=\(Self.perPage)&page=\(page)").array ?? []
            for p in list {
                if at(p["updated_at"]?.string) < at(since) { return (merged, closed, false) }
                let pr = PR(number: p["number"]?.int ?? 0, title: p["title"]?.string ?? "",
                            branch: p["head"]?["ref"]?.string ?? "", url: p["html_url"]?.string ?? "")
                if let mergedAt = p["merged_at"]?.string {
                    if at(mergedAt) >= at(since) { merged.append(MergedPR(pr: pr, mergedAt: mergedAt, mergeSha: p["merge_commit_sha"]?.string ?? "")) }
                } else if let closedAt = p["closed_at"]?.string, at(closedAt) >= at(since) {
                    closed.append(ClosedPR(pr: pr, closedAt: closedAt))
                }
            }
            if list.count < Self.perPage { return (merged, closed, false) }
        }
        return (merged, closed, true)
    }

    public func listPRs(repo: String) async throws -> [BoardPR] {
        let result = await Self.gh(["pr", "list", "-R", repo, "--state", "open", "--limit", "100",
                                    "--json", "number,title,headRefName,statusCheckRollup,url,mergeable"])
        if result.code != 0 { throw Self.failure(result.missing, result.stderr, nil) }
        let list = (try? JSON.parse(result.stdout))?.array ?? []
        return list.map { p in
            let (checks, failedRunId) = rollup(p["statusCheckRollup"]?.array)
            // UNKNOWN while GitHub works it out: neither yes nor no.
            let mergeable = p["mergeable"]?.string
            return BoardPR(pr: PR(number: p["number"]?.int ?? 0, title: p["title"]?.string ?? "",
                                  branch: p["headRefName"]?.string ?? "", url: p["url"]?.string ?? ""),
                           checks: checks, failedRunId: failedRunId,
                           conflicts: mergeable == "CONFLICTING" ? true : mergeable == "MERGEABLE" ? false : nil)
        }
    }

    public func openPRs(repo: String) async throws -> [OpenPR] {
        var out = [OpenPR]()
        for page in 1...Self.maxPages {
            let list = try await json("repos/\(repo)/pulls?state=open&sort=created&direction=desc&per_page=\(Self.perPage)&page=\(page)").array ?? []
            for p in list {
                out.append(OpenPR(pr: PR(number: p["number"]?.int ?? 0, title: p["title"]?.string ?? "",
                                         branch: p["head"]?["ref"]?.string ?? "", url: p["html_url"]?.string ?? ""),
                                  author: p["user"]?["login"]?.string ?? "", draft: p["draft"]?.bool == true,
                                  trusted: Self.trusted(p)))
            }
            if list.count < Self.perPage { break }
        }
        return out
    }

    public func issueActivity(repo: String, kind: IssueKind, since: String) async throws -> (items: [IssueActivity], truncated: Bool) {
        switch kind {
        case .opened:
            let (items, truncated) = try await newest("repos/\(repo)/issues?state=all&sort=created&direction=desc",
                                                      since: since) { $0["created_at"]?.string }
            return (items.filter { $0["pull_request"] == nil }.map {
                IssueActivity(id: String($0["number"]?.int ?? 0), at: $0["created_at"]?.string ?? "",
                              issue: Self.issueOf($0), what: .opened, trusted: Self.trusted($0))
            }, truncated)
        case .commented:
            // `since` lists comments updated since; an edited old one is dropped by its created_at.
            let (items, truncated) = try await newest(
                "repos/\(repo)/issues/comments?sort=created&direction=desc&since=\(Self.encode(since))",
                since: since) { $0["created_at"]?.string }
            var out = [IssueActivity]()
            var issues: [String: JSON] = [:]
            for c in items {
                // A comment doesn't say whether its issue is a pull request; the issue does (and is cached).
                let path = (c["issue_url"]?.string ?? "").replacingOccurrences(of: "https://api.github.com/", with: "")
                if issues[path] == nil { issues[path] = try await json(path) }
                let i = issues[path]!
                if i["pull_request"] != nil { continue }
                out.append(IssueActivity(
                    id: String(c["id"]?.int ?? 0), at: c["created_at"]?.string ?? "",
                    issue: Self.issueOf(i),
                    what: .commented(author: c["user"]?["login"]?.string ?? "", url: c["html_url"]?.string ?? "",
                                     body: clip(c["body"]?.string)),
                    trusted: Self.trusted(c)))
            }
            return (out, truncated)
        case .labelled, .closed:
            let (items, truncated) = try await newest("repos/\(repo)/issues/events", since: since) { $0["created_at"]?.string }
            let wanted = kind == .labelled ? "labeled" : "closed"
            return (items.filter { $0["event"]?.string == wanted && $0["issue"] != nil && $0["issue"]?["pull_request"] == nil }
                .map { e in
                    let issue = e["issue"] ?? [:]
                    let by = e["actor"]?["login"]?.string ?? ""
                    let trusted = isTrustedActor(by, type: e["actor"]?["type"]?.string, closing: kind == .closed,
                                                 issueAuthor: issue["user"]?["login"]?.string ?? "",
                                                 authorTrusted: Self.trusted(issue))
                    return IssueActivity(
                        id: String(e["id"]?.int ?? 0), at: e["created_at"]?.string ?? "", issue: Self.issueOf(issue),
                        what: kind == .labelled ? .labelled(label: e["label"]?["name"]?.string ?? "", by: by)
                            : .closed(reason: reasonOf(e["state_reason"]?.string ?? issue["state_reason"]?.string), by: by),
                        trusted: trusted)
                }, truncated)
        }
    }

    public func listIssues(repo: String, label: String?) async throws -> [ListedIssue] {
        // The issues listing has pull requests in it too; ask for more than 100 so 100 issues are likely.
        var query = "state=open&sort=updated&direction=desc&per_page=\(Self.perPage)"
        if let label { query += "&labels=\(Self.encode(label))" }
        var out = [ListedIssue]()
        for page in 1...3 where out.count < Self.perPage {
            let list = try await json("repos/\(repo)/issues?\(query)&page=\(page)").array ?? []
            for i in list where i["pull_request"] == nil && out.count < Self.perPage {
                out.append(ListedIssue(issue: Self.issueOf(i), comments: i["comments"]?.int ?? 0,
                                       updatedAt: i["updated_at"]?.string ?? ""))
            }
            if list.count < Self.perPage { break }
        }
        return out
    }

    public func failedLog(repo: String, runId: Int, job: String?) async throws -> String {
        let jobs = try await failedJobs(repo, runId).filter { job == nil || $0["name"]?.string == job }
        var logs = [(name: String, url: String, log: String)]()
        for j in jobs {
            logs.append((j["name"]?.string ?? "", j["html_url"]?.string ?? "",
                         try await api("repos/\(repo)/actions/jobs/\(j["id"]?.int ?? 0)/logs", log: true)))
        }
        return formatLogs(logs, runId: runId)
    }

    public func rerunFailed(repo: String, runId: Int) async throws -> JSON {
        _ = try await api("repos/\(repo)/actions/runs/\(runId)/rerun-failed-jobs", method: "POST")
        return ["rerun": true, "url": .string(runURL(repo, runId))]
    }

    public func commentOnPR(repo: String, number: Int, body: String) async throws -> JSON {
        let comment = try JSON.parse(try await api("repos/\(repo)/issues/\(number)/comments", method: "POST", fields: [("body", body)]))
        return ["url": JSON(comment["html_url"]?.string)]
    }

    public func prDetail(repo: String, number: Int, diff: Bool) async throws -> JSON {
        let view = await Self.gh(["pr", "view", String(number), "-R", repo, "--json",
                                  "number,title,headRefName,baseRefName,url,author,state,isDraft,body,createdAt,additions,deletions,"
                                      + "mergeable,reviewDecision,statusCheckRollup,files,comments,reviews,autoMergeRequest"])
        if view.code != 0 { throw Self.failure(view.missing, view.stderr, nil) }
        guard let p = try? JSON.parse(view.stdout) else { throw GhError(.failed, "gh: GitHub's answer is not JSON") }
        var text: String?
        if diff {
            let ran = await Self.gh(["pr", "diff", String(number), "-R", repo, "--color", "never"])
            if ran.code != 0 { throw Self.failure(ran.missing, ran.stderr, nil) }
            text = ran.stdout
        }
        return prPage(gh: p, diff: text)
    }

    public func mergePR(repo: String, number: Int, auto: Bool) async throws -> JSON {
        // -R keeps gh off the server's own folder: it deletes the branch on GitHub only, and never
        // checks out or deletes a local branch.
        let ran = await Self.gh(["pr", "merge", String(number), "-R", repo, "--squash", "--delete-branch"] + (auto ? ["--auto"] : []))
        if ran.code != 0 { throw Self.failure(ran.missing, ran.stderr, nil) }
        return ["merged": .bool(!auto), "auto": .bool(auto), "url": .string("https://github.com/\(repo)/pull/\(number)")]
    }

    /// As `encodeURIComponent` does it.
    static func encode(_ text: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }
}
