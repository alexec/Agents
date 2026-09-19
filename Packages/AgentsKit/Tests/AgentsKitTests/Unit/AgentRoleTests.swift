import Foundation
import Testing
@testable import AgentsKit

/// Every agent record written before projects existed has to open, and open as a
/// worker. A record that arrived as something we do not recognise opens as a worker
/// too: that is the reading that takes no powers with it.
@Suite("Worker or lead")
struct AgentRoleTests {
    private let json = """
    {"id":"6B1C9E2A-6C1E-4E2E-9E6B-2A6C1E4E2E9E","runtimeID":"claude",\
    "cwd":"file:///Users/alex/work/api","state":"finished",\
    "createdAt":"2026-09-18T10:00:00.000Z","lastActivityAt":"2026-09-18T10:00:00.000Z",\
    "endedReason":"endTurn"
    """

    @Test func aRecordWithNoRoleIsAWorker() throws {
        let agent = try StoreCoding.decoder.decode(Agent.self, from: Data((json + "}").utf8))
        #expect(agent.role == .worker)
    }

    @Test func aRoleWeDoNotKnowIsAWorker() throws {
        let text = json + ",\"role\":\"overlord\"}"
        let agent = try StoreCoding.decoder.decode(Agent.self, from: Data(text.utf8))
        #expect(agent.role == .worker, "a newer build's role must not become a power here")
    }

    @Test func aLeadDecodesAsOne() throws {
        let text = json + ",\"role\":\"lead\"}"
        let agent = try StoreCoding.decoder.decode(Agent.self, from: Data(text.utf8))
        #expect(agent.role == .lead)
    }

    @Test func aWorkerWritesNoRoleAtAll() throws {
        let agent = Agent(runtimeID: "claude", cwd: URL(filePath: "/work/api"),
                          endedReason: .endTurn)
        let text = String(decoding: try StoreCoding.encoder.encode(agent), as: UTF8.self)
        #expect(!text.contains("role"), "the default is not worth a line in the file")
    }

    @Test func aLeadSurvivesARoundTrip() throws {
        let agent = Agent(runtimeID: "claude", cwd: URL(filePath: "/work/api"),
                          endedReason: .endTurn, role: .lead)
        let data = try StoreCoding.encoder.encode(agent)
        #expect(try StoreCoding.decoder.decode(Agent.self, from: data).role == .lead)
    }

    @Test func unknownFieldsAreStillKept() throws {
        let text = json + ",\"role\":\"lead\",\"somethingNewer\":{\"kept\":true}}"
        let agent = try StoreCoding.decoder.decode(Agent.self, from: Data(text.utf8))
        let out = String(decoding: try StoreCoding.encoder.encode(agent), as: UTF8.self)
        #expect(out.contains("somethingNewer"))
    }
}
