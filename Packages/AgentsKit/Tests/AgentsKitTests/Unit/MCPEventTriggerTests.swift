import Foundation
import Testing
@testable import AgentsKitCore

/// A trigger's link to the PR or issue it names (#3077).
@Suite("MCP event trigger")
struct MCPEventTriggerTests {
    @Test func aRepoAndAPRIsALink() {
        let trigger = MCPEventTrigger(event: "pr.merged", arguments: ["repo": .string("alexec/Agents"), "pr": .int(123)])
        #expect(trigger.url == URL(string: "https://github.com/alexec/Agents/pull/123"))
    }

    @Test func aRepoAndAnIssueIsALink() {
        let trigger = MCPEventTrigger(event: "issue.assigned", arguments: ["repo": .string("alexec/Agents"), "issue": .int(45)])
        #expect(trigger.url == URL(string: "https://github.com/alexec/Agents/issues/45"))
    }

    @Test func aGitLabProjectAndMergeRequestIsALink() {
        let trigger = MCPEventTrigger(event: "pr.merged", arguments: ["project": .string("group/sub"), "pr": .int(7)])
        #expect(trigger.url == URL(string: "https://gitlab.com/group/sub/-/merge_requests/7"))
    }

    @Test func aGitLabProjectAndIssueIsALink() {
        let trigger = MCPEventTrigger(event: "issue.assigned", arguments: ["project": .string("group/sub"), "issue": .int(9)])
        #expect(trigger.url == URL(string: "https://gitlab.com/group/sub/-/issues/9"))
    }

    /// A project named by its numeric id has no path to link to.
    @Test func aGitLabProjectByItsIDHasNoLink() {
        let trigger = MCPEventTrigger(event: "pr.merged", arguments: ["project": .string("42"), "pr": .int(7)])
        #expect(trigger.url == nil)
    }

    @Test func neitherAPRNorAnIssueIsNoLink() {
        let trigger = MCPEventTrigger(event: "checks.failed", arguments: ["repo": .string("alexec/Agents")])
        #expect(trigger.url == nil)
    }

    @Test func noRepoOrProjectIsNoLink() {
        let trigger = MCPEventTrigger(event: "pr.merged", arguments: ["pr": .int(123)])
        #expect(trigger.url == nil)
    }
}
