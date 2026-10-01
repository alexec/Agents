import Foundation
import Testing
@testable import AgentsKitCore

@Suite("Session labels")
struct SessionLabelTests {
    private let project = URL(filePath: "/work/labels")

    @Test func trimsAndMatchesCaseWithoutDuplicating() throws {
        let first = try SessionLabelPolicy.change(current: [], add: [" Perf "],
                                                  actor: .person, projectLabels: [])
        #expect(first.map(\.value) == ["Perf"])
        let second = try SessionLabelPolicy.change(current: first, add: ["perf"],
                                                   actor: .person, projectLabels: first)
        #expect(second == first)
    }

    @Test func commaFinishesWhatWasTyped() {
        #expect(SessionLabelPolicy.split(typed: "perf") == (finished: [], remainder: "perf"))
        #expect(SessionLabelPolicy.split(typed: "perf,") == (finished: ["perf"], remainder: ""))
        #expect(SessionLabelPolicy.split(typed: "a, b,c") == (finished: ["a", " b"], remainder: "c"))
        #expect(SessionLabelPolicy.split(typed: "") == (finished: [], remainder: ""))
    }

    @Test func acceptsOnlyWhatFits() {
        #expect(SessionLabelPolicy.accepted([" ui ", "", "UI", "perf"], existing: ["Perf"]) == ["ui"])
        #expect(SessionLabelPolicy.accepted([String(repeating: "x", count: 25), "ok"], existing: []) == ["ok"])
        #expect(SessionLabelPolicy.accepted(["f", "g"], existing: ["a", "b", "c", "d"]) == ["f"])
    }

    @Test func refusesEmptyAndOverlongValues() throws {
        #expect(throws: SessionLabelPolicy.Refusal.self) {
            try SessionLabelPolicy.change(current: [], add: ["   "],
                                          actor: .person, projectLabels: [])
        }
        #expect(throws: SessionLabelPolicy.Refusal.self) {
            try SessionLabelPolicy.change(current: [], add: [String(repeating: "x", count: 25)],
                                          actor: .person, projectLabels: [])
        }
    }

    @Test func refusesSixthWithoutChangingFive() throws {
        let five = try SessionLabelPolicy.change(current: [],
                                                 add: ["one", "two", "three", "four", "five"],
                                                 actor: .person, projectLabels: [])
        #expect(five.count == 5)
        #expect(throws: SessionLabelPolicy.Refusal.self) {
            try SessionLabelPolicy.change(current: five, add: ["six"],
                                          actor: .person, projectLabels: five)
        }
        #expect(five.count == 5)
    }

    @Test func reusesTheProjectsFirstSpelling() throws {
        let first = try SessionLabelPolicy.change(current: [], add: ["Perf"],
                                                  actor: .person, projectLabels: [])
        let second = try SessionLabelPolicy.change(current: [], add: ["perf"],
                                                   actor: .agent, projectLabels: first)
        #expect(second.map(\.value) == ["Perf"])
        #expect(second.map(\.owner) == [.agent])
    }

    @Test func vocabularyIncludesArchiveAndForgetsFinalRemoval() throws {
        var archived = Agent(runtimeID: "claude", cwd: project, state: .archived,
                             archivedReason: .byUser)
        archived.labels = try SessionLabelPolicy.change(current: [], add: ["Perf"],
                                                        actor: .person, projectLabels: [])
        var elsewhere = Agent(runtimeID: "claude", cwd: URL(filePath: "/work/elsewhere"))
        elsewhere.labels = try SessionLabelPolicy.change(current: [], add: ["other"],
                                                         actor: .person, projectLabels: [])
        let listed = SessionLabelPolicy.vocabulary(in: project, agents: [archived, elsewhere])
        #expect(listed.map(\.value) == ["Perf"])
        archived.labels = []
        #expect(SessionLabelPolicy.vocabulary(in: project, agents: [archived, elsewhere]).isEmpty)
    }

    @Test func personCanTakeOwnershipButAgentCannotClaimPersonLabel() throws {
        let byAgent = try SessionLabelPolicy.change(current: [], add: ["urgent"],
                                                    actor: .agent, projectLabels: [])
        let byPerson = try SessionLabelPolicy.change(current: byAgent, add: ["URGENT"],
                                                     actor: .person, projectLabels: byAgent)
        #expect(byPerson.count == 1)
        #expect(byPerson[0].owner == .person)
        #expect(throws: SessionLabelPolicy.Refusal.self) {
            try SessionLabelPolicy.change(current: byPerson, add: ["urgent"],
                                          actor: .agent, projectLabels: byPerson)
        }
        #expect(throws: SessionLabelPolicy.Refusal.self) {
            try SessionLabelPolicy.change(current: byPerson, remove: [" UrGeNt "],
                                          actor: .agent, projectLabels: byPerson)
        }
    }
}
