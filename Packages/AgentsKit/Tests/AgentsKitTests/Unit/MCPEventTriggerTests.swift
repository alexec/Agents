import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// A server's event as a workflow trigger (#383, contracts/workflow-trigger.md).
@Suite("MCP event triggers")
struct MCPEventTriggerTests {
    private let project = URL(fileURLWithPath: "/tmp/project")

    private func parse(_ on: String) -> Workflow {
        WorkflowFile.parse("---\non:\n\(on)\n---\n\nDo it.\n", workflowID: "w", in: project)
    }

    // MARK: Names

    @Test func everyEventIsNounDotVerbed() {
        for name in ["checks.failed", "pull_request.opened", "a1.b_2"] { #expect(EventCatalogue.isEventName(name)) }
        for name in ["checksFailed", "Checks.failed", "a.b.c", ".failed", "checks.", "1checks.failed", "checks.*"] {
            #expect(!EventCatalogue.isEventName(name), "\(name)")
        }
    }

    @Test func theAppsNounsAreReserved() {
        #expect(EventCatalogue.reservedNouns == ["agent", "project", "workflow", "branch", "lease", "mac",
                                                 "machine", "person", "cost", "server", "custom"])
    }

    @Test func aServersEventIsAnyOtherNounDotVerbed() {
        #expect(EventCatalogue.isServerEventName("checks.failed"))
        #expect(EventCatalogue.isServerEventName("pr.merged"))
        for name in ["branch.created", "agent.finished", "custom.x", "mac.disk_low", "checksFailed", "checks.*"] {
            #expect(!EventCatalogue.isServerEventName(name), "\(name)")
        }
    }

    // MARK: Parsing

    @Test func aNameAloneHearsEveryServer() {
        let workflow = parse("  - checks.failed")
        #expect(workflow.problem == nil)
        #expect(workflow.triggers == [.serverEvent(MCPEventTrigger(event: "checks.failed"))])
    }

    @Test func itsKeysAreTheSubscriptionsArguments() {
        let workflow = parse("""
              - checks.failed:
                  repo: alexec/Agents
                  branch: [main, release]
            """)
        #expect(workflow.problem == nil)
        #expect(workflow.triggers == [.serverEvent(MCPEventTrigger(
            event: "checks.failed",
            arguments: ["repo": "alexec/Agents", "branch": ["main", "release"]]))])
    }

    @Test func anArgumentCanBeAMap() {
        let workflow = parse("""
              - ticket.opened:
                  queue:
                    name: support
                    priority: 2
            """)
        #expect(workflow.problem == nil)
        #expect(workflow.triggers == [.serverEvent(MCPEventTrigger(
            event: "ticket.opened", arguments: ["queue": ["name": "support", "priority": "2"]]))])
    }

    @Test func aNameThatIsNotNounDotVerbedIsAFileProblem() {
        #expect(parse("  - checksFailed").problem == .triggerNotSupported("checksFailed"))
    }

    @Test func serverNarrowsItToOneOrAList() {
        let one = parse("""
              - checks.failed:
                  server: ci
                  repo: alexec/Agents
            """)
        #expect(one.triggers == [.serverEvent(MCPEventTrigger(event: "checks.failed", servers: ["ci"],
                                                              arguments: ["repo": "alexec/Agents"]))])
        let two = parse("""
              - pull_request.opened:
                  server: [github, gitlab]
            """)
        #expect(two.triggers == [.serverEvent(MCPEventTrigger(event: "pull_request.opened", servers: ["github", "gitlab"]))])
    }

    @Test func aBadServerValueIsAFileError() {
        for value in ["\"not a name\"", "[ci, \"a b\"]"] {
            let workflow = parse("  - checks.failed:\n      server: \(value)")
            guard case .unreadable(let why)? = workflow.problem else { Issue.record("not refused: \(value)"); continue }
            #expect(why.contains("server:"))
        }
        let mapping = parse("  - checks.failed:\n      server:\n        name: ci")
        #expect(mapping.problem != nil)
    }

    @Test func argumentsOverTwoKilobytesAreAFileError() {
        let workflow = parse("  - checks.failed:\n      repo: \(String(repeating: "a", count: 2100))")
        guard case .unreadable(let why)? = workflow.problem else { Issue.record("not refused"); return }
        #expect(why.contains("over 2 KB"))
    }

    @Test func theAppsOwnNamesAreUnchanged() {
        let workflow = parse("  - branch.moved:\n      branch: main")
        #expect(workflow.triggers == [.event(EventPattern("branch.moved", filters: ["branch": "main"]))])
    }

    // MARK: Keys and matching

    @Test func theKeyIsSixteenHexAndCanonical() {
        let a = MCPEventTrigger(event: "checks.failed", arguments: ["repo": "x", "branch": "main"])
        let b = MCPEventTrigger(event: "checks.failed", arguments: ["branch": "main", "repo": "x"])
        let key = a.subscriptionKey(server: "ci")
        #expect(key.count == 16)
        #expect(key.allSatisfy { "0123456789abcdef".contains($0) })
        #expect(key == b.subscriptionKey(server: "ci"))
        #expect(key != a.subscriptionKey(server: "other"))
        #expect(key != MCPEventTrigger(event: "checks.passed", arguments: a.arguments).subscriptionKey(server: "ci"))
        #expect(key != MCPEventTrigger(event: "checks.failed", arguments: ["repo": "y", "branch": "main"])
            .subscriptionKey(server: "ci"))
        // `server:` narrows which servers, and is not part of what is asked of one.
        #expect(key == MCPEventTrigger(event: "checks.failed", servers: ["ci"], arguments: a.arguments)
            .subscriptionKey(server: "ci"))
    }

    private func event(_ name: String, server: String, subscription: String) -> Event {
        Event(position: 1, name: name, at: Date(), scope: .project(folder: project), sentence: "",
              details: ["server": server, "subscription": subscription])
    }

    @Test func itMatchesOnlyItsOwnSubscriptions() {
        let any = MCPEventTrigger(event: "checks.failed", arguments: ["repo": "x"])
        let ciOnly = MCPEventTrigger(event: "checks.failed", servers: ["ci"], arguments: ["repo": "x"])
        let fromCI = event("checks.failed", server: "ci", subscription: any.subscriptionKey(server: "ci"))
        let fromGH = event("checks.failed", server: "gh", subscription: any.subscriptionKey(server: "gh"))
        #expect(WorkflowTrigger.serverEvent(any).matches(fromCI))
        #expect(WorkflowTrigger.serverEvent(any).matches(fromGH))
        #expect(WorkflowTrigger.serverEvent(ciOnly).matches(fromCI))
        #expect(!WorkflowTrigger.serverEvent(ciOnly).matches(fromGH))
        let otherArguments = MCPEventTrigger(event: "checks.failed", arguments: ["repo": "y"])
        #expect(!WorkflowTrigger.serverEvent(otherArguments).matches(fromCI))
        #expect(!WorkflowTrigger.serverEvent(any).matches(
            event("checks.passed", server: "ci", subscription: any.subscriptionKey(server: "ci"))))
    }

    // MARK: The wire

    @Test func itTravelsAsATriggerAnOlderDeviceDoesNotKnow() throws {
        let trigger = WorkflowTrigger.serverEvent(MCPEventTrigger(event: "checks.failed", servers: ["ci"],
                                                                  arguments: ["repo": "alexec/Agents"]))
        let data = try JSONEncoder().encode(trigger)
        let unknown = try JSONEncoder().encode(WorkflowTrigger.unrecognised(
            name: "checks.failed", keys: ["server": "ci", "repo": "alexec/Agents"]))
        #expect(try JSONValue.parse(data) == JSONValue.parse(unknown))
        #expect(try JSONDecoder().decode(WorkflowTrigger.self, from: data) == trigger)
        let list = WorkflowTrigger.serverEvent(MCPEventTrigger(event: "pr.merged", servers: ["a", "b"]))
        #expect(try JSONDecoder().decode(WorkflowTrigger.self, from: JSONEncoder().encode(list)) == list)
    }

    @Test func theAppsEventsStillTravelAsBefore() throws {
        let trigger = WorkflowTrigger.event(EventPattern("branch.moved", filters: ["branch": "main"]))
        #expect(try JSONDecoder().decode(WorkflowTrigger.self, from: JSONEncoder().encode(trigger)) == trigger)
    }

    @Test func itSaysWhatItWaitsFor() {
        #expect(WorkflowTrigger.serverEvent(MCPEventTrigger(event: "checks.failed", servers: ["ci"],
                                                            arguments: ["repo": "alexec/Agents"])).summary
            == "When ci reports checks.failed (repo alexec/Agents)")
        #expect(WorkflowTrigger.serverEvent(MCPEventTrigger(event: "pr.merged")).summary
            == "When a server here reports pr.merged")
    }
}
