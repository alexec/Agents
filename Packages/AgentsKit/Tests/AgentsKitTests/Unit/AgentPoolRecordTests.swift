import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// What a chat that carries on keeps on its record (052): the pool entry it is on, and
/// its own switch.
@Suite("A chat's pool fields, on the record")
struct AgentPoolRecordTests {
    @Test func theyAreWrittenOnlyWhenSetAndSurviveBeingSaved() throws {
        let plain = Agent(runtimeID: "claude", cwd: URL(filePath: "/tmp/repo"))
        let json = try #require(try JSONSerialization.jsonObject(with: StoreCoding.encoder.encode(plain)) as? [String: Any])
        #expect(json["poolEntryID"] == nil && json["switchingOff"] == nil)

        var moved = plain
        moved.poolEntryID = UUID()
        moved.switchingOff = true
        let read = try StoreCoding.decoder.decode(Agent.self, from: StoreCoding.encoder.encode(moved))
        #expect(read.poolEntryID == moved.poolEntryID)
        #expect(read.switchingOff)
    }

    /// A record written before 052 has neither field: on the runtime it started with,
    /// with carrying on as the pool says.
    @Test func aRecordFromBeforeThePoolReadsAsNeverMoved() throws {
        var agent = Agent(runtimeID: "claude", cwd: URL(filePath: "/tmp/repo"))
        agent.poolEntryID = UUID()
        agent.switchingOff = true
        var json = try #require(try JSONSerialization.jsonObject(with: StoreCoding.encoder.encode(agent)) as? [String: Any])
        json["poolEntryID"] = nil
        json["switchingOff"] = nil
        let read = try StoreCoding.decoder.decode(Agent.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(read.poolEntryID == nil)
        #expect(!read.switchingOff)
    }

    /// An older daemon or phone reading a newer record reads past the two keys: the
    /// record is still the same chat, on the runtime it names.
    @Test func anOlderReaderReadsPastThem() throws {
        struct OlderAgent: Decodable { var id: UUID; var runtimeID: String }
        var agent = Agent(runtimeID: "codex", cwd: URL(filePath: "/tmp/repo"))
        agent.poolEntryID = UUID()
        agent.switchingOff = true
        let read = try StoreCoding.decoder.decode(OlderAgent.self, from: StoreCoding.encoder.encode(agent))
        #expect(read.id == agent.id && read.runtimeID == "codex")
    }
}
