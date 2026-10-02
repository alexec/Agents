import Foundation
import Testing
@testable import AgentsKitCore

/// One detail's wanted values: one, or any of a list (073 FR-002, FR-014).
@Suite("Detail filters")
struct DetailFilterTests {
    @Test func aListMatchesAnyOfItsValues() throws {
        let filter = try #require(DetailFilter(anyOf: ["done", "nothing_to_do"]))
        #expect(filter.matches("done", isSet: false))
        #expect(filter.matches("nothing_to_do", isSet: false))
        #expect(!filter.matches("stuck", isSet: false))
        #expect(!filter.matches(nil, isSet: false))
    }

    @Test func aListOfOneIsTheSingleValue() {
        #expect(DetailFilter(anyOf: ["done"]) == DetailFilter("done"))
        #expect(DetailFilter(anyOf: ["done"])?.single == "done")
        #expect(DetailFilter(anyOf: []) == nil)
    }

    @Test func aSetDetailMatchesWhenItHoldsAnyValueComparedAsLabelsAre() throws {
        let bug: DetailFilter = "Bug"
        #expect(bug.matches("bug,p1", isSet: true))
        #expect(!bug.matches("bugfix,p1", isSet: true))
        #expect(!bug.matches("", isSet: true))
        #expect(DetailFilter("needs review").matches("needs review,p1", isSet: true))
        let either = try #require(DetailFilter(anyOf: ["bug", "regression"]))
        #expect(either.matches("regression", isSet: true))
        // Not a set: the whole value, exactly.
        #expect(!bug.matches("bug", isSet: false))
    }

    @Test func itIsWrittenAsTheStatusLineTheCapsuleAndTheFileSayIt() throws {
        let list = try #require(DetailFilter(anyOf: ["done", "nothing_to_do"]))
        #expect(list.label == "done|nothing_to_do")
        #expect(list.capsule == "done | nothing_to_do")
        #expect(list.yaml == "[done, nothing_to_do]")
        #expect(DetailFilter("feature x").yaml == "\"feature x\"")
    }

    @Test func itTravelsAsAStringOrAList() throws {
        let one = try JSONEncoder().encode(DetailFilter("done"))
        #expect(String(decoding: one, as: UTF8.self) == "\"done\"")
        let list = try #require(DetailFilter(anyOf: ["done", "stuck"]))
        let many = try JSONEncoder().encode(list)
        #expect(String(decoding: many, as: UTF8.self) == "[\"done\",\"stuck\"]")
        #expect(try JSONDecoder().decode(DetailFilter.self, from: many) == list)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(DetailFilter.self, from: Data("[]".utf8)) }
    }
}
