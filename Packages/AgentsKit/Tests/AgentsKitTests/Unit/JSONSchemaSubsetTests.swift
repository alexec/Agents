import Foundation
import Testing
@testable import AgentsKitCore

/// The subset of JSON Schema an event's filters are checked with (#383, research R8).
@Suite("JSON Schema subset")
struct JSONSchemaSubsetTests {
    private let schema: JSONValue = [
        "type": "object",
        "properties": ["repo": ["type": "string"], "branch": ["type": "string"],
                       "state": ["enum": ["open", "closed"]], "limit": ["type": "integer"],
                       "labels": ["type": "array", "items": ["type": "string"]]],
        "required": ["repo"],
        "additionalProperties": false,
    ]

    private func check(_ value: JSONValue, _ schema: JSONValue? = nil) -> String? {
        JSONSchemaSubset.check(value, against: schema ?? self.schema, name: "ci's checks.failed")
    }

    @Test func whatFitsPasses() {
        #expect(check(["repo": "alexec/Agents"]) == nil)
        #expect(check(["repo": "x", "branch": "main", "state": "open", "limit": 3, "labels": ["a", "b"]]) == nil)
        #expect(check(["repo": "x", "limit": .double(3)]) == nil)
    }

    @Test func aMissingRequiredKeyNamesTheKeys() {
        #expect(check([:]) == "ci's checks.failed takes branch, labels, limit, repo (required), state; repo is needed.")
    }

    @Test func anExtraKeyIsRefusedOnlyWhenTheSchemaSaysSo() {
        #expect(check(["repo": "x", "brnch": "main"]) == #"ci's checks.failed takes branch, labels, limit, repo (required), state; "brnch" is not one of its arguments."#)
        let open: JSONValue = ["type": "object", "properties": ["repo": ["type": "string"]]]
        #expect(check(["repo": "x", "brnch": "main"], open) == nil)
    }

    @Test func typesEnumsAndItemsAreChecked() {
        #expect(check(["repo": 4]) == "ci's checks.failed: repo should be text.")
        #expect(check(["repo": "x", "limit": "three"]) == "ci's checks.failed: limit should be an integer.")
        #expect(check(["repo": "x", "limit": .double(2.5)]) == "ci's checks.failed: limit should be an integer.")
        #expect(check(["repo": "x", "state": "merged"]) == "ci's checks.failed: state is one of open, closed, not merged.")
        #expect(check(["repo": "x", "labels": ["a", 1]]) == "ci's checks.failed: labels[1] should be text.")
    }

    @Test func otherKeywordsAreIgnored() {
        let schema: JSONValue = ["type": "object", "properties": ["repo": ["type": "string", "pattern": "^nope$",
                                                                          "minLength": 99]],
                                 "oneOf": [["required": ["x"]]]]
        #expect(check(["repo": "x"], schema) == nil)
    }
}
