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

    private func pattern(_ name: String, _ filters: [String: String] = [:]) throws -> EventPattern {
        try EventPattern.parse(name, filters: filters).get()
    }

    @Test func aWholeSubjectMatchesEveryKindInItAndNothingElse() throws {
        let all = try pattern("pull_request.*")
        for kind in EventCatalogue.kinds(in: .pullRequest) { #expect(all.matches(event(kind.name))) }
        #expect(EventCatalogue.kinds(in: .pullRequest).count == 10)
        #expect(!all.matches(event("branch.moved")))
        #expect(!all.matches(event("mac.wake")))
    }

    @Test func filtersNarrowByDetailComparedAsStrings() throws {
        let merged41 = try pattern("pull_request.merged", ["number": "41"])
        #expect(merged41.matches(event("pull_request.merged", ["number": "41"])))
        #expect(!merged41.matches(event("pull_request.merged", ["number": "42"])))
        #expect(!merged41.matches(event("pull_request.merged")))
        #expect(!merged41.matches(event("pull_request.closed", ["number": "41"])))
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
        let message = EventPattern.parse("pull_request.merge").failure?.message ?? ""
        #expect(message.contains("Did you mean pull_request.merged?"))
        #expect(message.contains("mac.wake"))
        #expect(message.contains("custom.<name>"))
    }

    @Test func anUnknownSubjectIsRefused() {
        #expect(EventPattern.parse("nope.*").failure == .unknown("nope.*"))
    }

    @Test func aFilterTheKindDoesNotCarryIsRefusedNamingWhatItDoes() {
        let problem = EventPattern.parse("pull_request.merged", filters: ["branch": "x"]).failure
        #expect(problem?.message == "pull_request.merged carries number; \"branch\" is not one of its details.")
        #expect(EventPattern.parse("pull_request.*", filters: ["branch": "x"]).failure != nil)
        #expect(EventPattern.parse("pull_request.*", filters: ["number": "4"]).failure == nil)
    }

    @Test func aBadCustomNameIsRefused() {
        #expect(EventPattern.parse("custom.Build Green").failure == .badCustomName("custom.build green"))
    }

    @Test func namesAreTrimmedAndLowercased() throws {
        #expect(try pattern("  Mac.Wake ").name == "mac.wake")
    }

    @Test func theLabelWritesANumberAsAHash() throws {
        #expect(try pattern("pull_request.merged", ["number": "44"]).label == "pull_request.merged #44")
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let failure) = self { return failure }
        return nil
    }
}
