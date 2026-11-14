import Foundation
import Testing
@testable import AgentsKitCore

/// Build trends ↗ on the Pipeline line (#5180, spec 5166 board 5; tier Web + Mac link, #4937).
struct BuildTrendsLinkTests {
    private typealias Node = DaemonAPI.LineageNode

    @Test func itOpensTheRunsDrillDown() {
        // The old form and the full form name the same run.
        for ref in ["github:alexec/agents/actions/run/123", "github:run:alexec/agents#123"] {
            #expect(BuildTrendsLink.place(run: Node(kind: "ci-run", ref: ref))
                == "/reports/value/builds?repo=github:alexec/agents&range=month&drill=github:run:alexec/agents%23123")
        }
        // The repository is lower case, as builds/history names it.
        #expect(BuildTrendsLink.place(run: Node(kind: "ci-run", ref: "github:Alexec/Agents/actions/run/9"))?
            .hasPrefix("/reports/value/builds?repo=github:alexec/agents&") == true)
        // A ref that names no repository has no link.
        #expect(BuildTrendsLink.place(run: Node(kind: "ci-run", ref: "nonsense")) == nil)
    }

    @Test func thePlaceOpensWholeOnThePage() throws {
        let place = try #require(BuildTrendsLink.place(run: Node(kind: "ci-run", ref: "github:run:alexec/agents#123")))
        let url = try #require(BrowserOpening.pageURL("http://127.0.0.1:8792", place: place))
        #expect(url.fragment(percentEncoded: true)
            == "/reports/value/builds?repo=github:alexec/agents&range=month&drill=github:run:alexec/agents%23123")
    }

    @Test func itTakesTheNewestRun() {
        let pr = Node(kind: "release", ref: "github:alexec/agents/release/v1.2")
        let newest = Node(kind: "ci-run", ref: "github:alexec/agents/actions/run/2")
        let older = Node(kind: "ci-run", ref: "github:alexec/agents/actions/run/1")
        #expect(BuildTrendsLink.run(in: [pr, newest, older]) == newest)
        #expect(BuildTrendsLink.run(in: [pr]) == nil)
    }

    @Test func itsHelpSaysWhichRun() {
        #expect(BuildTrendsLink.help(kind: "pr") == "Build trends on the web page, at this pull request’s last run on main.")
        #expect(BuildTrendsLink.help(kind: "release") == "Build trends on the web page, at this release’s CI run.")
    }
}
