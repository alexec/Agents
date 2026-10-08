import Foundation
import Testing
@testable import AgentsKitCore

/// What a wait and a trigger match, which is one thing (042 R1, FR-006, FR-021).
@Suite("Event patterns")
struct EventPatternTests {
    private let folder = URL(fileURLWithPath: "/tmp/project")

    private func event(_ name: String, _ details: [String: String] = [:], position: EventPosition = 1) -> Event {
        Event(position: position, name: name, at: Date(timeIntervalSince1970: 0),
              scope: .project(folder: folder), sentence: "", details: details)
    }

    private func pattern(_ name: String, _ filters: [String: DetailFilter] = [:]) throws -> EventPattern {
        try EventPattern.parse(name, filters: filters).get()
    }

    @Test func aWholeSubjectMatchesEveryKindInItAndNothingElse() throws {
        let all = try pattern("workflow.*")
        for kind in EventCatalogue.kinds(in: .workflow) { #expect(all.matches(event(kind.name))) }
        #expect(EventCatalogue.kinds(in: .workflow).count == 3)
        #expect(!all.matches(event("branch.moved")))
        #expect(!all.matches(event("mac.wake")))
    }

    @Test func filtersNarrowByDetailComparedAsStrings() throws {
        let nightly = try pattern("workflow.completed", ["workflow": "nightly"])
        #expect(nightly.matches(event("workflow.completed", ["workflow": "nightly"])))
        #expect(!nightly.matches(event("workflow.completed", ["workflow": "weekly"])))
        #expect(!nightly.matches(event("workflow.completed")))
        #expect(!nightly.matches(event("workflow.ran", ["workflow": "nightly"])))
    }

    @Test func aCustomNameMatchesOnlyItself() throws {
        let green = try pattern("custom.build_green")
        #expect(green.matches(event("custom.build_green")))
        #expect(!green.matches(event("custom.build_red")))
        // Custom filters are free-form: whatever the publisher put in its details.
        let tagged = try pattern("custom.build_green", ["branch": "main"])
        #expect(tagged.matches(event("custom.build_green", ["branch": "main"])))
    }

    @Test func anUnknownNameIsRefusedWithASuggestionAndTheList() {
        let message = EventPattern.parse("workflow.complete").failure?.message ?? ""
        #expect(message.contains("Did you mean workflow.completed?"))
        #expect(message.contains("mac.wake"))
        #expect(message.contains("custom.<name>"))
    }

    @Test func anUnknownSubjectIsRefused() {
        #expect(EventPattern.parse("no-pe.*").failure == .unknown("no-pe.*"))
    }

    /// A server's event (#383): any other `noun.verbed`, its details open, and `noun.*`
    /// for every one of a noun's, never one of the app's.
    @Test func aServersEventAndItsNounAreWaitedOn() throws {
        let failed = try pattern("checks.failed", ["repo": "x"])
        #expect(failed.matches(event("checks.failed", ["repo": "x", "server": "ci"])))
        #expect(!failed.matches(event("checks.failed", ["repo": "y"])))
        let checks = try pattern("checks.*")
        #expect(checks.matches(event("checks.failed")))
        #expect(checks.matches(event("checks.passed")))
        #expect(!checks.matches(event("checksx.failed")))
        #expect(!checks.matches(event("pr.merged")))
        #expect(EventPattern.parse("branch.created").failure == .unknown("branch.created"))
        #expect(EventPattern.parse("checksFailed").failure != nil)
    }

    @Test func aFilterTheKindDoesNotCarryIsRefusedNamingWhatItDoes() {
        let problem = EventPattern.parse("branch.moved", filters: ["number": "x"]).failure
        #expect(problem?.message == "branch.moved carries branch, from, to; \"number\" is not one of its details.")
        #expect(EventPattern.parse("branch.*", filters: ["number": "x"]).failure != nil)
        #expect(EventPattern.parse("branch.*", filters: ["branch": "main"]).failure == nil)
    }

    @Test func aBadCustomNameIsRefused() {
        #expect(EventPattern.parse("custom.Build Green").failure == .badCustomName("custom.build green"))
    }

    @Test func namesAreTrimmedAndLowercased() throws {
        #expect(try pattern("  Mac.Wake ").name == "mac.wake")
    }

    @Test func copyAsTriggerNarrowsByTheKindsDetailsOnly() {
        let moved = event("branch.moved", ["branch": "main", "from": "a1", "to": "b2", "extra": "x"])
        #expect(EventPattern.matching(moved).asTrigger
                == "on:\n  - branch.moved:\n      branch: main\n      from: a1\n      to: b2")
        #expect(EventPattern.matching(event("mac.wake")).asTrigger == "on:\n  - mac.wake")
        let custom = event("custom.build_green", ["branch": "feature x"])
        #expect(EventPattern.matching(custom).asTrigger
                == "on:\n  - custom.build_green:\n      branch: \"feature x\"")
    }

    @Test func theLabelWritesEachFilterAfterTheName() throws {
        #expect(try pattern("branch.moved", ["branch": "main"]).label == "branch.moved branch main")
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let failure) = self { return failure }
        return nil
    }
}
