import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// The viewer's pull requests as events, from 038's refresh and nothing else (042 R8).
@Suite("Pull request events", .timeLimit(.minutes(1)))
struct PullRequestEventTests {
    private func fixture(_ name: String) throws -> String {
        let url = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Fixtures/GitHub/\(name).json")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func names(_ sandbox: PullRequestSandbox) async -> [String] {
        await sandbox.core.eventLog.events.map(\.name).filter { $0.hasPrefix("pull_request.") }
    }

    @Test func theFirstListOnlySaysWhereThingsStand() async throws {
        let sandbox = try await PullRequestSandbox.make()
        _ = await sandbox.core.refreshPullRequestsNow(in: sandbox.project)
        #expect(await names(sandbox).isEmpty)
    }

    @Test func newPullRequestsAreOpened() async throws {
        let sandbox = try await PullRequestSandbox.make()
        try sandbox.gh.answer(with: "pulls-empty")
        _ = await sandbox.core.refreshPullRequestsNow(in: sandbox.project)
        try sandbox.gh.answer(with: "pulls-mixed")
        _ = await sandbox.core.refreshPullRequestsNow(in: sandbox.project)
        let raised = await names(sandbox)
        #expect(raised.contains("pull_request.opened"))
        let opened = await sandbox.core.eventLog.events.filter { $0.name == "pull_request.opened" }
        #expect(opened.contains { $0.details["number"] == "412" && $0.sentence == "#412 Fix login redirect was opened." })
        // Each is followed by the catch-all saying which.
        #expect(await sandbox.core.eventLog.events.contains { $0.name == "pull_request.changed" && $0.details["what"] == "opened" })
    }

    @Test func checksThatStartFailingAreRaised() async throws {
        let sandbox = try await PullRequestSandbox.make()
        try sandbox.gh.answer(try fixture("pulls-mixed").replacingOccurrences(of: "\"FAILURE\"", with: "\"SUCCESS\""))
        _ = await sandbox.core.refreshPullRequestsNow(in: sandbox.project)
        try sandbox.gh.answer(with: "pulls-mixed")
        _ = await sandbox.core.refreshPullRequestsNow(in: sandbox.project)
        let failed = await sandbox.core.eventLog.events.filter { $0.name == "pull_request.checks_failed" }
        #expect(failed.contains { $0.details["number"] == "412" })
    }

    @Test func oneThatLeftTheOpenListIsMergedOrClosed() async throws {
        let sandbox = try await PullRequestSandbox.make()
        _ = await sandbox.core.refreshPullRequestsNow(in: sandbox.project)
        try sandbox.gh.answer(with: "pulls-empty")
        try sandbox.gh.reply(#"{"state": "closed", "merged": true, "merged_at": "2026-09-25T06:55:00Z"}"#)
        _ = await sandbox.core.refreshPullRequestsNow(in: sandbox.project)
        let merged = await sandbox.core.eventLog.events.filter { $0.name == "pull_request.merged" }
        #expect(merged.contains { $0.details["number"] == "412" && $0.sentence == "#412 Fix login redirect was merged." })
        #expect(sandbox.gh.calledWith().contains { $0.contains("repos/alexec/agents/pulls/412") })
    }

    @Test func oneThatCannotBeAskedAboutIsAskedAgainNextTime() async throws {
        let sandbox = try await PullRequestSandbox.make()
        _ = await sandbox.core.refreshPullRequestsNow(in: sandbox.project)
        try sandbox.gh.answer(with: "pulls-empty")
        try sandbox.gh.reply("not json")
        _ = await sandbox.core.refreshPullRequestsNow(in: sandbox.project)
        #expect(!(await names(sandbox)).contains("pull_request.merged"))
        try sandbox.gh.reply(#"{"state": "closed", "merged": false}"#)
        _ = await sandbox.core.refreshPullRequestsNow(in: sandbox.project)
        let closed = await sandbox.core.eventLog.events.filter { $0.name == "pull_request.closed" }
        #expect(closed.contains { $0.details["number"] == "412" })
    }
}
