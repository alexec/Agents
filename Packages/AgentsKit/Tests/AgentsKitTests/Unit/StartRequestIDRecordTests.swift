import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// The id a caller sends with a start so that a retry is not a second start, on the wire
/// and on the record, and what an older caller or an older record makes of it (029).
@Suite("A start's request id, on the wire and on the record")
struct StartRequestIDRecordTests {
    @Test func aStartFromBeforeThisFeatureHasNoRequestID() throws {
        let json = Data(#"{"runtimeID":"claude","cwd":"file:///tmp/","prompt":"Go"}"#.utf8)
        let request = try JSONDecoder().decode(DaemonAPI.StartRequest.self, from: json)
        #expect(request.requestID == nil)
    }

    @Test func theRequestIDSurvivesTheWire() throws {
        let id = UUID()
        let sent = DaemonAPI.StartRequest(runtimeID: "claude", cwd: URL(filePath: "/tmp"),
                                          prompt: "Go", requestID: id)
        let read = try JSONDecoder().decode(DaemonAPI.StartRequest.self,
                                            from: JSONEncoder().encode(sent))
        #expect(read.requestID == id)
    }

    @Test func theStartRequestIDSurvivesBeingSaved() throws {
        var agent = Agent(runtimeID: "claude", cwd: URL(filePath: "/tmp"))
        let id = UUID()
        agent.startRequestID = id
        let read = try StoreCoding.decoder.decode(Agent.self, from: StoreCoding.encoder.encode(agent))
        #expect(read.startRequestID == id)
    }

    @Test func aRecordFromBeforeThisFeatureHasNoStartRequestID() throws {
        let agent = Agent(runtimeID: "claude", cwd: URL(filePath: "/tmp"))
        let written = try StoreCoding.encoder.encode(agent)
        let json = try #require(try JSONSerialization.jsonObject(with: written) as? [String: Any])
        #expect(json["startRequestID"] == nil, "written only when there is one")
        #expect(try StoreCoding.decoder.decode(Agent.self, from: written).startRequestID == nil)
    }
}
