import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// The Pull requests section, from the daemon's side (038 US1).
///
/// Real git in a real repository cloned from a local bare one, whose `origin` says
/// github.com and is rewritten to the bare one with `insteadOf`, so fetches work with
/// no network. `gh` is `FakeGitHub`, answering from the recorded fixtures.
@Suite("My pull requests, listed", .timeLimit(.minutes(1)))
struct PullRequestListTests {
    private typealias Setup = PullRequestSandbox

    @discardableResult
    private func git(_ arguments: [String], in folder: URL) async throws -> String {
        try await PullRequestSandbox.git(arguments, in: folder)
    }

    private func setUp(origin: String = "https://github.com/alexec/agents.git") async throws -> Setup {
        try await PullRequestSandbox.make(origin: origin)
    }

    @Test func eachPullRequestIsMatchedToWhereItsBranchIs() async throws {
        let setup = try await setUp()
        let list = try #require(await setup.core.refreshPullRequestsNow(in: setup.project))

        #expect(list.problem == nil)
        #expect(list.viewer == "alexec")
        #expect(list.repository == GitHubRepository(host: "github.com", owner: "alexec", name: "agents"))
        #expect(list.pullRequests.map(\.number) == [412, 405, 398, 390, 377])

        let byNumber = Dictionary(uniqueKeysWithValues: list.pullRequests.map { ($0.number, $0) })
        #expect(byNumber[405]?.worktree?.isProjectFolder == true)
        #expect(byNumber[405]?.worktree?.root == setup.project)
        #expect(byNumber[412]?.worktree?.name == "fix-login-redirect")
        #expect(byNumber[412]?.worktree?.isProjectFolder == false)
        #expect(byNumber[390]?.worktree == nil)

        // One GraphQL request, for this host, with the viewer's own search.
        let calls = setup.gh.calledWith()
        #expect(calls.count == 1)
        #expect(calls.first?.hasPrefix("api graphql --hostname github.com") == true)
        #expect(calls.first?.contains("search=repo:alexec/agents is:pr is:open author:@me") == true)
    }

    @Test func theListIsRememberedAcrossARestart() async throws {
        let setup = try await setUp()
        _ = await setup.core.refreshPullRequestsNow(in: setup.project)

        let again = DaemonCore(store: try AgentStore(locations: await setup.core.locations),
                               locations: await setup.core.locations,
                               discovery: .findsEverything, launcher: FakeLauncher())
        let list = await again.pullRequestList(for: setup.project)
        #expect(list?.pullRequests.count == 5)
        #expect(setup.gh.calledWith().count == 1)
    }

    @Test func aPullRequestIsCheckedOutOnItsOwnBranch() async throws {
        let setup = try await setUp()
        _ = await setup.core.refreshPullRequestsNow(in: setup.project)

        let list = try await setup.core.checkOutPullRequest(390, in: setup.project)
        let docs = try #require(list.pullRequests.first { $0.number == 390 })
        let worktree = try #require(docs.worktree)
        #expect(worktree.name == "docs-for-leases")
        #expect(worktree.root.path.hasSuffix(".agents/worktrees/docs-for-leases"))
        #expect(try await git(["rev-parse", "--abbrev-ref", "HEAD"], in: worktree.root) == "docs-for-leases")
        // Its branch tracks the pull request's, so the agent can pull what GitHub has.
        #expect(try await git(["rev-parse", "--abbrev-ref", "@{upstream}"], in: worktree.root) == "origin/docs-for-leases")
    }

    @Test func aSameNamedLocalBranchDoesNotClaimAFork() async throws {
        let setup = try await setUp()
        try await git(["branch", "fix-typo"], in: setup.project)
        try await git(["worktree", "add", "-q", setup.project.deletingLastPathComponent().appending(path: "typo").path,
                       "fix-typo"], in: setup.project)
        try setup.gh.answer(with: "pulls-fork")

        let list = try #require(await setup.core.refreshPullRequestsNow(in: setup.project))
        #expect(list.pullRequests.first?.isFromFork == true)
        #expect(list.pullRequests.first?.worktree == nil)
    }

    @Test func aProjectThatIsNotOnGitHubHasNoSection() async throws {
        let setup = try await setUp(origin: "https://gitlab.com/alexec/agents.git")
        #expect(await setup.core.refreshPullRequestsNow(in: setup.project) == nil)
        #expect(await setup.core.pullRequestList(for: setup.project) == nil)
        #expect(setup.gh.calledWith().isEmpty)
    }

    @Test func notSignedInSaysSoInsteadOfRows() async throws {
        let setup = try await setUp()
        try setup.gh.set(.signedOut)
        let list = try #require(await setup.core.refreshPullRequestsNow(in: setup.project))
        #expect(list.problem == .notSignedIn(host: "github.com"))
        #expect(list.pullRequests.isEmpty)
        #expect(!list.showsRows)
        #expect(list.problem?.fix == "gh auth login --hostname github.com")
    }

    @Test func aRepositoryTheSignInCannotSeeIsNamed() async throws {
        let setup = try await setUp()
        try setup.gh.answer(with: "error-not-found")
        // The real `gh` exits 1 on a GraphQL error, with the body on stdout.
        try setup.gh.set(.answers)
        let script = try String(contentsOf: setup.gh.script, encoding: .utf8)
            .replacingOccurrences(of: "cat \"$dir/response.json\"; else", with: "cat \"$dir/response.json\"; exit 1; else")
        try script.write(to: setup.gh.script, atomically: true, encoding: .utf8)

        let list = try #require(await setup.core.refreshPullRequestsNow(in: setup.project))
        #expect(list.problem == .cannotSee(host: "github.com", repository: "alexec/agents", login: "alexec"))
        #expect(list.problem?.message == "Can't see pull requests on alexec/agents with the account alexec.")
    }

    @Test func unreachableKeepsTheLastGoodRows() async throws {
        let setup = try await setUp()
        let good = try #require(await setup.core.refreshPullRequestsNow(in: setup.project))
        try setup.gh.set(.offline)

        let later = try #require(await setup.core.refreshPullRequestsNow(in: setup.project))
        #expect(later.problem?.isUnreachable == true)
        #expect(later.showsRows)
        #expect(later.pullRequests.map(\.number) == good.pullRequests.map(\.number))
        #expect(later.fetchedAt == good.fetchedAt)
    }

    @Test func anAskedForRefreshHasAFloorOfAMinute() async throws {
        let setup = try await setUp()
        _ = await setup.core.refreshPullRequests(in: setup.project)
        _ = await setup.core.refreshPullRequests(in: setup.project)
        #expect(setup.gh.calledWith().count == 1)
    }

    @Test func aGitHubProjectNotYetFetchedStillHasASection() async throws {
        let setup = try await setUp()
        let list = try #require(await setup.core.pullRequestList(for: setup.project))
        #expect(list.pullRequests.isEmpty)
        #expect(list.fetchedAt == nil)
        #expect(setup.gh.calledWith().isEmpty)
    }
}
