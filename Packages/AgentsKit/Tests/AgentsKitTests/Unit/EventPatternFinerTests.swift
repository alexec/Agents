import Foundation
import Testing
@testable import AgentsKitCore

/// Filters (073, #574): only `branch` on `branch.moved` and `why` on `person.away` and
/// `person.back` narrow an event, any of a list, through the one matcher a wait and a
/// trigger share. Every other key is refused naming what the event does take.
@Suite("Event patterns, finer")
struct EventPatternFinerTests {
    private let folder = URL(fileURLWithPath: "/tmp/project")

    private func event(_ name: String, _ details: [String: String] = [:]) -> Event {
        Event(position: 1, name: name, at: Date(timeIntervalSince1970: 0),
              scope: .project(folder: folder), sentence: "", details: details)
    }

    /// An agent event as the daemon raises one: the agent and its context, then its own.
    private func about(_ name: String, labels: String = "", _ own: [String: String] = [:]) -> Event {
        event(name, ["agent": UUID().uuidString, "labels": labels, "runtime": "claude", "started_by": "person"]
            .merging(own) { $1 })
    }

    private func pattern(_ name: String, _ filters: [String: DetailFilter] = [:]) throws -> EventPattern {
        try EventPattern.parse(name, filters: filters).get()
    }

    private func any(_ values: String...) -> DetailFilter { DetailFilter(anyOf: values)! }

    // MARK: The filters left

    @Test func aBranchOrAListOfThem() throws {
        let main = try pattern("branch.moved", ["branch": "main"])
        #expect(main.matches(event("branch.moved", ["branch": "main", "from": "a", "to": "b"])))
        #expect(!main.matches(event("branch.moved", ["branch": "develop"])))
        let either = try pattern("branch.moved", ["branch": any("main", "release/1.0")])
        #expect(either.matches(event("branch.moved", ["branch": "release/1.0"])))
        #expect(!either.matches(event("branch.moved")))
    }

    @Test func whyOnAwayAndBack() throws {
        let locked = try pattern("person.away", ["why": "locked"])
        #expect(locked.matches(event("person.away", ["why": "locked"])))
        #expect(!locked.matches(event("person.away", ["why": "idle"])))
        let back = try pattern("person.*", ["why": "idle"])
        #expect(back.matches(event("person.back", ["why": "idle"])))
        #expect(!back.matches(event("branch.moved", ["why": "idle"])))
    }

    @Test func aFiltersValueIsCheckedWhenItHasFixedOnes() {
        let problem = EventPattern.parse("person.away", filters: ["why": "asleep"]).failure
        #expect(problem?.message == "person.away: why is one of locked, idle, not asleep.")
        #expect(EventPattern.parse("person.back", filters: ["why": any("locked", "nope")]).failure?.isBadFilter == true)
    }

    /// One checker (#579): a where an app event does not take is refused in the words a
    /// server's event's would be.
    @Test func anAppEventsRefusalReadsLikeAServersEvent() {
        let server: JSONValue = ["type": "object", "additionalProperties": false,
                                 "properties": ["repo": ["type": "string"],
                                                "state": ["type": "string", "enum": ["open", "closed"]]]]
        #expect(JSONSchemaSubset.check(["nope": "x"], against: server, name: "github's pr.merged")
                == "github's pr.merged takes repo, state; \"nope\" is not one of its arguments.")
        #expect(EventPattern.parse("branch.moved", filters: ["nope": "x"]).failure?.message
                == "branch.moved takes branch; \"nope\" is not one of its arguments.")
        #expect(JSONSchemaSubset.check(["state": "merged"], against: server, name: "github's pr.merged")
                == "github's pr.merged: state is one of open, closed, not merged.")
        #expect(EventPattern.parse("person.away", filters: ["why": "merged"]).failure?.message
                == "person.away: why is one of locked, idle, not merged.")
    }

    // MARK: Everything else is refused (#574)

    @Test func anAgentEventCannotBeNarrowedAndSaysHowToWaitForAgents() {
        for (name, key) in [("agent.finished", "outcome"), ("agent.finished", "labels"), ("agent.failed", "runtime"),
                            ("agent.finished", "agent"), ("agent.stopped", "by"), ("agent.*", "started_by"),
                            ("agent.messaged", "from"), ("agent.deleted", "because")] {
            let problem = EventPattern.parse(name, filters: [key: "x"]).failure
            #expect(problem?.isBadFilter == true, "\(name) \(key)")
            #expect(problem?.message == "\(name) takes no arguments; \"\(key)\" is not one of its arguments. "
                    + "To wait for particular agents, use wait_for_event with agents.")
        }
    }

    @Test func otherEventsNameTheFiltersTheyTakeOrSayNone() {
        #expect(EventPattern.parse("branch.moved", filters: ["to": "abc"]).failure?.message
                == "branch.moved takes branch; \"to\" is not one of its arguments.")
        #expect(EventPattern.parse("workflow.completed", filters: ["workflow": "nightly"]).failure?.message
                == "workflow.completed takes no arguments; \"workflow\" is not one of its arguments.")
        for (name, key) in [("project.idle", "agents"), ("dropbox.file_added", "extension"),
                            ("lease.released", "how"), ("machine.disk_low", "level"), ("cost.allowance_out", "runtime"),
                            ("server.offline", "server"), ("custom.ship", "labels"), ("custom.*", "message"),
                            ("workflow.*", "workflow")] {
            #expect(EventPattern.parse(name, filters: [key: "x"]).failure?.isBadFilter == true, "\(name) \(key)")
        }
    }

    @Test func aServersEventKeepsItsKeys() throws {
        // Out of scope here (#577): compared with the event's details, as before.
        _ = try pattern("pr.merged", ["server": "github"])
        _ = try pattern("ci.*", ["event": "checks.failed"])
    }

    // MARK: Waits already stored (#574)

    /// What the previous version decodes a pattern as.
    private struct OldPattern: Codable {
        var name: String
        var filters: [String: String]
    }

    @Test func aStoredWaitWithARemovedKeyIsReadAndStillMatches() throws {
        let stored = Data(#"{"name":"agent.finished","filters":{"outcome":"done"}}"#.utf8)
        let read = try JSONDecoder().decode(EventPattern.self, from: stored)
        #expect(read.matches(about("agent.finished", ["outcome": "done"])))
        #expect(!read.matches(about("agent.finished", ["outcome": "stuck"])))
        let list = Data(#"{"name":"workflow.completed","filters":{"outcome":"stuck|partly_done"},"anyOf":{"outcome":["stuck","partly_done"]}}"#.utf8)
        #expect(try JSONDecoder().decode(EventPattern.self, from: list)
            .matches(event("workflow.completed", ["workflow": "nightly", "outcome": "partly_done"])))
    }

    @Test func singleValuesAreStoredExactlyAsBefore() throws {
        let old = OldPattern(name: "branch.moved", filters: ["branch": "main"])
        let new = try pattern("branch.moved", ["branch": "main"])
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        #expect(try encoder.encode(new) == encoder.encode(old))
        #expect(try JSONDecoder().decode(EventPattern.self, from: encoder.encode(old)) == new)
    }

    @Test func aListIsReadBackAndAnOlderBuildReadsItAsNeverMatching() throws {
        let new = try pattern("person.away", ["why": any("locked", "idle")])
        let data = try JSONEncoder().encode(new)
        #expect(try JSONDecoder().decode(EventPattern.self, from: data) == new)
        let old = try JSONDecoder().decode(OldPattern.self, from: data)
        #expect(old.filters == ["why": "locked|idle"])
    }

    // MARK: Words

    @Test func theSummarySaysEachFilterAsItsKeyAndValues() throws {
        #expect(try pattern("branch.moved", ["branch": any("main", "develop")]).summary
                == "A branch moved: the default branch, or one an agent works on (branch main or develop)")
        #expect(try pattern("person.away", ["why": "locked"]).summary
                == "You locked the screen or stepped away for 5 minutes (why locked)")
        #expect(try pattern("person.*", ["why": "idle"]).summary == "Anything about persons (why idle)")
    }

    @Test func theLabelAndTheTriggerTextWriteAListOneLine() throws {
        let either = try pattern("branch.moved", ["branch": any("main", "develop")])
        #expect(either.label == "branch.moved branch main|develop")
        #expect(either.asTrigger == "on:\n  - branch.moved:\n      branch: [main, develop]")
    }

    @Test func copyAsTriggerCopiesOnlyTheFilters() throws {
        let moved = event("branch.moved", ["branch": "main", "from": "a1", "to": "b2"])
        #expect(EventPattern.matching(moved).asTrigger == "on:\n  - branch.moved:\n      branch: main")
        #expect(EventPattern.matching(event("person.back", ["why": "idle"])).asTrigger
                == "on:\n  - person.back:\n      why: idle")
        let finished = about("agent.finished", labels: "bug", ["outcome": "done", "afterwards": "park"])
        #expect(EventPattern.matching(finished).asTrigger == "on:\n  - agent.finished")
        #expect(EventPattern.matching(event("custom.ship", ["labels": "bug"])).asTrigger == "on:\n  - custom.ship")
        let dropped = event("dropbox.file_added", ["path": "a.txt", "extension": "txt"])
        #expect(EventPattern.matching(dropped).asTrigger == "on:\n  - dropbox.file_added")
        // What it copies reads back.
        for copied in [moved, finished, dropped] {
            let pattern = EventPattern.matching(copied)
            #expect(try EventPattern.parse(pattern.name, filters: pattern.filters).get() == pattern)
        }
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let failure) = self { return failure }
        return nil
    }
}
