import Foundation
import Testing
@testable import AgentsKitCore

/// A release in the Work look (#4421, `specs/4328-work-look/milestones.md`, Releases), from
/// what lineage knows.
@Suite("Work release look")
struct WorkReleaseLookTests {
    typealias Node = DaemonAPI.LineageNode
    let now = Date(timeIntervalSince1970: 1_793_000_000)

    private func release(_ tag: String, repo: String = "github:alexec/Agents", ago: TimeInterval = 3600) -> WorkList.Row {
        WorkList.Row(.init(node: Node(kind: "release", ref: "\(repo)/release/\(tag)"), lastAt: now.addingTimeInterval(-ago)))
    }

    @Test func versionsOrderByNumberNotByWords() {
        #expect(WorkReleaseLook.version("v0.42.0") == [0, 42, 0])
        #expect(WorkReleaseLook.version("nightly") == nil)
        #expect(WorkReleaseLook.newer("v0.10.0", than: "v0.9.0"))
        #expect(!WorkReleaseLook.newer("v0.9.0", than: "v0.10.0"))
        #expect(!WorkReleaseLook.newer("v1.0.0", than: "v1.0.0"))
        #expect(WorkReleaseLook.newer("v0.1.0", than: "nightly"))
    }

    @Test func newestIsTheHighestVersion() {
        let rows = [release("v0.9.0", ago: 10), release("v0.10.0", ago: 9000), release("v0.8.1")]
        #expect(WorkList.sort(rows, by: .newest).map(\.title) == ["v0.10.0", "v0.9.0", "v0.8.1"])
        #expect(WorkList.Kind.release.sorts == [.newest, .cost])
        #expect(WorkList.Kind.release.defaultSort == .newest)
        #expect(WorkList.Kind.issue.defaultSort == .updated)
    }

    @Test func latestAndPreviousAreByRepo() {
        let rows = [release("v0.41.0"), release("v0.42.0"), release("v0.40.2"), release("v2.0.0", repo: "github:a/b")]
        #expect(WorkReleaseLook.latest(rows) == ["github:alexec/Agents/release/v0.42.0", "github:a/b/release/v2.0.0"])
        #expect(WorkReleaseLook.previous(of: "github:alexec/Agents/release/v0.42.0", in: rows)?.title == "v0.41.0")
        #expect(WorkReleaseLook.previous(of: "github:alexec/Agents/release/v0.40.2", in: rows) == nil)
        #expect(WorkReleaseLook.previous(of: "github:a/b/release/v2.0.0", in: rows) == nil)
        #expect(WorkReleaseLook.compareURL("github:alexec/Agents/release/v0.42.0", from: "v0.41.0")?.absoluteString
            == "https://github.com/alexec/Agents/compare/v0.41.0...v0.42.0")
        #expect(WorkReleaseLook.compareURL("gitlab:g/r/release/v1.0.0", from: "v0.9.0") == nil)
        #expect(WorkReleaseLook.rangeWords(from: "v0.41.0", to: "v0.42.0") == "v0.41.0…v0.42.0")
    }

    @Test func theRowSaysWhenItWasReleased() {
        var row = release("v0.42.0", ago: 2 * 3600)
        #expect(WorkLook.rowLine(row, compact: false, now: now) == "released 2 h ago")
        row.lineage?.sessions = 3
        #expect(WorkLook.rowLine(row, compact: false, now: now) == "released 2 h ago · 3 sessions")
        #expect(WorkLook.rowLine(row, compact: true, now: now) == "2 h · 3 sessions")
    }

    @Test func theStateLine() {
        let at = now.addingTimeInterval(-7200)
        #expect(WorkReleaseLook.stateWords(released: at, pulls: 23, compact: false, now: now) == "released 2 h ago · 23 pull requests")
        #expect(WorkReleaseLook.stateWords(released: nil, pulls: 1, compact: false, now: now) == "1 pull request")
        #expect(WorkReleaseLook.stateWords(released: at, pulls: nil, compact: true, now: now) == "2 h")
    }

    @Test func itsPullRequestsAndPipelineFromTheWalk() {
        let rel = Node(kind: "release", ref: "github:alexec/Agents/release/v0.42.0")
        let pr12 = Node(kind: "pr", ref: "github:alexec/Agents#12")
        let pr40 = Node(kind: "pr", ref: "github:alexec/Agents#40")
        let run = Node(kind: "ci-run", ref: "github:alexec/Agents/actions/run/99")
        let flight = Node(kind: "deploy", ref: "testflight:app/42")
        let at = now
        let graph = DaemonAPI.LineageGraph(
            nodes: [rel, pr12, pr40, run, flight],
            links: [
                .init(from: pr12, to: rel, rel: "part-of", source: "release", at: at),
                .init(from: pr40, to: rel, rel: "part-of", source: "release", at: at),
                .init(from: pr40, to: rel, rel: "part-of", source: "release", at: at),
                .init(from: run, to: rel, rel: "builds", source: "ci", at: at),
                .init(from: rel, to: flight, rel: "deployed-as", source: "ci", at: at),
            ],
            resolved: [pr40.ref: .init(title: "Releases on the Mac", state: "merged", labels: ["enhancement"])])
        let pulls = WorkReleaseLook.pullRequests(of: rel, in: graph)
        #expect(pulls.map(\.title) == ["Releases on the Mac", "#12"])
        #expect(pulls.map(\.state) == ["merged", "merged"])
        #expect(pulls.first?.labels.map(\.name) == ["enhancement"])
        let stages = WorkReleaseLook.pipeline(of: rel, in: graph)
        #expect(stages.map(\.words) == ["CI run", "TestFlight 42"])
        #expect(stages.first?.url?.absoluteString == "https://github.com/alexec/Agents/actions/runs/99")
        #expect(WorkReleaseLook.pipeline(of: rel, in: .init()).isEmpty)
    }

    @Test func lineageOnThePanel() {
        let f = DaemonAPI.LineageFigures(node: Node(kind: "release", ref: "r"), cost: .init(cost: ["USD": 18.4]), sessions: 3, running: 1,
                                         runtimes: [.init(runtimeID: "claude", sessions: 2), .init(runtimeID: "codex", sessions: 1)],
                                         leadTimeSeconds: 2 * 3600 + 600)
        #expect(WorkReleaseLook.lineageWords(f) == "$18.40 · 3 sessions, 1 running · lead time 2h 10m")
        #expect(WorkReleaseLook.runtimesWords(f) == "Claude 2 · Codex 1")
        #expect(WorkReleaseLook.lineageWords(.init(node: Node(kind: "release", ref: "r"))) == nil)
        #expect(WorkReleaseLook.notesElsewhere("github:alexec/Agents/release/v1.0.0") == "The release notes are on GitHub.")
    }
}
