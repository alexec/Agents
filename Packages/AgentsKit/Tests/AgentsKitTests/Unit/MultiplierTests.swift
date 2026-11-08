import Foundation
import Testing
@testable import AgentsKitCore

/// The Multiplier as the host sends it (#3903) and the hero page reads it (#3904).
@Suite("Multiplier")
struct MultiplierTests {
    /// `multiplier/changed` after a merge, as agentsd writes it.
    static let changed = Data("""
    {"prsMerged":7,"reverts":1,"multiplier":5,"engineerHours":200,"agentsWorking":2,
     "since":815000000,"baseline":{"prsPerWeek":1.4,"hoursPerWeek":40,"source":"DX 2025"},
     "changedBy":{"kind":"pr","ref":"github:alexec/agents#1234"},"bestWeek":6.4,"mostAtOnce":9}
    """.utf8)

    @Test func readsWhatTheHostSends() throws {
        let m = try JSONDecoder().decode(DaemonAPI.Multiplier.self, from: Self.changed)
        #expect(m.prsMerged == 7)
        #expect(m.multiplier == 5)
        #expect(m.engineerHours == 200)
        #expect(m.baseline.source == "DX 2025")
        #expect(m.changedBy?.shortName == "#1234")
        #expect(m.bestWeek == 6.4)
        #expect(m.mostAtOnce == 9)
    }

    @Test func nothingCountedHasNoFigure() throws {
        let m = try JSONDecoder().decode(DaemonAPI.Multiplier.self, from: Data("""
        {"prsMerged":0,"reverts":0,"agentsWorking":0,"since":815000000,
         "baseline":{"prsPerWeek":1.4,"hoursPerWeek":40,"source":"DX 2025"}}
        """.utf8))
        #expect(m.multiplier == nil)
        #expect(m.engineerHours == nil)
        #expect(m.bestWeek == nil)
        #expect(m.mostAtOnce == nil)
    }

    @Test func writesWhatTheSchemaSays() throws {
        let schema = try WireSchema(WireSchemaTests.read("daemon.schema.json"))
        let written = try WireSchemaTests.through(DaemonAPI.Multiplier.self)(JSONValue.parse(Self.changed))
        #expect(schema.errors(written, against: "Multiplier").isEmpty)
    }

    /// The line under the figures (#3991): the person's own, else the default with their figure.
    @Test func theLineIsThePersonsOrTheDefault() throws {
        let own = try JSONDecoder().decode(DaemonAPI.MultiplierBaseline.self, from: Data("""
        {"prsPerWeek":2,"hoursPerWeek":40,"source":"DX 2025","line":"My team: 2 a week"}
        """.utf8))
        #expect(own.shownLine == "My team: 2 a week")
        let none = DaemonAPI.MultiplierBaseline(prsPerWeek: 2, hoursPerWeek: 40, source: "DX 2025")
        #expect(none.shownLine == "An average engineer merged 2 PRs a week (DX 2025)")
    }

    @Test func aRefWithNoNumberIsItself() {
        #expect(DaemonAPI.LineageNode(kind: "pr", ref: "linear:ENG-4").shortName == "linear:ENG-4")
    }
}
