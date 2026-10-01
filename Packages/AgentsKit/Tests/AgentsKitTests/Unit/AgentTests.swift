import Foundation
import Testing
@testable import AgentsKitCore

@Suite("Agent labels on the record")
struct AgentTests {
    @Test func labelsRoundTripWithOwner() throws {
        let agent = Agent(runtimeID: "claude", cwd: URL(filePath: "/tmp/project"),
                          labels: [SessionLabel(value: "perf", owner: .person),
                                   SessionLabel(value: "#42", owner: .agent)])
        let read = try JSONDecoder().decode(Agent.self, from: JSONEncoder().encode(agent))
        #expect(read.labels.map(\.value) == ["perf", "#42"])
        #expect(read.labels.map(\.owner) == [.person, .agent])
    }

    @Test func oldRecordWithoutLabelsStaysReadable() throws {
        let agent = Agent(runtimeID: "claude", cwd: URL(filePath: "/tmp/project"))
        var record = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(agent))
            as? [String: Any])
        record.removeValue(forKey: "labels")
        record["aFutureField"] = "still here"
        let read = try JSONDecoder().decode(Agent.self,
                                             from: JSONSerialization.data(withJSONObject: record))
        #expect(read.labels.isEmpty)
        let written = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(read))
            as? [String: Any])
        #expect(written["aFutureField"] as? String == "still here")
    }
}
