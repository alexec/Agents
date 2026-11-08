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
     "changedBy":{"kind":"pr","ref":"github:alexec/agents#1234"}}
    """.utf8)

    @Test func readsWhatTheHostSends() throws {
        let m = try JSONDecoder().decode(DaemonAPI.Multiplier.self, from: Self.changed)
        #expect(m.prsMerged == 7)
        #expect(m.multiplier == 5)
        #expect(m.engineerHours == 200)
        #expect(m.baseline.source == "DX 2025")
        #expect(m.changedBy?.shortName == "#1234")
    }

    @Test func nothingCountedHasNoFigure() throws {
        let m = try JSONDecoder().decode(DaemonAPI.Multiplier.self, from: Data("""
        {"prsMerged":0,"reverts":0,"agentsWorking":0,"since":815000000,
         "baseline":{"prsPerWeek":1.4,"hoursPerWeek":40,"source":"DX 2025"}}
        """.utf8))
        #expect(m.multiplier == nil)
        #expect(m.engineerHours == nil)
    }

    @Test func writesWhatTheSchemaSays() throws {
        let schema = try WireSchema(WireSchemaTests.read("daemon.schema.json"))
        let written = try WireSchemaTests.through(DaemonAPI.Multiplier.self)(JSONValue.parse(Self.changed))
        #expect(schema.errors(written, against: "Multiplier").isEmpty)
    }

    @Test func aRefWithNoNumberIsItself() {
        #expect(DaemonAPI.LineageNode(kind: "pr", ref: "linear:ENG-4").shortName == "linear:ENG-4")
    }
}
