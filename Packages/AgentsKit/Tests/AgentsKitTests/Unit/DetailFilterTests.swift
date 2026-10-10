import Foundation
import Testing
@testable import AgentsKitCore

/// One detail's wanted values: one, or any of a list (073 FR-002, FR-014).
@Suite("Detail filters")
struct DetailFilterTests {
    @Test func aListMatchesAnyOfItsValues() throws {
        let filter = try #require(DetailFilter(anyOf: ["done", "nothing_to_do"]))
        #expect(filter.matches("done"))
        #expect(filter.matches("nothing_to_do"))
        #expect(!filter.matches("stuck"))
        #expect(!filter.matches(nil))
        // The whole value, exactly: a comma-joined one is not a set (#574).
        #expect(!DetailFilter("bug").matches("bug,p1"))
    }

    @Test func aListOfOneIsTheSingleValue() {
        #expect(DetailFilter(anyOf: ["done"]) == DetailFilter("done"))
        #expect(DetailFilter(anyOf: ["done"])?.single == "done")
        #expect(DetailFilter(anyOf: []) == nil)
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
