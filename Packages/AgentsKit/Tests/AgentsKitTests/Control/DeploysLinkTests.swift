import Foundation
import Testing
@testable import AgentsKitCore

/// Deployed ↗ and Live in ↗ on the Work pages (#5243; tier Web + Mac link, #4937, Lead role, #5290).
struct DeploysLinkTests {
    @Test func itOpensTheSamePageOnTheWeb() throws {
        #expect(DeploysLink.place(kind: "release", ref: "github:release:alexec/agents#v0.18.0")
            == "/work/release/github%3Arelease%3Aalexec%2Fagents%23v0.18.0")
        #expect(DeploysLink.place(kind: "pr", ref: "github:alexec/agents#3983") == "/work/pr/github%3Aalexec%2Fagents%233983")
        #expect(DeploysLink.place(kind: "issue", ref: "github:alexec/agents#1") == nil)
        #expect(DeploysLink.place(kind: "pr", ref: "") == nil)
        let place = try #require(DeploysLink.place(kind: "pr", ref: "github:alexec/agents#3983"))
        let url = try #require(BrowserOpening.pageURL("http://127.0.0.1:8792", place: place))
        #expect(url.fragment(percentEncoded: true) == "/work/pr/github%3Aalexec%2Fagents%233983")
    }

    @Test func itsNameIsTheSections() {
        #expect(DeploysLink.title(kind: "release") == "Deployed")
        #expect(DeploysLink.title(kind: "pr") == "Live in")
    }
}
