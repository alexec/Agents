// The CI watcher in its fake mode, against a copy of Fixtures/ci.json, ported from the Node
// server's tests (#700). Nothing here calls gh or GitHub. Each test has its own copy.
import CIWatcher
import Foundation
import MCPServerKit
import Testing

let repo = "alexec/Agents"

/// One server over a scratch copy of the fixture.
final class Harness: @unchecked Sendable {
    let scratch: URL
    let fixture: URL
    let server: MCPServer

    init() throws {
        scratch = FileManager.default.temporaryDirectory.appending(path: "ci-watcher-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        fixture = scratch.appending(path: "ci.json")
        let source = try #require(Bundle.module.url(forResource: "ci", withExtension: "json", subdirectory: "Fixtures"))
        try FileManager.default.copyItem(at: source, to: fixture)
        server = CIWatcher.server(FakeGitHub(file: fixture))
    }

    deinit { try? FileManager.default.removeItem(at: scratch) }

    func read() throws -> JSON { try JSON.parse(Data(contentsOf: fixture)) }

    /// The fixture as it is now, changed by `change`, written back.
    func edit(_ change: (inout JSON) -> Void) throws {
        var data = try read()
        change(&data)
        try Data(data.prettyText.utf8).write(to: fixture)
    }

    /// Changes this repo's part of the fixture.
    func editRepo(_ change: (inout JSON) -> Void) throws {
        try edit { data in
            var r = data["repos"]?[repo] ?? [:]
            change(&r)
            data["repos"]?[repo] = r
        }
    }

    func rpc(_ method: String, _ params: JSON = [:]) async -> JSON {
        await JSONRPC.answer(message: ["jsonrpc": "2.0", "id": 1, "method": .string(method), "params": params],
                             with: server, name: "test") ?? .null
    }

    func ok(_ method: String, _ params: JSON = [:]) async throws -> JSON {
        let body = await rpc(method, params)
        #expect(body["error"] == nil, "\(body["error"]?.text ?? "")")
        return try #require(body["result"])
    }

    func poll(_ name: String, _ args: JSON, _ cursor: JSON, maxEvents: Int = 50) async throws -> JSON {
        try await ok("events/poll", ["name": .string(name), "arguments": args, "cursor": cursor, "maxEvents": .int(maxEvents)])
    }

    func call(_ tool: String, _ args: JSON) async throws -> JSON {
        try await ok("tools/call", ["name": .string(tool), "arguments": args])
    }
}

func now(_ offsetMs: Double = 0) -> String { Time.string(Date().addingTimeInterval(offsetMs / 1000)) }
func cursorAt(_ since: String) -> JSON { .string(PollCursor(since: since).encoded) }
func ids(_ result: JSON) -> [String] { (result["events"]?.array ?? []).compactMap { $0["eventId"]?.string } }
func append(_ r: inout JSON, _ key: String, _ items: JSON...) { r[key] = .array((r[key]?.array ?? []) + items) }

func failedRun(_ id: Int, _ branch: String, _ updatedAt: String, attempt: Int = 1, pr: Int = 402) -> JSON {
    [
        "id": .int(id), "attempt": .int(attempt), "name": "CI", "url": .string("https://github.com/\(repo)/actions/runs/\(id)"),
        "event": "pull_request", "status": "completed", "conclusion": "failure",
        "branch": .string(branch), "headSha": .string("sha\(id)"), "pr": .int(pr), "updatedAt": .string(updatedAt),
        "jobs": [
            ["name": "test", "url": .string("https://github.com/\(repo)/actions/runs/\(id)/job/1"), "conclusion": "failure", "log": "boom"],
            ["name": "check", "url": .string("https://github.com/\(repo)/actions/runs/\(id)/job/2"), "conclusion": "success", "log": "fine"],
        ],
    ]
}

func openPR(_ number: Int, _ branch: String, _ extra: [String: JSON] = [:]) -> JSON {
    JSON.object(["number": .int(number), "title": .string("PR \(number)"), "branch": .string(branch),
                 "url": .string("https://github.com/\(repo)/pull/\(number)"), "state": "open", "updatedAt": .string(now())])
        .merging(extra)
}

func newIssue(_ number: Int, _ labels: [String], _ createdAt: String) -> JSON {
    ["number": .int(number), "title": .string("Issue \(number)"), "author": "someone", "labels": JSON(labels),
     "url": .string("https://github.com/\(repo)/issues/\(number)"), "state": "open",
     "createdAt": .string(createdAt), "updatedAt": .string(createdAt), "comments": [], "events": []]
}

/// Changes the issue numbered `number` in a repo's part of the fixture.
func editIssue(_ r: inout JSON, _ number: Int, _ change: (inout JSON) -> Void) {
    var issues = r["issues"]?.array ?? []
    if let i = issues.firstIndex(where: { $0["number"]?.int == number }) { change(&issues[i]) }
    r["issues"] = .array(issues)
}

@Suite struct CIWatcherTests {
    let h: Harness
    init() throws { h = try Harness() }

    @Test func initializeGivesTheContractsCapabilities() async throws {
        let result = try await h.ok("initialize", ["protocolVersion": "2026-07-28", "capabilities": [:], "clientInfo": ["name": "t", "version": "1"]])
        #expect(result["protocolVersion"] == "2026-07-28")
        #expect(result["capabilities"] == [
            "tools": [:], "resources": [:], "events": ["listChanged": false],
            "extensions": ["io.modelcontextprotocol/ui": [:]],
        ])
        #expect(result["serverInfo"]?["name"] == "ci-watcher")
        let older = try await h.ok("initialize", ["protocolVersion": "2025-06-18", "capabilities": [:]])
        #expect(older["protocolVersion"] == "2025-06-18")
    }

    @Test func aNotificationIsAnsweredWithNothing() async throws {
        let answer = await JSONRPC.answer(message: ["jsonrpc": "2.0", "method": "notifications/initialized"], with: h.server, name: "test")
        #expect(answer == nil)
        #expect(try await h.ok("ping") == [:])
    }

    @Test func eventsListGivesEveryEventPollOnlyWithTheirSchemas() async throws {
        let events = try #require(try await h.ok("events/list")["events"]?.array)
        #expect(events.compactMap { $0["name"]?.string }.sorted() ==
            ["checks.failed", "issue.closed", "issue.commented", "issue.labelled", "issue.opened", "pr.closed", "pr.conflicted", "pr.merged"])
        for e in events {
            #expect(e["delivery"] == ["poll"])
            #expect(e["description"]?.string?.isEmpty == false)
            #expect(e["inputSchema"]?["type"] == "object")
            #expect(e["inputSchema"]?["required"] == [])
            #expect(e["inputSchema"]?["properties"]?["repo"]?["type"] == "string")
            #expect(e["payloadSchema"]?["type"] == "object")
            let name = e["name"]?.string ?? ""
            if name.hasPrefix("issue.") {
                #expect(e["inputSchema"]?["properties"]?["label"]?["type"] == "string")
                #expect(e["inputSchema"]?["properties"]?["issue"]?["type"] == (name == "issue.opened" ? nil : "integer"))
                #expect(e["payloadSchema"]?["properties"]?["issue"]?["type"] == "object")
            } else {
                #expect(e["inputSchema"]?["properties"]?["branch"]?["type"] == "string")
                #expect(e["inputSchema"]?["properties"]?["pr"]?["type"] == "integer")
                #expect(e["inputSchema"]?["properties"]?["pr"]?["description"] != nil)
            }
        }
    }

    @Test func cursorNullGivesNoEventsAndACursor() async throws {
        let result = try await h.poll("checks.failed", ["repo": .string(repo)], .null)
        #expect(result["events"] == [])
        #expect(result["cursor"]?.string != nil)
        #expect(result["truncated"] == false)
        #expect(result["hasMore"] == false)
        #expect(result["nextPollMs"] == 30000)
    }

    @Test func anAppendedFailedRunGivesOneChecksFailedAndASecondAttemptANewId() async throws {
        let args: JSON = ["repo": .string(repo)]
        let first = try await h.poll("checks.failed", args, .null)
        try h.editRepo { append(&$0, "runs", failedRun(9100, "agents/queue-helpers", now(5))) }
        let raised = try await h.poll("checks.failed", args, first["cursor"] ?? .null)
        let event = try #require(raised["events"]?.array?.first)
        #expect(ids(raised) == ["checks.failed:\(repo):9100:1"])
        #expect(event["name"] == "checks.failed")
        #expect(Time.parse(event["timestamp"]?.string ?? "") != nil)
        #expect(event["data"] == [
            "pr": ["number": 402, "title": "Queue helpers past the limit", "branch": "agents/queue-helpers",
                   "url": .string("https://github.com/\(repo)/pull/402")],
            "headSha": "sha9100",
            "run": ["id": 9100, "attempt": 1, "name": "CI", "url": .string("https://github.com/\(repo)/actions/runs/9100")],
            "failedJobs": [["name": "test", "url": .string("https://github.com/\(repo)/actions/runs/9100/job/1")]],
        ])

        let quiet = try await h.poll("checks.failed", args, raised["cursor"] ?? .null)
        #expect(quiet["events"] == [])

        try h.editRepo { r in
            var runs = r["runs"]?.array ?? []
            if let i = runs.firstIndex(where: { $0["id"] == 9100 }) {
                runs[i]["attempt"] = 2
                runs[i]["updatedAt"] = .string(now(1000))
            }
            r["runs"] = .array(runs)
        }
        let again = try await h.poll("checks.failed", args, quiet["cursor"] ?? .null)
        #expect(ids(again) == ["checks.failed:\(repo):9100:2"])
    }

    @Test func prMerged() async throws {
        let args: JSON = ["repo": .string(repo)]
        let first = try await h.poll("pr.merged", args, .null)
        try h.editRepo { r in
            var prs = r["prs"]?.array ?? []
            if let i = prs.firstIndex(where: { $0["number"] == 401 }) {
                prs[i] = prs[i].merging(["state": "merged", "mergedAt": .string(now(5)), "mergeSha": "abc401", "updatedAt": .string(now(5))])
            }
            r["prs"] = .array(prs)
        }
        let raised = try await h.poll("pr.merged", args, first["cursor"] ?? .null)
        #expect(ids(raised) == ["pr.merged:\(repo):401"])
        let event = try #require(raised["events"]?.array?.first)
        #expect(event["data"]?["pr"] == ["number": 401, "title": "Make the sidebar fold faster",
                                         "branch": "agents/fold-faster", "url": .string("https://github.com/\(repo)/pull/401")])
        #expect(event["data"]?["mergeSha"] == "abc401")
        #expect(Time.parse(event["data"]?["mergedAt"]?.string ?? "") != nil)
        let quiet = try await h.poll("pr.merged", args, raised["cursor"] ?? .null)
        #expect(quiet["events"] == [])
    }

    @Test func prClosedIsClosedWithoutMergingNotMerged() async throws {
        let args: JSON = ["repo": .string(repo), "pr": 408]
        let first = try await h.poll("pr.closed", args, .null)
        let firstMerged = try await h.poll("pr.merged", args, .null)
        let closedAt = now(5)
        try h.editRepo { append(&$0, "prs", openPR(408, "agents/pr-408", ["state": "closed", "closedAt": .string(closedAt), "updatedAt": .string(closedAt)])) }
        let raised = try await h.poll("pr.closed", args, first["cursor"] ?? .null)
        #expect(ids(raised) == ["pr.closed:\(repo):408:\(closedAt)"])
        let event = try #require(raised["events"]?.array?.first)
        #expect(event["data"]?["pr"]?["branch"] == "agents/pr-408")
        #expect(event["data"]?["closedAt"] == .string(closedAt))
        let notMerged = try await h.poll("pr.merged", args, firstMerged["cursor"] ?? .null)
        #expect(notMerged["events"] == [])
        let quiet = try await h.poll("pr.closed", args, raised["cursor"] ?? .null)
        #expect(quiet["events"] == [])
    }

    @Test func repoLeftOutIsTheProjects() async throws {
        let first = try await h.poll("pr.merged", [:], .null)
        try h.editRepo { append(&$0, "prs", openPR(407, "agents/pr-407", ["state": "merged", "mergedAt": .string(now(5)), "mergeSha": "abc", "updatedAt": .string(now(5))])) }
        let raised = try await h.poll("pr.merged", ["pr": 407], first["cursor"] ?? .null)
        #expect(ids(raised) == ["pr.merged:\(repo):407"])
        let list = try await h.call("list_prs", [:])
        #expect((list["structuredContent"]?["prs"]?.array?.count ?? 0) > 0)
        try h.edit { $0["repos"]?["someone/else"] = ["prs": [], "runs": [], "issues": []] }
        let none = await h.rpc("events/poll", ["name": "checks.failed", "arguments": [:], "cursor": .null])
        #expect(none["error"]?["code"] == -32602)
        #expect(none["error"]?["message"]?.string?.contains("repo is needed") == true)
    }

    @Test func branchNarrows() async throws {
        let args: JSON = ["repo": .string(repo), "branch": "agents/narrow-me"]
        let first = try await h.poll("checks.failed", args, .null)
        try h.editRepo { append(&$0, "runs", failedRun(9200, "agents/narrow-me", now(5)), failedRun(9201, "agents/someone-else", now(5))) }
        let raised = try await h.poll("checks.failed", args, first["cursor"] ?? .null)
        #expect(ids(raised) == ["checks.failed:\(repo):9200:1"])
    }

    @Test func prNarrowsChecksFailedAndWithBranchBothMustHold() async throws {
        try h.editRepo { append(&$0, "prs", openPR(403, "agents/pr-403"), openPR(404, "agents/pr-404")) }
        let args: JSON = ["repo": .string(repo), "pr": 403]
        let both: JSON = ["repo": .string(repo), "pr": 403, "branch": "agents/pr-403"]
        let crossed: JSON = ["repo": .string(repo), "pr": 404, "branch": "agents/pr-403"]
        let first = try await h.poll("checks.failed", args, .null)
        let firstBoth = try await h.poll("checks.failed", both, .null)
        let firstCrossed = try await h.poll("checks.failed", crossed, .null)
        try h.editRepo {
            append(&$0, "runs", failedRun(9400, "agents/pr-403", now(5), pr: 403), failedRun(9401, "agents/pr-404", now(5), pr: 404))
        }
        let raised = try await h.poll("checks.failed", args, first["cursor"] ?? .null)
        #expect(ids(raised) == ["checks.failed:\(repo):9400:1"])
        #expect(raised["events"]?.array?.first?["data"]?["pr"]?["number"] == 403)
        let quiet = try await h.poll("checks.failed", args, raised["cursor"] ?? .null)
        #expect(quiet["events"] == [])
        let narrowed = try await h.poll("checks.failed", both, firstBoth["cursor"] ?? .null)
        #expect(ids(narrowed) == ["checks.failed:\(repo):9400:1"])
        let none = try await h.poll("checks.failed", crossed, firstCrossed["cursor"] ?? .null)
        #expect(none["events"] == [])
    }

    @Test func prAndBranchNarrowPrMerged() async throws {
        let byPR: JSON = ["repo": .string(repo), "pr": 405]
        let byBranch: JSON = ["repo": .string(repo), "branch": "agents/pr-406"]
        let crossed: JSON = ["repo": .string(repo), "pr": 405, "branch": "agents/pr-406"]
        let first = try await h.poll("pr.merged", byPR, .null)
        let firstBranch = try await h.poll("pr.merged", byBranch, .null)
        let firstCrossed = try await h.poll("pr.merged", crossed, .null)
        let merged: [String: JSON] = ["state": "merged", "mergedAt": .string(now(5)), "mergeSha": "abc", "updatedAt": .string(now(5))]
        try h.editRepo { append(&$0, "prs", openPR(405, "agents/pr-405", merged), openPR(406, "agents/pr-406", merged)) }
        #expect(ids(try await h.poll("pr.merged", byPR, first["cursor"] ?? .null)) == ["pr.merged:\(repo):405"])
        #expect(ids(try await h.poll("pr.merged", byBranch, firstBranch["cursor"] ?? .null)) == ["pr.merged:\(repo):406"])
        #expect(try await h.poll("pr.merged", crossed, firstCrossed["cursor"] ?? .null)["events"] == [])
    }

    @Test func issueOpenedNarrowedByLabel() async throws {
        let all: JSON = ["repo": .string(repo)], bugs: JSON = ["repo": .string(repo), "label": "bug"]
        let first = try await h.poll("issue.opened", all, .null)
        let firstBug = try await h.poll("issue.opened", bugs, .null)
        try h.editRepo { append(&$0, "issues", newIssue(420, ["bug"], now(5)), newIssue(421, [], now(5))) }
        let raised = try await h.poll("issue.opened", all, first["cursor"] ?? .null)
        #expect(ids(raised) == ["issue.opened:\(repo):420", "issue.opened:\(repo):421"])
        let data = raised["events"]?.array?.first?["data"]
        #expect(data?["issue"] == ["number": 420, "title": "Issue 420", "author": "someone", "labels": ["bug"],
                                   "url": .string("https://github.com/\(repo)/issues/420")])
        #expect(Time.parse(data?["openedAt"]?.string ?? "") != nil)
        let bugged = try await h.poll("issue.opened", bugs, firstBug["cursor"] ?? .null)
        #expect((bugged["events"]?.array ?? []).compactMap { $0["data"]?["issue"]?["number"]?.int } == [420])
        #expect(try await h.poll("issue.opened", all, raised["cursor"] ?? .null)["events"] == [])
    }

    @Test func issueLabelledMatchesTheLabelAddedIssueClosedGivesItsReason() async throws {
        let labelArgs: JSON = ["repo": .string(repo), "label": "expedite"]
        let closedArgs: JSON = ["repo": .string(repo), "issue": 411]
        let otherArgs: JSON = ["repo": .string(repo), "issue": 410]
        let labelled = try await h.poll("issue.labelled", labelArgs, .null)
        let closed = try await h.poll("issue.closed", closedArgs, .null)
        let other = try await h.poll("issue.closed", otherArgs, .null)
        try h.editRepo { r in
            editIssue(&r, 411) { i in
                append(&i, "labels", "expedite")
                append(&i, "events",
                       ["id": 8100, "event": "labeled", "label": "expedite", "actor": "alexec", "createdAt": .string(now(5))],
                       ["id": 8101, "event": "labeled", "label": "enhancement", "actor": "alexec", "createdAt": .string(now(5))],
                       ["id": 8102, "event": "closed", "reason": "not_planned", "actor": "alexec", "createdAt": .string(now(6))])
                i["state"] = "closed"
            }
        }
        let raisedLabel = try await h.poll("issue.labelled", labelArgs, labelled["cursor"] ?? .null)
        #expect(ids(raisedLabel) == ["issue.labelled:\(repo):8100"])
        #expect(raisedLabel["events"]?.array?.first?["data"]?["label"] == "expedite")
        #expect(raisedLabel["events"]?.array?.first?["data"]?["by"] == "alexec")
        let raisedClosed = try await h.poll("issue.closed", closedArgs, closed["cursor"] ?? .null)
        #expect(ids(raisedClosed) == ["issue.closed:\(repo):8102"])
        #expect(raisedClosed["events"]?.array?.first?["data"]?["reason"] == "not_planned")
        #expect(try await h.poll("issue.closed", otherArgs, other["cursor"] ?? .null)["events"] == [])
    }

    @Test func issueCommentedGivesTheCommentItsBodyCutTo4000Characters() async throws {
        let args: JSON = ["repo": .string(repo), "label": "bug"]
        let first = try await h.poll("issue.commented", args, .null)
        try h.editRepo { r in
            editIssue(&r, 410) {
                append(&$0, "comments", ["id": 7100, "author": "someone", "url": .string("https://github.com/\(repo)/issues/410#issuecomment-7100"),
                                         "body": .string(String(repeating: "x", count: 5000)), "createdAt": .string(now(5))])
            }
            editIssue(&r, 411) {
                append(&$0, "comments", ["id": 7101, "author": "someone", "url": "u", "body": "not a bug", "createdAt": .string(now(5))])
            }
        }
        let raised = try await h.poll("issue.commented", args, first["cursor"] ?? .null)
        #expect(ids(raised) == ["issue.commented:\(repo):7100"])
        let data = try #require(raised["events"]?.array?.first?["data"])
        #expect(data["issue"]?["number"] == 410)
        #expect(data["comment"]?["author"] == "someone")
        let body = data["comment"]?["body"]?.string ?? ""
        #expect(body.count == 4001)
        #expect(body.hasSuffix("…"))
    }

    @Test func tiesAtOneUpdatedAtArentLost() async throws {
        let args: JSON = ["repo": .string(repo), "branch": "agents/ties"]
        let first = try await h.poll("checks.failed", args, .null)
        let at = now(5)
        try h.editRepo { append(&$0, "runs", failedRun(9301, "agents/ties", at), failedRun(9302, "agents/ties", at), failedRun(9303, "agents/ties", at)) }
        let one = try await h.poll("checks.failed", args, first["cursor"] ?? .null, maxEvents: 1)
        #expect(ids(one).count == 1)
        #expect(one["hasMore"] == true)
        let two = try await h.poll("checks.failed", args, one["cursor"] ?? .null, maxEvents: 1)
        #expect(ids(two).count == 1)
        let rest = try await h.poll("checks.failed", args, two["cursor"] ?? .null, maxEvents: 5)
        #expect(ids(rest).count == 1)
        #expect(rest["hasMore"] == false)
        #expect((ids(one) + ids(two) + ids(rest)).sorted() == [9301, 9302, 9303].map { "checks.failed:\(repo):\($0):1" })
        #expect(try await h.poll("checks.failed", args, rest["cursor"] ?? .null)["events"] == [])
    }

    @Test func aCursorOlderThan90DaysIsTruncated() async throws {
        let old = cursorAt(Time.string(Date().addingTimeInterval(-91 * 86400)))
        #expect(try await h.poll("pr.merged", ["repo": .string(repo)], old)["truncated"] == true)
    }

    @Test func badArgumentsAreInvalidParamsAnUnknownEventIsItsOwnCode() async throws {
        let extra = await h.rpc("events/poll", ["name": "pr.merged", "arguments": ["repo": .string(repo), "sha": "x"], "cursor": .null])
        #expect(extra["error"]?["code"] == -32602)
        for name in ["checks.failed", "pr.merged"] {
            for pr: JSON in ["551", 0, -1, 1.5] {
                let wrong = await h.rpc("events/poll", ["name": .string(name), "arguments": ["repo": .string(repo), "pr": pr], "cursor": .null])
                #expect(wrong["error"]?["code"] == -32602)
                #expect(wrong["error"]?["message"] == "pr must be a positive integer")
            }
        }
        let shape = await h.rpc("events/poll", ["name": "checks.failed", "arguments": ["repo": "not a repo"], "cursor": .null])
        #expect(shape["error"]?["code"] == -32602)
        let cursor = await h.rpc("events/poll", ["name": "checks.failed", "arguments": ["repo": .string(repo)], "cursor": "%%%"])
        #expect(cursor["error"]?["code"] == -32602)
        let unknown = await h.rpc("events/poll", ["name": "checks.passed", "arguments": ["repo": .string(repo)], "cursor": .null])
        #expect(unknown["error"]?["code"] == -32011)
        let method = await h.rpc("events/nope")
        #expect(method["error"]?["code"] == -32601)
    }

    @Test func toolsListAnnotationsAndVisibility() async throws {
        let tools = try #require(try await h.ok("tools/list")["tools"]?.array)
        let byName = Dictionary(tools.map { ($0["name"]?.string ?? "", $0) }) { a, _ in a }
        #expect(byName.keys.sorted() == ["comment_on_pr", "failed_log", "list_issues", "list_prs", "rerun_failed"])
        for (name, readOnly, visibility) in [("list_issues", true, ["model", "app"]), ("list_prs", true, ["model", "app"]),
                                             ("failed_log", true, ["model"]), ("rerun_failed", false, ["model", "app"]),
                                             ("comment_on_pr", false, ["model"])] {
            #expect(byName[name]?["annotations"]?["readOnlyHint"] == (readOnly ? true : nil), "\(name)")
            #expect(byName[name]?["_meta"]?["ui"]?["visibility"] == JSON(visibility), "\(name)")
        }
        for t in tools {
            #expect(t["inputSchema"]?["type"] == "object")
            #expect(t["inputSchema"]?["required"]?.array?.contains("repo") == false)
            #expect(t["inputSchema"]?["properties"]?["repo"]?["type"] == "string")
        }
    }

    @Test func listPrsMarksAPRThatConflictsWithItsBase() async throws {
        try h.editRepo { append(&$0, "prs", openPR(712, "agents/stale", ["checks": "none", "conflicts": true])) }
        let prs = try await h.call("list_prs", ["repo": .string(repo)])["structuredContent"]?["prs"]?.array ?? []
        #expect(prs.first { $0["number"] == 712 }?["conflicts"] == true)
        #expect(prs.first { $0["number"] == 402 }?["conflicts"] == nil, "one not worked out yet says nothing")
    }

    @Test func prConflictedRaisesAPROncePerConflictNewOnesOnly() async throws {
        func conflicts(_ number: Int, _ value: Bool?) throws {
            try h.editRepo { r in
                var prs = r["prs"]?.array ?? []
                if let i = prs.firstIndex(where: { $0["number"]?.int == number }) { prs[i]["conflicts"] = value.map(JSON.bool) }
                r["prs"] = .array(prs)
            }
        }
        let all: JSON = ["repo": .string(repo)]
        try h.editRepo { append(&$0, "prs", openPR(720, "agents/old-conflict", ["conflicts": true]), openPR(721, "agents/fresh", ["conflicts": false])) }
        let first = try await h.poll("pr.conflicted", all, .null)
        #expect(first["events"] == [], "one already in conflict is known, not raised")

        try conflicts(721, true)
        let raised = try await h.poll("pr.conflicted", all, first["cursor"] ?? .null)
        let events = raised["events"]?.array ?? []
        #expect(events.compactMap { $0["data"]?["pr"]?["number"]?.int } == [721])
        #expect(events.first?["data"]?["pr"]?["branch"] == "agents/fresh")
        #expect(events.first?["eventId"]?.string?.hasPrefix("pr.conflicted:\(repo):721:") == true)

        try conflicts(721, nil)
        let unknown = try await h.poll("pr.conflicted", all, raised["cursor"] ?? .null)
        try conflicts(721, true)
        let still = try await h.poll("pr.conflicted", all, unknown["cursor"] ?? .null)
        #expect(ids(unknown) + ids(still) == [], "not worked out yet keeps its state")

        try conflicts(721, false)
        let clean = try await h.poll("pr.conflicted", all, still["cursor"] ?? .null)
        try conflicts(721, true)
        let again = try await h.poll("pr.conflicted", all, clean["cursor"] ?? .null)
        #expect((again["events"]?.array ?? []).compactMap { $0["data"]?["pr"]?["number"]?.int } == [721],
                "rebased and conflicting anew is raised again")

        let only721: JSON = ["repo": .string(repo), "pr": 721]
        try conflicts(720, false)
        let narrowed = try await h.poll("pr.conflicted", only721, .null)
        try conflicts(720, true)
        #expect(try await h.poll("pr.conflicted", only721, narrowed["cursor"] ?? .null)["events"] == [], "pr narrows")
    }

    @Test func eachToolsResultShape() async throws {
        let list = try await h.call("list_prs", ["repo": .string(repo)])
        #expect(list["isError"] == nil)
        let prs = list["structuredContent"]?["prs"]?.array ?? []
        #expect(prs.first { $0["number"] == 402 } == [
            "number": 402, "title": "Queue helpers past the limit", "branch": "agents/queue-helpers",
            "url": .string("https://github.com/\(repo)/pull/402"), "checks": "failing", "failedRunId": 9001,
        ])
        for p in prs { #expect(["passing", "failing", "running", "none"].contains(p["checks"]?.string ?? "")) }
        #expect(!prs.contains { $0["number"] == 400 }, "a merged PR is not open")
        let text = list["content"]?.array?.first?["text"]?.string ?? ""
        #expect(try JSON.parse(text) == list["structuredContent"])

        let log = try await h.call("failed_log", ["repo": .string(repo), "runId": 9001])
        let logText = log["content"]?.array?.first?["text"]?.string ?? ""
        #expect(logText.contains("HelperLimitTests"))
        #expect(logText.contains("cannot be built"))
        #expect(!logText.contains("All checks passed"))
        let one = try await h.call("failed_log", ["repo": .string(repo), "runId": 9001, "job": "packages"])
        let oneText = one["content"]?.array?.first?["text"]?.string ?? ""
        #expect(oneText.contains("cannot be built"))
        #expect(!oneText.contains("HelperLimitTests"))

        let rerun = try await h.call("rerun_failed", ["repo": .string(repo), "runId": 9001])
        #expect(rerun["structuredContent"] == ["rerun": true, "url": .string("https://github.com/\(repo)/actions/runs/9001")])
        #expect(try h.read()["reruns"]?.array?.last?["runId"] == 9001)
        let after = try await h.call("list_prs", ["repo": .string(repo)])
        #expect((after["structuredContent"]?["prs"]?.array ?? []).first { $0["number"] == 402 }?["checks"] == "running")

        let comment = try await h.call("comment_on_pr", ["repo": .string(repo), "number": 402, "body": "Fixed the test."])
        #expect(comment["structuredContent"]?["url"]?.string?.contains("pull/402#issuecomment-") == true)
        #expect(try h.read()["comments"]?.array?.last?["body"] == "Fixed the test.")

        let issues = try await h.call("list_issues", ["repo": .string(repo)])
        #expect(issues["isError"] == nil)
        let open = issues["structuredContent"]?["issues"]?.array ?? []
        #expect(!open.contains { $0["number"] == 409 }, "a closed issue is not open")
        let flicker = try #require(open.first { $0["number"] == 410 })
        #expect(flicker == ["number": 410, "title": "The sidebar flickers on wake", "author": "alexec", "labels": ["bug"],
                            "url": .string("https://github.com/\(repo)/issues/410"), "comments": 1, "updatedAt": "2026-10-01T11:00:00Z"])
        let bugs = try await h.call("list_issues", ["repo": .string(repo), "label": "bug"])
        #expect((bugs["structuredContent"]?["issues"]?.array ?? []).allSatisfy { $0["labels"]?.array?.contains("bug") == true })

        let bad = try await h.call("failed_log", ["repo": .string(repo)])
        #expect(bad["isError"] == true)
        let unknown = await h.rpc("tools/call", ["name": "nope", "arguments": [:]])
        #expect(unknown["error"]?["code"] == -32602)
    }

    @Test func ghNotSignedInAndARateLimit() async throws {
        try h.edit { $0["gh"] = "notSignedIn" }
        let poll = await h.rpc("events/poll", ["name": "checks.failed", "arguments": ["repo": .string(repo)], "cursor": cursorAt(now())])
        #expect(poll["error"]?["code"] == -32012)
        #expect(poll["error"]?["data"]?["reason"] == "gh not signed in")
        let tool = try await h.call("list_prs", ["repo": .string(repo)])
        #expect(tool["isError"] == true)
        #expect(tool["content"]?.array?.first?["text"]?.string?.contains("gh not signed in") == true)

        try h.edit { $0["gh"] = ["rateLimitedForMs": 60000] }
        let limited = await h.rpc("events/poll", ["name": "pr.merged", "arguments": ["repo": .string(repo)], "cursor": cursorAt(now())])
        #expect(limited["error"]?["code"] == -32013)
        let ms = limited["error"]?["data"]?["retryAfterMs"]?.int ?? 0
        #expect(ms > 50000 && ms <= 60000)
    }

    @Test(arguments: [("list_prs", "ui://ci/board", ["rerun_failed", "list_prs"]), ("list_issues", "ui://ci/issues", ["list_issues"])])
    func toolFeedsItsViewWhichResourcesReadServes(tool: String, uri: String, words: [String]) async throws {
        let tools = try await h.ok("tools/list")["tools"]?.array ?? []
        let fed = try #require(tools.first { $0["name"] == .string(tool) })
        #expect(fed["_meta"]?["ui"]?["resourceUri"] == .string(uri))
        #expect(fed["_meta"]?["ui/resourceUri"] == .string(uri))
        for t in tools where !["list_prs", "list_issues"].contains(t["name"]?.string ?? "") {
            #expect(t["_meta"]?["ui"]?["resourceUri"] == nil)
        }

        let resources = try await h.ok("resources/list")["resources"]?.array ?? []
        #expect(resources.compactMap { $0["uri"]?.string } == ["ui://ci/board", "ui://ci/issues"])
        let listed = try #require(resources.first { $0["uri"] == .string(uri) })
        #expect(listed["mimeType"] == "text/html;profile=mcp-app")
        #expect(listed["text"] == nil)

        let contents = try await h.ok("resources/read", ["uri": .string(uri)])["contents"]?.array ?? []
        #expect(contents.count == 1)
        let page = try #require(contents.first)
        #expect(page["uri"] == .string(uri))
        #expect(page["mimeType"] == "text/html;profile=mcp-app")
        #expect(page["_meta"]?["ui"]?["csp"] == [:])
        let text = page["text"]?.string ?? ""
        #expect(text.hasPrefix("<!doctype html>") || text.hasPrefix("<!DOCTYPE html>"))
        #expect(text.hasSuffix("</html>\n"))
        for word in ["ui/initialize", "ui/notifications/initialized", "ui/notifications/tool-result", "ui/open-link"] + words {
            #expect(text.contains(word), "\(word)")
        }
        #expect(text.range(of: #"fetch\(|XMLHttpRequest|WebSocket|<script src|<link "#, options: .regularExpression) == nil,
                "the view has no network")

        let missing = await h.rpc("resources/read", ["uri": "ui://ci/nope"])
        #expect(missing["error"]?["code"] == -32002)
    }
}
