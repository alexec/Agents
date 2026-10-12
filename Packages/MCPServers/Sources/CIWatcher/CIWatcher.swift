// The CI watcher MCP server (#383): this repo's pull requests' CI and its issues (#682) as
// events, tools and views, over MCP's stdio transport. The Agents daemon hosts it (#488). The
// contract is specs/383-mcp-integrations/contracts/ci-watcher-server.md.
import Foundation
import MCPServerKit

public enum CIWatcher {
    public static let version = "0.2.0"

    static let repoProperty = Schema.Property.string(
        "The GitHub repo, owner/name. Left out, the repo this project's folder pushes to.",
        pattern: (#"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"#, "owner/name"))
    static let prProperty = Schema.Property.integer("Only this pull request, by number.")
    /// Anyone's issue, comment or PR is opted into (#728); left out, only the repo's own people.
    static let anyoneProperty = Schema.Property.boolean(
        "true: from anyone, bots and people outside the repo too. Left out, only the repo's owner, members and collaborators, never a bot.")

    /// The CI watcher over `gh`.
    public static func server(_ gh: some GitHub) -> MCPServer {
        let poller = EventPoll()
        return MCPServer(
            info: .init(name: "ci-watcher", title: "CI watcher", version: version),
            instructions: "This repo's pull requests, their CI, and its issues. Events: checks.failed, pr.merged, pr.conflicted, pr.closed, issue.opened, issue.labelled, issue.commented, issue.closed. Tools list pull requests and issues, read logs, rerun failed jobs and comment, as the signed-in gh user.",
            tools: tools, resources: resources, events: events,
            extensions: ["io.modelcontextprotocol/ui": [:]],
            callTool: { tool, arguments in await callTool(gh, tool, arguments) },
            poll: { event, params in
                let args = try await withRepo(gh, try event.inputSchema.check(params["arguments"]))
                if event.name == "pr.conflicted" { return try await pollConflicts(gh, args, params) }
                return try await poller.poll(event: event, params: params,
                                             candidates: { since in try await candidates(gh, event.name, args, since) },
                                             mapError: eventsError)
            })
    }

    // MARK: Errors

    /// A gh failure as the events draft's error codes.
    static func eventsError(_ error: any Error) -> RPCError {
        if let error = error as? RPCError { return error }
        guard let error = error as? GhError else { return .internalError("\(error)") }
        switch error.kind {
        case .notSignedIn: return RPCError(-32012, error.message, data: ["reason": "gh not signed in"])
        case .rateLimited: return RPCError(-32013, error.message, data: ["retryAfterMs": JSON(error.retryAfterMs)])
        case .notFound: return .invalidParams("\(error.message): check repo")
        case .failed: return .internalError(error.message)
        }
    }

    /// `args` with `repo` filled in from the project's folder when it was left out (#702).
    static func withRepo(_ gh: some GitHub, _ args: [String: JSON]) async throws(RPCError) -> [String: JSON] {
        if args["repo"] != nil { return args }
        do {
            var filled = args
            filled["repo"] = .string(try await gh.defaultRepo())
            return filled
        } catch let error as GhError where error.kind == .notFound {
            throw .invalidParams(error.message)
        } catch {
            throw eventsError(error)
        }
    }

    // MARK: Events

    static let prSchema: JSON = [
        "type": "object",
        "properties": ["number": ["type": "integer"], "title": ["type": "string"], "branch": ["type": "string"], "url": ["type": "string"]],
    ]

    static let events: [Event] = [
        Event(name: "checks.failed", title: "Checks failed",
              description: "A pull request's checks finished with a failure: one event per run and attempt, so a rerun that fails again is a new one. Only PRs by the repo's owner, members and collaborators, unless anyone is true.",
              inputSchema: Schema(["repo": repoProperty, "branch": .string("Only runs on this PR branch."), "pr": prProperty,
                                   "anyone": anyoneProperty]),
              payloadSchema: [
                  "type": "object",
                  "properties": [
                      "pr": prSchema, "headSha": ["type": "string"],
                      "run": ["type": "object", "properties": ["id": ["type": "integer"], "attempt": ["type": "integer"],
                                                               "name": ["type": "string"], "url": ["type": "string"]]],
                      "failedJobs": ["type": "array", "items": ["type": "object", "properties": ["name": ["type": "string"], "url": ["type": "string"]]]],
                  ],
              ]),
        Event(name: "pr.merged", title: "Pull request merged", description: "A pull request was merged.",
              inputSchema: Schema(["repo": repoProperty, "branch": .string("Only the PR from this branch."), "pr": prProperty]),
              payloadSchema: ["type": "object", "properties": ["pr": prSchema, "mergedAt": ["type": "string"], "mergeSha": ["type": "string"]]]),
        Event(name: "pr.closed", title: "Pull request closed", description: "A pull request was closed without being merged.",
              inputSchema: Schema(["repo": repoProperty, "branch": .string("Only the PR from this branch."), "pr": prProperty]),
              payloadSchema: ["type": "object", "properties": ["pr": prSchema, "closedAt": ["type": "string"]]]),
        Event(name: "pr.conflicted", title: "Pull request in conflict",
              description: "An open pull request began to conflict with its base, so it cannot merge and its CI may not run until it is rebased. Once per conflict: it is raised again only after the PR merges cleanly and then conflicts anew.",
              inputSchema: Schema(["repo": repoProperty, "branch": .string("Only the PR from this branch."), "pr": prProperty]),
              payloadSchema: ["type": "object", "properties": ["pr": prSchema, "conflictedAt": ["type": "string"]]]),
    ] + issueEvents()

    static func issueEvents() -> [Event] {
        let issueSchema: JSON = [
            "type": "object",
            "properties": [
                "number": ["type": "integer"], "title": ["type": "string"], "author": ["type": "string"],
                "labels": ["type": "array", "items": ["type": "string"]], "url": ["type": "string"],
            ],
        ]
        let issue = Schema.Property.integer("Only this issue, by number.")
        let kinds: [(kind: IssueKind, title: String, description: String, label: String, payload: [String: JSON])] = [
            (.opened, "Issue opened", "An issue was opened. Pull requests are not issues here.",
             "Only issues opened with this label.", ["openedAt": ["type": "string"]]),
            (.labelled, "Issue labelled", "A label was added to an issue: one event per label added.",
             "Only when this label is the one added.",
             ["label": ["type": "string"], "by": ["type": "string"], "labelledAt": ["type": "string"]]),
            (.commented, "Issue commented on",
             "A comment was left on an issue (not a pull request). Its body is the first 4000 characters.",
             "Only issues with this label.",
             ["comment": ["type": "object", "properties": ["author": ["type": "string"], "url": ["type": "string"], "body": ["type": "string"]]],
              "commentedAt": ["type": "string"]]),
            (.closed, "Issue closed", "An issue was closed, as completed or not planned.", "Only issues with this label.",
             ["reason": ["type": "string", "enum": ["completed", "not_planned"]], "by": ["type": "string"], "closedAt": ["type": "string"]]),
        ]
        // Whose doing it must be (#728), unless anyone is true.
        let who: [IssueKind: String] = [
            .opened: "Only issues opened by", .labelled: "Only labels added by",
            .commented: "Only comments by", .closed: "Only issues closed by",
        ]
        return kinds.map { k in
            let label = Schema.Property.string(k.label)
            return Event(
                name: "issue.\(k.kind.rawValue)", title: k.title,
                description: k.description + " \(who[k.kind]!) the repo's owner, members and collaborators, never a bot, unless anyone is true."
                    + (k.kind == .closed ? " Someone outside the repo closing their own issue does not count." : ""),
                inputSchema: k.kind == .opened ? Schema(["repo": repoProperty, "label": label, "anyone": anyoneProperty])
                    : Schema(["repo": repoProperty, "label": label, "issue": issue, "anyone": anyoneProperty]),
                payloadSchema: ["type": "object", "properties": JSON.object(["issue": issueSchema]).merging(k.payload)])
        }
    }

    static func candidates(_ gh: some GitHub, _ name: String, _ args: [String: JSON], _ since: String) async throws
        -> (list: [Candidate], truncated: Bool)
    {
        let repo = args["repo"]?.string ?? ""
        let pr = args["pr"]?.int, branch = args["branch"]?.string
        let anyone = args["anyone"]?.bool == true
        if name.hasPrefix("issue."), let kind = IssueKind(rawValue: String(name.dropFirst("issue.".count))) {
            let issue = args["issue"]?.int, label = args["label"]?.string
            let (items, truncated) = try await gh.issueActivity(repo: repo, kind: kind, since: since)
            let list = items
                .filter { issue == nil || $0.issue.number == issue }
                .filter { anyone || $0.trusted }
                .filter { a in
                    guard let label else { return true }
                    if case .labelled(let added, _) = a.what { return added == label }
                    return a.issue.labels.contains(label)
                }
                .compactMap { a in
                    Time.normalized(a.at).map { time in
                        Candidate(eventId: "\(name):\(repo):\(a.id)", time: time) { a.data }
                    }
                }
            return (list, truncated)
        }
        if name == "checks.failed" {
            let (runs, truncated) = try await gh.failedRuns(repo: repo, branch: branch, since: since)
            // A run that names another PR is skipped before its details are fetched; one that names
            // none is checked against the PR its details find. The cursor still moves past both.
            let list = runs.compactMap { ref in
                Time.normalized(ref.updatedAt).map { time in
                    Candidate(eventId: "checks.failed:\(repo):\(ref.id):\(ref.attempt)", time: time) {
                        if let pr, let named = ref.prNumber, named != pr { return nil }
                        let details = try await gh.runDetails(repo: repo, run: ref)
                        if let pr, details?.pr.number != pr { return nil }
                        if !anyone, details?.trusted != true { return nil }
                        return details?.json
                    }
                }
            }
            return (list, truncated)
        }
        let (merged, closed, truncated) = try await gh.closedPRs(repo: repo, since: since)
        let wanted = { (p: PR) in (pr == nil || p.number == pr) && (branch == nil || p.branch == branch) }
        let list: [Candidate] = name == "pr.merged"
            ? merged.filter { wanted($0.pr) }.compactMap { m in
                Time.normalized(m.mergedAt).map { Candidate(eventId: "pr.merged:\(repo):\(m.pr.number)", time: $0) { m.json } }
            }
            // Its close time in the id: a PR reopened and closed again is a new event.
            : closed.filter { wanted($0.pr) }.compactMap { c in
                Time.normalized(c.closedAt).map { Candidate(eventId: "pr.closed:\(repo):\(c.pr.number):\(c.closedAt)", time: $0) { c.json } }
            }
        return (list, truncated)
    }

    /// A conflict has no time on GitHub, only a state, so `pr.conflicted` diffs it (#712): the
    /// cursor's ids are the PRs that were in conflict at the last poll, and one that is now and
    /// was not then is raised. A first poll takes those already in conflict as known. A PR
    /// GitHub has not worked out yet keeps the state it had.
    static func pollConflicts(_ gh: some GitHub, _ args: [String: JSON], _ params: JSON) async throws(RPCError) -> JSON {
        let first = params["cursor"] == nil || params["cursor"] == .null
        let cursor = first ? PollCursor(since: "") : try PollCursor.decode(params["cursor"])
        let limit = first ? 100 : min(100, max(1, params["maxEvents"]?.int ?? 50))
        let prs: [BoardPR]
        do { prs = try await gh.listPRs(repo: args["repo"]?.string ?? "") } catch { throw eventsError(error) }
        let repo = args["repo"]?.string ?? "", pr = args["pr"]?.int, branch = args["branch"]?.string
        let was = Set(cursor.ids)
        let id = { (number: Int) in "pr.conflicted:\(repo):\(number)" }
        let wanted = prs.filter { (pr == nil || $0.pr.number == pr) && (branch == nil || $0.pr.branch == branch) }
        let now = wanted.filter { $0.conflicts == true || ($0.conflicts == nil && was.contains(id($0.pr.number))) }
        let fresh = now.filter { !was.contains(id($0.pr.number)) }.sorted { $0.pr.number < $1.pr.number }
        let taken = fresh.prefix(limit)
        let time = Time.string(Date())
        let ids = (now.filter { was.contains(id($0.pr.number)) } + taken).map { id($0.pr.number) }
        let events: [JSON] = first ? [] : taken.map {
            ["eventId": .string("\(id($0.pr.number)):\(time)"), "name": "pr.conflicted", "timestamp": .string(time),
             "data": ["pr": $0.pr.json, "conflictedAt": .string(time)]]
        }
        return ["events": .array(events), "cursor": .string(PollCursor(since: time, ids: ids).encoded), "truncated": false,
                "hasMore": .bool(!first && fresh.count > taken.count), "nextPollMs": 30000]
    }

    // MARK: Tools

    static let tools: [Tool] = [
        Tool(name: "list_prs", title: "List pull requests",
             description: "The repo's open pull requests, each with its checks: passing, failing, running or none. A failing one has the failed run's id for failed_log and rerun_failed. conflicts says whether it conflicts with its base (left out while GitHub works it out); one in conflict may get no CI until it is rebased.",
             inputSchema: Schema(["repo": repoProperty]),
             annotations: ["readOnlyHint": true],
             meta: ["ui": ["resourceUri": "ui://ci/board", "visibility": ["model", "app"]], "ui/resourceUri": "ui://ci/board"]),
        Tool(name: "list_issues", title: "List issues",
             description: "The repo's open issues (not pull requests), newest updated first, at most 100, each with its labels and comment count.",
             inputSchema: Schema(["repo": repoProperty, "label": .string("Only issues with this label.")]),
             annotations: ["readOnlyHint": true],
             meta: ["ui": ["resourceUri": "ui://ci/issues", "visibility": ["model", "app"]], "ui/resourceUri": "ui://ci/issues"]),
        Tool(name: "failed_log", title: "Read a failed run's log",
             description: "The last 300 lines of each failed job's log in an Actions run, or of one job by name.",
             inputSchema: Schema(["repo": repoProperty, "runId": .integer("The Actions run's id."),
                                  "job": .string("Only the job with this name.")], required: ["runId"]),
             annotations: ["readOnlyHint": true],
             meta: ["ui": ["visibility": ["model"]]]),
        Tool(name: "rerun_failed", title: "Rerun failed jobs",
             description: "Reruns an Actions run's failed jobs. Use it for a failure that is known to be flaky, not to hide a real one.",
             inputSchema: Schema(["repo": repoProperty, "runId": .integer("The Actions run's id.")], required: ["runId"]),
             meta: ["ui": ["visibility": ["model", "app"]]]),
        Tool(name: "comment_on_pr", title: "Comment on a pull request",
             description: "Adds a comment to a pull request, as the signed-in person. Say what you changed or why it needs a person.",
             inputSchema: Schema(["repo": repoProperty, "number": .integer("The pull request's number."),
                                  "body": .string("The comment, in Markdown.", maxLength: 65536)], required: ["number", "body"]),
             meta: ["ui": ["visibility": ["model"]]]),
    ]

    /// A tool's answer; anything that goes wrong, bad arguments included, is `isError` with why.
    static func callTool(_ gh: some GitHub, _ tool: Tool, _ arguments: JSON?) async -> JSON {
        do {
            let a = try await withRepo(gh, try tool.inputSchema.check(arguments))
            let repo = a["repo"]?.string ?? ""
            switch tool.name {
            case "failed_log":
                return ToolResult.text(try await gh.failedLog(repo: repo, runId: a["runId"]?.int ?? 0, job: a["job"]?.string))
            case "list_prs":
                return ToolResult.structured(["prs": .array(try await gh.listPRs(repo: repo).map(\.json))])
            case "list_issues":
                return ToolResult.structured(["issues": .array(try await gh.listIssues(repo: repo, label: a["label"]?.string).map(\.json))])
            case "rerun_failed":
                return ToolResult.structured(try await gh.rerunFailed(repo: repo, runId: a["runId"]?.int ?? 0))
            default:
                return ToolResult.structured(try await gh.commentOnPR(repo: repo, number: a["number"]?.int ?? 0, body: a["body"]?.string ?? ""))
            }
        } catch let error as GhError where error.kind == .rateLimited {
            return ToolResult.error("\(error.message); try again in \(((error.retryAfterMs ?? 60_000) + 999) / 1000)s")
        } catch let error as RPCError {
            return ToolResult.error(error.message)
        } catch {
            return ToolResult.error("\(error)")
        }
    }

    // MARK: Resources

    static let viewMime = "text/html;profile=mcp-app"
    // No network at all: an empty csp, so the host draws it under its strictest policy.
    static let viewMeta: JSON = ["ui": ["csp": [:], "prefersBorder": true]]

    static let resources: [Resource] = [
        Resource(uri: "ui://ci/board", name: "board", title: "Pull requests",
                 description: "The repo's open pull requests and their checks, with Rerun on a failing one. Fed by list_prs.",
                 mimeType: viewMime, meta: viewMeta, text: boardHTML),
        Resource(uri: "ui://ci/issues", name: "issues", title: "Issues",
                 description: "The repo's open issues with their labels; a label narrows the list. Fed by list_issues.",
                 mimeType: viewMime, meta: viewMeta, text: issuesHTML),
    ]
}
