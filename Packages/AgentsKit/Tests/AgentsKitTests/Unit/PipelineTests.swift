import Foundation
import Testing
@testable import AgentsKitCore

/// The outer loop's line on a Work page (#3588), as `Web/test/pipeline.test.mjs` has it on the web
/// page: from an issue to its deploy and health, and back.
@Suite("Pipeline")
struct PipelineTests {
    typealias Node = DaemonAPI.LineageNode
    let at = Date(timeIntervalSince1970: 1_793_000_000)

    let issue = Node(kind: "issue", ref: "github:alexec/Agents#10")
    let pr = Node(kind: "pr", ref: "github:alexec/Agents#12")
    let release = Node(kind: "release", ref: "github:alexec/Agents/release/v1.2.0")
    let run = Node(kind: "ci-run", ref: "github:alexec/Agents/actions/run/987")
    let build = Node(kind: "deploy", ref: "testflight:com.example.app/42")
    let crash = Node(kind: "health", ref: "sentry:acme/4321")
    let bug = Node(kind: "issue", ref: "github:alexec/Agents#20")

    func link(_ from: Node, _ rel: String, _ to: Node) -> DaemonAPI.LineageLink {
        .init(from: from, to: to, rel: rel, source: "forge", at: at)
    }

    var graph: DaemonAPI.LineageGraph {
        .init(nodes: [issue, pr, release, run, build, crash, bug], links: [
            link(pr, "fixes", issue), link(pr, "part-of", release), link(run, "builds", release),
            link(release, "deployed-as", build), link(crash, "seen-in", release), link(crash, "seen-in", build),
            link(bug, "reports", crash),
        ])
    }

    func words(_ steps: [Pipeline.Step]) -> [String] { steps.map(\.words) }

    @Test func anIssueReachesItsReleaseCIRunBuildAndTheSentryIssueSeenInIt() {
        let steps = Pipeline.steps(of: issue, in: graph)
        #expect(words(steps) == ["Release v1.2.0", "CI run", "TestFlight 42", "Sentry issue 4321"])
        #expect(steps.map(\.url?.absoluteString) == [
            "https://github.com/alexec/Agents/releases/tag/v1.2.0",
            "https://github.com/alexec/Agents/actions/runs/987",
            "https://appstoreconnect.apple.com/apps",
            "https://sentry.io/organizations/acme/issues/4321/",
        ])
    }

    @Test func aPRReachesTheSameStages() {
        #expect(words(Pipeline.steps(of: pr, in: graph)) == ["Release v1.2.0", "CI run", "TestFlight 42", "Sentry issue 4321"])
    }

    @Test func aBugFromSentryLeadsBackToTheReleaseItsPRsAndTheIssuesTheyFix() {
        #expect(words(Pipeline.steps(of: bug, in: graph)) == ["From Sentry issue 4321", "seen in v1.2.0", "TestFlight 42", "PR #12", "#10"])
    }

    @Test func aReleaseSaysWhatItCameFromAndWhereItWent() {
        #expect(words(Pipeline.steps(of: release, in: graph)) == ["PR #12", "#10", "CI run", "TestFlight 42", "Sentry issue 4321"])
    }

    @Test func nothingInReachIsNoLine() {
        #expect(Pipeline.steps(of: issue, in: .init(nodes: [issue])).isEmpty)
    }

    @Test func manyOfAKindNameTheFirstThreeAndCountTheRest() {
        let crashes = (1...5).map { Node(kind: "health", ref: "sentry:acme/\($0)") }
        let g = DaemonAPI.LineageGraph(links: [link(pr, "part-of", release)] + crashes.map { link($0, "seen-in", release) })
        let steps = Pipeline.steps(of: pr, in: g)
        #expect(words(steps) == ["Release v1.2.0", "Sentry issue 1", "Sentry issue 2", "Sentry issue 3", "2 more"])
        #expect(steps.last?.url == nil)
    }

    @Test func aGitLabPipelineHasItsPage() {
        #expect(Pipeline.url(Node(kind: "ci-run", ref: "gitlab:group/app/pipelines/55"))?.absoluteString
            == "https://gitlab.com/group/app/-/pipelines/55")
    }

    @Test func aCloudRunRevisionIsNamedAndHasItsServicesRevisions() {
        let rev = Node(kind: "deploy", ref: "cloudrun:acme-prod/us-central1/web/web-42")
        let g = DaemonAPI.LineageGraph(links: [link(pr, "part-of", release), link(release, "deployed-as", rev)])
        let steps = Pipeline.steps(of: pr, in: g)
        #expect(words(steps) == ["Release v1.2.0", "Cloud Run web-42"])
        #expect(steps.last?.url?.absoluteString
            == "https://console.cloud.google.com/run/detail/us-central1/web/revisions?project=acme-prod")
        #expect(Pipeline.url(Node(kind: "deploy", ref: "cloudrun:acme-prod/web/web-42")) == nil)
    }
}
