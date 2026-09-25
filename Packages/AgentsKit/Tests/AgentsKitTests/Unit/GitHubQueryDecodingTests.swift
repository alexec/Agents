import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// What one GitHub response says about the viewer's pull requests (038 R2, FR-011a).
@Suite("Reading GitHub's answer")
struct GitHubQueryDecodingTests {
    static func fixture(_ name: String) throws -> Data {
        let url = URL(filePath: #filePath)
            .deletingLastPathComponent()      // Unit
            .deletingLastPathComponent()      // AgentsKitTests
            .appending(path: "Fixtures/GitHub/\(name).json")
        return try Data(contentsOf: url)
    }

    private func mixed() throws -> GitHubQuery.Result {
        try GitHubQuery.decode(Self.fixture("pulls-mixed"))
    }

    private func pull(_ number: Int) throws -> PullRequest {
        try #require(try mixed().pullRequests.first { $0.number == number })
    }

    @Test func newestFirst() throws {
        let result = try mixed()
        #expect(result.viewer == "alexec")
        #expect(result.pullRequests.map(\.number) == [412, 405, 398, 390, 377])
    }

    @Test func eachPullRequestsState() throws {
        let fix = try pull(412)
        #expect(fix.checks == .failing([FailedCheck(id: "9001", name: "build",
            logURL: URL(string: "https://github.com/alexec/agents/actions/runs/1/job/9001"))]))
        #expect(fix.review == .changesRequested)
        #expect(fix.conflicts == .clean)
        #expect(fix.headBranch == "fix-login-redirect")

        let paper = try pull(405)
        #expect(paper.checks == .passing)
        #expect(paper.review == .approved)

        // A failing status context counts as much as a failing check run.
        guard case .failing(let failed) = try pull(398).checks else {
            Issue.record("expected #398 to be failing")
            return
        }
        #expect(failed.map(\.name) == ["ci/legacy"])

        let docs = try pull(390)
        #expect(docs.isDraft)
        #expect(docs.checks == .running)
        #expect(docs.conflicts == .conflicting)

        guard case .failing = try pull(377).checks else {
            Issue.record("a timed-out check is a failed one")
            return
        }
    }

    /// FR-011a: only people with write access, never the viewer, never a bot, and a
    /// review only when it asks for changes or has something to say.
    @Test func onlyWordsThatMayStartBabysittingAreKept() throws {
        let items = try pull(412).countableComments
        #expect(items.map(\.id) == [2210984, 2210990, 4763207602])
        #expect(items.map(\.author) == ["jdoe", "jdoe", "maintainer"])
        #expect(items[0].kind == .threadComment)
        #expect(items[0].path == "App/Login/LoginRouter.swift")
        #expect(items[0].line == 42)
        #expect(items[1].kind == .review)
        #expect(items[1].requestsChanges)
        #expect(items[2].kind == .conversationComment)
        #expect(!items.contains { $0.body.contains("my feature") })
    }

    @Test func theViewersLastActionIsTheirLatestWord() throws {
        let fix = try pull(412)
        let expected = ISO8601DateFormatter().date(from: "2026-09-24T11:10:00Z")
        #expect(fix.viewerLastActionAt == expected)
    }

    @Test func aForkSaysSoAndWhereItsHeadIs() throws {
        let fork = try #require(try GitHubQuery.decode(Self.fixture("pulls-fork")).pullRequests.first)
        #expect(fork.isFromFork)
        #expect(fork.headRepositoryURL == URL(string: "https://github.com/someone/agents"))
        #expect(fork.checks == PullRequestChecks.none)
    }

    @Test func unknownMergeabilityIsNotAConflict() throws {
        let only = try #require(try GitHubQuery.decode(Self.fixture("pulls-unknown-mergeable")).pullRequests.first)
        #expect(only.conflicts == .unknown)
    }

    @Test func noPullRequestsIsAnEmptyList() throws {
        #expect(try GitHubQuery.decode(Self.fixture("pulls-empty")).pullRequests.isEmpty)
    }

    @Test func aRepositoryTheSignInCannotSeeSaysSo() throws {
        let body = try Self.fixture("error-not-found")
        #expect(GitHubCLI.errorTypes(in: body) == ["NOT_FOUND"])
        #expect(GitHubCLI.viewer(in: body) == "alexec")
    }

    @Test func theSearchIsForTheViewersOpenPullRequestsHere() {
        let repository = GitHubRepository(host: "github.com", owner: "alexec", name: "agents")
        #expect(GitHubQuery.variables(for: repository)["search"] == "repo:alexec/agents is:pr is:open author:@me")
    }
}
