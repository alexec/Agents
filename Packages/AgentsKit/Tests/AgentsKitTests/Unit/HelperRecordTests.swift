import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// What an agent started by another agent carries on its record, and what an older
/// build makes of it (028).
@Suite("An agent another agent started, on the record")
struct HelperRecordTests {
    @Test func whoStartedItSurvivesBeingSaved() throws {
        var agent = Agent(runtimeID: "claude", cwd: URL(filePath: "/tmp"))
        let starter = UUID()
        agent.startedByAgent = starter
        let read = try StoreCoding.decoder.decode(Agent.self, from: StoreCoding.encoder.encode(agent))
        #expect(read.startedByAgent == starter)
    }

    @Test func aRecordFromBeforeThisFeatureWasStartedByNoAgent() throws {
        let agent = Agent(runtimeID: "claude", cwd: URL(filePath: "/tmp"))
        let written = try StoreCoding.encoder.encode(agent)
        let json = try #require(try JSONSerialization.jsonObject(with: written) as? [String: Any])
        #expect(json["startedByAgent"] == nil, "written only when there is one")
        #expect(try StoreCoding.decoder.decode(Agent.self, from: written).startedByAgent == nil)
    }

    @Test func theNewEndingReadsAsItself() throws {
        let read = try JSONDecoder().decode(EndedReason.self, from: Data("\"stoppedByAgent\"".utf8))
        #expect(read == .stoppedByAgent)
        #expect(read.summary == "Stopped by the agent that started it")
    }

    @Test func theNewArchiveReasonReadsAsItselfAndAnUnknownOneIsStillArchived() throws {
        let decoder = JSONDecoder()
        #expect(try decoder.decode(Agent.ArchivedReason.self, from: Data("\"byAgent\"".utf8)) == .byAgent)
        #expect(try decoder.decode(Agent.ArchivedReason.self, from: Data("\"byMoonlight\"".utf8)) == .byUser)
    }

    /// Stopped by an agent is a stop like any other: the record's rules still hold.
    @Test func anAgentStoppedOrArchivedByAnotherIsConsistent() {
        var agent = Agent(runtimeID: "claude", cwd: URL(filePath: "/tmp"))
        agent.state = .stopped
        agent.endedReason = .stoppedByAgent
        #expect(agent.isConsistent)
        agent.state = .archived
        agent.archivedReason = .byAgent
        #expect(agent.isConsistent)
    }
}
