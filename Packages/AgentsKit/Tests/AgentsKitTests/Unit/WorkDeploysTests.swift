import Foundation
import Testing
@testable import AgentsKitCore

/// Work ▸ Deploys (#5270): the grid's columns, rows and words, and several machines as one.
struct WorkDeploysTests {
    typealias T = DaemonAPI.DeployTargetNow

    static let utc = TimeZone(identifier: "UTC")!
    static let t0 = Date(timeIntervalSince1970: 1_762_599_060) // 8 Nov 2025, 10:51 UTC

    static func target(_ component: String, _ env: String, _ tier: DaemonAPI.EnvironmentTier, labels: [String: String]? = nil,
                       live: [(String?, String, Double?, Date)] = [], next: [(String, DaemonAPI.DeployState)] = []) -> T {
        let t = DaemonAPI.DeployTarget(component: .init(system: "github", id: "alexec/agents/\(component)", name: component),
                                       environment: .init(system: "github", name: env, tier: tier), labels: labels)
        func deploy(_ name: String?, _ sha: String, _ state: DaemonAPI.DeployState) -> DaemonAPI.Deploy {
            .init(system: "github", id: sha, target: t,
                  version: .init(artifacts: [.init(kind: "commit", system: "github", id: sha)], name: name), state: state,
                  url: "https://github.com/alexec/agents/actions/runs/1/job/2")
        }
        return T(target: t,
                 live: live.map { .init(deploy: deploy($0.0, $0.1, .succeeded), release: $0.0.map { "github:release:alexec/agents#\($0)" },
                                        since: $0.3, share: $0.2) },
                 next: next.map { .init(deploy: deploy($0.0, "ccc", $0.1)) })
    }

    @Test func columnsGoInTierOrderAndRowsByName() throws {
        let grid = WorkDeploys.grid([
            Self.target("Remote", "app-store", .production, live: [("v0.18.0", "aaa", 100, Self.t0)]),
            Self.target("Remote", "testflight", .testing, live: [("v0.18.0", "aaa", 100, Self.t0)]),
            Self.target("Mac app", "github-releases", .production, live: [("v0.18.0", "aaa", 100, Self.t0)]),
            Self.target("Docs", "github-pages", .production, live: [(nil, "1357c99abc", 100, Self.t0)]),
        ])
        try #require(grid.rows.map(\.name) == ["Docs", "Mac app", "Remote"])
        let docs = try #require(grid.rows.first?.cells.dropFirst(2).first?.first?.live.first)
        let remote = try #require(grid.rows.last)
        #expect(grid.columns.map(\.name) == ["testflight", "app-store", "github-pages", "github-releases"])
        #expect(remote.cells.map(\.count) == [1, 1, 0, 0])
        #expect(WorkDeploys.versionWords(docs.deploy.version) == "1357c99")
        #expect(WorkDeploys.tierChip(.production) == "production")
        #expect(WorkDeploys.tierChip(.testing) == nil)
    }

    @Test func words() throws {
        #expect(WorkDeploys.sinceWords(Self.t0, timeZone: Self.utc) == "since 8 Nov, 10:51")
        #expect(WorkDeploys.shareWords(100) == nil)
        #expect(WorkDeploys.shareWords(90) == "90 %")
        #expect(WorkDeploys.shareWords(12.5) == "12.5 %")
        let canary = Self.target("Remote", "production", .production, labels: ["region": "eu"],
                                 live: [("v0.18.0", "aaa", 90, Self.t0), ("v0.19.0", "bbb", 10, Self.t0)],
                                 next: [("v0.20.0", .waiting)])
        #expect(WorkDeploys.labelsLine(canary.target) == "region eu")
        try #require(canary.next.count == 1)
        #expect(WorkDeploys.nextWords(canary.next[0]) == "next: v0.20.0, waiting")
        #expect(WorkDeploys.cellLabel(component: "Remote", environment: "production", [canary], timeZone: Self.utc)
            == "Remote in production: region eu, v0.18.0 live at 90 % since 8 Nov, 10:51, v0.19.0 live at 10 % since 8 Nov, 10:51, next: v0.20.0, waiting")
        #expect(WorkDeploys.cellLabel(component: "Docs", environment: "testflight", []) == "Docs in testflight: none")
    }

    @Test func twoMachinesKeepTheNewerTarget() {
        let old = Self.target("Remote", "testflight", .testing, live: [("v0.17.0", "aaa", 100, Self.t0)])
        let new = Self.target("Remote", "testflight", .testing, live: [("v0.18.0", "bbb", 100, Self.t0.addingTimeInterval(60))])
        let docs = Self.target("Docs", "github-pages", .production, live: [(nil, "ddd", 100, Self.t0)])
        let merged = WorkDeploys.merge([[old, docs], [new]])
        #expect(merged.map { $0.live[0].deploy.version.name } == ["v0.18.0", nil])
        #expect(WorkDeploys.merge([[new], [old]]).map { $0.live[0].deploy.version.name } == ["v0.18.0"])
    }

    @Test func aTierThisBuildDoesNotKnowIsOther() throws {
        let got = try JSONDecoder().decode([DaemonAPI.EnvironmentTier].self, from: Data(#"["production","canary"]"#.utf8))
        #expect(got == [.production, .other])
    }

    @Test func aDeployNodeOpensNoWorkPage() {
        #expect(WorkList.kind(of: .init(kind: "deploy", ref: "github:deploy:alexec/agents#1")) == nil)
        #expect(WorkList.Kind.deploy.title == "Deploys")
    }
}
