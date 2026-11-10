@testable import AgentsKitCore
import Foundation
import Testing

/// A lineage node's words (#2351, #3023), as the web page's `model/value.ts` says them.
struct ReportValueWordsTests {
    @Test func aNodeIsNamedWithoutItsTrackerAndAGitHubOneLinks() {
        #expect(ReportValueWords.name(.init(kind: "issue", ref: "github:alexec/agents#12")) == "alexec/agents#12")
        #expect(ReportValueWords.name(.init(kind: "issue", ref: "linear:ENG-4")) == "ENG-4")
        #expect(ReportValueWords.name(.init(kind: "release", ref: "github:alexec/agents/release/v0.14.0")) == "alexec/agents release v0.14.0")
        #expect(ReportValueWords.url(.init(kind: "issue", ref: "github:alexec/agents#12"))?.absoluteString
            == "https://github.com/alexec/agents/issues/12")
        #expect(ReportValueWords.url(.init(kind: "release", ref: "github:alexec/agents/release/v0.14.0"))?.absoluteString
            == "https://github.com/alexec/agents/releases/tag/v0.14.0")
        #expect(ReportValueWords.url(.init(kind: "issue", ref: "gitlab:g/p#3")) == nil)
    }
}
